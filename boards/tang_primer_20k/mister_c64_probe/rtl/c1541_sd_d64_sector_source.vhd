library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Raw SD-card D64 sector source for the Tang MiSTer C64 probe.
--
-- Version 1 deliberately avoids in-fabric FAT parsing to keep the MiSTer C64 +
-- 1541 + SID design inside the Tang 20K.  The default raw image stores one
-- 256-byte D64 sector in the lower half of each 512-byte SD block starting at
-- RAW_D64_LBA.  PACKED_D64_FILE instead treats RAW_D64_LBA as the start of a
-- normal contiguous .d64 file and selects the lower/upper SD-block half.
entity c1541_sd_d64_sector_source is
  generic (
    RAW_D64_LBA       : std_logic_vector(31 downto 0) := x"00000000";
    -- false: expanded raw layout, one D64 sector per SD block, lower half only.
    -- true:  normal contiguous .d64 file, two 256-byte D64 sectors per SD block.
    PACKED_D64_FILE    : boolean := false;
    SD_BYTE_ADDRESSING : boolean := false;
    CLK_HZ             : integer := 32000000;
    BAUD               : integer := 230400;
    DEBUG_UART         : boolean := false
  );
  port (
    clk     : in  std_logic;
    reset   : in  std_logic;                       -- synchronous, active-high

    track   : in  std_logic_vector(7 downto 0);    -- 1-based D64 track
    sector  : in  std_logic_vector(4 downto 0);    -- 0-based D64 sector
    offset  : in  std_logic_vector(7 downto 0);    -- 0..255 byte
    dout    : out std_logic_vector(7 downto 0);
    valid   : out std_logic;

    sd_init_done           : in  std_logic;
    sd_sec_read            : out std_logic;
    sd_sec_read_addr       : out std_logic_vector(31 downto 0);
    sd_sec_read_data       : in  std_logic_vector(7 downto 0);
    sd_sec_read_data_valid : in  std_logic;
    sd_sec_read_end        : in  std_logic;

    mount_lba    : in std_logic_vector(31 downto 0);
    mount_strobe : in std_logic;

    uart_tx : out std_logic
  );
end entity;

architecture rtl of c1541_sd_d64_sector_source is
  type sec_buf_t is array(0 to 255) of std_logic_vector(7 downto 0);
  signal sec_buf : sec_buf_t := (others => (others => '0'));
  -- '1' while the "loaded" sector is the all-zero placeholder for an illegal
  -- track/sector. Kept as a flag instead of bulk-clearing sec_buf: a whole-
  -- array write in one clock stops Gowin from extracting the buffer as RAM
  -- (256x8 falls into registers + muxes, >1.5k LUTs).
  signal blank_sector : std_logic := '0';

  type state_t is (
    S_WAIT_SD,
    S_MOUNT,
    S_READY,
    S_DRV_REQ,
    S_DRV_STARTED,
    S_DRV_WAIT,
    S_COPY_ADDR,
    S_COPY_WAIT,
    S_COPY_STORE
  );
  signal state : state_t := S_WAIT_SD;

  signal loaded_track  : std_logic_vector(7 downto 0) := (others => '1');
  signal loaded_sector : std_logic_vector(4 downto 0) := (others => '1');
  signal fetch_track   : std_logic_vector(7 downto 0) := (others => '0');
  signal fetch_sector  : std_logic_vector(4 downto 0) := (others => '0');
  signal req_change    : std_logic;

  signal mounted : std_logic := '0';
  signal map_valid : std_logic;
  signal map_index : std_logic_vector(9 downto 0);
  signal map_error : std_logic_vector(7 downto 0);
  signal active_d64_lba : unsigned(31 downto 0) := (others => '0');
  signal target_lba : unsigned(31 downto 0) := (others => '0');
  signal fetch_upper_half : std_logic := '0';
  signal raw_pos : unsigned(9 downto 0) := (others => '0');
  signal sd_read_r : std_logic := '0';
  signal copy_idx : unsigned(7 downto 0) := (others => '0');
  signal raw_valid_count : unsigned(9 downto 0) := (others => '0');

  type dbg_buf_t is array(0 to 15) of std_logic_vector(7 downto 0);
  signal dbg_buf : dbg_buf_t := (others => (others => '0'));
  signal dbg_pending : std_logic := '0';
  signal dbg_sent    : std_logic := '0';
  signal dbg_pos     : unsigned(6 downto 0) := (others => '0');
  signal utx_data    : std_logic_vector(7 downto 0) := x"00";
  signal utx_valid   : std_logic := '0';
  signal utx_ready   : std_logic;
  signal utx_busy    : std_logic;

  function hex_char(n : std_logic_vector(3 downto 0)) return std_logic_vector is
    variable u : unsigned(3 downto 0);
  begin
    u := unsigned(n);
    if u < 10 then
      return std_logic_vector(to_unsigned(48 + to_integer(u), 8));
    end if;
    return std_logic_vector(to_unsigned(55 + to_integer(u), 8));
  end function;

  function dbg_char(pos : unsigned(6 downto 0); b : dbg_buf_t) return std_logic_vector is
    variable p : integer;
    variable bi : integer;
    variable sub : integer;
  begin
    p := to_integer(pos);
    case p is
      when 0 => return x"53"; -- S
      when 1 => return x"44"; -- D
      when 2 => return x"20"; -- space
      when 3 => return x"54"; -- T
      when 4 => return x"31"; -- 1
      when 5 => return x"38"; -- 8
      when 6 => return x"53"; -- S
      when 7 => return x"30"; -- 0
      when 8 => return x"20"; -- space
      when others =>
        if p >= 9 and p < 57 then
          bi := (p - 9) / 3;
          sub := (p - 9) mod 3;
          if sub = 0 then
            return hex_char(b(bi)(7 downto 4));
          elsif sub = 1 then
            return hex_char(b(bi)(3 downto 0));
          else
            return x"20";
          end if;
        elsif p = 57 then
          return x"0D";
        elsif p = 58 then
          return x"0A";
        end if;
    end case;
    return x"00";
  end function;
