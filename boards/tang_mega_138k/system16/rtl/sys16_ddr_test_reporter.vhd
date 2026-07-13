library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
entity sys16_ddr_test_reporter is
  port(clk,reset_n,start,failed,calib_failed:in std_logic;tx:out std_logic;active,done:out std_logic);
end entity;
architecture rtl of sys16_ddr_test_reporter is
  constant N:natural:=25;
  type bytes_t is array(0 to N-1) of std_logic_vector(7 downto 0);
  constant PASS_MSG:bytes_t:=(x"44",x"44",x"52",x"33",x"20",x"46",x"55",x"4C",x"4C",x"20",x"54",x"45",x"53",x"54",x"20",x"50",x"41",x"53",x"53",x"20",x"31",x"47",x"42",x"20",x"0A");
  constant FAIL_MSG:bytes_t:=(x"44",x"44",x"52",x"33",x"20",x"46",x"55",x"4C",x"4C",x"20",x"54",x"45",x"53",x"54",x"20",x"46",x"41",x"49",x"4C",x"20",x"20",x"20",x"20",x"20",x"0A");
  constant CAL_MSG:bytes_t:=(x"44",x"44",x"52",x"33",x"20",x"43",x"41",x"4C",x"49",x"42",x"52",x"41",x"54",x"49",x"4F",x"4E",x"20",x"46",x"41",x"49",x"4C",x"20",x"20",x"20",x"0A");
  type state_t is(IDLE,LAUNCH,WAIT_BUSY,WAIT_DONE,FINISHED);
  signal state:state_t:=IDLE;signal idx:natural range 0 to N-1:=0;
  signal valid,busy,fail_l,cal_l:std_logic:='0';signal data:std_logic_vector(7 downto 0);
begin
  active<='1' when state/=IDLE and state/=FINISHED else '0';
  done<='1' when state=FINISHED else '0';
  data<=CAL_MSG(idx) when cal_l='1' else FAIL_MSG(idx) when fail_l='1' else PASS_MSG(idx);
  tx_i:entity work.uart_tx_ser generic map(CLK_HZ=>50_000_000,BAUD=>115_200)
    port map(clk=>clk,reset_n=>reset_n,data=>data,valid=>valid,tx=>tx,busy=>busy);
  process(clk)begin if rising_edge(clk)then valid<='0';if reset_n='0'then idx<=0;state<=IDLE;fail_l<='0';cal_l<='0';
    else case state is
      when IDLE=>if start='1'then fail_l<=failed;cal_l<=calib_failed;state<=LAUNCH;end if;
      when LAUNCH=>valid<='1';state<=WAIT_BUSY;
      when WAIT_BUSY=>if busy='1'then state<=WAIT_DONE;end if;
      when WAIT_DONE=>if busy='0'then if idx=N-1 then state<=FINISHED;else idx<=idx+1;state<=LAUNCH;end if;end if;
      when FINISHED=>null;
    end case;end if;end if;end process;
end architecture;
