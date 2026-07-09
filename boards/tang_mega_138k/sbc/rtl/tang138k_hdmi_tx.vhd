-- Tang Mega 138K HDMI/DVI transmitter wrapper.
--
-- This keeps the SBC at a clean 50 MHz and uses the proven direct TMDS path:
-- 50 MHz system clock, 25 MHz pixel clock and 125 MHz TMDS bit clock. There is
-- no scaling framebuffer here; the VIC drives native 640x480 VGA timing.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tang138k_hdmi_tx is
  generic (
    -- Render the 16 debug bits as small squares in the top border (green = 1,
    -- dim red = 0, bit 0 leftmost). The Tang Console has no FPGA user LEDs, so
    -- this is the board's live status display; see the board top's debug_bus
    -- assignments for the bit map.
    DEBUG_OVERLAY : boolean := true
  );
  port (
    clk_in    : in  std_logic;   -- 50 MHz board oscillator
    reset_n   : in  std_logic;
    vga_de    : in  std_logic;
    vga_hs    : in  std_logic;
    vga_vs    : in  std_logic;
    vga_r     : in  std_logic_vector(4 downto 0);
    vga_g     : in  std_logic_vector(5 downto 0);
    vga_b     : in  std_logic_vector(4 downto 0);
    debug     : in  std_logic_vector(15 downto 0);
    clk_sys   : out std_logic;   -- 50 MHz SBC system clock
    clk_pix   : out std_logic;   -- 25 MHz HDMI/DVI pixel clock
    pll_lock  : out std_logic;
    tmds_clk_p : out std_logic;
    tmds_clk_n : out std_logic;
    tmds_d_p   : out std_logic_vector(2 downto 0);
    tmds_d_n   : out std_logic_vector(2 downto 0)
  );
end entity;

architecture rtl of tang138k_hdmi_tx is
  component Gowin_HDMI_PLL is
    port (
      lock    : out std_logic;
      clkout0 : out std_logic; -- 25 MHz pixel clock
      clkout1 : out std_logic; -- 125 MHz TMDS bit clock
      clkout2 : out std_logic; -- 50 MHz system clock
      clkin   : in  std_logic
    );
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
      tmds_d2       : out std_logic_vector(1 downto 0)
    );
  end component;

  signal lock_i        : std_logic;
  signal clk_pix_i     : std_logic;
  signal clk_5x_i      : std_logic;
  signal clk_sys_i     : std_logic;
  signal reset_i       : std_logic;
  signal reset_pix_sr  : std_logic_vector(7 downto 0) := (others => '0');
  signal reset_pix_n   : std_logic := '0';
  signal pixel_data    : std_logic_vector(23 downto 0) := (others => '0');
  signal de_pix        : std_logic := '0';
  signal hs_pix        : std_logic := '1';
  signal vs_pix        : std_logic := '1';
  signal tmds_clk_pair : std_logic_vector(1 downto 0);
  signal tmds_d0_pair  : std_logic_vector(1 downto 0);
  signal tmds_d1_pair  : std_logic_vector(1 downto 0);
  signal tmds_d2_pair  : std_logic_vector(1 downto 0);

  -- Debug overlay: pixel coordinate tracking (both syncs are negative
  -- polarity) and the cell walk for 16 squares of 8 px + 4 px gap, starting
  -- at OV_X0 in border line OV_Y0. The debug bits come from clk_sys and are
  -- 2-FF synchronised into the pixel domain (display only, no handshake).
  constant OV_X0 : natural := 16;
  constant OV_Y0 : natural := 8;
  signal dbg_meta : std_logic_vector(15 downto 0) := (others => '0');
  signal dbg_sync : std_logic_vector(15 downto 0) := (others => '0');
  signal xcnt     : unsigned(9 downto 0) := (others => '0');
  signal ycnt     : unsigned(9 downto 0) := (others => '0');
  signal de_d     : std_logic := '0';
  signal cell_px  : unsigned(3 downto 0) := (others => '0');
  signal cell_idx : unsigned(3 downto 0) := (others => '0');
