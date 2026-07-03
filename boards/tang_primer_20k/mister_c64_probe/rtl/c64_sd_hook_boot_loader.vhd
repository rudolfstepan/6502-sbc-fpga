library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Standalone boot loader for the resident C64 SD hook.
--
-- After reset the C64 core is held paused while this FSM waits for the SD
-- card, reads the hook image from a fixed LBA in the unpartitioned gap
-- before the FAT16 partition, and streams it into C64 RAM.  The patched
-- KERNAL then finds the hook signature on the first LOAD; no UART upload
-- and no RUN are needed.
--
-- SD-card initialization time at the slow SPI clock is hard to bound, so
-- the C64 is only held for HOLD_MS.  If the card is not ready by then the
-- C64 boots normally and the FSM keeps waiting; when sd_init_done finally
-- arrives it briefly re-pauses the C64 (the copy takes a few milliseconds)
-- and installs the hook late.  That also covers a card inserted after
-- power-on.  A stalled transfer is retried from block 0 up to RETRY_MAX
-- attempts.
--
-- On-card image format, written by tools/d64/make_fat16_d64_card.py
-- (--hook-image), starting at HOOK_LBA:
--   bytes 0-7    magic "C64HOOK1"
--   bytes 8-9    load address, little-endian (normally $C000)
--   bytes 10-11  payload length, little-endian
--   bytes 12-15  reserved, zero
--   bytes 16..   payload, continuing through following blocks
--
-- The first payload byte (the hook's JMP signature opcode) is written last,
-- so an interrupted copy never leaves a half image that the KERNAL guard
-- stub would mistake for a valid hook.
--
-- status output (readable at $DF06 in the C64 I/O2 window):
--   bit0  done: the loader finished (successfully or not)
--   bit1  success: hook copied and signature byte written
--   bit2  header seen: magic + sane length parsed
--   bit3  gave up: bad header or all copy attempts timed out
--   bit4  sd_init_done was observed
--   bit7:5 copy attempts started
entity c64_sd_hook_boot_loader is
  generic (
    HOOK_LBA   : std_logic_vector(31 downto 0) := x"00000008";
    -- Maximum payload accepted (the hook RAM window is $C000-$CFFF).
    MAX_LEN    : integer := 4096;
    CLK_HZ     : integer := 31500000;
    -- Hold the C64 in pause at power-up for at most this long.
    HOLD_MS    : integer := 2000;
    -- Per-attempt copy watchdog and gap before a retry.
    COPY_MS    : integer := 1000;
    RETRY_GAP_MS : integer := 10;
    RETRY_MAX  : integer := 3
  );
  port (
    clk     : in  std_logic;
    reset_n : in  std_logic;

    sd_init_done           : in  std_logic;
    sd_sec_read            : out std_logic;
    sd_sec_read_addr       : out std_logic_vector(31 downto 0);
    sd_sec_read_data       : in  std_logic_vector(7 downto 0);
    sd_sec_read_data_valid : in  std_logic;
    sd_sec_read_end        : in  std_logic;

    -- Direct C64 RAM write port, valid while active = '1'.
    mem_we    : out std_logic;
    mem_addr  : out std_logic_vector(15 downto 0);
    mem_wdata : out std_logic_vector(7 downto 0);

    active : out std_logic;   -- '1': keep the C64 paused, own the RAM port
    done   : out std_logic;
    status : out std_logic_vector(7 downto 0)
  );
end entity;

architecture rtl of c64_sd_hook_boot_loader is
  constant HOLD_MAX  : integer := (CLK_HZ / 1000) * HOLD_MS;
  constant COPY_MAX  : integer := (CLK_HZ / 1000) * COPY_MS;
  constant GAP_MAX   : integer := (CLK_HZ / 1000) * RETRY_GAP_MS;

  type magic_t is array (0 to 7) of std_logic_vector(7 downto 0);
  constant MAGIC : magic_t := (
    x"43", x"36", x"34", x"48", x"4F", x"4F", x"4B", x"31");  -- "C64HOOK1"

  type state_t is (S_WAIT_SD, S_REQ, S_STREAM, S_NEXT, S_RETRY,
                   S_FINALIZE, S_DONE);
  signal state : state_t := S_WAIT_SD;

  signal hold_cnt   : integer range 0 to HOLD_MAX := 0;
  signal copy_cnt   : integer range 0 to COPY_MAX := 0;
  signal gap_cnt    : integer range 0 to GAP_MAX := 0;
  signal attempts   : unsigned(2 downto 0) := (others => '0');
  signal block_idx  : unsigned(7 downto 0) := (others => '0');
  signal byte_pos   : unsigned(9 downto 0) := (others => '0');
  signal magic_ok   : std_logic := '1';
  signal load_addr  : unsigned(15 downto 0) := (others => '0');
  signal length     : unsigned(15 downto 0) := (others => '0');
  signal have_len   : std_logic := '0';
  signal pay_idx    : unsigned(15 downto 0) := (others => '0');
  signal first_byte : std_logic_vector(7 downto 0) := (others => '0');

  signal sd_read_r  : std_logic := '0';
  signal mem_we_r   : std_logic := '0';
  signal mem_addr_r : unsigned(15 downto 0) := (others => '0');
  signal mem_data_r : std_logic_vector(7 downto 0) := (others => '0');
  signal active_r   : std_logic := '1';
  signal done_r     : std_logic := '0';
  signal st_success : std_logic := '0';
  signal st_header  : std_logic := '0';
  signal st_giveup  : std_logic := '0';
  signal st_sd_seen : std_logic := '0';
begin
  sd_sec_read <= sd_read_r;
  sd_sec_read_addr <= std_logic_vector(unsigned(HOOK_LBA) + resize(block_idx, 32));
  mem_we <= mem_we_r;
  mem_addr <= std_logic_vector(mem_addr_r);
  mem_wdata <= mem_data_r;
  active <= active_r;
  done <= done_r;
  status <= std_logic_vector(attempts) & st_sd_seen & st_giveup & st_header
            & st_success & done_r;

  process(clk)
    variable pos : integer range 0 to 1023;
  begin
    if rising_edge(clk) then
      sd_read_r <= '0';
      mem_we_r <= '0';
      if reset_n = '0' then
        state <= S_WAIT_SD;
        hold_cnt <= 0;
        copy_cnt <= 0;
        gap_cnt <= 0;
        attempts <= (others => '0');
        block_idx <= (others => '0');
        byte_pos <= (others => '0');
        magic_ok <= '1';
        load_addr <= (others => '0');
        length <= (others => '0');
        have_len <= '0';
        pay_idx <= (others => '0');
        first_byte <= (others => '0');
        active_r <= '1';
        done_r <= '0';
        st_success <= '0';
        st_header <= '0';
        st_giveup <= '0';
        st_sd_seen <= '0';
      else
        case state is
          when S_WAIT_SD =>
            -- Wait for the card as long as it takes, but stop holding the
            -- C64 hostage after HOLD_MS: a late (or later inserted) card
            -- re-pauses the C64 for the few milliseconds the copy needs.
            if sd_init_done = '1' then
              st_sd_seen <= '1';
              active_r <= '1';
              attempts <= attempts + 1;
              block_idx <= (others => '0');
              pay_idx <= (others => '0');
              magic_ok <= '1';
              have_len <= '0';
              copy_cnt <= 0;
              state <= S_REQ;
            elsif hold_cnt = HOLD_MAX then
              active_r <= '0';
            else
              hold_cnt <= hold_cnt + 1;
            end if;

          when S_REQ =>
            sd_read_r <= '1';
            byte_pos <= (others => '0');
            state <= S_STREAM;

          when S_STREAM =>
            if sd_sec_read_data_valid = '1' then
              byte_pos <= byte_pos + 1;
              pos := to_integer(byte_pos);
              if block_idx = 0 and pos <= 15 then
                case pos is
                  when 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 =>
                    if sd_sec_read_data /= MAGIC(pos) then
                      magic_ok <= '0';
                    end if;
                  when 8 =>
                    load_addr(7 downto 0) <= unsigned(sd_sec_read_data);
                  when 9 =>
                    load_addr(15 downto 8) <= unsigned(sd_sec_read_data);
                  when 10 =>
                    length(7 downto 0) <= unsigned(sd_sec_read_data);
                  when 11 =>
                    length(15 downto 8) <= unsigned(sd_sec_read_data);
                    have_len <= '1';
                  when others =>
                    null;
                end case;
              elsif magic_ok = '1' and have_len = '1'
                    and pay_idx < length then
                if pay_idx = 0 then
                  first_byte <= sd_sec_read_data;  -- signature goes in last
                else
                  mem_we_r <= '1';
                  mem_addr_r <= load_addr + pay_idx;
                  mem_data_r <= sd_sec_read_data;
                end if;
                pay_idx <= pay_idx + 1;
              end if;
            end if;
            if sd_sec_read_end = '1' then
              state <= S_NEXT;
            end if;

          when S_NEXT =>
            if magic_ok = '0' or have_len = '0'
               or to_integer(length) = 0
               or to_integer(length) > MAX_LEN then
              -- A bad or missing header is permanent; retrying will read
              -- the same bytes again.
              st_giveup <= '1';
              state <= S_DONE;
            elsif pay_idx >= length then
              st_header <= '1';
              state <= S_FINALIZE;
            else
              st_header <= '1';
              block_idx <= block_idx + 1;
              state <= S_REQ;
            end if;

          when S_RETRY =>
            -- Let a possibly still-streaming stale transfer drain before
            -- the next attempt; its bytes are ignored here.
            if gap_cnt = GAP_MAX then
              gap_cnt <= 0;
              attempts <= attempts + 1;
              block_idx <= (others => '0');
              pay_idx <= (others => '0');
              magic_ok <= '1';
              have_len <= '0';
              copy_cnt <= 0;
              state <= S_REQ;
            else
              gap_cnt <= gap_cnt + 1;
            end if;

          when S_FINALIZE =>
            mem_we_r <= '1';
            mem_addr_r <= load_addr;
            mem_data_r <= first_byte;
            st_success <= '1';
            state <= S_DONE;

          when S_DONE =>
            active_r <= '0';
            done_r <= '1';
        end case;

        -- Per-attempt copy watchdog: a hung transfer is retried a few
        -- times, then the C64 is released without the hook.
        if state = S_REQ or state = S_STREAM or state = S_NEXT then
          if copy_cnt = COPY_MAX then
            if to_integer(attempts) >= RETRY_MAX then
              st_giveup <= '1';
              state <= S_DONE;
            else
              state <= S_RETRY;
            end if;
          else
            copy_cnt <= copy_cnt + 1;
          end if;
        end if;
      end if;
    end if;
  end process;
end architecture;
