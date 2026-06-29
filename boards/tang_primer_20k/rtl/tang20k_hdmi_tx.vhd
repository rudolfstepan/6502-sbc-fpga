-- Tang Primer 20K HDMI transmitter.
-- Takes VGA-style RGB + sync signals and outputs HDMI TMDS. The hdmi_encoder
-- adds the HDMI data island carrying an AVI InfoFrame (plus video preamble and
-- guard bands), so capture devices that reject bare DVI recognise the format.
--
-- System clock: 54 MHz (T65 effective 27 MHz through its two-phase bus).
-- Pixel clock:  27 MHz (CLK_DIV=2 in vic_vga).
-- Bit clock:    135 MHz = 5 x 27 MHz.
-- Bit rate:    270 Mbps per channel (135 MHz FCLK, DDR via OSER10).
--
-- VGA refresh at 27 MHz pixel clock, 858x525 total (CEA-861 480p timing):
--   H = 27 MHz / 858 = 31.47 kHz
--   V = 31468 / 525  = 59.94 Hz   (standard 640x480 @ 60 Hz)
--
-- Clock generation:
--   rPLL:  27 MHz -> 270 MHz (VCO 540 MHz)
--   CLKDIV /2 -> 135 MHz TMDS serializer clock
--   CLKDIV /5 ->  54 MHz SBC system clock
--   CLKDIV /5 ->  27 MHz pixel/serializer parallel clock (from 135 MHz)
--
-- TMDS channel mapping (DVI spec):
--   D0 = Blue,  C0=HS, C1=VS during blanking
--   D1 = Green, C0=0,  C1=0
--   D2 = Red,   C0=0,  C1=0
--   CLK = fixed 1111100000 pattern
--
-- Gowin primitives used:
--   rPLL     -- generates 135 MHz (CLKOUT) from 27 MHz input
--   CLKDIV   -- divides 135 MHz by 5 to produce 27 MHz pixel clock
--   OSER10   -- 10:1 DDR serialiser (PCLK=27 MHz, FCLK=135 MHz)
--   ELVDS_OBUF -- differential LVDS output driver
library ieee;
use ieee.std_logic_1164.all;
use work.sbc_pkg.all;

entity tang20k_hdmi_tx is
  port (
    clk_in    : in  std_logic;   -- 27 MHz board oscillator
    reset_n   : in  std_logic;
    -- VGA pixel data (from SBC VIC or boot/status renderer)
    vga_de    : in  std_logic;
    vga_hs    : in  std_logic;
    vga_vs    : in  std_logic;
    vga_r     : in  std_logic_vector(4 downto 0);
    vga_g     : in  std_logic_vector(5 downto 0);
    vga_b     : in  std_logic_vector(4 downto 0);
    -- PLL-derived clocks fed back to board top for the SBC
    clk_sys   : out std_logic;   -- 54 MHz SBC system clock
    clk_pix   : out std_logic;   -- 27 MHz HDMI pixel clock
    pll_lock  : out std_logic;
    -- HDMI TMDS differential outputs
    tmds_clk_p : out std_logic;
    tmds_clk_n : out std_logic;
    tmds_d_p   : out std_logic_vector(2 downto 0);
    tmds_d_n   : out std_logic_vector(2 downto 0)
  );
end entity;

