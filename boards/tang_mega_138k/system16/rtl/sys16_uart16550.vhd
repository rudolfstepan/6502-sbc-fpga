library ieee;
use ieee.std_logic_1164.all;

-- Small 16550-compatible polling UART for OpenSBI/Linux. Interrupt and modem
-- functions are intentionally inert; THR/RBR and LSR implement the standard
-- byte register layout with reg-shift 0.
entity sys16_uart16550 is
  generic (CLK_HZ : positive := 50_000_000; BAUD : positive := 115_200);
  port (
    clk, reset_n : in std_logic;
    req, we : in std_logic;
    addr : in std_logic_vector(2 downto 0);
    be : in std_logic_vector(3 downto 0);
    wdata : in std_logic_vector(31 downto 0);
    rdata : out std_logic_vector(31 downto 0);
    uart_rx : in std_logic;
    uart_tx : out std_logic
  );
end entity;

architecture rtl of sys16_uart16550 is
  signal tx_data, rx_data, rx_latch : std_logic_vector(7 downto 0) := (others=>'0');
  signal tx_valid, tx_busy, rx_valid, rx_pending : std_logic := '0';
  signal ier : std_logic_vector(7 downto 0) := (others=>'0');
  signal lcr : std_logic_vector(7 downto 0) := x"03";
  signal mcr : std_logic_vector(7 downto 0) := (others=>'0');
  signal read_byte : std_logic_vector(7 downto 0);
begin
  tx_i:entity work.uart_tx_ser generic map(CLK_HZ=>CLK_HZ,BAUD=>BAUD)
    port map(clk=>clk,reset_n=>reset_n,data=>tx_data,valid=>tx_valid,tx=>uart_tx,busy=>tx_busy);
  rx_i:entity work.uart_rx_ser generic map(CLK_HZ=>CLK_HZ,BAUD=>BAUD)
    port map(clk=>clk,reset_n=>reset_n,rx=>uart_rx,data=>rx_data,valid=>rx_valid);

  process(addr,rx_latch,rx_pending,tx_busy,tx_valid,ier,lcr,mcr)
  begin
    read_byte <= (others=>'0');
    case addr is
      when "000" => read_byte <= rx_latch;                  -- RBR
      when "001" => read_byte <= ier;                       -- IER
      when "010" => read_byte <= x"01";                     -- IIR: no IRQ
      when "011" => read_byte <= lcr;
      when "100" => read_byte <= mcr;
      when "101" => read_byte <= "011000" & '0' & rx_pending; -- LSR THRE|TEMT
      when others => null;
    end case;
  end process;
  rdata <= read_byte & read_byte & read_byte & read_byte;

  process(clk)
    variable value : std_logic_vector(7 downto 0);
  begin
    if rising_edge(clk) then
      tx_valid <= '0';
      if reset_n='0' then
        rx_pending<='0'; ier<=(others=>'0'); lcr<=x"03"; mcr<=(others=>'0');
      else
        if rx_valid='1' then rx_latch<=rx_data; rx_pending<='1'; end if;
        value := wdata(7 downto 0);
        if be(1)='1' then value:=wdata(15 downto 8);
        elsif be(2)='1' then value:=wdata(23 downto 16);
        elsif be(3)='1' then value:=wdata(31 downto 24); end if;
        if req='1' then
          if we='1' then
            case addr is
              when "000" => if tx_busy='0' then tx_data<=value;tx_valid<='1';end if;
              when "001" => ier<=value;
              when "010" => null; -- FCR accepted
              when "011" => lcr<=value;
              when "100" => mcr<=value;
              when others => null;
            end case;
          elsif addr="000" then rx_pending<='0';
          end if;
        end if;
      end if;
    end if;
  end process;
end architecture;
