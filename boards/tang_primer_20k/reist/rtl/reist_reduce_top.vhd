-- ============================================================================
-- reist_reduce_top -- area/Fmax probe for the REIST reduction unit.
--
-- Identical measurement harness to ip_reduce_top, differing ONLY in the
-- reduction it instantiates, so the synthesis resource and timing reports
-- compare apples to apples:
--
--   LFSR -> input regs (a,b,m) -> sum_r = a+b (reg) -> REDUCE -> out reg -> probe
--
-- Here REDUCE is reist_core (one centered correction: comparator + add/sub +
-- mux). The probe XORs the result to one pin so nothing is optimised away.
-- Build this top alone (boards/.../reist/area) and read its LUT/Reg count and
-- Max Frequency. VHDL-93 compatible.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity reist_reduce_top is
  generic (W : positive := 32);
  port (
    clk   : in  std_logic;
    probe : out std_logic
  );
end entity;

architecture rtl of reist_reduce_top is
  signal lfsr  : std_logic_vector(31 downto 0) := x"1234ABCD";
  signal a_r, b_r, m_r : signed(W downto 0) := (others => '0');
  signal sum_r : signed(W downto 0) := (others => '0');
  signal out_r : signed(W downto 0) := (others => '0');
  signal cent  : signed(W downto 0);

  function lfsr_next(v : std_logic_vector(31 downto 0)) return std_logic_vector is
    variable fb : std_logic;
  begin
    fb := v(31) xor v(21) xor v(1) xor v(0);      -- 32-bit maximal LFSR
    return v(30 downto 0) & fb;
  end function;
begin

  reduce : entity work.reist_core
    generic map (W => W)
    port map (b => m_r, sum => sum_r, r => cent);

  process(clk)
    variable p : std_logic;
  begin
    if rising_edge(clk) then
      lfsr  <= lfsr_next(lfsr);
      a_r   <= signed(resize(unsigned(lfsr(15 downto 0)), W+1));
      b_r   <= signed(resize(unsigned(lfsr(31 downto 16)), W+1));
      -- modulus forced odd/non-zero
      m_r   <= signed(resize(unsigned(lfsr(16 downto 1)), W+1)) or to_signed(1, W+1);
      sum_r <= a_r + b_r;
      out_r <= cent;
      p := '0';
      for i in 0 to W loop
        p := p xor out_r(i);
      end loop;
      probe <= p;
    end if;
  end process;
end architecture;