architecture rtl of tang20k_hdmi_tx is
  -- Gowin rPLL
  component rPLL is
    generic (
      FCLKIN         : string  := "100.0";
      DEVICE         : string  := "GW1N-1";
      IDIV_SEL       : integer := 0;
      FBDIV_SEL      : integer := 0;
      ODIV_SEL       : integer := 8;
      PSDA_SEL       : string  := "0000";
      DUTYDA_SEL     : string  := "1000";
      DYN_SDIV_SEL   : integer := 2;
      CLKFB_SEL      : string  := "internal";
      CLKOUT_BYPASS  : string  := "false";
      CLKOUTP_BYPASS : string  := "false";
      CLKOUTD_BYPASS : string  := "false";
      CLKOUTD_SRC    : string  := "CLKOUT"
    );
    port (
      CLKOUT  : out std_logic;
      LOCK    : out std_logic;
      CLKOUTP : out std_logic;
      CLKOUTD : out std_logic;
      RESET   : in  std_logic;
      RESET_P : in  std_logic;
      CLKIN   : in  std_logic;
      CLKFB   : in  std_logic;
      FBDSEL  : in  std_logic_vector(5 downto 0);
      IDSEL   : in  std_logic_vector(5 downto 0);
      ODSEL   : in  std_logic_vector(5 downto 0);
      PSDA    : in  std_logic_vector(3 downto 0);
      DUTYDA  : in  std_logic_vector(3 downto 0);
      FDLY    : in  std_logic_vector(3 downto 0)
    );
  end component;

  -- Gowin dedicated clock divider (supports odd divisors, unlike rPLL CLKOUTD)
  component CLKDIV is
    generic (
      DIV_MODE : string := "2";
      GSREN    : string := "false"
    );
    port (
      CLKOUT : out std_logic;
      HCLKIN : in  std_logic;
      RESETN : in  std_logic;
      CALIB  : in  std_logic
    );
  end component;

  -- Gowin 10:1 DDR serialiser
  component OSER10 is
    generic (GSREN : string := "false"; LSREN : string := "true");
    port (
      Q     : out std_logic;
      D0    : in  std_logic;
      D1    : in  std_logic;
      D2    : in  std_logic;
      D3    : in  std_logic;
      D4    : in  std_logic;
      D5    : in  std_logic;
      D6    : in  std_logic;
      D7    : in  std_logic;
      D8    : in  std_logic;
      D9    : in  std_logic;
      FCLK  : in  std_logic;
      PCLK  : in  std_logic;
      RESET : in  std_logic
    );
  end component;

  -- Gowin ELVDS differential output buffer
  component ELVDS_OBUF is
    port (
      I  : in  std_logic;
      O  : out std_logic;
      OB : out std_logic
    );
  end component;

  signal clk_pll  : std_logic;
  signal clk_5x   : std_logic;
  signal clk_sys_i : std_logic;
  signal clk_pix_i : std_logic;
  signal lock_i   : std_logic;
  signal rst      : std_logic;

  -- 8-bit expanded colour (replicate MSBs to fill low bits)
  signal r8 : std_logic_vector(7 downto 0);
  signal g8 : std_logic_vector(7 downto 0);
  signal b8 : std_logic_vector(7 downto 0);

  -- Pixel-domain input registers. The current C64/VIC path produces pixels on
  -- clk_pix_i already, so keep the HDMI handoff in the same pixel domain.
  signal de_pix : std_logic := '0';
  signal hs_pix : std_logic := '1';
  signal vs_pix : std_logic := '1';
  signal r_pix  : std_logic_vector(4 downto 0) := (others => '0');
  signal g_pix  : std_logic_vector(5 downto 0) := (others => '0');
  signal b_pix  : std_logic_vector(4 downto 0) := (others => '0');

  -- TMDS encoded words (10 bits per channel)
  signal tmds_r : std_logic_vector(9 downto 0);
  signal tmds_g : std_logic_vector(9 downto 0);
  signal tmds_b : std_logic_vector(9 downto 0);

  -- Serialised single-bit outputs from OSER10
  signal ser_clk : std_logic;
  signal ser_d   : std_logic_vector(2 downto 0);

  -- TMDS clock pattern: 5 high then 5 low, LSB first
  constant TMDS_CLK : std_logic_vector(9 downto 0) := "0000011111";
