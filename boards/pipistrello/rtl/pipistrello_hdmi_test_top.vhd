library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library UNISIM;
use UNISIM.Vcomponents.all;

entity pipistrello_hdmi_test_top is
  port (
    clk_50mhz : in  std_logic;
    reset_btn : in  std_logic;
    led       : out std_logic_vector(1 downto 0);
    tmds      : out std_logic_vector(3 downto 0);
    tmdsb     : out std_logic_vector(3 downto 0)
  );
end entity;

architecture rtl of pipistrello_hdmi_test_top is
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

  signal hcnt : unsigned(9 downto 0) := (others => '0');
  signal vcnt : unsigned(9 downto 0) := (others => '0');
  signal de   : std_logic := '0';
  signal hs   : std_logic := '1';
  signal vs   : std_logic := '1';
  signal r8   : std_logic_vector(7 downto 0) := (others => '0');
  signal g8   : std_logic_vector(7 downto 0) := (others => '0');
  signal b8   : std_logic_vector(7 downto 0) := (others => '0');

  signal tmds_data0 : std_logic_vector(4 downto 0);
  signal tmds_data1 : std_logic_vector(4 downto 0);
  signal tmds_data2 : std_logic_vector(4 downto 0);
  signal tmdsint    : std_logic_vector(2 downto 0);
  signal tmdsclkint : std_logic_vector(4 downto 0);
  signal tmdsclk    : std_logic;
  signal toggle     : std_logic := '0';
begin
  reset <= reset_btn or (not bufpll_lock);
  led(0) <= pll_lckd;
  led(1) <= de;

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

  timing : process(pclk)
    variable x : integer;
    variable y : integer;
    variable rv : std_logic_vector(7 downto 0);
    variable gv : std_logic_vector(7 downto 0);
    variable bv : std_logic_vector(7 downto 0);
  begin
    if rising_edge(pclk) then
      if reset = '1' then
        hcnt <= (others => '0');
        vcnt <= (others => '0');
        de <= '0';
        hs <= '1';
        vs <= '1';
        r8 <= (others => '0');
        g8 <= (others => '0');
        b8 <= (others => '0');
      else
        if hcnt = 799 then
          hcnt <= (others => '0');
          if vcnt = 524 then vcnt <= (others => '0'); else vcnt <= vcnt + 1; end if;
        else
          hcnt <= hcnt + 1;
        end if;

        x := to_integer(hcnt);
        y := to_integer(vcnt);
        if x < 640 and y < 480 then de <= '1'; else de <= '0'; end if;
        if x >= 656 and x < 752 then hs <= '0'; else hs <= '1'; end if;
        if y >= 490 and y < 492 then vs <= '0'; else vs <= '1'; end if;

        if y < 480 and x < 640 then
          case x / 80 is
            when 0 => rv := x"FF"; gv := x"FF"; bv := x"FF";
            when 1 => rv := x"FF"; gv := x"FF"; bv := x"00";
            when 2 => rv := x"00"; gv := x"FF"; bv := x"FF";
            when 3 => rv := x"00"; gv := x"FF"; bv := x"00";
            when 4 => rv := x"FF"; gv := x"00"; bv := x"FF";
            when 5 => rv := x"FF"; gv := x"00"; bv := x"00";
            when 6 => rv := x"00"; gv := x"00"; bv := x"FF";
            when others => rv := x"20"; gv := x"20"; bv := x"20";
          end case;
          if hcnt(5) = vcnt(5) then
            rv := std_logic_vector(unsigned(rv) xor x"20");
            gv := std_logic_vector(unsigned(gv) xor x"20");
            bv := std_logic_vector(unsigned(bv) xor x"20");
          end if;
          r8 <= rv;
          g8 <= gv;
          b8 <= bv;
        else
          r8 <= (others => '0');
          g8 <= (others => '0');
          b8 <= (others => '0');
        end if;
      end if;
    end if;
  end process;

  enc_i : entity work.dvi_encoder
    port map (
      clkin => pclk,
      clkx2in => pclkx2,
      rstin => reset,
      blue_din => b8,
      green_din => g8,
      red_din => r8,
      hsync => hs,
      vsync => vs,
      de => de,
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
