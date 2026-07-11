library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Linux-capable RV32IMA/Sv32 CPU front end.  It arbitrates the VexRiscv
-- instruction and data cache-fill ports onto the System16 32-bit bus.
entity sys16_rv32_soc is
  port (
    clk, reset_n : in std_logic;
    bus_req, bus_we : out std_logic;
    bus_addr, bus_wdata : out std_logic_vector(31 downto 0);
    bus_be : out std_logic_vector(3 downto 0);
    bus_rdata : in std_logic_vector(31 downto 0);
    bus_ready, external_irq : in std_logic;
    uart_rx : in std_logic;
    uart_tx : out std_logic;
    cpu_seen, uart_seen, bridge_alive, fetch_seen, fetch_rsp_seen : out std_logic;
    sbi_fetch_seen, data_req_seen, data_rsp_seen, kernel_fetch_seen : out std_logic;
    sbi_progress : out std_logic_vector(3 downto 0);
    last_fetch_addr : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of sys16_rv32_soc is
  component sys16_vex_bridge is port (
    clk,reset,timer_irq,external_irq,software_irq:in std_logic;
    i_valid:out std_logic;i_ready:in std_logic;i_addr:out std_logic_vector(31 downto 0);i_size:out std_logic_vector(2 downto 0);
    i_rsp_valid:in std_logic;i_rsp_data:in std_logic_vector(31 downto 0);
    d_valid:out std_logic;d_ready:in std_logic;d_write:out std_logic;
    d_addr,d_wdata:out std_logic_vector(31 downto 0);d_mask:out std_logic_vector(3 downto 0);d_size:out std_logic_vector(2 downto 0);
    d_rsp_valid:in std_logic;d_rsp_data:in std_logic_vector(31 downto 0);d_rsp_last:in std_logic;
    bridge_alive,fetch_seen:out std_logic
  );end component;
  type state_t is (IDLE, MEM_WAIT, MEM_DROP, TIMER_WAIT, UART_WAIT, RESPONSE);
  signal state:state_t:=IDLE; signal owner_d:std_logic:='0';
  signal dv,dr,dwr,iv,ir:std_logic; signal da,dd,ia:std_logic_vector(31 downto 0); signal dm:std_logic_vector(3 downto 0);
  signal isize:std_logic_vector(2 downto 0);signal burst_left:natural range 1 to 32:=1;
  signal dsize:std_logic_vector(2 downto 0);signal d_rsp_last:std_logic:='1';
  signal q:std_logic_vector(31 downto 0):=(others=>'0'); signal a,w:std_logic_vector(31 downto 0); signal lanes:std_logic_vector(3 downto 0); signal wr:std_logic;
  signal d_rsp,i_rsp:std_logic:='0'; signal timer_req,timer_ready,timer_irq,soft_irq:std_logic; signal timer_q:std_logic_vector(31 downto 0);
  signal cpu_reset : std_logic;
  signal uart_req : std_logic; signal uart_q : std_logic_vector(31 downto 0);
  signal cpu_seen_r, uart_seen_r : std_logic := '0';
  signal fetch_rsp_seen_r : std_logic := '0';
  signal sbi_fetch_seen_r, data_req_seen_r, data_rsp_seen_r,
         kernel_fetch_seen_r : std_logic := '0';
  signal sbi_progress_r : std_logic_vector(3 downto 0) := (others=>'0');
  signal last_fetch_addr_r : std_logic_vector(31 downto 0) := (others=>'0');
begin
  cpu_seen<=cpu_seen_r;uart_seen<=uart_seen_r;fetch_rsp_seen<=fetch_rsp_seen_r;
  sbi_fetch_seen<=sbi_fetch_seen_r;data_req_seen<=data_req_seen_r;
  data_rsp_seen<=data_rsp_seen_r;kernel_fetch_seen<=kernel_fetch_seen_r;
  sbi_progress<=sbi_progress_r;
  last_fetch_addr<=last_fetch_addr_r;
  cpu_reset <= not reset_n;
  bus_req<='1' when state=MEM_WAIT else '0'; bus_addr<=a; bus_wdata<=w; bus_be<=lanes; bus_we<=wr;
  timer_req<='1' when state=TIMER_WAIT else '0';
  uart_req<='1' when state=UART_WAIT else '0';
  dr<='1' when state=IDLE else '0'; ir<='1' when state=IDLE and dv='0' else '0';
  cpu:sys16_vex_bridge port map(
    clk=>clk,reset=>cpu_reset,timer_irq=>timer_irq,external_irq=>external_irq,software_irq=>soft_irq,
    i_valid=>iv,i_ready=>ir,i_addr=>ia,i_size=>isize,i_rsp_valid=>i_rsp,i_rsp_data=>q,
    d_valid=>dv,d_ready=>dr,d_write=>dwr,d_addr=>da,d_wdata=>dd,d_mask=>dm,d_size=>dsize,
    d_rsp_valid=>d_rsp,d_rsp_data=>q,d_rsp_last=>d_rsp_last,bridge_alive=>bridge_alive,fetch_seen=>fetch_seen);
  timer:entity work.sys16_timer32 port map(clk=>clk,reset_n=>reset_n,req=>timer_req,we=>wr,addr=>a(4 downto 0),be=>lanes,wdata=>w,rdata=>timer_q,ready=>timer_ready,timer_irq=>timer_irq,software_irq=>soft_irq);
  uart:entity work.sys16_uart16550 port map(clk=>clk,reset_n=>reset_n,req=>uart_req,we=>wr,addr=>a(2 downto 0),be=>lanes,wdata=>w,rdata=>uart_q,uart_rx=>uart_rx,uart_tx=>uart_tx);
  process(clk) begin if rising_edge(clk) then
    d_rsp<='0';i_rsp<='0';d_rsp_last<='1';
    if reset_n='0' then state<=IDLE;owner_d<='0';q<=(others=>'0');cpu_seen_r<='0';uart_seen_r<='0';fetch_rsp_seen_r<='0';
      sbi_fetch_seen_r<='0';data_req_seen_r<='0';data_rsp_seen_r<='0';kernel_fetch_seen_r<='0';
      sbi_progress_r<=(others=>'0');
      last_fetch_addr_r<=(others=>'0');
    else case state is
      when IDLE => if dv='1' then cpu_seen_r<='1';data_req_seen_r<='1';owner_d<='1';a<=da;w<=dd;lanes<=dm;wr<=dwr;
                     if dwr='0' and unsigned(dsize)>=2 then burst_left<=2**(to_integer(unsigned(dsize))-2);else burst_left<=1;end if;
                     if da(31 downto 12)=x"F0001" then state<=TIMER_WAIT;elsif da(31 downto 8)=x"F00000" then uart_seen_r<='1';state<=UART_WAIT;else state<=MEM_WAIT;end if;
                   elsif iv='1' then cpu_seen_r<='1';owner_d<='0';a<=ia;w<=(others=>'0');lanes<="1111";wr<='0';
                     last_fetch_addr_r<=ia;
                     if unsigned(ia)>=16#2000# and unsigned(ia)<16#100000# then sbi_fetch_seen_r<='1';end if;
                     -- Milestones around OpenSBI's first atomic lottery and
                     -- relocation loop. Keep the highest one reached.
                     if unsigned(ia)>=16#3000# and unsigned(ia)<16#100000# then sbi_progress_r<=x"4";
                     elsif unsigned(ia)>=16#2100# and unsigned(ia)<16#100000# and unsigned(sbi_progress_r)<3 then sbi_progress_r<=x"3";
                     elsif unsigned(ia)>=16#208C# and unsigned(ia)<16#100000# and unsigned(sbi_progress_r)<2 then sbi_progress_r<=x"2";
                     elsif unsigned(ia)>=16#2040# and unsigned(ia)<16#100000# and unsigned(sbi_progress_r)<1 then sbi_progress_r<=x"1";
                     end if;
                     if unsigned(ia)>=16#400000# and unsigned(ia)<16#F00000# then kernel_fetch_seen_r<='1';end if;
                     if unsigned(isize)>=2 then burst_left<=2**(to_integer(unsigned(isize))-2);else burst_left<=1;end if;
                     state<=MEM_WAIT;end if;
      when MEM_WAIT => if bus_ready='1' then q<=bus_rdata;state<=MEM_DROP;end if;
      when MEM_DROP => if bus_ready='0' then state<=RESPONSE;end if;
      when TIMER_WAIT => if timer_ready='1' then q<=timer_q;state<=RESPONSE;end if;
      when UART_WAIT => q<=uart_q; state<=RESPONSE;
      when RESPONSE => if owner_d='1' then d_rsp<='1';data_rsp_seen_r<='1';if wr='0' and burst_left>1 then d_rsp_last<='0';burst_left<=burst_left-1;a<=std_logic_vector(unsigned(a)+4);state<=MEM_WAIT;else d_rsp_last<='1';state<=IDLE;end if;
        else i_rsp<='1';fetch_rsp_seen_r<='1';if burst_left>1 then burst_left<=burst_left-1;a<=std_logic_vector(unsigned(a)+4);state<=MEM_WAIT;else state<=IDLE;end if;end if;
    end case; end if; end if; end process;
end architecture;
