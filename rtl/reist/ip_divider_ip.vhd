-- ============================================================================
-- ip_divider (Gowin IP wrapper) -- binds the generated Integer Division soft IP
-- to the same interface the behavioural ip_divider.vhd model uses, so the
-- engine instantiates work.ip_divider unchanged.
--
-- Use this file in the GowinEDA project (with src/integer_division/...);
-- use the behavioural ip_divider.vhd in the GHDL flow. Both declare entity
-- ip_divider, so compile exactly ONE per flow.
--
-- The Integer_Division_Top core is a fixed-latency pipeline (no valid/ready):
-- remainder(t) = dividend(t-LATENCY) mod divisor(t-LATENCY), throughput 1. We
-- recreate out_valid by delaying in_valid by LATENCY. LATENCY must match the
-- generated core (Gowin reports it in the instance name, e.g. LATENCY=2). The
-- core is 32-bit; W must be 32.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ip_divider is
  generic (
    W       : positive := 32;
    LATENCY : positive := 2
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

architecture gowin_ip of ip_divider is
  component Integer_Division_Top
    port (
      clk       : in  std_logic;
      rstn      : in  std_logic;
      dividend  : in  std_logic_vector(31 downto 0);
      divisor   : in  std_logic_vector(31 downto 0);
      remainder : out std_logic_vector(31 downto 0);
      quotient  : out std_logic_vector(31 downto 0)
    );
  end component;

  signal dvd_slv : std_logic_vector(31 downto 0);
  signal dvs_slv : std_logic_vector(31 downto 0);
  signal rem_slv : std_logic_vector(31 downto 0);
  signal quo_slv : std_logic_vector(31 downto 0);
  signal vpipe   : std_logic_vector(LATENCY-1 downto 0) := (others => '0');
begin

  dvd_slv <= std_logic_vector(resize(in_dividend, 32));
  dvs_slv <= std_logic_vector(resize(in_divisor, 32));

  u_div : Integer_Division_Top
    port map (
      clk       => clk,
      rstn      => reset_n,
      dividend  => dvd_slv,
      divisor   => dvs_slv,
      remainder => rem_slv,
      quotient  => quo_slv);

  -- mirror the core's fixed latency to produce out_valid aligned with the result
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        vpipe <= (others => '0');
      elsif LATENCY = 1 then
        vpipe(0) <= in_valid;
      else
        vpipe <= vpipe(LATENCY-2 downto 0) & in_valid;
      end if;
    end if;
  end process;

  out_valid     <= vpipe(LATENCY-1);
  out_remainder <= resize(unsigned(rem_slv), W);

end architecture;
