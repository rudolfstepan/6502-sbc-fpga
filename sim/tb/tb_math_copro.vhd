-- Testbench for math_copro: signed 32x32 fixed-point multiplier.
-- Drives the memory-mapped register interface the way the 6502 does (byte
-- writes of the two operands, then byte reads of the 8.24 result) and checks a
-- set of signed products, including the values the Mandelbrot ROM relies on.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_math_copro is
end entity;

architecture sim of tb_math_copro is
  constant CLK_PERIOD : time := 20 ns;
  signal clk     : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal cs      : std_logic := '0';
  signal we      : std_logic := '0';
  signal addr    : std_logic_vector(3 downto 0) := (others => '0');
  signal din     : std_logic_vector(7 downto 0) := (others => '0');
  signal dout    : std_logic_vector(7 downto 0);
begin
  dut : entity work.math_copro
    port map (clk => clk, reset_n => reset_n, cs => cs, we => we,
              addr => addr, din => din, dout => dout);

  clk <= not clk after CLK_PERIOD/2;

  stim : process
    variable errors : integer := 0;

    -- one register write (cs+we for a single clock), like a 6502 store
    procedure wr(constant ofs : in integer; constant b : in std_logic_vector(7 downto 0)) is
    begin
      addr <= std_logic_vector(to_unsigned(ofs, 4));
      din  <= b;
      we   <= '1';
      cs   <= '1';
      wait until rising_edge(clk);
      wait for 1 ns;
      we <= '0';
      cs <= '0';
    end procedure;

    -- one register read; the read mux is combinational on addr
    procedure rd(constant ofs : in integer; variable b : out std_logic_vector(7 downto 0)) is
    begin
      addr <= std_logic_vector(to_unsigned(ofs, 4));
      we   <= '0';
      cs   <= '1';
      wait until rising_edge(clk);
      wait for 1 ns;
      b := dout;
      cs <= '0';
    end procedure;

    -- write A and B, let the pipeline settle, read the scaled 8.24 result
    procedure mul_check(constant a32   : in std_logic_vector(31 downto 0);
                        constant b32   : in std_logic_vector(31 downto 0);
                        constant exp32 : in std_logic_vector(31 downto 0);
                        constant name  : in string) is
      variable r   : std_logic_vector(31 downto 0);
      variable tmp : std_logic_vector(7 downto 0);
    begin
      wr(0, a32(7 downto 0));
      wr(1, a32(15 downto 8));
      wr(2, a32(23 downto 16));
      wr(3, a32(31 downto 24));
      wr(4, b32(7 downto 0));
      wr(5, b32(15 downto 8));
      wr(6, b32(23 downto 16));
      wr(7, b32(31 downto 24));
      for i in 0 to 4 loop          -- settle multiply + shift pipeline
        wait until rising_edge(clk);
      end loop;
      rd(8,  tmp); r(7 downto 0)   := tmp;
      rd(9,  tmp); r(15 downto 8)  := tmp;
      rd(10, tmp); r(23 downto 16) := tmp;
      rd(11, tmp); r(31 downto 24) := tmp;
      if r = exp32 then
        report "PASS  " & name & "  = 0x" & to_hstring(r);
      else
        report "FAIL  " & name & ": got 0x" & to_hstring(r) &
               " expected 0x" & to_hstring(exp32) severity error;
        errors := errors + 1;
      end if;
    end procedure;

  begin
    reset_n <= '0';
    wait for 100 ns;
    wait until rising_edge(clk);
    reset_n <= '1';
    wait until rising_edge(clk);

    -- SHIFT = 24 (8.24 fixed-point), exactly what the ROM programs
    wr(12, x"18");
    wait until rising_edge(clk);

    -- value(8.24) = raw / 2^24.  Hex below = value * 16777216.
    mul_check(x"01000000", x"01000000", x"01000000", " 1.0  *  1.0  = 1.0 ");
    mul_check(x"02000000", x"03000000", x"06000000", " 2.0  *  3.0  = 6.0 ");
    mul_check(x"FF000000", x"01000000", x"FF000000", "-1.0  *  1.0  =-1.0 ");
    mul_check(x"FE000000", x"FE000000", x"04000000", "-2.0  * -2.0  = 4.0 ");
    mul_check(x"00800000", x"00800000", x"00400000", " 0.5  *  0.5  = 0.25");
    mul_check(x"01800000", x"01800000", x"02400000", " 1.5  *  1.5  = 2.25");
    mul_check(x"FF800000", x"01800000", x"FF400000", "-0.5  *  1.5  =-0.75");

    -- SHIFT changeable: same operands in 4.12 -> result scales differently.
    wr(12, x"0C");                  -- SHIFT = 12 (4.12)
    wait until rising_edge(clk);
    -- 1.0(8.24) raw 0x01000000 times itself, >>12 -> 0x01000000000>>12 low32
    -- = 0x00001000_... -> check it at least shifts by 12 not 24
    mul_check(x"00001000", x"00001000", x"00001000", " Q12  1.0 * 1.0     ");

    if errors = 0 then
      report "==== ALL MATH_COPRO TESTS PASSED ====" severity note;
    else
      report integer'image(errors) & " MATH_COPRO TEST(S) FAILED" severity failure;
    end if;
    finish;
  end process;
end architecture;
