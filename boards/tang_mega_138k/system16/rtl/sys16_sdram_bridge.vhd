library ieee;
use ieee.std_logic_1164.all;

entity sys16_sdram_bridge is
  port (
    clk       : in  std_logic;
    reset_n   : in  std_logic;
    req       : in  std_logic;
    we        : in  std_logic;
    addr      : in  std_logic_vector(23 downto 1);
    be        : in  std_logic_vector(1 downto 0);
    wdata     : in  std_logic_vector(15 downto 0);
    rdata     : out std_logic_vector(15 downto 0);
    ready     : out std_logic;
    init_done : out std_logic;

    sdram_cs_n  : out   std_logic;
    sdram_ras_n : out   std_logic;
    sdram_cas_n : out   std_logic;
    sdram_we_n  : out   std_logic;
    sdram_ba    : out   std_logic_vector(1 downto 0);
    sdram_addr  : out   std_logic_vector(12 downto 0);
    sdram_dqm   : out   std_logic_vector(1 downto 0);
    sdram_dq    : inout std_logic_vector(15 downto 0)
  );
end entity;

architecture rtl of sys16_sdram_bridge is
  type state_t is (S_WAIT_INIT, S_IDLE, S_READ_REQ, S_READ_WAIT,
                   S_WRITE_REQ, S_WRITE_WAIT, S_RESPONSE);

  signal state       : state_t := S_WAIT_INIT;
  signal addr_latch  : std_logic_vector(23 downto 1) := (others => '0');
  signal be_latch    : std_logic_vector(1 downto 0) := (others => '0');
  signal wdata_latch : std_logic_vector(15 downto 0) := (others => '0');
  signal rdata_latch : std_logic_vector(15 downto 0) := (others => '0');
  signal init_done_i : std_logic := '0';

  signal ctrl_idle          : std_logic;
  signal wr_burst_req       : std_logic := '0';
  signal wr_burst_data_req  : std_logic;
  signal wr_burst_finish    : std_logic;
  signal rd_burst_req       : std_logic := '0';
  signal rd_burst_data      : std_logic_vector(15 downto 0);
  signal rd_burst_valid     : std_logic;
  signal rd_burst_finish    : std_logic;
  signal sdram_rst          : std_logic;
  signal burst_addr         : std_logic_vector(23 downto 0);
  signal write_dqm          : std_logic_vector(1 downto 0);
begin
  rdata     <= rdata_latch;
  ready     <= '1' when state = S_RESPONSE else '0';
  init_done <= init_done_i;
  sdram_rst <= not reset_n;
  burst_addr <= '0' & addr_latch;
  write_dqm <= not be_latch;

  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        state         <= S_WAIT_INIT;
        addr_latch    <= (others => '0');
        be_latch      <= (others => '0');
        wdata_latch   <= (others => '0');
        rdata_latch   <= (others => '0');
        init_done_i   <= '0';
        wr_burst_req  <= '0';
        rd_burst_req  <= '0';
      else
        case state is
          when S_WAIT_INIT =>
            wr_burst_req <= '0';
            rd_burst_req <= '0';
            if ctrl_idle = '1' then
              init_done_i <= '1';
              state       <= S_IDLE;
            end if;

          when S_IDLE =>
            wr_burst_req <= '0';
            rd_burst_req <= '0';
            if req = '1' then
              addr_latch  <= addr;
              be_latch    <= be;
              wdata_latch <= wdata;
              if we = '1' then
                state <= S_WRITE_REQ;
              else
                state <= S_READ_REQ;
              end if;
            end if;

          when S_READ_REQ =>
            rd_burst_req <= '1';
            if rd_burst_valid = '1' then
              rdata_latch <= rd_burst_data;
              rd_burst_req <= '0';
              state <= S_READ_WAIT;
            end if;

          when S_READ_WAIT =>
            rd_burst_req <= '0';
            if ctrl_idle = '1' then
              state <= S_RESPONSE;
            end if;

          when S_WRITE_REQ =>
            wr_burst_req <= '1';
            if wr_burst_data_req = '1' then
              wr_burst_req <= '0';
              state <= S_WRITE_WAIT;
            end if;

          when S_WRITE_WAIT =>
            wr_burst_req <= '0';
            if ctrl_idle = '1' then
              state <= S_RESPONSE;
            end if;

          when S_RESPONSE =>
            wr_burst_req <= '0';
            rd_burst_req <= '0';
            if req = '0' then
              state <= S_IDLE;
            end if;
        end case;
      end if;
    end if;
  end process;

  ctrl_i : entity work.sdram_ctrl
    port map (
      clk                   => clk,
      rst                   => sdram_rst,
      wr_burst_req          => wr_burst_req,
      wr_burst_data         => wdata_latch,
      wr_burst_len          => "0000000001",
      wr_burst_addr         => burst_addr,
      wr_dqm                => write_dqm,
      wr_burst_data_req     => wr_burst_data_req,
      wr_burst_finish       => wr_burst_finish,
      rd_burst_req          => rd_burst_req,
      rd_burst_len          => "0000000001",
      rd_burst_addr         => burst_addr,
      rd_burst_data         => rd_burst_data,
      rd_burst_data_valid   => rd_burst_valid,
      rd_burst_finish       => rd_burst_finish,
      sdram_cke             => open,
      sdram_cs_n            => sdram_cs_n,
      sdram_ras_n           => sdram_ras_n,
      sdram_cas_n           => sdram_cas_n,
      sdram_we_n            => sdram_we_n,
      sdram_ba              => sdram_ba,
      sdram_addr            => sdram_addr,
      sdram_dqm             => sdram_dqm,
      sdram_dq              => sdram_dq,
      ctrl_idle             => ctrl_idle
    );
end architecture;
