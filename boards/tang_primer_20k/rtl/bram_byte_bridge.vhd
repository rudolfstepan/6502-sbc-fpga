-- Low-power byte RAM backend for the Tang Primer 20K.
--
-- Implements the same req/ack byte interface as ddr3_byte_bridge, allowing the
-- board top to switch between an 8 KiB BSRAM and DDR3 without changing the SBC
-- core. The RAM is cleared after reset before ram_ready is asserted.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity bram_byte_bridge is
  generic (
    BUS_ADDR_BITS : positive := 15;
    RAM_ADDR_BITS : positive := 13
  );
  port (
    clk       : in  std_logic;
    reset_n   : in  std_logic;
    req       : in  std_logic;
    we        : in  std_logic;
    addr      : in  std_logic_vector(BUS_ADDR_BITS - 1 downto 0);
    din       : in  data_t;
    dout      : out data_t;
    ack       : out std_logic;
    ram_ready : out std_logic;

    ram_test_active    : out std_logic;
    ram_test_done      : out std_logic;
    ram_test_error     : out std_logic;
    ram_test_phase     : out std_logic_vector(3 downto 0);
    ram_test_addr      : out std_logic_vector(BUS_ADDR_BITS - 1 downto 0);
    ram_test_fail_addr : out std_logic_vector(BUS_ADDR_BITS - 1 downto 0);
    ram_test_expected  : out data_t;
    ram_test_actual    : out data_t
  );
end entity;

architecture rtl of bram_byte_bridge is
  type ram_t is array (0 to (2 ** RAM_ADDR_BITS) - 1) of data_t;
  signal ram : ram_t := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of ram : signal is "block";

  signal clearing   : std_logic := '1';
  signal clear_addr : unsigned(RAM_ADDR_BITS - 1 downto 0) := (others => '0');
  signal dout_reg   : data_t := (others => '0');
begin
  dout <= dout_reg;

  ram_test_error     <= '0';
  ram_test_fail_addr <= (others => '0');
  ram_test_expected  <= (others => '0');
  ram_test_actual    <= (others => '0');
  ram_test_addr      <= std_logic_vector(resize(clear_addr, BUS_ADDR_BITS));

  process(clk)
    variable index : natural range 0 to (2 ** RAM_ADDR_BITS) - 1;
  begin
    if rising_edge(clk) then
      ack <= '0';

      if reset_n = '0' then
        clearing       <= '1';
        clear_addr     <= (others => '0');
        dout_reg       <= (others => '0');
        ram_ready      <= '0';
        ram_test_active <= '0';
        ram_test_done  <= '0';
        ram_test_phase <= x"0";
      elsif clearing = '1' then
        ram(to_integer(clear_addr)) <= (others => '0');
        ram_ready       <= '0';
        ram_test_active <= '1';
        ram_test_done   <= '0';
        ram_test_phase  <= x"4";  -- same clear phase used by DDR diagnostics

        if clear_addr = to_unsigned((2 ** RAM_ADDR_BITS) - 1, RAM_ADDR_BITS) then
          clearing       <= '0';
          clear_addr     <= (others => '0');
          ram_ready      <= '1';
          ram_test_active <= '0';
          ram_test_done  <= '1';
          ram_test_phase <= x"3";
        else
          clear_addr <= clear_addr + 1;
        end if;
      else
        ram_ready       <= '1';
        ram_test_active <= '0';
        ram_test_done   <= '1';
        ram_test_phase  <= x"3";

        if req = '1' then
          index := to_integer(unsigned(addr(RAM_ADDR_BITS - 1 downto 0)));
          if we = '1' then
            ram(index) <= din;
            dout_reg   <= din;
          else
            dout_reg <= ram(index);
          end if;
          ack <= '1';
        end if;
      end if;
    end if;
  end process;
end architecture;
