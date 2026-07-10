library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sys16_hdmi_720p is
  port (
    clk_in     : in  std_logic;
    reset_n    : in  std_logic;
    status_word : in std_logic_vector(15 downto 0);
    pll_lock   : out std_logic;
    tmds_clk_p : out std_logic;
    tmds_clk_n : out std_logic;
    tmds_d_p   : out std_logic_vector(2 downto 0);
    tmds_d_n   : out std_logic_vector(2 downto 0)
  );
end entity;

architecture rtl of sys16_hdmi_720p is
  component Gowin_HDMI_720P_PLL is
    port (
      lock    : out std_logic;
      clkout0 : out std_logic;
      clkout1 : out std_logic;
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

  constant H_ACTIVE : natural := 1280;
  constant H_FP     : natural := 110;
  constant H_SYNC   : natural := 40;
  constant H_BP     : natural := 220;
  constant H_TOTAL  : natural := H_ACTIVE + H_FP + H_SYNC + H_BP;
  constant V_ACTIVE : natural := 720;
  constant V_FP     : natural := 5;
  constant V_SYNC   : natural := 5;
  constant V_BP     : natural := 20;
  constant V_TOTAL  : natural := V_ACTIVE + V_FP + V_SYNC + V_BP;

  signal lock_i        : std_logic;
  signal clk_pix       : std_logic;
  signal clk_5x        : std_logic;
  signal reset_sr      : std_logic_vector(7 downto 0) := (others => '0');
  signal reset_video   : std_logic;
  signal x             : unsigned(10 downto 0) := (others => '0');
  signal y             : unsigned(9 downto 0) := (others => '0');
  signal active        : std_logic;
  signal hsync         : std_logic;
  signal vsync         : std_logic;
  signal status_meta   : std_logic_vector(15 downto 0) := (others => '0');
  signal status_sync   : std_logic_vector(15 downto 0) := (others => '0');
  signal pixel_data    : std_logic_vector(23 downto 0);
  signal tmds_clk_pair : std_logic_vector(1 downto 0);
  signal tmds_d0_pair  : std_logic_vector(1 downto 0);
  signal tmds_d1_pair  : std_logic_vector(1 downto 0);
  signal tmds_d2_pair  : std_logic_vector(1 downto 0);
begin
  pll_lock    <= lock_i;
  reset_video <= not reset_sr(7);

  pll_i : Gowin_HDMI_720P_PLL
    port map (
      lock    => lock_i,
      clkout0 => clk_pix,
      clkout1 => clk_5x,
      clkin   => clk_in
    );

  process(clk_pix, lock_i, reset_n)
  begin
    if lock_i = '0' or reset_n = '0' then
      reset_sr <= (others => '0');
    elsif rising_edge(clk_pix) then
      reset_sr <= reset_sr(6 downto 0) & '1';
    end if;
  end process;

  process(clk_pix)
  begin
    if rising_edge(clk_pix) then
      if reset_video = '1' then
        x           <= (others => '0');
        y           <= (others => '0');
        status_meta <= (others => '0');
        status_sync <= (others => '0');
      else
        status_meta <= status_word;
        status_sync <= status_meta;

        if x = to_unsigned(H_TOTAL - 1, x'length) then
          x <= (others => '0');
          if y = to_unsigned(V_TOTAL - 1, y'length) then
            y <= (others => '0');
          else
            y <= y + 1;
          end if;
        else
          x <= x + 1;
        end if;
      end if;
    end if;
  end process;

  active <= '1' when x < to_unsigned(H_ACTIVE, x'length) and
                     y < to_unsigned(V_ACTIVE, y'length) else '0';
  hsync <= '1' when x >= to_unsigned(H_ACTIVE + H_FP, x'length) and
                    x < to_unsigned(H_ACTIVE + H_FP + H_SYNC, x'length) else '0';
  vsync <= '1' when y >= to_unsigned(V_ACTIVE + V_FP, y'length) and
                    y < to_unsigned(V_ACTIVE + V_FP + V_SYNC, y'length) else '0';

  process(x, y, active, status_sync)
    variable status_rgb : std_logic_vector(23 downto 0);
  begin
    status_rgb := status_sync(15 downto 11) & status_sync(15 downto 13) &
                  status_sync(10 downto 5) & status_sync(10 downto 9) &
                  status_sync(4 downto 0) & status_sync(4 downto 2);

    if active = '0' then
      pixel_data <= x"000000";
    elsif y < to_unsigned(48, y'length) then
      pixel_data <= status_rgb;
    elsif x < to_unsigned(160, x'length) then
      pixel_data <= x"FFFFFF";
    elsif x < to_unsigned(320, x'length) then
      pixel_data <= x"FFFF00";
    elsif x < to_unsigned(480, x'length) then
      pixel_data <= x"00FFFF";
    elsif x < to_unsigned(640, x'length) then
      pixel_data <= x"00FF00";
    elsif x < to_unsigned(800, x'length) then
      pixel_data <= x"FF00FF";
    elsif x < to_unsigned(960, x'length) then
      pixel_data <= x"FF0000";
    elsif x < to_unsigned(1120, x'length) then
      pixel_data <= x"0000FF";
    else
      pixel_data <= x"202020";
    end if;
  end process;

  dvi_i : dvi_tx_top
    port map (
      pixel_clock   => clk_pix,
      ddr_bit_clock => clk_5x,
      reset         => reset_video,
      den           => active,
      hsync         => hsync,
      vsync         => vsync,
      pixel_data    => pixel_data,
      tmds_clk      => tmds_clk_pair,
      tmds_d0       => tmds_d0_pair,
      tmds_d1       => tmds_d1_pair,
      tmds_d2       => tmds_d2_pair
    );

  tmds_clk_p  <= tmds_clk_pair(1);
  tmds_clk_n  <= tmds_clk_pair(0);
  tmds_d_p(0) <= tmds_d0_pair(1);
  tmds_d_n(0) <= tmds_d0_pair(0);
  tmds_d_p(1) <= tmds_d1_pair(1);
  tmds_d_n(1) <= tmds_d1_pair(0);
  tmds_d_p(2) <= tmds_d2_pair(1);
  tmds_d_n(2) <= tmds_d2_pair(0);
end architecture;
