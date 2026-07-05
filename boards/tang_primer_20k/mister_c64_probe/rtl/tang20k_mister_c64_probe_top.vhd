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
  signal ram_we_mux : std_logic;
  signal c64_ram_addr : unsigned(15 downto 0);
  signal c64_ram_dout : unsigned(7 downto 0);
  signal c64_ram_ce   : std_logic;
  signal c64_ram_we   : std_logic;

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
  signal sd_card_sec_read      : std_logic;
  signal sd_card_sec_read_addr : std_logic_vector(31 downto 0);
  signal sd_sec_read_data : std_logic_vector(7 downto 0);
  signal sd_sec_read_valid : std_logic;
  signal sd_sec_read_end : std_logic;
  signal drive_sd_sec_read    : std_logic;
  signal drive_sd_sec_read_addr : std_logic_vector(31 downto 0);
  signal drive_sd_sec_read_valid : std_logic;
  signal drive_sd_sec_read_end : std_logic;

  signal pause_out : std_logic;
  signal nmi_ack   : std_logic;
  signal dma_din   : unsigned(7 downto 0);
  constant MONITOR_MAGIC0 : std_logic_vector(7 downto 0) := x"A5";
  constant MONITOR_MAGIC1 : std_logic_vector(7 downto 0) := x"5A";
  constant MONITOR_MAGIC2 : std_logic_vector(7 downto 0) := x"C3";
  constant MONITOR_MAGIC3 : std_logic_vector(7 downto 0) := x"3C";
  signal mon_rx_data    : std_logic_vector(7 downto 0);
  signal mon_rx_valid   : std_logic;
  signal mon_tx_data    : std_logic_vector(7 downto 0);
  signal mon_tx_valid   : std_logic;
  signal mon_tx_busy    : std_logic;
  signal mon_uart_tx    : std_logic;
  signal mon_active     : std_logic;
  signal mon_enter      : std_logic := '0';
  signal mon_magic_idx  : integer range 0 to 3 := 0;
  signal mon_mem_req    : std_logic;
  signal mon_mem_we     : std_logic;
  signal mon_mem_addr   : std_logic_vector(15 downto 0);
  signal mon_mem_wdata  : std_logic_vector(7 downto 0);
  signal mon_mem_ready  : std_logic := '0';
  signal mon_mem_req_d  : std_logic := '0';
  signal drive_uart_tx  : std_logic;
  signal cart_io_addr  : unsigned(15 downto 0);
  signal cart_io_wdata : unsigned(7 downto 0);
  signal cart_io_we    : std_logic;
  signal cart_ioe      : std_logic;
  signal cart_iof      : std_logic;
  signal disk_io_ext   : std_logic;
  signal disk_io_data  : std_logic_vector(7 downto 0);
  signal sd_mount_lba_reg : std_logic_vector(31 downto 0) := (others => '0');
  signal sd_mount_strobe  : std_logic := '0';
  type fast_buf_t is array(0 to 255) of std_logic_vector(7 downto 0);
  signal fast_buf : fast_buf_t := (others => (others => '0'));
  type fast_state_t is (FAST_IDLE, FAST_WAIT);
  signal fast_state : fast_state_t := FAST_IDLE;
  signal fast_track_reg  : std_logic_vector(7 downto 0) := x"12";
  signal fast_sector_reg : std_logic_vector(4 downto 0) := "00001";
  signal fast_offset_reg : unsigned(7 downto 0) := (others => '0');
  signal fast_ready      : std_logic := '0';
  signal fast_error      : std_logic := '0';
  signal fast_map_valid  : std_logic;
  signal fast_map_index  : std_logic_vector(9 downto 0);
  signal fast_map_error  : std_logic_vector(7 downto 0);
  signal fast_upper_half : std_logic := '0';
  signal fast_raw_pos    : unsigned(9 downto 0) := (others => '0');
  -- ~0.53 s at 31.5 MHz; well above a worst-case SPI sector read.
  constant FAST_TIMEOUT  : unsigned(23 downto 0) := (others => '1');
  signal fast_wait_cnt   : unsigned(23 downto 0) := (others => '0');
  signal fast_req_pend   : std_logic := '0';
  signal fast_req_addr   : std_logic_vector(31 downto 0) := (others => '0');
  signal drive_req_pend  : std_logic := '0';
  signal drive_req_addr  : std_logic_vector(31 downto 0) := (others => '0');
  signal sd_mounted      : std_logic := '0';
  signal sd_owner_fast   : std_logic := '0';
  signal sd_owner_boot   : std_logic := '0';
  signal sd_xfer_busy    : std_logic := '0';
  signal sd_issue_read   : std_logic := '0';
  signal sd_issue_addr   : std_logic_vector(31 downto 0) := (others => '0');
  signal boot_req_pend   : std_logic := '0';
  signal boot_req_addr   : std_logic_vector(31 downto 0) := (others => '0');
  signal boot_sd_sec_read : std_logic;
  signal boot_sd_sec_read_addr : std_logic_vector(31 downto 0);
  signal boot_sd_valid   : std_logic;
  signal boot_sd_end     : std_logic;
  signal boot_mem_we     : std_logic;
  signal boot_mem_addr   : std_logic_vector(15 downto 0);
  signal boot_mem_wdata  : std_logic_vector(7 downto 0);
  signal boot_active     : std_logic;
  signal boot_done       : std_logic;
  signal boot_status     : std_logic_vector(7 downto 0);
  signal c64_pause       : std_logic;
  signal pb_o      : unsigned(7 downto 0);
  signal pa2_o     : std_logic;
  signal pc2_n_o   : std_logic;
  signal sp1_o, sp2_o : std_logic;
  signal cnt1_o, cnt2_o : std_logic;
  signal cass_motor, cass_write : std_logic;
