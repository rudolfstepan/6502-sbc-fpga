-- Testbench for d64_sector_map.
--
-- Mirrors tools/d64/test_d64_common.py: the explicit valid/invalid vectors are
-- the table from future_works/TODO_D64_HYBRID_DRIVE_FULL.md section 5.3, plus a
-- full dense-index sweep over every legal (track, sector) of a 35-track image.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use std.env.all;

entity tb_d64_sector_map is
end entity;

architecture sim of tb_d64_sector_map is
  signal track        : std_logic_vector(7 downto 0) := (others => '0');
  signal sector       : std_logic_vector(7 downto 0) := (others => '0');
  signal valid        : std_logic;
  signal sector_index : std_logic_vector(9 downto 0);
  signal error_code   : std_logic_vector(7 downto 0);

  constant ERR_OK             : std_logic_vector(7 downto 0) := x"00";
  constant ERR_INVALID_TRACK  : std_logic_vector(7 downto 0) := x"02";
  constant ERR_INVALID_SECTOR : std_logic_vector(7 downto 0) := x"03";

  -- sectors-per-track for the dense sweep (mirrors d64_common.sectors_per_track)
  function spt(t : integer) return integer is
  begin
    if    t >= 1  and t <= 17 then return 21;
    elsif t >= 18 and t <= 24 then return 19;
    elsif t >= 25 and t <= 30 then return 18;
    elsif t >= 31 and t <= 35 then return 17;
    else return 0;
    end if;
  end function;
begin
  dut : entity work.d64_sector_map
    port map (
      track        => track,
      sector       => sector,
      valid        => valid,
      sector_index => sector_index,
      error_code   => error_code
    );

  process
    -- check one valid case: expected index, valid='1', error=OK
    procedure chk_valid(t, s, idx : integer) is
    begin
      track  <= std_logic_vector(to_unsigned(t, 8));
      sector <= std_logic_vector(to_unsigned(s, 8));
      wait for 1 ns;
      assert valid = '1'
        report "T" & integer'image(t) & "/S" & integer'image(s)
             & " expected valid" severity failure;
      assert to_integer(unsigned(sector_index)) = idx
        report "T" & integer'image(t) & "/S" & integer'image(s)
             & " index=" & integer'image(to_integer(unsigned(sector_index)))
             & " expected " & integer'image(idx) severity failure;
      assert error_code = ERR_OK
        report "T" & integer'image(t) & "/S" & integer'image(s)
             & " expected OK error code" severity failure;
    end procedure;

    -- check an invalid case: valid='0', error is one of the invalid codes
    procedure chk_invalid(t, s : integer) is
    begin
      track  <= std_logic_vector(to_unsigned(t, 8));
      sector <= std_logic_vector(to_unsigned(s, 8));
      wait for 1 ns;
      assert valid = '0'
        report "T" & integer'image(t) & "/S" & integer'image(s)
             & " expected invalid" severity failure;
      assert error_code = ERR_INVALID_TRACK
          or error_code = ERR_INVALID_SECTOR
        report "T" & integer'image(t) & "/S" & integer'image(s)
             & " expected an invalid error code" severity failure;
    end procedure;

    variable expected : integer;
  begin
    -- ── valid vectors (spec section 5.3) ────────────────────────────────────
    chk_valid(1, 0, 0);
    chk_valid(1, 20, 20);
    chk_valid(2, 0, 21);
    chk_valid(17, 20, 356);
    chk_valid(18, 0, 357);
    chk_valid(18, 1, 358);
    chk_valid(24, 18, 489);
    chk_valid(25, 0, 490);
    chk_valid(30, 17, 597);
    chk_valid(31, 0, 598);
    chk_valid(35, 16, 682);

    -- ── invalid vectors (spec section 5.3) ──────────────────────────────────
    chk_invalid(0, 0);
    chk_invalid(1, 21);
    chk_invalid(18, 19);
    chk_invalid(25, 18);
    chk_invalid(35, 17);
    chk_invalid(36, 0);

    -- track 0 / track 36 must report INVALID_TRACK specifically
    track <= x"00"; sector <= x"00"; wait for 1 ns;
    assert error_code = ERR_INVALID_TRACK report "T0 should be INVALID_TRACK" severity failure;
    track <= x"24"; sector <= x"00"; wait for 1 ns;  -- track 36
    assert error_code = ERR_INVALID_TRACK report "T36 should be INVALID_TRACK" severity failure;

    -- over-range sector on a valid track must report INVALID_SECTOR
    track <= x"01"; sector <= std_logic_vector(to_unsigned(21, 8)); wait for 1 ns;
    assert error_code = ERR_INVALID_SECTOR report "T1/S21 should be INVALID_SECTOR" severity failure;

    -- ── dense sweep: every legal sector yields 0,1,2,...,682 with no gaps ────
    expected := 0;
    for t in 1 to 35 loop
      for s in 0 to spt(t) - 1 loop
        chk_valid(t, s, expected);
        expected := expected + 1;
      end loop;
    end loop;
    assert expected = 683
      report "dense sweep produced " & integer'image(expected)
           & " sectors, expected 683" severity failure;

    report "tb_d64_sector_map passed";
    finish;
  end process;
end architecture;
