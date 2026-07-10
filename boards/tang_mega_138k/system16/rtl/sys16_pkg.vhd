library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package sys16_pkg is
  subtype word16_t is std_logic_vector(15 downto 0);
  subtype addr24_t is std_logic_vector(23 downto 0);

  -- Small on-chip boot/scratch RAM. Main memory will live in external
  -- DDR3 or SDRAM behind a dedicated memory bridge.
  constant SYS16_RAM_WORDS      : natural := 1024;
  constant SYS16_RAM_ADDR_BITS  : natural := 10;

  constant SYS16_IO_BASE        : std_logic_vector(23 downto 16) := x"F0";
  constant SYS16_REG_LED_STATUS : std_logic_vector(7 downto 0) := x"00";
  constant SYS16_REG_VIDEO_CTRL : std_logic_vector(7 downto 0) := x"02";
  constant SYS16_REG_UART_DATA  : std_logic_vector(7 downto 0) := x"10";
  constant SYS16_REG_UART_STAT  : std_logic_vector(7 downto 0) := x"12";
  constant SYS16_REG_UART_RX    : std_logic_vector(7 downto 0) := x"14";
end package;

package body sys16_pkg is
end package body;
