library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tang20k_mister_c64_probe_top is
  port (
    clk_27mhz  : in  std_logic;
    key        : in  std_logic_vector(0 downto 0);

    ps2_clk    : in  std_logic;
    ps2_data   : in  std_logic;

    dac_bck    : out std_logic;
    dac_ws     : out std_logic;
    dac_din    : out std_logic;
    pa_en      : out std_logic;

    tmds_clk_p : out std_logic;
    tmds_clk_n : out std_logic;
    tmds_d_p   : out std_logic_vector(2 downto 0);
    tmds_d_n   : out std_logic_vector(2 downto 0);

    sd_dclk    : out std_logic;
    sd_ncs     : out std_logic;
    sd_mosi    : out std_logic;
    sd_miso    : in  std_logic;

    uart_tx    : out std_logic;
    uart_rx    : in  std_logic
  );
end entity;

architecture rtl of tang20k_mister_c64_probe_top is
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

  component sd_card_top
    generic (
      SPI_LOW_SPEED_DIV  : integer := 268;
      SPI_HIGH_SPEED_DIV : integer := 2
    );
    port (
      clk                    : in  std_logic;
      rst                    : in  std_logic;
      SD_nCS                 : out std_logic;
      SD_DCLK                : out std_logic;
      SD_MOSI                : out std_logic;
      SD_MISO                : in  std_logic;
      sd_init_done           : out std_logic;
      sd_sec_read            : in  std_logic;
      sd_sec_read_addr       : in  std_logic_vector(31 downto 0);
      sd_sec_read_data       : out std_logic_vector(7 downto 0);
      sd_sec_read_data_valid : out std_logic;
      sd_sec_read_end        : out std_logic;
      sd_sec_write           : in  std_logic;
      sd_sec_write_addr      : in  std_logic_vector(31 downto 0);
      sd_sec_write_data      : in  std_logic_vector(7 downto 0);
      sd_sec_write_data_req  : out std_logic;
      sd_sec_write_end       : out std_logic;
      debug_sec_state        : out std_logic_vector(4 downto 0);
      debug_cmd_state        : out std_logic_vector(3 downto 0);
      debug_cmd_error        : out std_logic
    );
  end component;

  constant C64_CLK_HZ : integer := 32000000;

  signal clk_sys  : std_logic;
  signal clk_pix  : std_logic;
  signal clk_c64  : std_logic;
  signal pll_lock : std_logic;
  signal c64_pll_lock : std_logic;
  signal reset_n  : std_logic;
  signal reset_cnt : unsigned(20 downto 0) := (others => '0');
  signal reset_released : std_logic := '0';

  signal ram_addr : unsigned(15 downto 0);
  signal ram_din  : unsigned(7 downto 0);
  signal ram_dout : unsigned(7 downto 0);
  signal ram_ce   : std_logic;
  signal ram_we   : std_logic;

  signal raw_hs, raw_vs : std_logic;
  signal sync_hs, sync_vs : std_logic;
  signal hblank, vblank : std_logic;
  signal r8, g8, b8 : unsigned(7 downto 0);
  signal vga_de : std_logic := '0';
  signal vga_hs, vga_vs : std_logic := '1';
  signal vga_r, vga_b : std_logic_vector(4 downto 0) := (others => '0');
  signal vga_g : std_logic_vector(5 downto 0) := (others => '0');

  signal audio_l, audio_r : std_logic_vector(17 downto 0);
  signal audio16 : std_logic_vector(15 downto 0);

  signal c64_iec_data_o : std_logic;
  signal c64_iec_clk_o  : std_logic;
  signal c64_iec_atn_o  : std_logic;
  signal iec_data_n     : std_logic;
  signal iec_clk_n      : std_logic;
  signal drive_clk_pull_n  : std_logic := '1';
  signal drive_data_pull_n : std_logic := '1';
  signal drive_led      : std_logic;
  signal ps2_key_mister : std_logic_vector(10 downto 0);
  signal sd_init_done   : std_logic;
  signal sd_sec_read    : std_logic;
  signal sd_sec_read_addr : std_logic_vector(31 downto 0);
  signal sd_sec_read_data : std_logic_vector(7 downto 0);
  signal sd_sec_read_valid : std_logic;
  signal sd_sec_read_end : std_logic;

  signal pause_out : std_logic;
  signal nmi_ack   : std_logic;
  signal dma_din   : unsigned(7 downto 0);
  signal pb_o      : unsigned(7 downto 0);
  signal pa2_o     : std_logic;
  signal pc2_n_o   : std_logic;
  signal sp1_o, sp2_o : std_logic;
  signal cnt1_o, cnt2_o : std_logic;
  signal cass_motor, cass_write : std_logic;
