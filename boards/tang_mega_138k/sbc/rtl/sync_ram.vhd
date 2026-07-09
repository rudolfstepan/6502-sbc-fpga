-- Tang Mega/Primer 138K variant of sync_ram.
--
-- GW5AST rejects the WRITE_MODE inferred from the generic core RAM pattern.
-- This version makes write-first forwarding explicit, which maps to a
-- supported single-port RAM write mode on the 138K family.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity sync_ram is
  generic (
    ADDR_WIDTH : positive := 15;
    ASYNC_READ : boolean := false
  );
  port (
    clk  : in  std_logic;
    we   : in  std_logic;
    addr : in  std_logic_vector(ADDR_WIDTH - 1 downto 0);
    din  : in  data_t;
    dout : out data_t
  );
end entity;

architecture rtl of sync_ram is
  type ram_t is array (0 to (2 ** ADDR_WIDTH) - 1) of data_t;

  signal ram : ram_t := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of ram : signal is "block";
begin
  sync_write_g : if not ASYNC_READ generate
    process(clk)
    begin
      if rising_edge(clk) then
        if we = '1' then
          ram(to_integer(unsigned(addr))) <= din;
          dout <= din;
        else
          dout <= ram(to_integer(unsigned(addr)));
        end if;
      end if;
    end process;
  end generate;

  async_write_g : if ASYNC_READ generate
    process(clk)
    begin
      if rising_edge(clk) then
        if we = '1' then
          ram(to_integer(unsigned(addr))) <= din;
        end if;
      end if;
    end process;
  end generate;

  async_read_g : if ASYNC_READ generate
    process(addr, we, din, ram)
    begin
      if is_x(addr) then
        dout <= (others => '0');
      elsif we = '1' then
        dout <= din;
      else
        dout <= ram(to_integer(unsigned(addr)));
      end if;
    end process;
  end generate;
end architecture;
