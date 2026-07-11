library ieee;
use ieee.std_logic_1164.all;

entity tb_sys16_bus32 is end entity;
architecture sim of tb_sys16_bus32 is
  signal clk : std_logic := '0'; signal reset_n, req, we, ready : std_logic := '0';
  signal addr, wdata, rdata : std_logic_vector(31 downto 0) := (others=>'0');
  signal be : std_logic_vector(3 downto 0) := (others=>'0');
  signal mr, mw, mready : std_logic := '0'; signal ma : std_logic_vector(23 downto 1);
  signal mbe : std_logic_vector(1 downto 0); signal mwd, mrd : std_logic_vector(15 downto 0) := (others=>'0');
begin
  clk <= not clk after 5 ns;
  dut: entity work.sys16_bus32_to_sdram16 port map(clk,reset_n,req,we,addr,be,wdata,rdata,ready,mr,mw,ma,mbe,mwd,mrd,mready);
  memory: process begin
    wait until mr='1'; wait until rising_edge(clk); mrd <= x"BEEF" when ma(1)='0' else x"CAFE"; mready<='1';
    wait until rising_edge(clk); mready<='0'; wait until mr='0';
  end process;
  test: process begin
    wait for 20 ns; reset_n<='1'; wait until rising_edge(clk);
    addr<=x"00102000"; be<="1111"; req<='1';
    wait until ready='1'; wait for 1 ns;
    assert rdata=x"CAFEBEEF" report "32-bit little-endian read failed" severity failure;
    req<='0'; wait until rising_edge(clk); report "tb_sys16_bus32 passed" severity note; wait;
  end process;
end architecture;
