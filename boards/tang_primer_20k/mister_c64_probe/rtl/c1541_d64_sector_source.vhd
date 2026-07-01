-- SDRAM-backed D64 sector source for the Tang MiSTer C64 probe.
--
-- Drop-in replacement for the combinational c1541_static_d64_image: it presents
-- the same logical disk interface
--
--     track / sector / offset  ->  byte
--
-- but serves the bytes of a real .d64 image held in external SDRAM.  Because the
-- surrounding c1541_static_dir_gcr streams one sector at a time (offset 0..255,
-- then sector++), a single 256-byte sector buffer is enough.  The buffer is
-- distributed/LUT RAM, so this module costs no BSRAM (the C64 core already uses
-- 46/46 blocks).
--
-- Prefetch model: when (track,sector) changes, `valid` drops and the FSM streams
-- the new 256-byte sector from SDRAM into the buffer.  c1541_static_dir_gcr
-- freezes its bit clock while `valid` is low (long SYNC/gap phase), so the refill
-- latency is hidden and never corrupts a sector.
--
-- SDRAM read handshake (decoupled, controller-agnostic):
--   * hold `sdram_rd` high with `sdram_addr` until `sdram_rd and sdram_ready`;
--     that cycle the request is accepted;
--   * later, `sdram_valid` high marks `sdram_q` as the data for the accepted read.
--   For a simple single-cycle controller, register `sdram_valid`/`sdram_q` one
--   cycle after the accept.  Adapt the native rtl/core/mem/sdram_ctrl.vhd port
--   names in the top-level wrapper.  Any physical SDRAM base offset is added in
--   that adapter; this module addresses the .d64 from D64_BASE (default 0).
--
-- The linear layout matches rtl/core/peripherals/d64_sector_map.vhd and
-- tools/d64/d64_common.py: byte = D64_BASE + sector_index*256 + offset.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity c1541_d64_sector_source is
  generic (
    D64_BASE : natural := 0  -- byte address of the .d64 in SDRAM
  );
  port (
    clk     : in  std_logic;
    reset   : in  std_logic;

    -- Logical disk request (same contract as c1541_static_d64_image).
    track   : in  std_logic_vector(7 downto 0);  -- 1-based D64 track (1..35)
    sector  : in  std_logic_vector(4 downto 0);  -- 0-based sector in the track
    offset  : in  std_logic_vector(7 downto 0);  -- 0..255 byte in the sector
    dout    : out std_logic_vector(7 downto 0);  -- buffer(offset)
    valid   : out std_logic;                     -- buffered sector matches request

    -- Simple SDRAM read port.
    sdram_addr  : out std_logic_vector(22 downto 0);
    sdram_rd    : out std_logic;
    sdram_q     : in  std_logic_vector(7 downto 0);
    sdram_valid : in  std_logic;
    sdram_ready : in  std_logic
  );
end entity;

architecture rtl of c1541_d64_sector_source is
  -- 256-byte sector buffer -> distributed/LUT RAM (no BSRAM).
  type buf_t is array(0 to 255) of std_logic_vector(7 downto 0);
  signal sec_buf : buf_t := (others => (others => '0'));

  type state_t is (SERVE, FILL);
  signal state : state_t := SERVE;

  -- (track,sector) currently held in the buffer.  Reset to an impossible value
  -- so the first real request always forces a fill.
  signal loaded_track  : std_logic_vector(7 downto 0) := (others => '1');
  signal loaded_sector : std_logic_vector(4 downto 0) := (others => '1');
  signal fill_track    : std_logic_vector(7 downto 0) := (others => '0');
  signal fill_sector   : std_logic_vector(4 downto 0) := (others => '0');
  signal base_addr     : unsigned(22 downto 0) := (others => '0');
  signal fill_idx      : unsigned(8 downto 0)  := (others => '0');
  signal req_pending   : std_logic := '0';
  signal rd_int        : std_logic := '0';

  signal req_change : std_logic;

  -- Linear sector index, identical to d64_sector_map.vhd (35-track image).
  function sector_index(t : std_logic_vector(7 downto 0);
                        s : std_logic_vector(4 downto 0)) return natural is
    variable ti : integer := to_integer(unsigned(t));
    variable si : integer := to_integer(unsigned(s));
  begin
    if    ti >= 1  and ti <= 17 then return (ti - 1) * 21 + si;
    elsif ti >= 18 and ti <= 24 then return 357 + (ti - 18) * 19 + si;
    elsif ti >= 25 and ti <= 30 then return 490 + (ti - 25) * 18 + si;
    elsif ti >= 31 and ti <= 35 then return 598 + (ti - 31) * 17 + si;
    else  return 0;  -- out of range: harmless, `valid` still gates the use
    end if;
  end function;
begin
  dout <= sec_buf(to_integer(unsigned(offset)));

  req_change <= '0' when (track = loaded_track and sector = loaded_sector)
                     else '1';
  valid    <= '1' when (state = SERVE and req_change = '0') else '0';
  sdram_rd <= rd_int;

  process(clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then
        state         <= SERVE;
        loaded_track  <= (others => '1');
        loaded_sector <= (others => '1');
        fill_track    <= (others => '0');
        fill_sector   <= (others => '0');
        base_addr     <= (others => '0');
        fill_idx      <= (others => '0');
        req_pending   <= '0';
        rd_int        <= '0';
        sdram_addr    <= (others => '0');
      else
        case state is
          when SERVE =>
            rd_int <= '0';
            if req_change = '1' then
              fill_track  <= track;
              fill_sector <= sector;
              base_addr   <= to_unsigned(D64_BASE
                                         + sector_index(track, sector) * 256, 23);
              fill_idx    <= (others => '0');
              req_pending <= '0';
              state       <= FILL;
            end if;

          when FILL =>
            if req_pending = '0' then
              if rd_int = '0' then
                -- Issue the read for the current byte.
                sdram_addr <= std_logic_vector(base_addr + fill_idx);
                rd_int     <= '1';
              elsif sdram_ready = '1' then
                -- Request accepted this cycle.
                rd_int      <= '0';
                req_pending <= '1';
              end if;
            elsif sdram_valid = '1' then
              -- Data for the accepted read.
              sec_buf(to_integer(fill_idx)) <= sdram_q;
              req_pending <= '0';
              if fill_idx = 255 then
                loaded_track  <= fill_track;
                loaded_sector <= fill_sector;
                state         <= SERVE;
              else
                fill_idx <= fill_idx + 1;
              end if;
            end if;
        end case;
      end if;
    end if;
  end process;
end architecture;