begin
  pa_en <= '1';
  uart_tx <= mon_uart_tx when mon_active = '1' else drive_uart_tx;

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
      we   => ram_we_mux
    );

  -- RAM port priority: SD boot loader (power-up only), UART monitor, C64.
  ram_addr <= unsigned(boot_mem_addr) when boot_active = '1' else
              unsigned(mon_mem_addr)  when mon_active = '1' else c64_ram_addr;
  ram_dout <= unsigned(boot_mem_wdata) when boot_active = '1' else
              unsigned(mon_mem_wdata)  when mon_active = '1' else c64_ram_dout;
  ram_we_mux <= boot_mem_we when boot_active = '1' else
                (mon_mem_req and mon_mem_we) when mon_active = '1' else
                (c64_ram_we and c64_ram_ce);
  c64_pause <= mon_active or boot_active;

  process(clk_c64)
  begin
    if rising_edge(clk_c64) then
      if reset_n = '0' then
        mon_mem_req_d <= '0';
        mon_mem_ready <= '0';
      else
        mon_mem_req_d <= mon_active and mon_mem_req;
        mon_mem_ready <= mon_mem_req_d;
      end if;
    end if;
  end process;

  c64_i : entity work.fpga64_sid_iec
    port map (
      clk32       => clk_c64,
      reset_n     => reset_n,
      bios        => "01",
      pause       => c64_pause,
      pause_out   => pause_out,
      ps2_key     => ps2_key_mister,
      kbd_reset   => '0',
      shift_mod   => "00",
      ramAddr     => c64_ram_addr,
      ramDin      => ram_din,
      ramDout     => c64_ram_dout,
      ramCE       => c64_ram_ce,
      ramWE       => c64_ram_we,
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
      io_ext      => disk_io_ext,
      io_data     => unsigned(disk_io_data),
      irq_n       => '1',
      nmi_n       => '1',
      nmi_ack     => nmi_ack,
      romL        => open,
      romH        => open,
      UMAXromH    => open,
      IOE         => cart_ioe,
      IOF         => cart_iof,
      cart_io_addr  => cart_io_addr,
      cart_io_wdata => cart_io_wdata,
      cart_io_we    => cart_io_we,
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

  -- Minimal SD D64 mount register window in C64 I/O2:
  --   $DF00-$DF03  selected .d64 start LBA, little-endian
  --   $DF04        write bit0=1 to mount/invalidate the cached sector
  --   $DF05        status: bit0 SD init done, bit1 drive active,
  --                bit2 D64 mounted, bit7 packed-D64 mode
  --   $DF06        hook boot loader status: bit0 done, bit1 success,
  --                bit2 header seen, bit3 gave up, bit4 SD seen,
  --                bits7:5 copy attempts
  --
  -- Tang fastload sector window:
  --   $DF08        D64 track (1-based)
  --   $DF09        D64 sector
  --   $DF0A        byte offset inside buffered sector
  --   $DF0B        write bit0=1 to read sector, bit1=1 to clear error
  --                read status: bit0 SD ready, bit1 busy, bit2 sector ready,
  --                bit3 error, bit4 D64 mounted, bit7 packed-D64 mode
  --   $DF0C        buffered sector byte at $DF0A
  --   $DF0D        write bit0=1 to read the raw 512-byte SD block at the
  --                $DF00-$DF03 LBA (no mount required), bit1 selects the
  --                buffered 256-byte half; poll $DF0B, read via $DF0A/$DF0C.
  --                Lets the C64 parse the FAT16 filesystem itself.
  disk_io_ext <= '1' when cart_iof = '1' and cart_io_addr(7 downto 4) = "0000" else '0';
  process(cart_io_addr, sd_mount_lba_reg, sd_init_done, drive_led, sd_mounted,
          fast_track_reg, fast_sector_reg, fast_offset_reg, fast_ready,
          fast_error, fast_state, fast_buf, boot_status)
  begin
    case to_integer(cart_io_addr(3 downto 0)) is
      when 0 => disk_io_data <= sd_mount_lba_reg(7 downto 0);
      when 1 => disk_io_data <= sd_mount_lba_reg(15 downto 8);
      when 2 => disk_io_data <= sd_mount_lba_reg(23 downto 16);
      when 3 => disk_io_data <= sd_mount_lba_reg(31 downto 24);
      when 5 => disk_io_data <= "1" & "0000" & sd_mounted & drive_led & sd_init_done;
      when 6 => disk_io_data <= boot_status;
      when 8 => disk_io_data <= fast_track_reg;
      when 9 => disk_io_data <= "000" & fast_sector_reg;
      when 10 => disk_io_data <= std_logic_vector(fast_offset_reg);
      when 11 =>
        if fast_state = FAST_IDLE then
          disk_io_data <= "1" & "00" & sd_mounted & fast_error & fast_ready & "0" & sd_init_done;
        else
          disk_io_data <= "1" & "00" & sd_mounted & fast_error & fast_ready & "1" & sd_init_done;
        end if;
      when 12 => disk_io_data <= fast_buf(to_integer(fast_offset_reg));
      when others => disk_io_data <= (others => '0');
    end case;
  end process;

  fast_map_i : entity work.d64_sector_map
    port map (
      track        => fast_track_reg,
      sector       => "000" & fast_sector_reg,
      valid        => fast_map_valid,
      sector_index => fast_map_index,
      error_code   => fast_map_error
    );

  -- SD access arbiter: the 1541 drive backend and the $DF08 fastload window
  -- both read whole 512-byte blocks from sd_card_top.  Requests are latched
  -- and the controller is granted to one owner per complete transfer, so
  -- neither side can steal the other's data stream mid-sector.
  sd_card_sec_read      <= sd_issue_read;
  sd_card_sec_read_addr <= sd_issue_addr;
  drive_sd_sec_read_valid <= sd_sec_read_valid when sd_owner_fast = '0' and sd_owner_boot = '0' and sd_xfer_busy = '1' else '0';
  drive_sd_sec_read_end   <= sd_sec_read_end   when sd_owner_fast = '0' and sd_owner_boot = '0' and sd_xfer_busy = '1' else '0';
  boot_sd_valid <= sd_sec_read_valid when sd_owner_boot = '1' and sd_xfer_busy = '1' else '0';
  boot_sd_end   <= sd_sec_read_end   when sd_owner_boot = '1' and sd_xfer_busy = '1' else '0';

  process(clk_c64)
  begin
    if rising_edge(clk_c64) then
      sd_mount_strobe <= '0';
      sd_issue_read <= '0';
      if reset_n = '0' then
        sd_mount_lba_reg <= (others => '0');
        sd_mounted <= '0';
        fast_state <= FAST_IDLE;
        fast_track_reg <= x"12";
        fast_sector_reg <= "00001";
        fast_offset_reg <= (others => '0');
        fast_ready <= '0';
        fast_error <= '0';
        fast_req_pend <= '0';
        fast_req_addr <= (others => '0');
        fast_upper_half <= '0';
        fast_raw_pos <= (others => '0');
        fast_wait_cnt <= (others => '0');
        drive_req_pend <= '0';
        drive_req_addr <= (others => '0');
        boot_req_pend <= '0';
        boot_req_addr <= (others => '0');
        sd_owner_fast <= '0';
        sd_owner_boot <= '0';
        sd_xfer_busy <= '0';
      else
        -- Latch drive and boot-loader sector requests so they survive a
        -- running transfer; each requester waits on sd_sec_read_end and
        -- never has more than one request outstanding.
        if drive_sd_sec_read = '1' then
          drive_req_pend <= '1';
          drive_req_addr <= drive_sd_sec_read_addr;
        end if;
        if boot_sd_sec_read = '1' then
          boot_req_pend <= '1';
          boot_req_addr <= boot_sd_sec_read_addr;
        end if;

        case fast_state is
          when FAST_IDLE =>
            null;

          when FAST_WAIT =>
            fast_wait_cnt <= fast_wait_cnt + 1;
            if sd_owner_fast = '1' and sd_xfer_busy = '1' then
              if sd_sec_read_valid = '1' then
                if fast_raw_pos(8) = fast_upper_half then
                  fast_buf(to_integer(fast_raw_pos(7 downto 0))) <= sd_sec_read_data;
                end if;
                fast_raw_pos <= fast_raw_pos + 1;
              end if;
              if sd_sec_read_end = '1' then
                fast_ready <= '1';
                fast_state <= FAST_IDLE;
              end if;
            end if;
            if fast_wait_cnt = FAST_TIMEOUT then
              fast_error <= '1';
              fast_req_pend <= '0';
              fast_state <= FAST_IDLE;
            end if;
        end case;

        if cart_io_we = '1' and cart_iof = '1' and cart_io_addr(7 downto 4) = "0000" then
          case to_integer(cart_io_addr(3 downto 0)) is
            when 0 => sd_mount_lba_reg(7 downto 0) <= std_logic_vector(cart_io_wdata);
            when 1 => sd_mount_lba_reg(15 downto 8) <= std_logic_vector(cart_io_wdata);
            when 2 => sd_mount_lba_reg(23 downto 16) <= std_logic_vector(cart_io_wdata);
            when 3 => sd_mount_lba_reg(31 downto 24) <= std_logic_vector(cart_io_wdata);
            when 4 =>
              if cart_io_wdata(0) = '1' then
                sd_mount_strobe <= '1';
                sd_mounted <= '1';
              end if;
            when 8 =>
              fast_track_reg <= std_logic_vector(cart_io_wdata);
            when 9 =>
              fast_sector_reg <= std_logic_vector(cart_io_wdata(4 downto 0));
            when 10 =>
              fast_offset_reg <= cart_io_wdata;
            when 11 =>
              if cart_io_wdata(1) = '1' then
                fast_error <= '0';
              end if;
              if cart_io_wdata(0) = '1' and fast_state = FAST_IDLE then
                fast_ready <= '0';
                -- Refuse to start while an aborted fastload transfer is
                -- still draining, so its tail cannot be mistaken for the
                -- new sector's data.
                if sd_init_done = '1' and sd_mounted = '1'
                   and fast_map_valid = '1'
                   and not (sd_xfer_busy = '1' and sd_owner_fast = '1') then
                  fast_req_addr <= std_logic_vector(unsigned(sd_mount_lba_reg)
                                 + resize(unsigned(fast_map_index(9 downto 1)), 32));
                  fast_upper_half <= fast_map_index(0);
                  fast_req_pend <= '1';
                  fast_raw_pos <= (others => '0');
                  fast_wait_cnt <= (others => '0');
                  fast_error <= '0';
                  fast_state <= FAST_WAIT;
                else
                  fast_error <= '1';
                end if;
              end if;
            when 13 =>
              -- Raw block read: LBA straight from $DF00-$DF03 instead of the
              -- track/sector map, so the mount guard does not apply here.
              if cart_io_wdata(0) = '1' and fast_state = FAST_IDLE then
                fast_ready <= '0';
                if sd_init_done = '1'
                   and not (sd_xfer_busy = '1' and sd_owner_fast = '1') then
                  fast_req_addr <= sd_mount_lba_reg;
                  fast_upper_half <= cart_io_wdata(1);
                  fast_req_pend <= '1';
                  fast_raw_pos <= (others => '0');
                  fast_wait_cnt <= (others => '0');
                  fast_error <= '0';
                  fast_state <= FAST_WAIT;
                else
                  fast_error <= '1';
                end if;
              end if;
            when others =>
              null;
          end case;
        end if;

        -- Grant the SD controller to one requester per whole transfer.
        -- The power-up boot loader goes first (the C64 is paused anyway),
        -- then the drive: the 1541 DOS is timing-sensitive while the
        -- fastload window simply polls a little longer.
        if sd_xfer_busy = '0' then
          if boot_req_pend = '1' then
            sd_issue_read <= '1';
            sd_issue_addr <= boot_req_addr;
            sd_owner_fast <= '0';
            sd_owner_boot <= '1';
            sd_xfer_busy <= '1';
            boot_req_pend <= '0';
          elsif drive_req_pend = '1' then
            sd_issue_read <= '1';
            sd_issue_addr <= drive_req_addr;
            sd_owner_fast <= '0';
            sd_owner_boot <= '0';
            sd_xfer_busy <= '1';
            drive_req_pend <= '0';
          elsif fast_req_pend = '1' then
            sd_issue_read <= '1';
            sd_issue_addr <= fast_req_addr;
            sd_owner_fast <= '1';
            sd_owner_boot <= '0';
            sd_xfer_busy <= '1';
            fast_req_pend <= '0';
          end if;
        elsif sd_sec_read_end = '1' then
          sd_xfer_busy <= '0';
        end if;
      end if;
    end if;
  end process;

  drive_i : entity work.mister_c1541_iec
    generic map (
      CLK_HZ       => C64_CLK_HZ,   -- must match clk_c64 for correct UART baud
      DRIVE_CPU_HZ => 1000000,     -- keep the real 1541 DOS core at stock speed
      BAUD         => 230400,      -- match the virtual_1541 GUI default baud
      GCR_TURBO    => 1,           -- keep disk rotation timing conservative
      D64_BACKEND  => 3,
      SD_PACKED_D64_FILE => true    -- normal contiguous .d64 file on FAT16
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
      uart_tx => drive_uart_tx,
      sd_init_done           => sd_init_done,
      sd_sec_read            => drive_sd_sec_read,
      sd_sec_read_addr       => drive_sd_sec_read_addr,
      sd_sec_read_data       => sd_sec_read_data,
      sd_sec_read_data_valid => drive_sd_sec_read_valid,
      sd_sec_read_end        => drive_sd_sec_read_end,
      sd_sec_write           => open,
      sd_sec_write_addr      => open,
      sd_sec_write_data      => open,
      sd_sec_write_data_req  => '0',
      sd_sec_write_end       => '0',
      sd_mount_lba           => sd_mount_lba_reg,
      sd_mount_strobe        => sd_mount_strobe,
      led => drive_led,
      read_active  => open,
      write_active => open,
      write_byte_pulse   => open,
      write_commit_pulse => open,
      write_block_done_pulse => open,
      write_checksum_error_pulse => open,
      write_checksum_calc => open,
      write_checksum_recv => open,
      write_prev_data => open,
      write_last_data => open,
      write_debug => open,
      write_trace_addr => (others => '0'),
      write_trace_data => open,
      write_trace_count => open,
      write_trace_clear => '0'
    );

  mon_rx_i : entity work.uart_rx_ser
    generic map (CLK_HZ => C64_CLK_HZ, BAUD => 115200)
    port map (
      clk     => clk_c64,
      reset_n => reset_n,
      rx      => uart_rx,
      data    => mon_rx_data,
      valid   => mon_rx_valid
    );

  mon_tx_i : entity work.uart_tx_ser
    generic map (CLK_HZ => C64_CLK_HZ, BAUD => 115200)
    port map (
      clk     => clk_c64,
      reset_n => reset_n,
      data    => mon_tx_data,
      valid   => mon_tx_valid,
      tx      => mon_uart_tx,
      busy    => mon_tx_busy
    );

  process(clk_c64)
  begin
    if rising_edge(clk_c64) then
      mon_enter <= '0';
      if reset_n = '0' or mon_active = '1' then
        mon_magic_idx <= 0;
      elsif mon_rx_valid = '1' then
        case mon_magic_idx is
          when 0 =>
            if mon_rx_data = MONITOR_MAGIC0 then
              mon_magic_idx <= 1;
            else
              mon_magic_idx <= 0;
            end if;
          when 1 =>
            if mon_rx_data = MONITOR_MAGIC1 then
              mon_magic_idx <= 2;
            elsif mon_rx_data = MONITOR_MAGIC0 then
              mon_magic_idx <= 1;
            else
              mon_magic_idx <= 0;
            end if;
          when 2 =>
            if mon_rx_data = MONITOR_MAGIC2 then
              mon_magic_idx <= 3;
            elsif mon_rx_data = MONITOR_MAGIC0 then
              mon_magic_idx <= 1;
            else
              mon_magic_idx <= 0;
            end if;
          when others =>
            if mon_rx_data = MONITOR_MAGIC3 then
              mon_enter <= '1';
            end if;
            mon_magic_idx <= 0;
        end case;
      end if;
    end if;
  end process;

  monitor_i : entity work.c64_prg_upload_monitor
    port map (
      clk       => clk_c64,
      reset_n   => reset_n,
      enter_btn => mon_enter,
      rx_data   => mon_rx_data,
      rx_valid  => mon_rx_valid,
      tx_busy   => mon_tx_busy,
      tx_data   => mon_tx_data,
      tx_valid  => mon_tx_valid,
      active    => mon_active,
      mem_req   => mon_mem_req,
      mem_we    => mon_mem_we,
      mem_addr  => mon_mem_addr,
      mem_wdata => mon_mem_wdata,
      mem_ready => mon_mem_ready
    );

  -- Standalone power-up loader: pulls the resident SD hook from the card
  -- (LBA 8, "C64HOOK1" header written by make_fat16_d64_card.py) into C64
  -- RAM while the core is paused, so no UART upload is needed.
  boot_i : entity work.c64_sd_hook_boot_loader
    generic map (
      HOOK_LBA => x"00000008",
      CLK_HZ   => C64_CLK_HZ
    )
    port map (
      clk     => clk_c64,
      reset_n => reset_n,
      sd_init_done           => sd_init_done,
      sd_sec_read            => boot_sd_sec_read,
      sd_sec_read_addr       => boot_sd_sec_read_addr,
      sd_sec_read_data       => sd_sec_read_data,
      sd_sec_read_data_valid => boot_sd_valid,
      sd_sec_read_end        => boot_sd_end,
      mem_we    => boot_mem_we,
      mem_addr  => boot_mem_addr,
      mem_wdata => boot_mem_wdata,
      active    => boot_active,
      done      => boot_done,
      status    => boot_status
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
      sd_sec_read            => sd_card_sec_read,
      sd_sec_read_addr       => sd_card_sec_read_addr,
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
