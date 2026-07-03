library ieee;
use ieee.std_logic_1164.all;

library UNISIM;
use UNISIM.Vcomponents.all;

use work.sbc_pkg.all;

entity pipistrello_6502_hdmi_top is
  generic (
    ROM_INIT_FILE : string := "../../../sim/hex/rom_welcome.hex"
  );
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

architecture rtl of pipistrello_6502_hdmi_top is
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

  signal via_portb     : data_t;
  signal uart_tx_data  : data_t;
  signal uart_tx_valid : std_logic;
  signal uart_tx_busy  : std_logic;

  signal vga_r  : std_logic_vector(4 downto 0);
  signal vga_g  : std_logic_vector(5 downto 0);
  signal vga_b  : std_logic_vector(4 downto 0);
  signal vga_hs : std_logic;
  signal vga_vs : std_logic;
  signal vga_de : std_logic;
  signal r8     : std_logic_vector(7 downto 0);
  signal g8     : std_logic_vector(7 downto 0);
  signal b8     : std_logic_vector(7 downto 0);

  signal tmds_data0 : std_logic_vector(4 downto 0);
  signal tmds_data1 : std_logic_vector(4 downto 0);
  signal tmds_data2 : std_logic_vector(4 downto 0);
  signal tmdsint    : std_logic_vector(2 downto 0);
  signal tmdsclkint : std_logic_vector(4 downto 0);
  signal tmdsclk    : std_logic;
  signal toggle     : std_logic := '0';
begin
  reset <= reset_btn or (not bufpll_lock);
  reset_n <= not reset;
  led(0) <= pll_lckd;
  led(1) <= via_portb(0);

  r8 <= vga_r & vga_r(4 downto 2);
  g8 <= vga_g & vga_g(5 downto 4);
  b8 <= vga_b & vga_b(4 downto 2);

  pclkbufg : BUFG port map (I => pllclk1, O => pclk);
  pclkx2bufg : BUFG port map (I => pllclk2, O => pclkx2);

  pll_i : PLL_BASE
    generic map (
      CLKIN_PERIOD   => 20.0,
      CLKFBOUT_MULT  => 10,
      CLKOUT0_DIVIDE => 2,
      CLKOUT1_DIVIDE => 20,
      CLKOUT2_DIVIDE => 10,
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

  sbc_i : entity work.sbc_minimal_top
    generic map (
      ROM_INIT_FILE => ROM_INIT_FILE,
      CLK_DIV       => 1,
      UART_CLK_HZ   => 25_000_000,
      VGA_640       => true
    )
    port map (
      clk           => pclk,
      reset_n       => reset_n,
      vga_r         => vga_r,
      vga_g         => vga_g,
      vga_b         => vga_b,
      vga_hs        => vga_hs,
      vga_vs        => vga_vs,
      vga_de        => vga_de,
      via_portb     => via_portb,
      uart_rx       => uart_rx,
      uart_tx_data  => uart_tx_data,
      uart_tx_valid => uart_tx_valid,
      uart_tx_busy  => uart_tx_busy,
      dbg_cpu_addr  => open,
      dbg_cpu_data  => open,
      dbg_cpu_din   => open,
      dbg_cpu_we    => open,
      dbg_cpu_sync  => open
    );

  uart_ser : entity work.uart_tx_ser
    generic map (CLK_HZ => 25_000_000)
    port map (
      clk     => pclk,
      reset_n => reset_n,
      data    => uart_tx_data,
      valid   => uart_tx_valid,
      tx      => uart_tx,
      busy    => uart_tx_busy
    );

  enc_i : entity work.dvi_encoder
    port map (
      clkin => pclk,
      clkx2in => pclkx2,
      rstin => reset,
      blue_din => b8,
      green_din => g8,
      red_din => r8,
      hsync => vga_hs,
      vsync => vga_vs,
      de => vga_de,
      tmds_data0 => tmds_data0,
      tmds_data1 => tmds_data1,
      tmds_data2 => tmds_data2
    );

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
