library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.sbc_pkg.all;

entity tb_bram_byte_bridge is
end entity;

architecture sim of tb_bram_byte_bridge is
  constant CLK_PERIOD : time := 10 ns;
  signal clk, reset_n, req, we, ack, ready : std_logic := '0';
  signal addr : std_logic_vector(14 downto 0) := (others => '0');
  signal din, dout : data_t := (others => '0');
  signal test_active, test_done, test_error : std_logic;
  signal test_phase : std_logic_vector(3 downto 0);
  signal test_addr, fail_addr : std_logic_vector(14 downto 0);
  signal expected, actual : data_t;
begin
  clk <= not clk after CLK_PERIOD / 2;

  dut : entity work.bram_byte_bridge
    generic map (BUS_ADDR_BITS => 15, RAM_ADDR_BITS => 4)
    port map (
      clk => clk, reset_n => reset_n, req => req, we => we,
      addr => addr, din => din, dout => dout, ack => ack, ram_ready => ready,
      ram_test_active => test_active, ram_test_done => test_done,
      ram_test_error => test_error, ram_test_phase => test_phase,
      ram_test_addr => test_addr, ram_test_fail_addr => fail_addr,
      ram_test_expected => expected, ram_test_actual => actual
    );

  test : process
  begin
    wait for 4 * CLK_PERIOD;
    reset_n <= '1';
    wait until ready = '1';
    assert test_done = '1' and test_error = '0'
      report "BSRAM clear/status failed" severity failure;

    wait until falling_edge(clk);
    addr <= std_logic_vector(to_unsigned(16#4001#, 15));
    din <= x"A5";
    we <= '1'; req <= '1';
    wait until rising_edge(clk);
    wait until falling_edge(clk);
    assert ack = '1' report "BSRAM write acknowledge missing" severity failure;
    req <= '0'; we <= '0';

    wait until falling_edge(clk);
    req <= '1';
    wait until rising_edge(clk);
    wait until falling_edge(clk);
    assert ack = '1' report "BSRAM read acknowledge missing" severity failure;
    req <= '0';
    assert dout = x"A5" report "BSRAM byte readback failed" severity failure;

    report "tb_bram_byte_bridge passed" severity note;
    finish;
  end process;
end architecture;
