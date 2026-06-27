-- ============================================================================
-- Unit tests for the REIST centered-correction core and the sequential divider.
--   * reist_core : result matches the reist_res() reference and stays inside
--                  the centered interval, across odd and even moduli.
--   * seq_divider: quotient/remainder match for a spread of operands.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

use work.reist_pkg.all;

entity tb_reist_core is
end entity;

architecture sim of tb_reist_core is
  constant W : positive := 32;

  -- reist_core
  signal b_s, sum_s, r_s : signed(W downto 0) := (others => '0');

  -- seq_divider
  signal clk     : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal d_start : std_logic := '0';
  signal d_dvd, d_dvs, d_q, d_rem : unsigned(W-1 downto 0) := (others => '0');
  signal d_busy, d_done : std_logic;

  type int_array is array (natural range <>) of integer;
  constant TEST_MODULI : int_array := (5, 6, 7, 8, 9, 16, 251, 256);
begin

  clk <= not clk after 5 ns;

  core : entity work.reist_core
    generic map (W => W)
    port map (b => b_s, sum => sum_s, r => r_s);

  div : entity work.seq_divider
    generic map (W => W)
    port map (clk => clk, reset_n => reset_n, start => d_start,
              dividend => d_dvd, divisor => d_dvs,
              quotient => d_q, remainder => d_rem,
              busy => d_busy, done => d_done);

  stim : process
    variable lo, hi, exp : integer;
    procedure do_div(dvd, dvs : integer) is
    begin
      d_dvd   <= to_unsigned(dvd, W);
      d_dvs   <= to_unsigned(dvs, W);
      wait until rising_edge(clk);
      d_start <= '1';
      wait until rising_edge(clk);
      d_start <= '0';
      wait until d_done = '1';
      wait until rising_edge(clk);
      assert to_integer(d_q) = dvd / dvs
        report "divider quotient wrong: " & integer'image(dvd) & "/" &
               integer'image(dvs) & " got " & integer'image(to_integer(d_q))
        severity failure;
      assert to_integer(d_rem) = dvd mod dvs
        report "divider remainder wrong: " & integer'image(dvd) & " mod " &
               integer'image(dvs) & " got " & integer'image(to_integer(d_rem))
        severity failure;
    end procedure;
  begin
    reset_n <= '0';
    wait for 23 ns;
    reset_n <= '1';
    wait until rising_edge(clk);

    -- ---- reist_core across odd/even moduli, full in-range sweep ----
    for mi in TEST_MODULI'range loop
      lo := -(TEST_MODULI(mi) / 2);
      hi := lo + TEST_MODULI(mi);
      b_s <= to_signed(TEST_MODULI(mi), W+1);
      -- one centered correction is valid for sum in [2*lo, 2*hi)
      for s in 2*lo to 2*hi - 1 loop
        sum_s <= to_signed(s, W+1);
        wait for 1 ns;
        exp := reist_res(s, TEST_MODULI(mi));
        assert to_integer(r_s) = exp
          report "reist_core mismatch: B=" & integer'image(TEST_MODULI(mi)) &
                 " sum=" & integer'image(s) & " got " &
                 integer'image(to_integer(r_s)) & " exp " & integer'image(exp)
          severity failure;
        assert (to_integer(r_s) >= lo) and (to_integer(r_s) < hi)
          report "reist_core out of interval: B=" &
                 integer'image(TEST_MODULI(mi)) & " r=" &
                 integer'image(to_integer(r_s))
          severity failure;
      end loop;
    end loop;
    report "reist_core: all centered corrections OK";

    -- ---- seq_divider spot checks ----
    do_div(100, 7);
    do_div(255, 16);
    do_div(1000, 251);
    do_div(65520, 65521);
    do_div(5, 5);
    do_div(0, 7);
    do_div(123456, 789);
    report "seq_divider: all divisions OK";

    report "tb_reist_core passed";
    finish;
  end process;
end architecture;
