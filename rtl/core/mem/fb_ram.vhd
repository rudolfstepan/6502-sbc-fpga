-- Framebuffer RAM: single-port synchronous block RAM with an EXACT word count.
--
-- Unlike sync_ram (which allocates 2**ADDR_WIDTH words and would round a 38400-
-- byte 320x240x4bpp framebuffer up to a 64 KiB / 32-block BSRAM), this RAM is
-- sized to DEPTH words so Gowin packs only the blocks actually needed
-- (38400 bytes -> ~19 of the 46 BSRAM blocks). The address bus is ADDR_WIDTH
-- bits wide; out-of-range accesses (addr >= DEPTH) are ignored on write and read
-- back as 0, so the banked $6000 CPU window cannot index past the array.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity fb_ram is
  generic (
    ADDR_WIDTH : positive := 16;   -- address bus width (>= ceil(log2(DEPTH)))
    DEPTH      : positive := 38400  -- exact number of bytes (words)
  );
  port (
    clk  : in  std_logic;
    we   : in  std_logic;
    addr : in  std_logic_vector(ADDR_WIDTH - 1 downto 0);
    din  : in  data_t;
    dout : out data_t
  );
end entity;

architecture rtl of fb_ram is
  type ram_t is array (0 to DEPTH - 1) of data_t;
  signal ram : ram_t := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of ram : signal is "block";
begin
  process(clk)
    variable ai : integer;
  begin
    if rising_edge(clk) then
      ai := to_integer(unsigned(addr));
      if ai < DEPTH then
        if we = '1' then
          ram(ai) <= din;
        end if;
        dout <= ram(ai);
      else
        dout <= (others => '0');
      end if;
    end if;
  end process;
end architecture;
