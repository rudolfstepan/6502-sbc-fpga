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
--
-- With SD_WRITE_ENABLE the source also flushes decoded 1541 write bursts back
-- to the card: the GCR engine streams the 256 data bytes into wr_buf, then
-- wr_commit triggers a read-modify-write of the containing 512-byte block
-- (the untouched half is preserved).  wr_busy freezes the GCR engine while
-- the flush is in flight.
entity c1541_sd_d64_sector_source is
  generic (
    RAW_D64_LBA       : std_logic_vector(31 downto 0) := x"00000000";
    -- false: expanded raw layout, one D64 sector per SD block, lower half only.
    -- true:  normal contiguous .d64 file, two 256-byte D64 sectors per SD block.
    PACKED_D64_FILE    : boolean := false;
    SD_BYTE_ADDRESSING : boolean := false;
    -- true enables the write-back path (decoded 1541 writes are flushed to the
    -- card as a read-modify-write of the 512-byte block).  Boards that do not
    -- wire the sd_sec_write channel MUST leave this false: commits are then
    -- silently dropped instead of hanging the drive on a dead write channel.
    SD_WRITE_ENABLE    : boolean := false;
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

    -- Decoded write-byte stream from the GCR engine.  Bytes are collected in
    -- a separate 256-byte buffer; wr_commit (after byte 255) flushes it to
    -- the card.  wr_busy='1' while flushing -> freeze the GCR engine.
    wr_en     : in  std_logic := '0';
    wr_offset : in  std_logic_vector(7 downto 0) := (others => '0');
    wr_data   : in  std_logic_vector(7 downto 0) := (others => '0');
    wr_commit : in  std_logic := '0';
    wr_busy   : out std_logic;

    sd_init_done           : in  std_logic;
    sd_sec_read            : out std_logic;
    sd_sec_read_addr       : out std_logic_vector(31 downto 0);
    sd_sec_read_data       : in  std_logic_vector(7 downto 0);
    sd_sec_read_data_valid : in  std_logic;
    sd_sec_read_end        : in  std_logic;

    -- Raw SD write channel (wired only when SD_WRITE_ENABLE).
    sd_sec_write           : out std_logic;
    sd_sec_write_addr      : out std_logic_vector(31 downto 0);
    sd_sec_write_data      : out std_logic_vector(7 downto 0);
    sd_sec_write_data_req  : in  std_logic := '0';
    sd_sec_write_end       : in  std_logic := '0';

    mount_lba    : in std_logic_vector(31 downto 0);
    mount_strobe : in std_logic;

    disk_id1 : out std_logic_vector(7 downto 0);
    disk_id2 : out std_logic_vector(7 downto 0);

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
    S_COPY_STORE,
    -- Write-back flush: map the written track/sector, read the 512-byte block
    -- to capture the untouched half, then write the block back with wr_buf in
    -- the written half.
    S_WR_MAP,
    S_WR_RMW_START,
    S_WR_RMW_WAIT,
    S_WR_ISSUE,
    S_WR_STREAM
  );
  signal state : state_t := S_WAIT_SD;

  signal loaded_track  : std_logic_vector(7 downto 0) := (others => '1');
  signal loaded_sector : std_logic_vector(4 downto 0) := (others => '1');
  signal fetch_track   : std_logic_vector(7 downto 0) := (others => '0');
  signal fetch_sector  : std_logic_vector(4 downto 0) := (others => '0');
  signal req_change    : std_logic;
  signal id_fetch      : std_logic := '0';
  signal disk_id1_r    : std_logic_vector(7 downto 0) := x"54";
  signal disk_id2_r    : std_logic_vector(7 downto 0) := x"50";

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

  -- Write-back path.  wr_buf collects the decoded data block; during the flush
  -- the RMW pre-read parks the untouched half of the SD block in sec_buf
  -- (whose loaded sector is invalidated afterwards, so a following DOS verify
  -- refetches the freshly written data from the card).
  type wr_buf_t is array(0 to 255) of std_logic_vector(7 downto 0);
  signal wr_buf : wr_buf_t := (others => (others => '0'));
  signal wr_commit_pend : std_logic := '0';
  signal wr_track  : std_logic_vector(7 downto 0) := (others => '0');
  signal wr_sector : std_logic_vector(4 downto 0) := (others => '0');
  signal wr_upper_half : std_logic := '0';
  signal wr_widx   : unsigned(9 downto 0) := (others => '0');
  signal wr_out    : std_logic_vector(7 downto 0) := (others => '0');
  signal sd_write_r : std_logic := '0';
  -- ~0.62 s at 27 MHz, well above a worst-case SPI block write incl. card busy.
  signal wr_guard  : unsigned(23 downto 0) := (others => '0');

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
  -- Single async read port per buffer (a second read port stops Gowin from
  -- extracting the 256x8 arrays as SSRAM and costs >1.5k LUTs each).  The
  -- flush states borrow sec_buf's port via the address mux; dout is unused
  -- then (the GCR engine is frozen and valid is low).
  signal sec_rd_addr : std_logic_vector(7 downto 0);
  signal sec_buf_rd  : std_logic_vector(7 downto 0);
  signal wr_buf_rd   : std_logic_vector(7 downto 0);

  -- Single write port for sec_buf.  Both capture paths (sector fetch and the
  -- RMW pre-read of a flush) store sd_sec_read_data at raw_pos and differ only
  -- in which block half they keep, so the write is one statement gated by this
  -- enable.  Two textual writes in different FSM branches made the synthesizer
  -- fall back from SSRAM to registers+muxes (~2k LUTs).
  signal sec_wr_en : std_logic;
