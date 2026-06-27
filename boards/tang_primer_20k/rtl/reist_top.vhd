-- ============================================================================
-- reist_top -- standalone Tang Primer 20K top for the REIST benchmark engine.
--
-- Self-contained: a 27 MHz clock, an internal power-on reset, the benchmark
-- engine and the UART reporter. Shares NO files with the 6502 SBC. It compares
-- REIST centered-correction modular accumulation against the Gowin Integer
-- Division IP (via the work.ip_divider wrapper, ip_divider_ip.vhd) and reports
-- the per-modulus cycle counts over UART.
--
-- One-shot: runs at configuration off the power-on reset (no external reset pin,
-- which also avoids the dock's dedicated SSPI button pins). Reprogram to re-run.
--
-- Pins (see boards/tang_primer_20k/reist/reist_bench.cst):
--   clk     H11   27 MHz oscillator
--   uart_tx M11   CH340 TX (115200 8N1)
--   led[3:0] L16/L14/N14/N16, active-low
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.reist_pkg.all;

entity reist_top is
  generic (
    CLK_HZ  : positive := 27_000_000;
    BAUD    : positive := 115_200;
    W       : positive := 32;
    N_ITERS : positive := 1024;
    IP_LAT  : positive := 2            -- match the generated Integer Division IP
  );
  port (
    clk     : in  std_logic;
    uart_tx : out std_logic;
    led     : out std_logic_vector(3 downto 0)
  );
end entity;

architecture rtl of reist_top is
  signal por_cnt    : unsigned(7 downto 0) := (others => '0');
  signal reset_n    : std_logic;

  signal eng_start  : std_logic := '0';
  signal eng_busy   : std_logic;
  signal eng_done   : std_logic;
  signal eng_started: std_logic := '0';

  signal res_index  : integer range 0 to MODULI'length-1;
  signal res_mod    : unsigned(31 downto 0);
  signal res_reist  : unsigned(31 downto 0);
  signal res_ipdep  : unsigned(31 downto 0);
  signal res_ipind  : unsigned(31 downto 0);

  signal rep_start  : std_logic := '0';
  signal rep_started: std_logic := '0';
  signal rep_done   : std_logic;

  signal heartbeat  : unsigned(24 downto 0) := (others => '0');
begin

  reset_n <= '1' when por_cnt = 255 else '0';

  process(clk)
  begin
    if rising_edge(clk) then
      if por_cnt /= 255 then
        por_cnt <= por_cnt + 1;
      end if;
      heartbeat <= heartbeat + 1;

      if reset_n = '0' then
        eng_start <= '0'; eng_started <= '0';
        rep_start <= '0'; rep_started <= '0';
      else
        eng_start <= '0';
        rep_start <= '0';
        if eng_started = '0' then
          eng_start <= '1'; eng_started <= '1';
        end if;
        if eng_done = '1' and rep_started = '0' then
          rep_start <= '1'; rep_started <= '1';
        end if;
      end if;
    end if;
  end process;

  engine : entity work.reist_bench_engine
    generic map (W => W, N_ITERS => N_ITERS, IP_LAT => IP_LAT)
    port map (
      clk => clk, reset_n => reset_n, start => eng_start,
      busy => eng_busy, done => eng_done,
      res_index => res_index, res_modulus => res_mod,
      res_reist => res_reist, res_ipdep => res_ipdep, res_ipind => res_ipind);

  reporter : entity work.bench_report
    generic map (CLK_HZ => CLK_HZ, BAUD => BAUD)
    port map (
      clk => clk, reset_n => reset_n, start => rep_start,
      res_index => res_index, res_modulus => res_mod,
      res_reist => res_reist, res_ipdep => res_ipdep, res_ipind => res_ipind,
      tx => uart_tx, done => rep_done);

  led(0) <= not eng_busy;        -- benchmark running
  led(1) <= not eng_done;        -- benchmark complete
  led(2) <= not rep_done;        -- report sent
  led(3) <= not heartbeat(24);   -- alive blink
end architecture;
