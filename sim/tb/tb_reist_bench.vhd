-- ============================================================================
-- End-to-end test of the REIST benchmark engine (behavioural ip_divider model).
-- Runs the sweep with a small N, reads back the per-modulus cycle counts and
-- prints them. Checks the honest expectations:
--   * in a dependency chain REIST beats the divider IP (reist < ipdep)
--   * the pipelined IP's independent stream beats its own dependency chain
--     (ipind < ipdep) and roughly matches REIST.
-- This is the simulation counterpart of the hardware UART report.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

use work.reist_pkg.all;

entity tb_reist_bench is
end entity;

architecture sim of tb_reist_bench is
  constant W      : positive := 32;
  constant N      : positive := 64;     -- iterations per path (small for sim)
  constant IP_LAT : positive := 2;      -- match the Gowin Integer Division IP

  signal clk     : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal start   : std_logic := '0';
  signal busy    : std_logic;
  signal done    : std_logic;
  signal idx     : integer range 0 to MODULI'length-1 := 0;
  signal r_mod, r_reist, r_ipdep, r_ipind : unsigned(31 downto 0);
begin

  clk <= not clk after 5 ns;

  dut : entity work.reist_bench_engine
    generic map (W => W, N_ITERS => N, IP_LAT => IP_LAT)
    port map (clk => clk, reset_n => reset_n, start => start,
              busy => busy, done => done,
              res_index => idx, res_modulus => r_mod,
              res_reist => r_reist, res_ipdep => r_ipdep, res_ipind => r_ipind);

  stim : process
    variable cr, cd, ci : integer;
  begin
    reset_n <= '0';
    wait for 23 ns;
    reset_n <= '1';
    wait until rising_edge(clk);
    start <= '1';
    wait until rising_edge(clk);
    start <= '0';

    wait until done = '1';
    wait until rising_edge(clk);

    report "REIST vs divider IP (LATENCY=" & integer'image(IP_LAT) &
           ", " & integer'image(N) & " modular adds per path):";
    for i in 0 to MODULI'length-1 loop
      idx <= i;
      wait for 1 ns;
      cr := to_integer(r_reist);
      cd := to_integer(r_ipdep);
      ci := to_integer(r_ipind);
      report "  B=" & integer'image(to_integer(r_mod)) &
             "  REIST=" & integer'image(cr) & " cyc" &
             "  IPdep=" & integer'image(cd) & " cyc (x" & integer'image(cd / cr) & ")" &
             "  IPind=" & integer'image(ci) & " cyc";
      assert cr > 0 and cd > 0 and ci > 0
        report "zero cycle count" severity failure;
      assert cr < cd
        report "REIST not faster than IP in dependency chain for B=" &
               integer'image(to_integer(r_mod)) severity failure;
      assert ci < cd
        report "IP independent stream not faster than its dependency chain for B=" &
               integer'image(to_integer(r_mod)) severity failure;
    end loop;

    report "tb_reist_bench passed";
    finish;
  end process;
end architecture;