begin
  clk_sys  <= clk_sys_i;
  clk_pix  <= clk_pix_i;
  pll_lock <= lock_i;
  reset_i  <= not reset_pix_n;

  pll_i : Gowin_HDMI_PLL
    port map (
      lock    => lock_i,
      clkout0 => clk_pix_i,
      clkout1 => clk_5x_i,
      clkout2 => clk_sys_i,
      clkin   => clk_in
    );

  reset_sync_i : process(clk_pix_i, lock_i, reset_n)
  begin
    if lock_i = '0' or reset_n = '0' then
      reset_pix_sr <= (others => '0');
      reset_pix_n  <= '0';
    elsif rising_edge(clk_pix_i) then
      reset_pix_sr <= reset_pix_sr(6 downto 0) & '1';
      reset_pix_n  <= reset_pix_sr(7);
    end if;
  end process;

  pixel_input_regs : process(clk_pix_i)
  begin
    if rising_edge(clk_pix_i) then
      if reset_pix_n = '0' then
        de_pix <= '0';
        hs_pix <= '1';
        vs_pix <= '1';
        pixel_data <= (others => '0');
        xcnt     <= (others => '0');
        ycnt     <= (others => '0');
        de_d     <= '0';
        cell_px  <= (others => '0');
        cell_idx <= (others => '0');
      else
        de_pix <= vga_de;
        hs_pix <= vga_hs;
        vs_pix <= vga_vs;

        dbg_meta <= debug;
        dbg_sync <= dbg_meta;

        -- pixel coordinates: x counts inside de, y advances at each de falling
        -- edge and resets during (active-low) vsync
        de_d <= vga_de;
        if vga_de = '1' then
          xcnt <= xcnt + 1;
        else
          xcnt <= (others => '0');
        end if;
        if vga_vs = '0' then
          ycnt <= (others => '0');
        elsif vga_de = '0' and de_d = '1' then
          ycnt <= ycnt + 1;
        end if;

        -- overlay cell walk: aligned so cell 0/pixel 0 lands on xcnt = OV_X0
        if vga_de = '1' then
          if xcnt = OV_X0 - 1 then
            cell_px  <= (others => '0');
            cell_idx <= (others => '0');
          elsif cell_px = 11 then
            cell_px  <= (others => '0');
            cell_idx <= cell_idx + 1;
          else
            cell_px <= cell_px + 1;
          end if;
        end if;

        pixel_data <= (vga_r & vga_r(4 downto 2)) &
                      (vga_g & vga_g(5 downto 4)) &
                      (vga_b & vga_b(4 downto 2));

        if DEBUG_OVERLAY and vga_de = '1' and
           ycnt >= OV_Y0 and ycnt < OV_Y0 + 8 and
           xcnt >= OV_X0 and xcnt < OV_X0 + 16 * 12 and
           cell_px < 8 then
          if dbg_sync(to_integer(cell_idx)) = '1' then
            pixel_data <= x"20FF20";   -- lit: green
          else
            pixel_data <= x"501010";   -- off: dim red
          end if;
        end if;
      end if;
    end if;
  end process;

  dvi_i : dvi_tx_top
    port map (
      pixel_clock   => clk_pix_i,
      ddr_bit_clock => clk_5x_i,
      reset         => reset_i,
      den           => de_pix,
      hsync         => hs_pix,
      vsync         => vs_pix,
      pixel_data    => pixel_data,
      tmds_clk      => tmds_clk_pair,
      tmds_d0       => tmds_d0_pair,
      tmds_d1       => tmds_d1_pair,
      tmds_d2       => tmds_d2_pair
    );

  tmds_clk_p <= tmds_clk_pair(1);
  tmds_clk_n <= tmds_clk_pair(0);
  tmds_d_p(0) <= tmds_d0_pair(1);
  tmds_d_n(0) <= tmds_d0_pair(0);
  tmds_d_p(1) <= tmds_d1_pair(1);
  tmds_d_n(1) <= tmds_d1_pair(0);
  tmds_d_p(2) <= tmds_d2_pair(1);
  tmds_d_n(2) <= tmds_d2_pair(0);
end architecture;
