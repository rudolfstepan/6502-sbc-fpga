-- Byte-oriented backend for the Tang Console SDRAM0 connector.
--
-- Presents the same one-request/one-ack byte interface as bram_byte_bridge,
-- while rtl/core/mem/sdram_if.vhd and sdram_ctrl.vhd perform the 16-bit SDRAM
-- burst access. On reset the lower RAM window is cleared before ram_ready is
-- asserted, matching the old BRAM bring-up behaviour.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity sdram_byte_bridge is
  generic (
    BUS_ADDR_BITS   : positive := 15;
    CLEAR_ADDR_BITS : positive := 13
  );
  port (
    clk       : in  std_logic;
    reset_n   : in  std_logic;
    req       : in  std_logic;
    we        : in  std_logic;
    addr      : in  std_logic_vector(BUS_ADDR_BITS - 1 downto 0);
    din       : in  data_t;
    dout      : out data_t;
    ack       : out std_logic;
    ram_ready : out std_logic;

    ram_test_active    : out std_logic;
    ram_test_done      : out std_logic;
    ram_test_error     : out std_logic;
    ram_test_phase     : out std_logic_vector(3 downto 0);
    ram_test_addr      : out std_logic_vector(BUS_ADDR_BITS - 1 downto 0);
    ram_test_fail_addr : out std_logic_vector(BUS_ADDR_BITS - 1 downto 0);
    ram_test_expected  : out data_t;
    ram_test_actual    : out data_t;

    sdram_cke   : out   std_logic;
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

architecture rtl of sdram_byte_bridge is
  type state_t is (S_WAIT_INIT, S_CLEAR_PULSE, S_CLEAR_WAIT, S_READY,
                   S_REQ_WAIT);

  signal state      : state_t := S_WAIT_INIT;
  signal clear_addr : unsigned(CLEAR_ADDR_BITS - 1 downto 0) := (others => '0');
  signal wait_low   : std_logic := '0';

  signal if_addr       : std_logic_vector(14 downto 0) := (others => '0');
  signal if_din        : data_t := (others => '0');
  signal if_dout       : data_t;
  signal if_cs         : std_logic := '0';
  signal if_cpu_we     : std_logic := '0';
  signal if_cpu_bus_we : std_logic := '0';
  signal if_rdy        : std_logic;
  signal ctrl_idle     : std_logic;
  signal sdram_rst     : std_logic;

  signal wr_burst_req        : std_logic;
  signal wr_burst_data       : std_logic_vector(15 downto 0);
  signal wr_burst_len        : std_logic_vector(9 downto 0);
  signal wr_burst_addr       : std_logic_vector(23 downto 0);
  signal wr_dqm              : std_logic_vector(1 downto 0);
  signal wr_burst_data_req   : std_logic;
  signal wr_burst_finish     : std_logic;
  signal rd_burst_req        : std_logic;
  signal rd_burst_len        : std_logic_vector(9 downto 0);
  signal rd_burst_addr       : std_logic_vector(23 downto 0);
  signal rd_burst_data       : std_logic_vector(15 downto 0);
  signal rd_burst_data_valid : std_logic;
  signal rd_burst_finish     : std_logic;

  signal dout_reg : data_t := (others => '0');
begin
  dout <= dout_reg;
  sdram_rst <= not reset_n;

  ram_test_error     <= '0';
  ram_test_fail_addr <= (others => '0');
  ram_test_expected  <= (others => '0');
  ram_test_actual    <= (others => '0');
  ram_test_addr      <= std_logic_vector(resize(clear_addr, BUS_ADDR_BITS));

  process(clk)
    variable req_addr15 : std_logic_vector(14 downto 0);
  begin
    if rising_edge(clk) then
      ack           <= '0';
      if_cpu_bus_we <= '0';

      if reset_n = '0' then
        state           <= S_WAIT_INIT;
        clear_addr      <= (others => '0');
        wait_low        <= '0';
        if_addr         <= (others => '0');
        if_din          <= (others => '0');
        if_cs           <= '0';
        if_cpu_we       <= '0';
        dout_reg        <= (others => '0');
        ram_ready       <= '0';
        ram_test_active <= '0';
        ram_test_done   <= '0';
        ram_test_phase  <= x"0";
      else
        case state is
          when S_WAIT_INIT =>
            if_cs           <= '0';
            if_cpu_we       <= '0';
            ram_ready       <= '0';
            ram_test_active <= '1';
            ram_test_done   <= '0';
            ram_test_phase  <= x"1";
            wait_low        <= '0';
            if ctrl_idle = '1' then
              state <= S_CLEAR_PULSE;
            end if;

          when S_CLEAR_PULSE =>
            if_addr         <= std_logic_vector(resize(clear_addr, if_addr'length));
            if_din          <= (others => '0');
            if_cpu_we       <= '1';
            if_cpu_bus_we   <= '1';
            if_cs           <= '1';
            ram_ready       <= '0';
            ram_test_active <= '1';
            ram_test_done   <= '0';
            ram_test_phase  <= x"4";
            wait_low        <= '0';
            state           <= S_CLEAR_WAIT;

          when S_CLEAR_WAIT =>
            if_cs           <= '1';
            if_cpu_we       <= '1';
            ram_ready       <= '0';
            ram_test_active <= '1';
            ram_test_done   <= '0';
            ram_test_phase  <= x"4";
            if if_rdy = '0' then
              wait_low <= '1';
            elsif wait_low = '1' then
              if_cs    <= '0';
              wait_low <= '0';
              if clear_addr = to_unsigned((2 ** CLEAR_ADDR_BITS) - 1, CLEAR_ADDR_BITS) then
                state <= S_READY;
              else
                clear_addr <= clear_addr + 1;
                state      <= S_CLEAR_PULSE;
              end if;
            end if;

          when S_READY =>
            if_cs           <= '0';
            if_cpu_we       <= '0';
            ram_ready       <= '1';
            ram_test_active <= '0';
            ram_test_done   <= '1';
            ram_test_phase  <= x"3";
            wait_low        <= '0';
            if req = '1' then
              req_addr15 := (others => '0');
              if BUS_ADDR_BITS >= 15 then
                req_addr15 := addr(14 downto 0);
              else
                req_addr15(BUS_ADDR_BITS - 1 downto 0) := addr;
              end if;
              if_addr       <= req_addr15;
              if_din        <= din;
              if_cpu_we     <= we;
              if_cs         <= '1';
              if we = '1' then
                if_cpu_bus_we <= '1';
              end if;
              state <= S_REQ_WAIT;
            end if;

          when S_REQ_WAIT =>
            if_cs     <= '1';
            ram_ready <= '1';
            if if_rdy = '0' then
              wait_low <= '1';
            elsif wait_low = '1' then
              dout_reg <= if_dout;
              ack      <= '1';
              if_cs    <= '0';
              wait_low <= '0';
              state    <= S_READY;
            end if;
        end case;
      end if;
    end if;
  end process;

  sdram_if_i : entity work.sdram_if
    port map (
      clk       => clk,
      reset_n   => reset_n,
      addr      => if_addr,
      din       => if_din,
      dout      => if_dout,
      cs        => if_cs,
      cpu_we    => if_cpu_we,
      cpu_bus_we=> if_cpu_bus_we,
      rdy       => if_rdy,
      ctrl_idle => ctrl_idle,
      wr_burst_req        => wr_burst_req,
      wr_burst_data       => wr_burst_data,
      wr_burst_len        => wr_burst_len,
      wr_burst_addr       => wr_burst_addr,
      wr_dqm              => wr_dqm,
      wr_burst_data_req   => wr_burst_data_req,
      wr_burst_finish     => wr_burst_finish,
      rd_burst_req        => rd_burst_req,
      rd_burst_len        => rd_burst_len,
      rd_burst_addr       => rd_burst_addr,
      rd_burst_data       => rd_burst_data,
      rd_burst_data_valid => rd_burst_data_valid,
      rd_burst_finish     => rd_burst_finish
    );

  sdram_ctrl_i : entity work.sdram_ctrl
    port map (
      clk                 => clk,
      rst                 => sdram_rst,
      wr_burst_req        => wr_burst_req,
      wr_burst_data       => wr_burst_data,
      wr_burst_len        => wr_burst_len,
      wr_burst_addr       => wr_burst_addr,
      wr_dqm              => wr_dqm,
      wr_burst_data_req   => wr_burst_data_req,
      wr_burst_finish     => wr_burst_finish,
      rd_burst_req        => rd_burst_req,
      rd_burst_len        => rd_burst_len,
      rd_burst_addr       => rd_burst_addr,
      rd_burst_data       => rd_burst_data,
      rd_burst_data_valid => rd_burst_data_valid,
      rd_burst_finish     => rd_burst_finish,
      sdram_cke           => sdram_cke,
      sdram_cs_n          => sdram_cs_n,
      sdram_ras_n         => sdram_ras_n,
      sdram_cas_n         => sdram_cas_n,
      sdram_we_n          => sdram_we_n,
      sdram_ba            => sdram_ba,
      sdram_addr          => sdram_addr,
      sdram_dqm           => sdram_dqm,
      sdram_dq            => sdram_dq,
      ctrl_idle           => ctrl_idle
    );
end architecture;