begin
  dout <= (others => '0') when blank_sector = '1'
          else sec_buf(to_integer(unsigned(offset)));
  req_change <= '0' when (track = loaded_track and sector = loaded_sector) else '1';
  valid <= '1' when state = S_READY and req_change = '0' and mounted = '1' else '0';

  map_i : entity work.d64_sector_map
    port map (
      track        => fetch_track,
      sector       => "000" & fetch_sector,
      valid        => map_valid,
      sector_index => map_index,
      error_code   => map_error
    );

  sd_sec_read <= sd_read_r;
  sd_sec_read_addr <= std_logic_vector(target_lba(22 downto 0)) & "000000000" when SD_BYTE_ADDRESSING
                      else std_logic_vector(target_lba);

  gen_debug_uart : if DEBUG_UART generate
    tx_i : entity work.uart_tx_ser
      generic map (
        CLK_HZ => CLK_HZ,
        BAUD   => BAUD
      )
      port map (
        clk     => clk,
        reset_n => not reset,
        data    => utx_data,
        valid   => utx_valid,
        tx      => uart_tx,
        busy    => utx_busy
      );
    utx_ready <= not utx_busy;
  end generate;

  gen_no_debug_uart : if not DEBUG_UART generate
    uart_tx <= '1';
    utx_ready <= '0';
    utx_busy <= '0';
  end generate;

  process(clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then
        state <= S_WAIT_SD;
        mounted <= '0';
        sd_read_r <= '0';
        loaded_track <= (others => '1');
        loaded_sector <= (others => '1');
        fetch_track <= (others => '0');
        fetch_sector <= (others => '0');
        blank_sector <= '0';
        active_d64_lba <= unsigned(RAW_D64_LBA);
        target_lba <= (others => '0');
        fetch_upper_half <= '0';
        raw_pos <= (others => '0');
        copy_idx <= (others => '0');
        raw_valid_count <= (others => '0');
        dbg_buf <= (others => (others => '0'));
        dbg_pending <= '0';
        dbg_sent <= '0';
        dbg_pos <= (others => '0');
        utx_data <= x"00";
        utx_valid <= '0';
      else
        sd_read_r <= '0';
        utx_valid <= '0';

        if mount_strobe = '1' then
          active_d64_lba <= unsigned(mount_lba);
          mounted <= '1';
          sd_read_r <= '0';
          loaded_track <= (others => '1');
          loaded_sector <= (others => '1');
          if sd_init_done = '1' then
            state <= S_READY;
          else
            state <= S_WAIT_SD;
          end if;
        else
        case state is
          when S_WAIT_SD =>
            if sd_init_done = '1' then
              state <= S_MOUNT;
            end if;

          when S_MOUNT =>
            mounted <= '1';
            loaded_track <= (others => '1');
            loaded_sector <= (others => '1');
            state <= S_READY;

          when S_READY =>
            if mounted = '1' and req_change = '1' then
              fetch_track <= track;
              fetch_sector <= sector;
              state <= S_DRV_REQ;
            end if;

          when S_DRV_REQ =>
            if map_valid = '1' then
              if PACKED_D64_FILE then
                target_lba <= active_d64_lba
                            + resize(unsigned(map_index(9 downto 1)), 32);
                fetch_upper_half <= map_index(0);
              else
                target_lba <= active_d64_lba + resize(unsigned(map_index), 32);
                fetch_upper_half <= '0';
              end if;
              raw_pos <= (others => '0');
              copy_idx <= (others => '0');
              raw_valid_count <= (others => '0');
              dbg_buf <= (others => (others => '0'));
              blank_sector <= '0';
              state <= S_DRV_STARTED;
            else
              -- Illegal track/sector: serve an all-zero sector via the
              -- blank_sector flag (see declaration for why no bulk clear).
              blank_sector <= '1';
              loaded_track <= fetch_track;
              loaded_sector <= fetch_sector;
              state <= S_READY;
            end if;

          when S_DRV_STARTED =>
            sd_read_r <= '1';
            state <= S_DRV_WAIT;

          when S_DRV_WAIT =>
            if sd_sec_read_data_valid = '1' then
              if raw_pos(8) = fetch_upper_half then
                sec_buf(to_integer(raw_pos(7 downto 0))) <= sd_sec_read_data;
                if raw_pos(7 downto 0) >= 2 and raw_pos(7 downto 0) < 16 then
                  dbg_buf(to_integer(raw_pos(3 downto 0))) <= sd_sec_read_data;
                end if;
              end if;
              raw_pos <= raw_pos + 1;
              raw_valid_count <= raw_valid_count + 1;
            end if;
            if sd_sec_read_end = '1' then
              loaded_track <= fetch_track;
              loaded_sector <= fetch_sector;
              state <= S_READY;
            end if;

          when others =>
            state <= S_WAIT_SD;
        end case;
        end if;

        if dbg_pending = '1' and utx_ready = '1' and utx_valid = '0' then
          utx_data <= dbg_char(dbg_pos, dbg_buf);
          utx_valid <= '1';
          if dbg_pos = to_unsigned(58, dbg_pos'length) then
            dbg_pending <= '0';
          else
            dbg_pos <= dbg_pos + 1;
          end if;
        end if;
      end if;
    end if;
  end process;
end architecture;
