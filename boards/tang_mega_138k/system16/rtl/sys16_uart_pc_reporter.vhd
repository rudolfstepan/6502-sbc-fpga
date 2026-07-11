library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- One-shot UART report: "PC=XXXXXXXX\r\n".
entity sys16_uart_pc_reporter is
  port(clk,reset_n,start:in std_logic; pc:in std_logic_vector(31 downto 0);
       tx:out std_logic; active,done:out std_logic);
end entity;
architecture rtl of sys16_uart_pc_reporter is
  type state_t is(IDLE,LAUNCH,WAIT_BUSY,WAIT_DONE,FINISHED);
  signal state:state_t:=IDLE;signal idx:natural range 0 to 12:=0;
  signal valid,busy:std_logic:='0';signal data:std_logic_vector(7 downto 0);
  signal pc_l:std_logic_vector(31 downto 0):=(others=>'0');
  function hexchar(n:std_logic_vector(3 downto 0)) return std_logic_vector is
  begin
    if unsigned(n)<10 then return std_logic_vector(to_unsigned(48+to_integer(unsigned(n)),8));
    else return std_logic_vector(to_unsigned(55+to_integer(unsigned(n)),8));end if;
  end;
begin
  active<='1' when state/=IDLE and state/=FINISHED else '0';
  done<='1' when state=FINISHED else '0';
  with idx select data<=x"50" when 0,x"43" when 1,x"3D" when 2,
    hexchar(pc_l(31 downto 28)) when 3,hexchar(pc_l(27 downto 24)) when 4,
    hexchar(pc_l(23 downto 20)) when 5,hexchar(pc_l(19 downto 16)) when 6,
    hexchar(pc_l(15 downto 12)) when 7,hexchar(pc_l(11 downto 8)) when 8,
    hexchar(pc_l(7 downto 4)) when 9,hexchar(pc_l(3 downto 0)) when 10,
    x"0D" when 11,x"0A" when others;
  tx_i:entity work.uart_tx_ser generic map(CLK_HZ=>50_000_000,BAUD=>115_200)
    port map(clk=>clk,reset_n=>reset_n,data=>data,valid=>valid,tx=>tx,busy=>busy);
  process(clk)begin if rising_edge(clk)then valid<='0';if reset_n='0'then state<=IDLE;idx<=0;
    else case state is
      when IDLE=>if start='1'theN pc_l<=pc;state<=LAUNCH;end if;
      when LAUNCH=>valid<='1';state<=WAIT_BUSY;
      when WAIT_BUSY=>if busy='1'then state<=WAIT_DONE;end if;
      when WAIT_DONE=>if busy='0'then if idx=12 then state<=FINISHED;else idx<=idx+1;state<=LAUNCH;end if;end if;
      when FINISHED=>null;
    end case;end if;end if;end process;
end architecture;
