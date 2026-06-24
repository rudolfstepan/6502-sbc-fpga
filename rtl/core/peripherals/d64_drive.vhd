-- D64 drive: read-only D64 sector engine on top of a raw 512-byte SD read
-- channel (the sd2 data-disk port).
--
-- Given mount metadata (the .d64 file's start LBA, resolved by fat32_reader or
-- the boot menu) and a 6502 READ_SECTOR request (D64 track + sector), this
-- module:
--   1. maps track/sector -> linear index -> byte offset (d64_sector_map)
--   2. computes the SD LBA (file_start_lba + offset/512) and which 256-byte
--      half of that 512-byte block holds the wanted D64 sector
--   3. issues one SD block read, captures only the wanted half into a 256-byte
--      buffer, and signals done/error
--
-- It is a *master* on the SD read channel.  C3 adds an arbiter so it can share
-- the channel with the existing raw sd_disk_ctrl path; standalone it owns it.
--
-- DISK_RESULT codes used here match the shared contract:
--   $00 OK  $01 NO_IMAGE  $02 INVALID_TRACK  $03 INVALID_SECTOR  $04 SD_READ_ERROR
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity d64_drive is
  port (
    clk         : in  std_logic;
    reset_n     : in  std_logic;

    -- ── Mount control (from boot menu / fat32_reader) ──────────────────────
    mount        : in  std_logic;                      -- pulse: latch metadata, set mounted
    unmount      : in  std_logic;                      -- pulse: clear mounted
    file_start_lba : in std_logic_vector(31 downto 0); -- LBA of byte 0 of the .d64 file
    write_protect_in : in std_logic := '1';            -- v1 images are read-only

    -- ── Sector read request (from disk controller / 6502) ──────────────────
    rd_req      : in  std_logic;                       -- pulse: start a READ_SECTOR
    rd_track    : in  std_logic_vector(7 downto 0);    -- 1-based D64 track
    rd_sector   : in  std_logic_vector(7 downto 0);    -- 0-based D64 sector

    -- ── Status ─────────────────────────────────────────────────────────────
    busy        : out std_logic;                       -- command in progress
    done        : out std_logic;                       -- last command OK (level)
    error       : out std_logic;                       -- last command failed (level)
    mounted     : out std_logic;
    write_protect : out std_logic;
    result      : out std_logic_vector(7 downto 0);    -- DISK_RESULT code

    -- ── 256-byte sector buffer read port (to 6502) ─────────────────────────
    buf_addr    : in  std_logic_vector(7 downto 0);
    buf_data    : out std_logic_vector(7 downto 0);

    -- ── Raw SD read channel (to sd_card_top, via arbiter in C3) ────────────
    sd_sec_read            : out std_logic;
    sd_sec_read_addr       : out std_logic_vector(31 downto 0);
    sd_sec_read_data       : in  std_logic_vector(7 downto 0);
    sd_sec_read_data_valid : in  std_logic;
    sd_sec_read_end        : in  std_logic
  );
end entity;

architecture rtl of d64_drive is
  -- DISK_RESULT codes
  constant RES_OK            : std_logic_vector(7 downto 0) := x"00";
  constant RES_NO_IMAGE      : std_logic_vector(7 downto 0) := x"01";
  constant RES_INVALID_TRACK : std_logic_vector(7 downto 0) := x"02";
  constant RES_INVALID_SECT  : std_logic_vector(7 downto 0) := x"03";
  constant RES_SD_READ_ERROR : std_logic_vector(7 downto 0) := x"04";

  -- 256-byte sector buffer (synchronous read, single port to CPU).
  type buf_t is array (0 to 255) of std_logic_vector(7 downto 0);
  signal buf : buf_t := (others => (others => '0'));

  -- Mount metadata
  signal mounted_r   : std_logic := '0';
  signal start_lba   : unsigned(31 downto 0) := (others => '0');
  signal wp_r        : std_logic := '1';

  -- Mapper interface (combinational)
  signal map_valid   : std_logic;
  signal map_index   : std_logic_vector(9 downto 0);
  signal map_error   : std_logic_vector(7 downto 0);

  -- Computed SD location, latched at request time
  signal want_upper  : std_logic := '0';   -- '1' if wanted half is bytes 256..511
  signal target_lba  : unsigned(31 downto 0) := (others => '0');

  -- Stream capture
  signal byte_cnt    : unsigned(9 downto 0) := (others => '0');  -- 0..511
  signal buf_wr_idx  : unsigned(7 downto 0) := (others => '0');

  type state_t is (S_IDLE, S_REQ, S_STREAM, S_DONE, S_ERROR);
  signal state : state_t := S_IDLE;

  signal busy_r   : std_logic := '0';
  signal done_r   : std_logic := '0';
  signal error_r  : std_logic := '0';
  signal result_r : std_logic_vector(7 downto 0) := RES_OK;
  signal sd_read_r : std_logic := '0';
