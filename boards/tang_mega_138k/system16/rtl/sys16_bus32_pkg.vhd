library ieee;
use ieee.std_logic_1164.all;

package sys16_bus32_pkg is
  subtype sys32_addr_t is std_logic_vector(31 downto 0);
  subtype sys32_data_t is std_logic_vector(31 downto 0);
  subtype sys32_be_t   is std_logic_vector(3 downto 0);

  constant SYS32_RAM_BASE  : sys32_addr_t := x"00001000";
  constant SYS32_RAM_LIMIT : sys32_addr_t := x"00F00000";
  constant SYS32_IO_BASE   : sys32_addr_t := x"F0000000";
  constant SYS32_TIMER_BASE: sys32_addr_t := x"F0001000";
end package;

package body sys16_bus32_pkg is
end package body;
