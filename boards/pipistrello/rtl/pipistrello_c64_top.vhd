library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library UNISIM;
use UNISIM.Vcomponents.all;

entity pipistrello_c64_top is
  port (
    clk_50mhz : in  std_logic;
    reset_btn : in  std_logic;
    led       : out std_logic_vector(1 downto 0);
    uart_tx   : out std_logic;
    uart_rx   : in  std_logic;
    tmds      : out std_logic_vector(3 downto 0);
    tmdsb     : out std_logic_vector(3 downto 0)
  );
end entity;

architecture rtl of pipistrello_c64_top is
  signal pllclk0      : std_logic;
  signal pllclk1      : std_logic;
  signal pllclk2      : std_logic;
  signal clkfbout     : std_logic;
  signal pll_lckd     : std_logic;
  signal pclk         : std_logic;
  signal pclkx2       : std_logic;
  signal pclkx10      : std_logic;
  signal serdesstrobe : std_logic;
  signal bufpll_lock  : std_logic;
  signal reset        : std_logic;
  signal reset_n      : std_logic;
  signal cold_reset   : std_logic := '1';
  signal cold_cnt     : unsigned(16 downto 0) := (others => '0');

  signal hs : std_logic;
  signal vs : std_logic;
  signal de : std_logic;
  signal r5 : std_logic_vector(4 downto 0);
  signal g6 : std_logic_vector(5 downto 0);
  signal b5 : std_logic_vector(4 downto 0);
  signal r8 : std_logic_vector(7 downto 0);
  signal g8 : std_logic_vector(7 downto 0);
  signal b8 : std_logic_vector(7 downto 0);

  signal tmds_word0 : std_logic_vector(9 downto 0);
  signal tmds_word1 : std_logic_vector(9 downto 0);
  signal tmds_word2 : std_logic_vector(9 downto 0);
  signal tmds_data0 : std_logic_vector(4 downto 0) := (others => '0');
  signal tmds_data1 : std_logic_vector(4 downto 0) := (others => '0');
  signal tmds_data2 : std_logic_vector(4 downto 0) := (others => '0');
  signal tmdsint    : std_logic_vector(2 downto 0);
  signal tmdsclkint : std_logic_vector(4 downto 0);
  signal tmdsclk    : std_logic;
  signal toggle     : std_logic := '0';
  signal half_word  : std_logic := '0';
