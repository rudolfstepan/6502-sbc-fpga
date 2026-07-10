library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sys16_boot_rom_image_pkg.all;

entity sys16_boot_rom is
  port (
    addr : in  std_logic_vector(8 downto 0);
    dout : out std_logic_vector(15 downto 0)
  );
end entity;

architecture rtl of sys16_boot_rom is
  -- 68000 reset vectors and first-stage boot monitor. It emits
  -- "SYSTEM16 READY" at 115200 baud, turns the video status green and then
  -- parks in a stable loop. The image package is generated from
  -- ../sw/boot_monitor.s by `make firmware`.
begin
  dout <= SYS16_BOOT_ROM_IMAGE(to_integer(unsigned(addr)));
end architecture;