begin
  sec_wr_en <= '1' when sd_sec_read_data_valid = '1'
                    and ((state = S_DRV_WAIT     and raw_pos(8) = fetch_upper_half)
                      or (state = S_WR_RMW_WAIT and raw_pos(8) /= wr_upper_half))
               else '0';
  sec_rd_addr <= std_logic_vector(wr_widx(7 downto 0))
                 when (state = S_WR_ISSUE or state = S_WR_STREAM) else offset;
  sec_buf_rd <= sec_buf(to_integer(unsigned(sec_rd_addr)));
  wr_buf_rd  <= wr_buf(to_integer(wr_widx(7 downto 0)));

  dout <= (others => '0') when blank_sector = '1'
          else sec_buf_rd;
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

  sd_sec_write <= sd_write_r;
  sd_sec_write_addr <= std_logic_vector(target_lba(22 downto 0)) & "000000000" when SD_BYTE_ADDRESSING
                       else std_logic_vector(target_lba);
  sd_sec_write_data <= wr_out;
  disk_id1 <= disk_id1_r;
  disk_id2 <= disk_id2_r;

  -- Freeze the GCR engine (write mode) while a flush is pending or running.
  wr_busy <= '1' when wr_commit_pend = '1'
                   or state = S_WR_MAP or state = S_WR_RMW_START
                   or state = S_WR_RMW_WAIT or state = S_WR_ISSUE
                   or state = S_WR_STREAM
             else '0';

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
        sd_write_r <= '0';
        wr_commit_pend <= '0';
        wr_track <= (others => '0');
        wr_sector <= (others => '0');
        wr_upper_half <= '0';
        wr_widx <= (others => '0');
        wr_out <= (others => '0');
        wr_guard <= (others => '0');
        loaded_track <= (others => '1');
        loaded_sector <= (others => '1');
        fetch_track <= (others => '0');
        fetch_sector <= (others => '0');
        id_fetch <= '0';
        disk_id1_r <= x"54";
        disk_id2_r <= x"50";
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
        sd_write_r <= '0';
        utx_valid <= '0';

        -- sec_buf single write port (see sec_wr_en above).
        if sec_wr_en = '1' then
          sec_buf(to_integer(raw_pos(7 downto 0))) <= sd_sec_read_data;
        end if;

        -- Collect decoded write bytes (independent of the FSM: the burst runs
        -- in real time against the virtual head, never against the SD card).
        if wr_en = '1' then
          wr_buf(to_integer(unsigned(wr_offset))) <= wr_data;
        end if;
        if SD_WRITE_ENABLE and wr_commit = '1' then
          wr_commit_pend <= '1';
          wr_track  <= track;
          wr_sector <= sector;
        end if;

        -- Registered read of the outgoing flush byte; the SD controller
        -- samples one cycle after its request, matching this 1-cycle mux.
        -- (sec_buf_rd follows wr_widx in the flush states via sec_rd_addr.)
        if wr_widx(8) = wr_upper_half then
          wr_out <= wr_buf_rd;
        else
          wr_out <= sec_buf_rd;
        end if;

        if mount_strobe = '1' then
          -- Remount aborts any pending/running flush (the freshly selected
          -- image should not receive a write burst aimed at the old one).
          active_d64_lba <= unsigned(mount_lba);
          mounted <= '1';
          sd_read_r <= '0';
          wr_commit_pend <= '0';
          loaded_track <= (others => '1');
          loaded_sector <= (others => '1');
          id_fetch <= '0';
          disk_id1_r <= x"54";
          disk_id2_r <= x"50";
          if sd_init_done = '1' then
            fetch_track <= x"12";
            fetch_sector <= "00000";
            id_fetch <= '1';
            state <= S_DRV_REQ;
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
            fetch_track <= x"12";
            fetch_sector <= "00000";
            id_fetch <= '1';
            state <= S_DRV_REQ;

          when S_READY =>
            -- A pending write flush beats a new fetch: the freshly written
            -- data must reach the card before any reread of that sector.
            if wr_commit_pend = '1' then
              wr_commit_pend <= '0';
              if mounted = '1' then
                fetch_track  <= wr_track;
                fetch_sector <= wr_sector;
                wr_guard <= (others => '0');
                state <= S_WR_MAP;
              end if;
            elsif mounted = '1' and req_change = '1' then
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
              id_fetch <= '0';
              state <= S_READY;
            end if;

          when S_DRV_STARTED =>
            sd_read_r <= '1';
            state <= S_DRV_WAIT;

          when S_DRV_WAIT =>
            -- (the sec_buf capture itself happens through the shared single
            -- write port above, gated by sec_wr_en)
            if sd_sec_read_data_valid = '1' then
              if raw_pos(8) = fetch_upper_half then
                if id_fetch = '1' and raw_pos(7 downto 0) = to_unsigned(16#A2#, 8) then
                  disk_id1_r <= sd_sec_read_data;
                elsif id_fetch = '1' and raw_pos(7 downto 0) = to_unsigned(16#A3#, 8) then
                  disk_id2_r <= sd_sec_read_data;
                end if;
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
              id_fetch <= '0';
              state <= S_READY;
            end if;

          -- ── Write-back flush ─────────────────────────────────────────────
          when S_WR_MAP =>
            wr_guard <= wr_guard + 1;
            if map_valid = '1' then
              if PACKED_D64_FILE then
                target_lba <= active_d64_lba
                            + resize(unsigned(map_index(9 downto 1)), 32);
                wr_upper_half <= map_index(0);
              else
                target_lba <= active_d64_lba + resize(unsigned(map_index), 32);
                wr_upper_half <= '0';
              end if;
              raw_pos <= (others => '0');
              state <= S_WR_RMW_START;
            else
              -- The DOS never writes an illegal track/sector; drop defensively.
              state <= S_READY;
            end if;

          when S_WR_RMW_START =>
            sd_read_r <= '1';
            state <= S_WR_RMW_WAIT;

          when S_WR_RMW_WAIT =>
            -- Park only the half we do NOT overwrite (via the shared sec_buf
            -- write port, gated by sec_wr_en); sec_buf is repurposed as
            -- scratch and its loaded sector invalidated after the flush.
            wr_guard <= wr_guard + 1;
            if sd_sec_read_data_valid = '1' then
              raw_pos <= raw_pos + 1;
            end if;
            if sd_sec_read_end = '1' then
              wr_widx <= (others => '0');
              state <= S_WR_ISSUE;
            elsif wr_guard = (wr_guard'range => '1') then
              loaded_track  <= (others => '1');
              loaded_sector <= (others => '1');
              state <= S_READY;
            end if;

          when S_WR_ISSUE =>
            sd_write_r <= '1';
            state <= S_WR_STREAM;

          when S_WR_STREAM =>
            wr_guard <= wr_guard + 1;
            if sd_sec_write_data_req = '1' then
              wr_widx <= wr_widx + 1;
            end if;
            if sd_sec_write_end = '1'
               or wr_guard = (wr_guard'range => '1') then
              -- Invalidate the buffered sector: a following DOS verify then
              -- refetches the sector from the card (which now holds the new
              -- data), instead of reading a stale buffer.
              loaded_track  <= (others => '1');
              loaded_sector <= (others => '1');
              blank_sector  <= '0';
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
