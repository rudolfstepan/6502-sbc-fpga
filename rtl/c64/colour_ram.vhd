-- C64 colour RAM: 1024 x 4-bit nibble RAM at $D800-$DBFF.
--
-- SINGLE-port, time-shared between the CPU and the VIC by an address mux in
-- c64_core (the VIC reads it during its steal, the CPU otherwise). Single-port on
-- purpose: a dual-port BSRAM corrupts on a same-address port-A-write/port-B-read
-- collision on Gowin hardware. No-change read pattern for a supported write mode.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity colour_ram is
  port (
    clk  : in  std_logic;
    addr : in  std_logic_vector(9 downto 0);
    we   : in  std_logic;
    din  : in  std_logic_vector(3 downto 0);
    dout : out std_logic_vector(3 downto 0)
  );
end entity;

architecture rtl of colour_ram is
  type mem_t is array (0 to 1023) of std_logic_vector(3 downto 0);
  signal mem : mem_t := (others => (others => '0'));
begin
  process(clk)
  begin
    if rising_edge(clk) then
      if we = '1' then
        mem(to_integer(unsigned(addr))) <= din;
      else
        dout <= mem(to_integer(unsigned(addr)));
      end if;
    end if;
  end process;
end architecture;
