-- HDMI text console "graphics card" for the GoRV32 Plus shell.
--
-- Thin wrapper around sys16_text_core: the CEA 720p PLL, pixel-domain reset
-- shift register and the DVI serialiser (all identical to sys16_hdmi_fb),
-- plus the testable text core that does the character rendering. Pin- and
-- register-compatible drop-in for sys16_hdmi_fb minus the DDR3 app port:
-- the text console lives entirely in BSRAM (char array + font ROM), so it
-- needs no external memory at all. See sys16_text_core for the register map
-- (ID reads "S16T").
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sys16_hdmi_text is
  port (
    clk_in      : in  std_logic;   -- 50 MHz bus clock
    reset_n     : in  std_logic;
    -- bus32 device port, driven by sys16_axi32_to_bus32
    req         : in  std_logic;
    we          : in  std_logic;
    addr        : in  std_logic_vector(23 downto 0);
    be          : in  std_logic_vector(3 downto 0);
    wdata       : in  std_logic_vector(31 downto 0);
    rdata       : out std_logic_vector(31 downto 0);
    ready       : out std_logic;
    -- decoded bytes from the board UART TX, shown until Linux takes over
    boot_data   : in  std_logic_vector(7 downto 0) := (others => '0');
    boot_valid  : in  std_logic := '0';
    -- diagnostic stripe colour (top 16 lines when CTRL bit2 is set)
    status_word : in  std_logic_vector(15 downto 0);
    pll_lock    : out std_logic;
    tmds_clk_p  : out std_logic;
    tmds_clk_n  : out std_logic;
    tmds_d_p    : out std_logic_vector(2 downto 0);
    tmds_d_n    : out std_logic_vector(2 downto 0)
  );
end entity;

architecture rtl of sys16_hdmi_text is
  component Gowin_HDMI_720P_PLL is
    port (lock : out std_logic; clkout0 : out std_logic;
          clkout1 : out std_logic; clkin : in std_logic);
  end component;

  component dvi_tx_top is
    port (
      pixel_clock   : in  std_logic;
      ddr_bit_clock : in  std_logic;
      reset         : in  std_logic;
      den           : in  std_logic;
      hsync         : in  std_logic;
      vsync         : in  std_logic;
      pixel_data    : in  std_logic_vector(23 downto 0);
      tmds_clk      : out std_logic_vector(1 downto 0);
      tmds_d0       : out std_logic_vector(1 downto 0);
      tmds_d1       : out std_logic_vector(1 downto 0);
      tmds_d2       : out std_logic_vector(1 downto 0));
  end component;

  signal lock_i      : std_logic;
  signal clk_pix     : std_logic;
  signal clk_5x      : std_logic;
  signal reset_sr    : std_logic_vector(7 downto 0) := (others => '0');
  signal reset_video : std_logic;
  signal de, hs, vs  : std_logic;
  signal pixel_data  : std_logic_vector(23 downto 0);
  signal tmds_clk_pair, tmds_d0_pair, tmds_d1_pair, tmds_d2_pair
                     : std_logic_vector(1 downto 0);
begin
  pll_lock    <= lock_i;
  reset_video <= not reset_sr(7);

  pll_i : Gowin_HDMI_720P_PLL
    port map (lock => lock_i, clkout0 => clk_pix, clkout1 => clk_5x,
              clkin => clk_in);

  process(clk_pix, lock_i, reset_n)
  begin
    if lock_i = '0' or reset_n = '0' then
      reset_sr <= (others => '0');
    elsif rising_edge(clk_pix) then
      reset_sr <= reset_sr(6 downto 0) & '1';
    end if;
  end process;

  core_i : entity work.sys16_text_core
    port map (
      clk_in => clk_in, reset_n => reset_n,
      req => req, we => we, addr => addr, be => be, wdata => wdata,
      rdata => rdata, ready => ready, boot_data => boot_data,
      boot_valid => boot_valid, status_word => status_word,
      clk_pix => clk_pix, reset_pix => reset_video,
      de => de, hsync => hs, vsync => vs, pixel_data => pixel_data,
      dbg_x => open, dbg_y => open);

  dvi_i : dvi_tx_top
    port map (
      pixel_clock => clk_pix, ddr_bit_clock => clk_5x, reset => reset_video,
      den => de, hsync => hs, vsync => vs, pixel_data => pixel_data,
      tmds_clk => tmds_clk_pair, tmds_d0 => tmds_d0_pair,
      tmds_d1 => tmds_d1_pair, tmds_d2 => tmds_d2_pair);

  tmds_clk_p  <= tmds_clk_pair(1); tmds_clk_n  <= tmds_clk_pair(0);
  tmds_d_p(0) <= tmds_d0_pair(1);  tmds_d_n(0) <= tmds_d0_pair(0);
  tmds_d_p(1) <= tmds_d1_pair(1);  tmds_d_n(1) <= tmds_d1_pair(0);
  tmds_d_p(2) <= tmds_d2_pair(1);  tmds_d_n(2) <= tmds_d2_pair(0);
end architecture;
