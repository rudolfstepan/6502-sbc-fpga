-- ============================================================================
-- ip_reduce_top -- area/Fmax probe for the Gowin Integer Division IP.
--
-- Same harness as reist_reduce_top; the only difference is the reduction unit,
-- here the generated Integer_Division_Top (a 32-bit pipelined divider):
--
--   LFSR -> input regs (a,b,m) -> sum_r = a+b (reg) -> IP DIVIDE -> out reg -> probe
--
-- Build this top alone (boards/.../reist/area) and read its LUT/Reg/DSP count
-- and Max Frequency, then compare with reist_reduce_top. VHDL-93 compatible.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ip_reduce_top is
  generic (W : positive := 32);
  port (
    clk   : in  std_logic;
    probe : out std_logic
  );
end entity;

architecture rtl of ip_reduce_top is
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

  signal lfsr  : std_logic_vector(31 downto 0) := x"1234ABCD";
  signal a_r, b_r, m_r : unsigned(W-1 downto 0) := (others => '0');
  signal sum_r : unsigned(W-1 downto 0) := (others => '0');
  signal dvd_slv, dvs_slv, rem_slv, quo_slv : std_logic_vector(31 downto 0);
  signal out_r : unsigned(W-1 downto 0) := (others => '0');

  function lfsr_next(v : std_logic_vector(31 downto 0)) return std_logic_vector is
    variable fb : std_logic;
  begin
    fb := v(31) xor v(21) xor v(1) xor v(0);
    return v(30 downto 0) & fb;
  end function;
begin

  dvd_slv <= std_logic_vector(resize(sum_r, 32));
  dvs_slv <= std_logic_vector(resize(m_r, 32));

  reduce : Integer_Division_Top
    port map (clk => clk, rstn => '1',
              dividend => dvd_slv, divisor => dvs_slv,
              remainder => rem_slv, quotient => quo_slv);

  process(clk)
    variable p : std_logic;
  begin
    if rising_edge(clk) then
      lfsr  <= lfsr_next(lfsr);
      a_r   <= resize(unsigned(lfsr(15 downto 0)), W);
      b_r   <= resize(unsigned(lfsr(31 downto 16)), W);
      m_r   <= resize(unsigned(lfsr(16 downto 1)), W) or to_unsigned(1, W);
      sum_r <= a_r + b_r;
      out_r <= resize(unsigned(rem_slv), W);
      p := '0';
      for i in 0 to W-1 loop
        p := p xor out_r(i);
      end loop;
      probe <= p;
    end if;
  end process;
end architecture;
