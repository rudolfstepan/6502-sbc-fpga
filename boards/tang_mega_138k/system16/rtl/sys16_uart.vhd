library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sys16_uart is
  generic (
    CLK_HZ : positive := 50_000_000;
    BAUD   : positive := 115_200
  );
  port (
    clk        : in  std_logic;
    reset_n    : in  std_logic;
    req        : in  std_logic;
    we         : in  std_logic;
    be         : in  std_logic_vector(1 downto 0);
    reg_offset : in  std_logic_vector(7 downto 0);
    wdata      : in  std_logic_vector(15 downto 0);
    rdata      : out std_logic_vector(15 downto 0);
    uart_rx    : in  std_logic;
    uart_tx    : out std_logic
  );
end entity;

architecture rtl of sys16_uart is
  signal tx_data    : std_logic_vector(7 downto 0) := (others => '0');
  signal tx_valid   : std_logic := '0';
  signal tx_busy    : std_logic;
  signal rx_data    : std_logic_vector(7 downto 0);
  signal rx_valid   : std_logic;
  signal rx_latch   : std_logic_vector(7 downto 0) := (others => '0');
  signal rx_pending : std_logic := '0';
begin
  tx_i : entity work.uart_tx_ser
    generic map (
      CLK_HZ => CLK_HZ,
      BAUD   => BAUD
    )
    port map (
      clk     => clk,
      reset_n => reset_n,
      data    => tx_data,
      valid   => tx_valid,
      tx      => uart_tx,
      busy    => tx_busy
    );

  rx_i : entity work.uart_rx_ser
    generic map (
      CLK_HZ => CLK_HZ,
      BAUD   => BAUD
    )
    port map (
      clk     => clk,
      reset_n => reset_n,
      rx      => uart_rx,
      data    => rx_data,
      valid   => rx_valid
    );

  process(clk)
  begin
    if rising_edge(clk) then
      tx_valid <= '0';

      if reset_n = '0' then
        tx_data    <= (others => '0');
        rx_latch   <= (others => '0');
        rx_pending <= '0';
      else
        if req = '1' then
          if we = '1' and reg_offset = x"10" and tx_busy = '0' and tx_valid = '0' then
            if be(0) = '1' then
              tx_data <= wdata(7 downto 0);
              tx_valid <= '1';
            elsif be(1) = '1' then
              tx_data <= wdata(15 downto 8);
              tx_valid <= '1';
            end if;
          elsif we = '0' and reg_offset = x"14" then
            rx_pending <= '0';
          end if;
        end if;

        if rx_valid = '1' then
          rx_latch   <= rx_data;
          rx_pending <= '1';
        end if;
      end if;
    end if;
  end process;

  process(reg_offset, tx_busy, tx_valid, rx_pending, rx_latch)
  begin
    rdata <= (others => '0');
    case reg_offset is
      when x"12" =>
        rdata(0) <= not (tx_busy or tx_valid);
        rdata(1) <= rx_pending;
      when x"14" =>
        rdata(7 downto 0) <= rx_latch;
      when others =>
        null;
    end case;
  end process;
end architecture;
