library ieee;
use ieee.std_logic_1164.all;

entity tb_sys16_uart is
end entity;

architecture sim of tb_sys16_uart is
  signal clk        : std_logic := '0';
  signal reset_n    : std_logic := '0';
  signal req        : std_logic := '0';
  signal we         : std_logic := '0';
  signal be         : std_logic_vector(1 downto 0) := "00";
  signal reg_offset : std_logic_vector(7 downto 0) := x"12";
  signal wdata      : std_logic_vector(15 downto 0) := (others => '0');
  signal rdata      : std_logic_vector(15 downto 0);
  signal uart_rx    : std_logic := '1';
  signal uart_tx    : std_logic;
begin
  clk <= not clk after 500 ns;

  dut : entity work.sys16_uart
    generic map (
      CLK_HZ => 1_000_000,
      BAUD   => 100_000
    )
    port map (
      clk        => clk,
      reset_n    => reset_n,
      req        => req,
      we         => we,
      be         => be,
      reg_offset => reg_offset,
      wdata      => wdata,
      rdata      => rdata,
      uart_rx    => uart_rx,
      uart_tx    => uart_tx
    );

  stimulus : process
    constant EXPECTED : std_logic_vector(7 downto 0) := x"55";
  begin
    wait for 3 us;
    reset_n <= '1';
    wait until rising_edge(clk);
    wait for 1 ns;
    assert rdata(0) = '1' report "UART not ready after reset" severity failure;

    -- Model adjacent 68000 MMIO cycles: status read followed immediately by
    -- the data write, without requiring req to go low for a clk cycle.
    reg_offset <= x"12";
    we         <= '0';
    req        <= '1';
    wait until rising_edge(clk);

    reg_offset <= x"10";
    wdata      <= x"0055";
    be         <= "11";
    we         <= '1';
    wait until rising_edge(clk);
    req <= '0';
    we  <= '0';

    wait for 2 us;
    assert uart_tx = '0' report "UART start bit missing" severity failure;
    wait for 3 us;

    for i in 0 to 7 loop
      wait for 10 us;
      assert uart_tx = EXPECTED(i) report "UART data bit mismatch" severity failure;
    end loop;

    wait for 10 us;
    assert uart_tx = '1' report "UART stop bit missing" severity failure;
    wait for 12 us;

    reg_offset <= x"12";
    wait for 1 ns;
    assert rdata(0) = '1' report "UART did not return to ready" severity failure;

    report "tb_sys16_uart passed" severity note;
    wait;
  end process;
end architecture;
