library ieee;
use ieee.std_logic_1164.all;
entity sys16_ddr_progress_reporter is
  port(clk,reset_n,enable:in std_logic;progress:in std_logic_vector(6 downto 0);
       tx:out std_logic;active:out std_logic);
end entity;
architecture rtl of sys16_ddr_progress_reporter is
  type state_t is(IDLE,LAUNCH,WAIT_BUSY,WAIT_DONE);
  signal state:state_t:=IDLE;signal last:std_logic_vector(6 downto 0):=(others=>'0');
  signal valid,busy:std_logic:='0';
begin
  active<='1' when state/=IDLE else '0';
  tx_i:entity work.uart_tx_ser generic map(CLK_HZ=>50_000_000,BAUD=>115_200)
    port map(clk=>clk,reset_n=>reset_n,data=>x"2E",valid=>valid,tx=>tx,busy=>busy);
  process(clk)begin if rising_edge(clk)then valid<='0';
    if reset_n='0'then state<=IDLE;last<=(others=>'0');
    else case state is
      when IDLE=>if enable='1'and progress/=last then last<=progress;state<=LAUNCH;end if;
      when LAUNCH=>valid<='1';state<=WAIT_BUSY;
      when WAIT_BUSY=>if busy='1'then state<=WAIT_DONE;end if;
      when WAIT_DONE=>if busy='0'then state<=IDLE;end if;
    end case;end if;end if;end process;
end architecture;
