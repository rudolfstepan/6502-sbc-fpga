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

    uart_tx    : out std_logic;
    uart_rx    : in  std_logic
  );
end entity;

architecture rtl of tang20k_mister_c64_probe_top is
  signal clk_sys  : std_logic;
  signal clk_pix  : std_logic;
  signal pll_lock : std_logic;
  signal reset_n  : std_logic;
  signal rst_sync : std_logic_vector(2 downto 0) := (others => '0');

  signal ram_addr : unsigned(15 downto 0);
  signal ram_din  : unsigned(7 downto 0);
  signal ram_dout : unsigned(7 downto 0);
  signal ram_ce   : std_logic;
  signal ram_we   : std_logic;

  signal raw_hs, raw_vs : std_logic;
  signal sync_hs, sync_vs : std_logic;
  signal hblank, vblank : std_logic;
  signal r8, g8, b8 : unsigned(7 downto 0);
  signal vga_de : std_logic;
  signal vga_r, vga_b : std_logic_vector(4 downto 0);
  signal vga_g : std_logic_vector(5 downto 0);

  signal audio_l, audio_r : std_logic_vector(17 downto 0);
  signal audio_mix : signed(18 downto 0);
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

  process(clk_pix)
  begin
    if rising_edge(clk_pix) then
      rst_sync <= rst_sync(1 downto 0) & (pll_lock and key(0));
    end if;
  end process;
  reset_n <= rst_sync(2);

  hdmi_i : entity work.tang20k_hdmi_tx
    port map (
      clk_in   => clk_27mhz,
      reset_n  => '1',
      vga_de   => vga_de,
      vga_hs   => sync_hs,
      vga_vs   => sync_vs,
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
      clk  => clk_pix,
      addr => ram_addr,
      data => ram_dout,
      q    => ram_din,
      we   => ram_we and ram_ce
    );

  c64_i : entity work.fpga64_sid_iec
    port map (
      clk32       => clk_pix,
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
      sid_ld_clk  => clk_pix,
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
      CLK_HZ       => 27000000,     -- must match clk_pix for correct UART baud
      DRIVE_CPU_HZ => 1000000,
      BAUD         => 230400,      -- match the virtual_1541 GUI default baud
      D64_BACKEND  => 2             -- virtual-1541 sectors over UART
    )
    port map (
      clk     => clk_pix,
      reset_n => reset_n,
      iec_atn_n  => c64_iec_atn_o,
      iec_clk_n  => iec_clk_n,
      iec_data_n => iec_data_n,
      drive_clk_pull_n  => drive_clk_pull_n,
      drive_data_pull_n => drive_data_pull_n,
      uart_rx => uart_rx,
      uart_tx => uart_tx,
      led => drive_led
    );

  ps2_i : entity work.ps2_to_mister_key
    port map (
      clk      => clk_pix,
      reset_n  => reset_n,
      ps2_clk  => ps2_clk,
      ps2_data => ps2_data,
      ps2_key  => ps2_key_mister
    );

  sync_i : entity work.video_sync
    port map (
      clk32 => clk_pix,
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

  vga_de <= not (hblank or vblank);
  vga_r <= std_logic_vector(r8(7 downto 3));
  vga_g <= std_logic_vector(g8(7 downto 2));
  vga_b <= std_logic_vector(b8(7 downto 3));

  audio_mix <= resize(signed(audio_l), 19) + resize(signed(audio_r), 19);
  audio16 <= std_logic_vector(audio_mix(18 downto 3));

  audio_i : entity work.pt8211_dac
    generic map (
      BCK_HALF => 4
    )
    port map (
      clk => clk_pix,
      reset_n => reset_n,
      sample => audio16,
      dac_bck => dac_bck,
      dac_ws => dac_ws,
      dac_din => dac_din
    );

end architecture;