begin
  reset <= reset_btn or (not bufpll_lock);
  reset_n <= not reset;

  led(0) <= pll_lckd;
  led(1) <= de;

  pclkbufg : BUFG port map (I => pllclk1, O => pclk);
  pclkx2bufg : BUFG port map (I => pllclk2, O => pclkx2);

  pll_i : PLL_BASE
    generic map (
      CLKIN_PERIOD   => 20.0,
      DIVCLK_DIVIDE  => 2,
      CLKFBOUT_MULT  => 43,
      CLKOUT0_DIVIDE => 4,
      CLKOUT1_DIVIDE => 40,
      CLKOUT2_DIVIDE => 20,
      COMPENSATION   => "INTERNAL"
    )
    port map (
      CLKFBIN  => clkfbout,
      CLKFBOUT => clkfbout,
      CLKIN    => clk_50mhz,
      CLKOUT0  => pllclk0,
      CLKOUT1  => pllclk1,
      CLKOUT2  => pllclk2,
      CLKOUT3  => open,
      CLKOUT4  => open,
      CLKOUT5  => open,
      LOCKED   => pll_lckd,
      RST      => reset_btn
    );

  bufpll_i : BUFPLL
    generic map (DIVIDE => 5)
    port map (
      GCLK => pclkx2,
      IOCLK => pclkx10,
      LOCK => bufpll_lock,
      LOCKED => pll_lckd,
      PLLIN => pllclk0,
      SERDESSTROBE => serdesstrobe
    );

  process(pclk)
  begin
    if rising_edge(pclk) then
      if reset = '1' then
        cold_reset <= '1';
        cold_cnt <= (others => '0');
      elsif cold_cnt = to_unsigned(70000, cold_cnt'length) then
        cold_reset <= '0';
      else
        cold_cnt <= cold_cnt + 1;
      end if;
    end if;
  end process;

  c64_i : entity work.c64_core
    generic map (
      PHI2_DIV => 27,
      IEC_BUS_MODEL => false,
      MISTER_1541_ENABLE => false,
      HOST_UART_ENABLE => true
    )
    port map (
      clk => pclk,
      reset_n => reset_n,
      cold_reset => cold_reset,
      dbg_addr => open,
      dbg_we => open,
      dbg_do => open,
      dbg_di => open,
      dbg_sync => open,
      dbg_phi => open,
      dbg_status => open,
      dbg_cia1 => open,
      dbg_iec => open,
      dbg_regs => open,
      vga_hs => hs,
      vga_vs => vs,
      vga_de => de,
      vga_r => r5,
      vga_g => g6,
      vga_b => b5,
      ps2_clk => '1',
      ps2_data => '1',
      audio => open,
      uart_tx => uart_tx,
      uart_rx => uart_rx,
      monitor_hold => '0',
      monitor_mem_req => '0',
      monitor_mem_we => '0',
      monitor_mem_addr => (others => '0'),
      monitor_mem_wdata => (others => '0'),
      monitor_mem_rdata => open,
      monitor_mem_ready => open
    );

  r8 <= r5 & r5(4 downto 2);
  g8 <= g6 & g6(5 downto 4);
  b8 <= b5 & b5(4 downto 2);

  enc0 : entity work.tmds_encoder
    port map (
      clk => pclk,
      reset_n => reset_n,
      de => de,
      d => b8,
      c0 => hs,
      c1 => vs,
      q => tmds_word0
    );

  enc1 : entity work.tmds_encoder
    port map (
      clk => pclk,
      reset_n => reset_n,
      de => de,
      d => g8,
      c0 => '0',
      c1 => '0',
      q => tmds_word1
    );

  enc2 : entity work.tmds_encoder
    port map (
      clk => pclk,
      reset_n => reset_n,
      de => de,
      d => r8,
      c0 => '0',
      c1 => '0',
      q => tmds_word2
    );

  process(pclkx2)
  begin
    if rising_edge(pclkx2) then
      if reset = '1' then
        half_word <= '0';
        tmds_data0 <= (others => '0');
        tmds_data1 <= (others => '0');
        tmds_data2 <= (others => '0');
      else
        if half_word = '0' then
          tmds_data0 <= tmds_word0(4 downto 0);
          tmds_data1 <= tmds_word1(4 downto 0);
          tmds_data2 <= tmds_word2(4 downto 0);
        else
          tmds_data0 <= tmds_word0(9 downto 5);
          tmds_data1 <= tmds_word1(9 downto 5);
          tmds_data2 <= tmds_word2(9 downto 5);
        end if;
        half_word <= not half_word;
      end if;
    end if;
  end process;

  ser0 : entity work.serdes_n_to_1
    generic map (SF => 5)
    port map (datain => tmds_data0, gclk => pclkx2, iob_data_out => tmdsint(0),
              ioclk => pclkx10, reset => reset, serdesstrobe => serdesstrobe);
  ser1 : entity work.serdes_n_to_1
    generic map (SF => 5)
    port map (datain => tmds_data1, gclk => pclkx2, iob_data_out => tmdsint(1),
              ioclk => pclkx10, reset => reset, serdesstrobe => serdesstrobe);
  ser2 : entity work.serdes_n_to_1
    generic map (SF => 5)
    port map (datain => tmds_data2, gclk => pclkx2, iob_data_out => tmdsint(2),
              ioclk => pclkx10, reset => reset, serdesstrobe => serdesstrobe);
  serclk : entity work.serdes_n_to_1
    generic map (SF => 5)
    port map (datain => tmdsclkint, gclk => pclkx2, iob_data_out => tmdsclk,
              ioclk => pclkx10, reset => reset, serdesstrobe => serdesstrobe);

  process(pclkx2)
  begin
    if rising_edge(pclkx2) then
      if reset = '1' then
        toggle <= '0';
      else
        toggle <= not toggle;
      end if;
      if toggle = '1' then tmdsclkint <= "11111"; else tmdsclkint <= "00000"; end if;
    end if;
  end process;

  tmds0 : OBUFDS port map (I => tmdsint(0), O => tmds(0), OB => tmdsb(0));
  tmds1 : OBUFDS port map (I => tmdsint(1), O => tmds(1), OB => tmdsb(1));
  tmds2 : OBUFDS port map (I => tmdsint(2), O => tmds(2), OB => tmdsb(2));
  tmds3 : OBUFDS port map (I => tmdsclk, O => tmds(3), OB => tmdsb(3));
end architecture;