begin
  rst      <= not reset_n;
  pll_lock <= lock_i;
  clk_sys  <= clk_sys_i;
  clk_pix  <= clk_pix_i;

  -- rPLL: 27 MHz -> 270 MHz, VCO = 540 MHz.
  pll_i : rPLL
    generic map (
      FCLKIN         => "27",
      DEVICE         => "GW2A-18C",
      IDIV_SEL       => 0,
      FBDIV_SEL      => 9,
      ODIV_SEL       => 2,
      CLKFB_SEL      => "internal",
      CLKOUT_BYPASS  => "false",
      CLKOUTP_BYPASS => "false",
      CLKOUTD_BYPASS => "false",
      CLKOUTD_SRC    => "CLKOUT"
    )
    port map (
      CLKIN   => clk_in,
      CLKOUT  => clk_pll,
      CLKOUTD => open,
      LOCK    => lock_i,
      RESET   => rst,
      RESET_P => '0',
      CLKFB   => '0',
      CLKOUTP => open,
      FBDSEL  => (others => '0'),
      IDSEL   => (others => '0'),
      ODSEL   => (others => '0'),
      PSDA    => (others => '0'),
      DUTYDA  => (others => '0'),
      FDLY    => (others => '0')
    );

  -- All clocks share the same PLL root, keeping the SBC/VIC and HDMI pixel
  -- domains frequency- and phase-related.
  clkdiv_tmds_i : CLKDIV
    generic map (DIV_MODE => "2", GSREN => "false")
    port map (
      HCLKIN => clk_pll,
      RESETN => lock_i,
      CALIB  => '0',
      CLKOUT => clk_5x
    );

  clkdiv_sys_i : CLKDIV
    generic map (DIV_MODE => "5", GSREN => "false")
    port map (
      HCLKIN => clk_pll,
      RESETN => lock_i,
      CALIB  => '0',
      CLKOUT => clk_sys_i
    );

  clkdiv_pix_i : CLKDIV
    generic map (DIV_MODE => "5", GSREN => "false")
    port map (
      -- OSER10 requires PCLK to be the phase-related divide-by-5 clock of
      -- its 135 MHz FCLK. Do not derive this clock from the 54 MHz SBC branch.
      HCLKIN => clk_5x,
      RESETN => lock_i,
      CALIB  => '0',
      CLKOUT => clk_pix_i
    );

  pixel_input_regs : process(clk_pix_i)
  begin
    if rising_edge(clk_pix_i) then
      if reset_n = '0' then
        de_pix <= '0';
        hs_pix <= '1';
        vs_pix <= '1';
        r_pix <= (others => '0');
        g_pix <= (others => '0');
        b_pix <= (others => '0');
      else
        de_pix <= vga_de;
        hs_pix <= vga_hs;
        vs_pix <= vga_vs;
        r_pix <= vga_r;
        g_pix <= vga_g;
        b_pix <= vga_b;
      end if;
    end if;
  end process;

  -- Expand 5/6/5-bit VGA colour to 8-bit (replicate top bits into low bits)
  r8 <= r_pix & r_pix(4 downto 2);
  g8 <= g_pix & g_pix(5 downto 4);
  b8 <= b_pix & b_pix(4 downto 2);

  -- HDMI TMDS generator: video 8b/10b plus the HDMI periphery (video
  -- preamble/guard band on every line and one AVI-InfoFrame data island per
  -- frame). This turns the stream from bare DVI into HDMI so capture devices
  -- recognise the format. Generic defaults already match the CEA 480p timing.
  hdmi_enc : entity work.hdmi_encoder
    port map (clk => clk_pix_i, reset_n => reset_n,
              de => de_pix, hs => hs_pix, vs => vs_pix,
              r8 => r8, g8 => g8, b8 => b8,
              tmds_ch0 => tmds_b, tmds_ch1 => tmds_g, tmds_ch2 => tmds_r);

  -- OSER10 serialisers (PCLK = 27 MHz from CLKDIV, FCLK = 135 MHz from rPLL)
  -- D0 is transmitted first (LSB first matches DVI TMDS bit order)
  ser_r : OSER10
    port map (PCLK => clk_pix_i, FCLK => clk_5x, RESET => rst, Q => ser_d(2),
              D0 => tmds_r(0), D1 => tmds_r(1), D2 => tmds_r(2), D3 => tmds_r(3),
              D4 => tmds_r(4), D5 => tmds_r(5), D6 => tmds_r(6), D7 => tmds_r(7),
              D8 => tmds_r(8), D9 => tmds_r(9));

  ser_g : OSER10
    port map (PCLK => clk_pix_i, FCLK => clk_5x, RESET => rst, Q => ser_d(1),
              D0 => tmds_g(0), D1 => tmds_g(1), D2 => tmds_g(2), D3 => tmds_g(3),
              D4 => tmds_g(4), D5 => tmds_g(5), D6 => tmds_g(6), D7 => tmds_g(7),
              D8 => tmds_g(8), D9 => tmds_g(9));

  ser_b : OSER10
    port map (PCLK => clk_pix_i, FCLK => clk_5x, RESET => rst, Q => ser_d(0),
              D0 => tmds_b(0), D1 => tmds_b(1), D2 => tmds_b(2), D3 => tmds_b(3),
              D4 => tmds_b(4), D5 => tmds_b(5), D6 => tmds_b(6), D7 => tmds_b(7),
              D8 => tmds_b(8), D9 => tmds_b(9));

  -- Clock channel: fixed 1111100000 pattern (no encoder needed)
  ser_clk_i : OSER10
    port map (PCLK => clk_pix_i, FCLK => clk_5x, RESET => rst, Q => ser_clk,
              D0 => TMDS_CLK(0), D1 => TMDS_CLK(1), D2 => TMDS_CLK(2), D3 => TMDS_CLK(3),
              D4 => TMDS_CLK(4), D5 => TMDS_CLK(5), D6 => TMDS_CLK(6), D7 => TMDS_CLK(7),
              D8 => TMDS_CLK(8), D9 => TMDS_CLK(9));

  -- ELVDS differential output buffers
  obuf_clk : ELVDS_OBUF port map (I => ser_clk,   O => tmds_clk_p, OB => tmds_clk_n);
  obuf_d0  : ELVDS_OBUF port map (I => ser_d(0),  O => tmds_d_p(0), OB => tmds_d_n(0));
  obuf_d1  : ELVDS_OBUF port map (I => ser_d(1),  O => tmds_d_p(1), OB => tmds_d_n(1));
  obuf_d2  : ELVDS_OBUF port map (I => ser_d(2),  O => tmds_d_p(2), OB => tmds_d_n(2));

end architecture;
