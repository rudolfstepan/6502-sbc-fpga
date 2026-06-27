-- ============================================================================
-- ip_divider -- stand-in for a vendor integer-divider IP core.
--
-- Streaming interface: present in_dividend/in_divisor with in_valid; the
-- remainder appears LATENCY clocks later with out_valid. The model accepts a
-- new operand EVERY clock (throughput 1), so it represents a fully pipelined
-- divider IP -- the strongest realistic baseline. Two usage patterns expose the
-- honest picture:
--   * dependency chain  -- issue, wait LATENCY, feed the result back, repeat:
--     the pipeline cannot be filled, so every step costs the full latency.
--   * independent stream -- issue every clock: throughput 1, ~N+LATENCY total.
--
-- This is a BEHAVIOURAL model for simulation and a first synthesizable baseline
-- (the divide is inferred). For real area/Fmax/latency, generate the Gowin
-- Divider soft IP and bind it to this exact entity -- see
-- boards/tang_primer_20k/reist/README.md. The benchmark counts CLOCK CYCLES, so
-- the cycle results are valid regardless of which divider sits behind the port.
-- VHDL-93 compatible.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ip_divider is
  generic (
    W       : positive := 32;
    LATENCY : positive := 34          -- clocks from in_valid to out_valid
  );
  port (
    clk           : in  std_logic;
    reset_n       : in  std_logic;
    in_valid      : in  std_logic;
    in_dividend   : in  unsigned(W-1 downto 0);
    in_divisor    : in  unsigned(W-1 downto 0);
    out_valid     : out std_logic;
    out_remainder : out unsigned(W-1 downto 0)
  );
end entity;

architecture behavioral of ip_divider is
  type rem_arr is array (0 to LATENCY-1) of unsigned(W-1 downto 0);
  signal rpipe : rem_arr := (others => (others => '0'));
  signal vpipe : std_logic_vector(LATENCY-1 downto 0) := (others => '0');
begin

  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        vpipe <= (others => '0');
      else
        -- stage 0: compute (inferred divide); div-by-zero passes the dividend
        if in_valid = '1' and in_divisor /= 0 then
          rpipe(0) <= in_dividend mod in_divisor;
        else
          rpipe(0) <= in_dividend;
        end if;
        vpipe(0) <= in_valid;
        -- shift the pipeline
        for i in 1 to LATENCY-1 loop
          rpipe(i) <= rpipe(i-1);
          vpipe(i) <= vpipe(i-1);
        end loop;
      end if;
    end if;
  end process;

  out_remainder <= rpipe(LATENCY-1);
  out_valid     <= vpipe(LATENCY-1);

end architecture;
