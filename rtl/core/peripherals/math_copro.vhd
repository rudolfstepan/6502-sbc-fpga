-- Math coprocessor: signed fixed-point multiplier for the 6502.
--
-- A small, memory-mapped helper that off-loads the dominant cost of fixed-point
-- workloads (Mandelbrot, fractals, DSP-ish code) from the 8-bit CPU: a single
-- signed 32x32 -> 64 multiply that maps to the FPGA's hardware DSP blocks, plus
-- an arithmetic right-shift so the result comes back already scaled to the
-- caller's Q-format.
--
-- Default Q-format is 8.24 (SHIFT = 24): operands and the scaled result are
-- signed 32-bit, range about -128.0 .. +127.999999.  The shift is writable, so
-- the same unit serves any Q-format (e.g. write 12 for 4.12).
--
-- Register map (16 bytes, base in sbc_pkg ADDR_MATH_BASE = $88B0):
--   offset  write                         read
--   0..3    operand A, byte 0 (LSB)..3    raw 64-bit product, byte 0..3
--   4..7    operand B, byte 0 (LSB)..3    raw 64-bit product, byte 4..7
--   8..B    -                             scaled result (A*B)>>SHIFT, byte 0..3
--   C       SHIFT amount (0..63)          SHIFT amount
--
-- Timing: the multiply and shift are registered (2-clock latency).  Operands are
-- written one byte at a time and the CPU does not read the result until several
-- cycles later, so the pipeline is always settled by then -- no wait states.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity math_copro is
  generic (
    DEFAULT_SHIFT : integer := 24    -- 8.24 fixed-point: result = (A*B) >> 24
  );
  port (
    clk     : in  std_logic;
    reset_n : in  std_logic;
    cs      : in  std_logic;                       -- chip select (address decoded)
    we      : in  std_logic;                       -- 1 = write (with cs)
    addr    : in  std_logic_vector(3 downto 0);    -- register offset (0..15)
    din     : in  std_logic_vector(7 downto 0);    -- CPU write data
    dout    : out std_logic_vector(7 downto 0)     -- read data
  );
end entity;

architecture rtl of math_copro is
  signal a_reg   : std_logic_vector(31 downto 0) := (others => '0');
  signal b_reg   : std_logic_vector(31 downto 0) := (others => '0');
  signal sh_reg  : unsigned(5 downto 0) := to_unsigned(DEFAULT_SHIFT, 6);
  signal product : signed(63 downto 0) := (others => '0');  -- A*B (registered)
  signal result  : signed(63 downto 0) := (others => '0');  -- product >> SHIFT
begin
  -- ── operand writes + pipelined signed multiply ─────────────────────────
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        a_reg  <= (others => '0');
        b_reg  <= (others => '0');
        sh_reg <= to_unsigned(DEFAULT_SHIFT, 6);
      elsif cs = '1' and we = '1' then
        case addr is
          when x"0" => a_reg(7 downto 0)   <= din;
          when x"1" => a_reg(15 downto 8)  <= din;
          when x"2" => a_reg(23 downto 16) <= din;
          when x"3" => a_reg(31 downto 24) <= din;
          when x"4" => b_reg(7 downto 0)   <= din;
          when x"5" => b_reg(15 downto 8)  <= din;
          when x"6" => b_reg(23 downto 16) <= din;
          when x"7" => b_reg(31 downto 24) <= din;
          when x"C" => sh_reg <= unsigned(din(5 downto 0));
          when others => null;
        end case;
      end if;

      -- continuous multiply (maps to DSP) then arithmetic shift; both registered
      product <= signed(a_reg) * signed(b_reg);
      result  <= shift_right(product, to_integer(sh_reg));
    end if;
  end process;

  -- ── read mux ───────────────────────────────────────────────────────────
  process(addr, product, result, sh_reg)
  begin
    case addr is
      when x"0" => dout <= std_logic_vector(product(7 downto 0));
      when x"1" => dout <= std_logic_vector(product(15 downto 8));
      when x"2" => dout <= std_logic_vector(product(23 downto 16));
      when x"3" => dout <= std_logic_vector(product(31 downto 24));
      when x"4" => dout <= std_logic_vector(product(39 downto 32));
      when x"5" => dout <= std_logic_vector(product(47 downto 40));
      when x"6" => dout <= std_logic_vector(product(55 downto 48));
      when x"7" => dout <= std_logic_vector(product(63 downto 56));
      when x"8" => dout <= std_logic_vector(result(7 downto 0));
      when x"9" => dout <= std_logic_vector(result(15 downto 8));
      when x"A" => dout <= std_logic_vector(result(23 downto 16));
      when x"B" => dout <= std_logic_vector(result(31 downto 24));
      when x"C" => dout <= "00" & std_logic_vector(sh_reg);
      when others => dout <= (others => '0');
    end case;
  end process;
end architecture;