begin
  pa_en <= '1';

  -- The MiSTer/fpga64 core expects a 32 MHz master clock. Running it from the
  -- 27 MHz HDMI pixel clock makes CPU, VIC, CIA timers and SID about 16% slow.
  c64_pll_i : rPLL
    generic map (
      FCLKIN         => "27",
      DEVICE         => "GW2A-18C",
      IDIV_SEL       => 8,
      FBDIV_SEL      => 63,
      ODIV_SEL       => 4,
      DYN_SDIV_SEL   => 6,
      CLKFB_SEL      => "internal",
      CLKOUT_BYPASS  => "false",
      CLKOUTP_BYPASS => "false",
      CLKOUTD_BYPASS => "false",
      CLKOUTD_SRC    => "CLKOUT"
    )
    port map (
      CLKIN   => clk_27mhz,
      CLKOUT  => open,
      CLKOUTD => clk_c64,
      LOCK    => c64_pll_lock,
      RESET   => '0',
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

  process(clk_c64)
  begin
    if rising_edge(clk_c64) then
      if key(0) = '0' then
        reset_cnt <= (others => '0');
        reset_released <= '0';
      elsif reset_released = '0' then
        if pll_lock = '1' and c64_pll_lock = '1' then
          if reset_cnt = (reset_cnt'range => '1') then
            reset_released <= '1';
          else
            reset_cnt <= reset_cnt + 1;
          end if;
        else
          reset_cnt <= (others => '0');
        end if;
      end if;
    end if;
  end process;
  reset_n <= reset_released;

  hdmi_i : entity work.tang20k_hdmi_tx
    generic map (
      HDMI_H_TOT    => 864,
      HDMI_V_TOT    => 625,
      HDMI_H_ACT    => 720,
      HDMI_V_ACT    => 576,
      HDMI_V_SYNC   => 581,
      HDMI_DI_LINE  => 578,
      HDMI_AVI_576P => true
    )
    port map (
      clk_in   => clk_27mhz,
      reset_n  => '1',
      vga_de   => vga_de,
      vga_hs   => vga_hs,
      vga_vs   => vga_vs,
      vga_r    => vga_r,
      vga_g    => vga_g,
      vga_b    => vga_b,
      clk_sys  => clk_sys,
      clk_pix  => clk_pix,
      pll_lock => pll_lock,
      tmds_clk_p => tmds_clk_p,
      tmds_clk_n => tmds_clk_n,
      tmds_d_p   => tmds_d_p,
      tmds_d_n   => tmds_d_n
    );

  ram_i : entity work.spram
    generic map (
      DATA_WIDTH => 8,
      ADDR_WIDTH => 16
    )
    port map (
      clk  => clk_c64,
      addr => ram_addr,
      data => ram_dout,
      q    => ram_din,
      we   => ram_we and ram_ce
    );

  c64_i : entity work.fpga64_sid_iec
    port map (
      clk32       => clk_c64,
      reset_n     => reset_n,
      bios        => "01",
      pause       => '0',
      pause_out   => pause_out,
      ps2_key     => ps2_key_mister,
      kbd_reset   => '0',
      shift_mod   => "00",
      ramAddr     => ram_addr,
      ramDin      => ram_din,
      ramDout     => ram_dout,
      ramCE       => ram_ce,
      ramWE       => ram_we,
      io_cycle    => open,
      ext_cycle   => open,
      refresh     => open,
      cia_mode    => '0',
      turbo_mode  => "00",
      turbo_speed => "00",
      vic_variant => "00",
      ntscMode    => '0',
      hsync       => raw_hs,
      vsync       => raw_vs,
      palette     => "000",
      r           => r8,
      g           => g8,
      b           => b8,
      game        => '1',
      exrom       => '1',
      io_rom      => '0',
      io_ext      => '0',
      io_data     => (others => '0'),
      irq_n       => '1',
      nmi_n       => '1',
      nmi_ack     => nmi_ack,
      romL        => open,
      romH        => open,
      UMAXromH    => open,
      IOE         => open,
      IOF         => open,
      freeze_key  => open,
      mod_key     => open,
      tape_play   => open,
      dma_req     => '0',
      dma_cycle   => open,
      dma_addr    => (others => '0'),
      dma_dout    => (others => '0'),
      dma_din     => dma_din,
      dma_we      => '0',
      irq_ext_n   => '1',
      joyA        => (others => '1'),
      joyB        => (others => '1'),
      pot1        => x"FF",
      pot2        => x"FF",
      pot3        => x"FF",
      pot4        => x"FF",
      audio_l     => audio_l,
      audio_r     => audio_r,
      sid_filter  => "00",
      sid_ver     => "00",
      sid_mode    => "000",
      sid_cfg     => "0000",
      sid_fc_off_l => (others => '0'),
      sid_fc_off_r => (others => '0'),
      sid_ld_clk  => clk_c64,
      sid_ld_addr => (others => '0'),
      sid_ld_data => (others => '0'),
      sid_ld_wr   => '0',
      sid_digifix => '0',
      pb_i        => (others => '1'),
      pb_o        => pb_o,
      pa2_i       => '1',
      pa2_o       => pa2_o,
      pc2_n_o     => pc2_n_o,
      flag2_n_i   => '1',
      sp2_i       => '1',
      sp2_o       => sp2_o,
      sp1_i       => '1',
      sp1_o       => sp1_o,
      cnt2_i      => '1',
      cnt2_o      => cnt2_o,
      cnt1_i      => '1',
      cnt1_o      => cnt1_o,
      iec_data_o  => c64_iec_data_o,
      iec_data_i  => iec_data_n,
      iec_clk_o   => c64_iec_clk_o,
      iec_clk_i   => iec_clk_n,
      iec_atn_o   => c64_iec_atn_o,
      c64rom_addr => (others => '0'),
      c64rom_data => (others => '0'),
      c64rom_wr   => '0',
      cass_motor  => cass_motor,
      cass_write  => cass_write,
      cass_sense  => '1',
      cass_read   => '1'
    );

  -- IEC is open collector: the C64 side and the drive side only pull low.
  iec_clk_n  <= c64_iec_clk_o and drive_clk_pull_n;
  iec_data_n <= c64_iec_data_o and drive_data_pull_n;

  drive_i : entity work.mister_c1541_iec
    generic map (
      CLK_HZ       => C64_CLK_HZ,   -- must match clk_c64 for correct UART baud
      DRIVE_CPU_HZ => 1000000,     -- keep the real 1541 DOS core at stock speed
      BAUD         => 230400,      -- match the virtual_1541 GUI default baud
      GCR_TURBO    => 1,           -- keep disk rotation timing conservative
      D64_BACKEND  => 3             -- first FAT32 root *.D64 on SD card
    )
    port map (
      clk     => clk_c64,
      reset_n => reset_n,
      iec_atn_n  => c64_iec_atn_o,
      iec_clk_n  => iec_clk_n,
      iec_data_n => iec_data_n,
      drive_clk_pull_n  => drive_clk_pull_n,
      drive_data_pull_n => drive_data_pull_n,
      uart_rx => uart_rx,
      uart_tx => uart_tx,
      sd_init_done           => sd_init_done,
      sd_sec_read            => sd_sec_read,
      sd_sec_read_addr       => sd_sec_read_addr,
      sd_sec_read_data       => sd_sec_read_data,
      sd_sec_read_data_valid => sd_sec_read_valid,
      sd_sec_read_end        => sd_sec_read_end,
      led => drive_led
    );

  sd_i : sd_card_top
    generic map (
      SPI_LOW_SPEED_DIV  => 268,
      SPI_HIGH_SPEED_DIV => 8
    )
    port map (
      clk                    => clk_c64,
      rst                    => not reset_n,
      SD_nCS                 => sd_ncs,
      SD_DCLK                => sd_dclk,
      SD_MOSI                => sd_mosi,
      SD_MISO                => sd_miso,
      sd_init_done           => sd_init_done,
      sd_sec_read            => sd_sec_read,
      sd_sec_read_addr       => sd_sec_read_addr,
      sd_sec_read_data       => sd_sec_read_data,
      sd_sec_read_data_valid => sd_sec_read_valid,
      sd_sec_read_end        => sd_sec_read_end,
      sd_sec_write           => '0',
      sd_sec_write_addr      => (others => '0'),
      sd_sec_write_data      => (others => '0'),
      sd_sec_write_data_req  => open,
      sd_sec_write_end       => open,
      debug_sec_state        => open,
      debug_cmd_state        => open,
      debug_cmd_error        => open
    );

  ps2_i : entity work.ps2_to_mister_key
    port map (
      clk      => clk_c64,
      reset_n  => reset_n,
      ps2_clk  => ps2_clk,
      ps2_data => ps2_data,
      ps2_key  => ps2_key_mister
    );

  sync_i : entity work.video_sync
    port map (
      clk32 => clk_c64,
      pause => '0',
      hsync => raw_hs,
      vsync => raw_vs,
      ntsc  => '0',
      wide  => '0',
      hsync_out => sync_hs,
      vsync_out => sync_vs,
      hblank => hblank,
      vblank => vblank
    );

  -- Register the MiSTer video output in the C64 clock domain before handing it
  -- to the HDMI pixel-clock domain. The two clocks come from independent PLLs,
  -- so the SDC cuts the CDC path; this register keeps the source side short.
  process(clk_c64)
  begin
    if rising_edge(clk_c64) then
      if reset_n = '0' then
        vga_de <= '0';
        vga_hs <= '1';
        vga_vs <= '1';
        vga_r  <= (others => '0');
        vga_g  <= (others => '0');
        vga_b  <= (others => '0');
      else
        vga_de <= not (hblank or vblank);
        vga_hs <= sync_hs;
        vga_vs <= sync_vs;
        vga_r  <= std_logic_vector(r8(7 downto 3));
        vga_g  <= std_logic_vector(g8(7 downto 2));
        vga_b  <= std_logic_vector(b8(7 downto 3));
      end if;
    end if;
  end process;

  -- sid_top_native mirrors the 16-bit SID sample into the 18-bit MiSTer audio
  -- ports by sign extension, so keep the original 16-bit level for the PT8211.
  audio16 <= audio_l(15 downto 0);

  audio_i : entity work.pt8211_dac
    generic map (
      BCK_HALF => 4
    )
    port map (
      clk => clk_c64,
      reset_n => reset_n,
      sample => audio16,
      dac_bck => dac_bck,
      dac_ws => dac_ws,
      dac_din => dac_din
    );

end architecture;