begin
  map_i : entity work.d64_sector_map
    port map (
      track        => rd_track,
      sector       => rd_sector,
      valid        => map_valid,
      sector_index => map_index,
      error_code   => map_error
    );

  busy          <= busy_r;
  done          <= done_r;
  error         <= error_r;
  mounted       <= mounted_r;
  write_protect <= wp_r;
  result        <= result_r;
  sd_sec_read   <= sd_read_r;
  sd_sec_read_addr <= std_logic_vector(target_lba);

  -- Synchronous CPU read port for the sector buffer.
  process(clk)
  begin
    if rising_edge(clk) then
      buf_data <= buf(to_integer(unsigned(buf_addr)));
    end if;
  end process;

  process(clk)
    -- byte offset = index * 256; block = offset / 512 = index / 2;
    -- half (upper) = bit 0 of index (odd index -> upper 256 bytes).
    variable idx_u : unsigned(9 downto 0);
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        mounted_r  <= '0';
        start_lba  <= (others => '0');
        wp_r       <= '1';
        state      <= S_IDLE;
        busy_r     <= '0';
        done_r     <= '0';
        error_r    <= '0';
        result_r   <= RES_OK;
        sd_read_r  <= '0';
        byte_cnt   <= (others => '0');
        buf_wr_idx <= (others => '0');
        want_upper <= '0';
        target_lba <= (others => '0');
      else
        sd_read_r <= '0';

        -- Mount / unmount take effect when idle.
        if state = S_IDLE then
          if unmount = '1' then
            mounted_r <= '0';
          elsif mount = '1' then
            mounted_r <= '1';
            start_lba <= unsigned(file_start_lba);
            wp_r      <= write_protect_in;
          end if;
        end if;

        case state is
          when S_IDLE =>
            if rd_req = '1' then
              -- Every command goes busy first, then resolves to done/error a
              -- cycle later, so a consumer always sees busy=1 before sampling
              -- the terminal done/error (no stale completion is observed).
              done_r  <= '0';
              error_r <= '0';
              busy_r  <= '1';
              if mounted_r = '0' then
                result_r <= RES_NO_IMAGE;
                state    <= S_ERROR;
              elsif map_valid = '0' then
                result_r <= map_error;  -- INVALID_TRACK or INVALID_SECTOR
                state    <= S_ERROR;
              else
                idx_u      := unsigned(map_index);
                -- target LBA = start_lba + index/2
                target_lba <= start_lba + resize(idx_u(9 downto 1), 32);
                want_upper <= idx_u(0);
                byte_cnt   <= (others => '0');
                buf_wr_idx <= (others => '0');
                state      <= S_REQ;
              end if;
            end if;

          when S_REQ =>
            sd_read_r <= '1';          -- one-cycle read strobe with target_lba
            state     <= S_STREAM;

          when S_STREAM =>
            if sd_sec_read_data_valid = '1' then
              -- Capture only the wanted 256-byte half.
              if want_upper = '0' then
                if byte_cnt < 256 then
                  buf(to_integer(buf_wr_idx)) <= sd_sec_read_data;
                  buf_wr_idx <= buf_wr_idx + 1;
                end if;
              else
                if byte_cnt >= 256 then
                  buf(to_integer(buf_wr_idx)) <= sd_sec_read_data;
                  buf_wr_idx <= buf_wr_idx + 1;
                end if;
              end if;
              byte_cnt <= byte_cnt + 1;
            end if;
            if sd_sec_read_end = '1' then
              state <= S_DONE;
            end if;

          when S_DONE =>
            busy_r   <= '0';
            done_r   <= '1';
            error_r  <= '0';
            result_r <= RES_OK;
            state    <= S_IDLE;

          when S_ERROR =>
            busy_r  <= '0';
            error_r <= '1';
            state   <= S_IDLE;

          when others =>
            state <= S_IDLE;
        end case;
      end if;
    end if;
  end process;
end architecture;
