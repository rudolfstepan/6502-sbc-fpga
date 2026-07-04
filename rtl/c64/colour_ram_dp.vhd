-- C64 colour RAM (1024 x 4) -- dual-port variant for the vic_ii_xl config:
--   port A: CPU read/write (never stolen)
--   port B: VIC read-only (c-access colour nibble)
--
-- Same collision reasoning as c64_ram_dp: a same-address write/read collision
-- can only ever glitch one video nibble for one scanline, never the CPU.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity colour_ram_dp is
  port (
    clk    : in  std_logic;
    -- port A: CPU
    a_addr : in  std_logic_vector(9 downto 0);
    a_we   : in  std_logic;
    a_din  : in  std_logic_vector(3 downto 0);
    a_dout : out std_logic_vector(3 downto 0);
    -- port B: VIC (read-only)
    b_addr : in  std_logic_vector(9 downto 0);
    b_dout : out std_logic_vector(3 downto 0)
  );
end entity;

architecture rtl of colour_ram_dp is
  type mem_t is array (0 to 1023) of std_logic_vector(3 downto 0);
  signal mem : mem_t := (others => (others => '0'));
  -- Distributed on purpose: 1K x 4 is cheap as LUT RAM and this frees one
  -- BSRAM block for the vic_ii_xl line buffer (the BSRAM budget is full).
  -- NOTE: Gowin only accepts "registers" / "distributed_ram" / "block_ram";
  -- the value "distributed" is silently rejected with WARN EX0200.
  attribute syn_ramstyle : string;
  attribute syn_ramstyle of mem : signal is "distributed_ram";
begin
  process(clk)
  begin
    if rising_edge(clk) then
      if a_we = '1' then
        mem(to_integer(unsigned(a_addr))) <= a_din;
      else
        a_dout <= mem(to_integer(unsigned(a_addr)));
      end if;
    end if;
  end process;

  process(clk)
  begin
    if rising_edge(clk) then
      b_dout <= mem(to_integer(unsigned(b_addr)));
    end if;
  end process;
end architecture;
