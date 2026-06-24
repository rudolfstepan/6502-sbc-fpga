-- D64 sector mapper: converts a D64 (track, sector) into a linear sector index
-- and validates the request, for the FPGA GoDrive.
--
-- This is the RTL twin of tools/d64/d64_common.py:d64_sector_index().  The two
-- must agree byte-for-byte; tb_d64_sector_map.vhd checks the same vectors as
-- tools/d64/test_d64_common.py (from future_works/TODO_D64_HYBRID_DRIVE_FULL.md).
--
-- Version 1: standard 35-track image (683 sectors, indices 0..682).
--   tracks  1..17 : 21 sectors    base   0
--   tracks 18..24 : 19 sectors    base 357
--   tracks 25..30 : 18 sectors    base 490
--   tracks 31..35 : 17 sectors    base 598
--
-- Combinational only.  683 sectors fit in 10 bits (max index 682).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity d64_sector_map is
  port (
    track        : in  std_logic_vector(7 downto 0);  -- 1-based D64 track
    sector       : in  std_logic_vector(7 downto 0);  -- 0-based D64 sector
    valid        : out std_logic;                     -- '1' if track/sector legal
    sector_index : out std_logic_vector(9 downto 0);  -- linear index 0..682
    error_code   : out std_logic_vector(7 downto 0)   -- $00 OK / $02 trk / $03 sec
  );
end entity;

architecture rtl of d64_sector_map is
  -- DISK_RESULT codes (subset) shared with the disk controller contract.
  constant ERR_OK             : std_logic_vector(7 downto 0) := x"00";
  constant ERR_INVALID_TRACK  : std_logic_vector(7 downto 0) := x"02";
  constant ERR_INVALID_SECTOR : std_logic_vector(7 downto 0) := x"03";
begin
  process(track, sector)
    variable t   : unsigned(7 downto 0);
    variable s   : unsigned(7 downto 0);
    variable idx : unsigned(9 downto 0);
  begin
    t := unsigned(track);
    s := unsigned(sector);

    -- defaults: invalid track
    valid        <= '0';
    sector_index <= (others => '0');
    error_code   <= ERR_INVALID_TRACK;
    idx          := (others => '0');

    if t >= 1 and t <= 17 then
      if s >= 21 then
        error_code <= ERR_INVALID_SECTOR;
      else
        idx := resize((t - 1) * 21 + s, 10);
        valid <= '1';
        error_code <= ERR_OK;
      end if;
    elsif t >= 18 and t <= 24 then
      if s >= 19 then
        error_code <= ERR_INVALID_SECTOR;
      else
        idx := resize(to_unsigned(357, 10) + (t - 18) * 19 + s, 10);
        valid <= '1';
        error_code <= ERR_OK;
      end if;
    elsif t >= 25 and t <= 30 then
      if s >= 18 then
        error_code <= ERR_INVALID_SECTOR;
      else
        idx := resize(to_unsigned(490, 10) + (t - 25) * 18 + s, 10);
        valid <= '1';
        error_code <= ERR_OK;
      end if;
    elsif t >= 31 and t <= 35 then
      if s >= 17 then
        error_code <= ERR_INVALID_SECTOR;
      else
        idx := resize(to_unsigned(598, 10) + (t - 31) * 17 + s, 10);
        valid <= '1';
        error_code <= ERR_OK;
      end if;
    end if;

    sector_index <= std_logic_vector(idx);
  end process;
end architecture;
