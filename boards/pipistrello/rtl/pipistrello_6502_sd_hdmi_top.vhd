library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library UNISIM;
use UNISIM.Vcomponents.all;

use work.sbc_pkg.all;

entity pipistrello_6502_sd_hdmi_top is
  port (
    clk_50mhz : in  std_logic;
    reset_btn : in  std_logic;
    led       : out std_logic_vector(1 downto 0);
    uart_tx   : out std_logic;
    uart_rx   : in  std_logic;
    sd_dclk   : out std_logic;
    sd_ncs    : out std_logic;
    sd_mosi   : out std_logic;
    sd_miso   : in  std_logic;
    tmds      : out std_logic_vector(3 downto 0);
    tmdsb     : out std_logic_vector(3 downto 0)
  );
end entity;

architecture rtl of pipistrello_6502_sd_hdmi_top is
  component sd_card_top
    generic (
      SPI_LOW_SPEED_DIV  : integer := 248;
      SPI_HIGH_SPEED_DIV : integer := 0
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
      sd_sec_read_data       : out data_t;
      sd_sec_read_data_valid : out std_logic;
      sd_sec_read_end        : out std_logic;
      sd_sec_write           : in  std_logic;
      sd_sec_write_addr      : in  std_logic_vector(31 downto 0);
      sd_sec_write_data      : in  data_t;
      sd_sec_write_data_req  : out std_logic;
      sd_sec_write_end       : out std_logic;
      debug_sec_state        : out std_logic_vector(4 downto 0);
      debug_cmd_state        : out std_logic_vector(3 downto 0);
      debug_cmd_error        : out std_logic
    );
  end component;

  component sd_rom_loader
    port (
      clk                    : in  std_logic;
      rst                    : in  std_logic;
      sd_init_done           : in  std_logic;
      sd_sec_read            : out std_logic;
      sd_sec_read_addr       : out std_logic_vector(31 downto 0);
      sd_sec_read_data       : in  data_t;
      sd_sec_read_data_valid : in  std_logic;
      sd_sec_read_end        : in  std_logic;
      rom_load_we            : out std_logic;
      rom_load_addr          : out std_logic_vector(13 downto 0);
      rom_load_data          : out data_t;
      boot_done              : out std_logic;
      boot_error             : out std_logic;
      dbg_state              : out std_logic_vector(3 downto 0)
    );
  end component;

  signal pllclk0, pllclk1, pllclk2, clkfbout : std_logic;
  signal pll_lckd, pclk, pclkx2, pclkx10 : std_logic;
  signal serdesstrobe, bufpll_lock : std_logic;
  signal reset, reset_n, video_reset : std_logic;

  signal sd_init_done, sd_sec_read, sd_sec_read_valid, sd_sec_read_end : std_logic;
  signal sd_ncs_i, sd_dclk_i, sd_mosi_i : std_logic;
  signal sd_sec_read_addr : std_logic_vector(31 downto 0);
  signal sd_sec_read_data : data_t;
  signal sd_sec_state : std_logic_vector(4 downto 0);
  signal sd_cmd_state : std_logic_vector(3 downto 0);
  signal sd_cmd_error : std_logic;
  signal sd_seen_read_req : std_logic := '0';
  signal sd_seen_data_valid : std_logic := '0';
  signal sd_seen_read_end : std_logic := '0';
  signal loader_state : std_logic_vector(3 downto 0);
  signal rom_load_we : std_logic;
  signal rom_load_addr : std_logic_vector(13 downto 0);
  signal rom_load_data : data_t;
  signal boot_done, boot_error : std_logic;

  signal via_portb : data_t;
  signal uart_tx_data, boot_dbg_data, uart_mux_data : data_t;
  signal uart_tx_valid, boot_dbg_valid, uart_mux_valid, uart_tx_busy : std_logic;
  signal boot_dbg_active : std_logic;

  signal sbc_r, boot_r, vga_r : std_logic_vector(4 downto 0);
  signal sbc_g, boot_g, vga_g : std_logic_vector(5 downto 0);
  signal sbc_b, boot_b, vga_b : std_logic_vector(4 downto 0);
  signal sbc_hs, boot_hs, vga_hs : std_logic;
  signal sbc_vs, boot_vs, vga_vs : std_logic;
  signal sbc_de, boot_de, vga_de : std_logic;
  signal r8, g8, b8 : std_logic_vector(7 downto 0);
  signal src_r8, src_g8, src_b8 : std_logic_vector(7 downto 0);
  signal src_hs, src_vs, src_de : std_logic;
  signal out_r8, out_g8, out_b8 : std_logic_vector(7 downto 0) := (others => '0');
  signal out_hs, out_vs, out_de : std_logic := '0';
  signal bar_r8, bar_g8, bar_b8 : std_logic_vector(7 downto 0);
  signal bar_hs, bar_vs, bar_de : std_logic;
  signal diag_r8, diag_g8, diag_b8 : std_logic_vector(7 downto 0);
  signal hcnt : unsigned(9 downto 0) := (others => '0');
  signal vcnt : unsigned(9 downto 0) := (others => '0');
  signal reset_btn_sync : std_logic_vector(1 downto 0) := (others => '0');
  signal test_mode : std_logic := '0';

  signal tmds_data0, tmds_data1, tmds_data2 : std_logic_vector(4 downto 0);
  signal tmdsint : std_logic_vector(2 downto 0);
  signal tmdsclkint : std_logic_vector(4 downto 0);
  signal tmdsclk, toggle : std_logic := '0';
begin
  reset <= reset_btn or (not bufpll_lock);
  reset_n <= not reset;
  video_reset <= not bufpll_lock;
  led(0) <= (sd_init_done or boot_done) when boot_done = '0' else via_portb(0);
  led(1) <= (boot_error or sd_seen_read_end) when boot_done = '0' else via_portb(1);
  sd_ncs <= sd_ncs_i;
  sd_dclk <= sd_dclk_i;
  sd_mosi <= sd_mosi_i;

  vga_r  <= sbc_r;
  vga_g  <= sbc_g;
  vga_b  <= sbc_b;
  vga_hs <= sbc_hs;
  vga_vs <= sbc_vs;
  vga_de <= sbc_de;
  r8 <= vga_r & vga_r(4 downto 2);
  g8 <= vga_g & vga_g(5 downto 4);
  b8 <= vga_b & vga_b(4 downto 2);
  src_r8 <= bar_r8 when test_mode = '1' else diag_r8 when boot_done = '0' else r8;
  src_g8 <= bar_g8 when test_mode = '1' else diag_g8 when boot_done = '0' else g8;
  src_b8 <= bar_b8 when test_mode = '1' else diag_b8 when boot_done = '0' else b8;
  src_hs <= bar_hs when test_mode = '1' or boot_done = '0' else vga_hs;
  src_vs <= bar_vs when test_mode = '1' or boot_done = '0' else vga_vs;
  src_de <= bar_de when test_mode = '1' or boot_done = '0' else vga_de;

  pclkbufg : BUFG port map (I => pllclk1, O => pclk);
  pclkx2bufg : BUFG port map (I => pllclk2, O => pclkx2);

  pll_i : PLL_BASE
    generic map (
      CLKIN_PERIOD => 20.0, CLKFBOUT_MULT => 10,
      CLKOUT0_DIVIDE => 2, CLKOUT1_DIVIDE => 20, CLKOUT2_DIVIDE => 10,
      COMPENSATION => "INTERNAL"
    )
    port map (
      CLKFBIN => clkfbout, CLKFBOUT => clkfbout, CLKIN => clk_50mhz,
      CLKOUT0 => pllclk0, CLKOUT1 => pllclk1, CLKOUT2 => pllclk2,
      CLKOUT3 => open, CLKOUT4 => open, CLKOUT5 => open,
      LOCKED => pll_lckd, RST => '0'
    );

  bars : process(pclk)
    variable x : integer;
    variable y : integer;
  begin
    if rising_edge(pclk) then
      if video_reset = '1' then
        hcnt <= (others => '0');
        vcnt <= (others => '0');
        bar_de <= '0';
        bar_hs <= '1';
        bar_vs <= '1';
        bar_r8 <= (others => '0');
        bar_g8 <= (others => '0');
        bar_b8 <= (others => '0');
      else
        if hcnt = 799 then
          hcnt <= (others => '0');
          if vcnt = 524 then vcnt <= (others => '0'); else vcnt <= vcnt + 1; end if;
        else
          hcnt <= hcnt + 1;
        end if;

        x := to_integer(hcnt);
        y := to_integer(vcnt);
        if x < 640 and y < 480 then bar_de <= '1'; else bar_de <= '0'; end if;
        if x >= 656 and x < 752 then bar_hs <= '0'; else bar_hs <= '1'; end if;
        if y >= 490 and y < 492 then bar_vs <= '0'; else bar_vs <= '1'; end if;

        if y < 480 and x < 640 then
          case x / 80 is
            when 0 => bar_r8 <= x"FF"; bar_g8 <= x"FF"; bar_b8 <= x"FF";
            when 1 => bar_r8 <= x"FF"; bar_g8 <= x"FF"; bar_b8 <= x"00";
            when 2 => bar_r8 <= x"00"; bar_g8 <= x"FF"; bar_b8 <= x"FF";
            when 3 => bar_r8 <= x"00"; bar_g8 <= x"FF"; bar_b8 <= x"00";
            when 4 => bar_r8 <= x"FF"; bar_g8 <= x"00"; bar_b8 <= x"FF";
            when 5 => bar_r8 <= x"FF"; bar_g8 <= x"00"; bar_b8 <= x"00";
            when 6 => bar_r8 <= x"00"; bar_g8 <= x"00"; bar_b8 <= x"FF";
            when others => bar_r8 <= x"20"; bar_g8 <= x"20"; bar_b8 <= x"20";
          end case;
        else
          bar_r8 <= (others => '0');
          bar_g8 <= (others => '0');
          bar_b8 <= (others => '0');
        end if;
      end if;
    end if;
  end process;

  process(pclk)
  begin
    if rising_edge(pclk) then
      if reset = '1' then
        sd_seen_read_req <= '0';
        sd_seen_data_valid <= '0';
        sd_seen_read_end <= '0';
      else
        if sd_sec_read = '1' then
          sd_seen_read_req <= '1';
        end if;
        if sd_sec_read_valid = '1' then
          sd_seen_data_valid <= '1';
        end if;
        if sd_sec_read_end = '1' then
          sd_seen_read_end <= '1';
        end if;
      end if;
    end if;
  end process;

  process(hcnt, vcnt, pll_lckd, sd_init_done, sd_seen_read_req,
          sd_seen_data_valid, sd_seen_read_end, boot_done, boot_error,
          sd_cmd_error, loader_state, sd_sec_state, sd_cmd_state)
    variable x : integer;
    variable y : integer;
    variable r : std_logic_vector(7 downto 0);
    variable g : std_logic_vector(7 downto 0);
    variable b : std_logic_vector(7 downto 0);
  begin
    x := to_integer(hcnt);
    y := to_integer(vcnt);
    r := x"08";
    g := x"08";
    b := x"08";

    if x < 640 and y < 480 then
      if y < 32 then
        if boot_error = '1' or sd_cmd_error = '1' then
          r := x"FF"; g := x"00"; b := x"00";
        elsif boot_done = '1' then
          r := x"00"; g := x"C0"; b := x"30";
        elsif sd_init_done = '1' then
          r := x"C0"; g := x"A0"; b := x"00";
        else
          r := x"40"; g := x"40"; b := x"40";
        end if;
      end if;

      if y >= 72 and y < 128 then
        if x >=  40 and x <  96 and pll_lckd = '1' then r := x"00"; g := x"D0"; b := x"40"; end if;
        if x >= 112 and x < 168 and sd_init_done = '1' then r := x"00"; g := x"D0"; b := x"40"; end if;
        if x >= 184 and x < 240 and sd_seen_read_req = '1' then r := x"00"; g := x"80"; b := x"FF"; end if;
        if x >= 256 and x < 312 and sd_seen_data_valid = '1' then r := x"80"; g := x"FF"; b := x"FF"; end if;
        if x >= 328 and x < 384 and sd_seen_read_end = '1' then r := x"00"; g := x"D0"; b := x"40"; end if;
        if x >= 400 and x < 456 and boot_done = '1' then r := x"00"; g := x"D0"; b := x"40"; end if;
        if x >= 472 and x < 528 and boot_error = '1' then r := x"FF"; g := x"00"; b := x"00"; end if;
        if x >= 544 and x < 600 and sd_cmd_error = '1' then r := x"FF"; g := x"00"; b := x"00"; end if;
      end if;

      if y >= 160 and y < 208 then
        if x >=  80 and x < 128 and loader_state(0) = '1' then r := x"FF"; g := x"FF"; b := x"00"; end if;
        if x >= 144 and x < 192 and loader_state(1) = '1' then r := x"FF"; g := x"FF"; b := x"00"; end if;
        if x >= 208 and x < 256 and loader_state(2) = '1' then r := x"FF"; g := x"FF"; b := x"00"; end if;
        if x >= 272 and x < 320 and loader_state(3) = '1' then r := x"FF"; g := x"FF"; b := x"00"; end if;
      end if;

      if y >= 240 and y < 288 then
        if x >=  80 and x < 128 and sd_sec_state(0) = '1' then r := x"FF"; g := x"80"; b := x"00"; end if;
        if x >= 144 and x < 192 and sd_sec_state(1) = '1' then r := x"FF"; g := x"80"; b := x"00"; end if;
        if x >= 208 and x < 256 and sd_sec_state(2) = '1' then r := x"FF"; g := x"80"; b := x"00"; end if;
        if x >= 272 and x < 320 and sd_sec_state(3) = '1' then r := x"FF"; g := x"80"; b := x"00"; end if;
        if x >= 336 and x < 384 and sd_sec_state(4) = '1' then r := x"FF"; g := x"80"; b := x"00"; end if;
      end if;

      if y >= 320 and y < 368 then
        if x >=  80 and x < 128 and sd_cmd_state(0) = '1' then r := x"80"; g := x"FF"; b := x"FF"; end if;
        if x >= 144 and x < 192 and sd_cmd_state(1) = '1' then r := x"80"; g := x"FF"; b := x"FF"; end if;
        if x >= 208 and x < 256 and sd_cmd_state(2) = '1' then r := x"80"; g := x"FF"; b := x"FF"; end if;
        if x >= 272 and x < 320 and sd_cmd_state(3) = '1' then r := x"80"; g := x"FF"; b := x"FF"; end if;
      end if;
    end if;

    diag_r8 <= r;
    diag_g8 <= g;
    diag_b8 <= b;
  end process;

  video_pipe : process(pclk)
  begin
    if rising_edge(pclk) then
      reset_btn_sync <= reset_btn_sync(0) & reset_btn;
      test_mode <= reset_btn_sync(1);

      if video_reset = '1' then
        out_r8 <= (others => '0');
        out_g8 <= (others => '0');
        out_b8 <= (others => '0');
        out_hs <= '1';
        out_vs <= '1';
        out_de <= '0';
      else
        out_r8 <= src_r8;
        out_g8 <= src_g8;
        out_b8 <= src_b8;
        out_hs <= src_hs;
        out_vs <= src_vs;
        out_de <= src_de;
      end if;
    end if;
  end process;

  bufpll_i : BUFPLL
    generic map (DIVIDE => 5)
    port map (
      GCLK => pclkx2, IOCLK => pclkx10, LOCK => bufpll_lock,
      LOCKED => pll_lckd, PLLIN => pllclk0, SERDESSTROBE => serdesstrobe
    );

  sd_i : sd_card_top
    generic map (
      SPI_LOW_SPEED_DIV  => 268,
      SPI_HIGH_SPEED_DIV => 2
    )
    port map (
      clk => pclk, rst => reset, SD_nCS => sd_ncs_i, SD_DCLK => sd_dclk_i,
      SD_MOSI => sd_mosi_i, SD_MISO => sd_miso, sd_init_done => sd_init_done,
      sd_sec_read => sd_sec_read, sd_sec_read_addr => sd_sec_read_addr,
      sd_sec_read_data => sd_sec_read_data,
      sd_sec_read_data_valid => sd_sec_read_valid,
      sd_sec_read_end => sd_sec_read_end,
      sd_sec_write => '0', sd_sec_write_addr => (others => '0'),
      sd_sec_write_data => (others => '0'), sd_sec_write_data_req => open,
      sd_sec_write_end => open, debug_sec_state => sd_sec_state,
      debug_cmd_state => sd_cmd_state, debug_cmd_error => sd_cmd_error
    );

  loader_i : sd_rom_loader
    port map (
      clk => pclk, rst => reset, sd_init_done => sd_init_done,
      sd_sec_read => sd_sec_read, sd_sec_read_addr => sd_sec_read_addr,
      sd_sec_read_data => sd_sec_read_data,
      sd_sec_read_data_valid => sd_sec_read_valid,
      sd_sec_read_end => sd_sec_read_end,
      rom_load_we => rom_load_we, rom_load_addr => rom_load_addr,
      rom_load_data => rom_load_data, boot_done => boot_done,
      boot_error => boot_error, dbg_state => loader_state
    );

  boot_vga_i : entity work.boot_vga_debug
    generic map (CLK_DIV => 1, VGA_640 => true)
    port map (
      clk => pclk, reset_n => reset_n, sd_init_done => sd_init_done,
      sd_sec_read => sd_sec_read, sd_sec_read_end => sd_sec_read_end,
      boot_done => boot_done, boot_error => boot_error,
      sd_ncs => sd_ncs_i, sd_dclk => sd_dclk_i, sd_mosi_o => sd_mosi_i,
      sd_miso_i => sd_miso, loader_state => loader_state,
      sd_sec_state => sd_sec_state, sd_cmd_state => sd_cmd_state,
      sd_cmd_error => sd_cmd_error,
      usb_connected => '0', usb_keycode => (others => '0'),
      usb_modif => (others => '0'), usb_ascii => (others => '0'),
      usb_phase => (others => '0'), usb_key_event => '0',
      usb_polling => '0',
      ram_test_active => '0', ram_test_done => '1', ram_test_error => '0',
      ram_test_phase => (others => '0'), ram_test_addr => (others => '0'),
      ram_test_fail_addr => (others => '0'), ram_test_expected => (others => '0'),
      ram_test_actual => (others => '0'),
      vga_r => boot_r, vga_g => boot_g, vga_b => boot_b,
      vga_hs => boot_hs, vga_vs => boot_vs, vga_de => boot_de
    );

  boot_uart_i : entity work.boot_debug_uart
    generic map (STATUS_DIV => 25_000_000)
    port map (
      clk => pclk, reset_n => reset_n, sd_init_done => sd_init_done,
      sd_sec_read => sd_sec_read, sd_sec_read_end => sd_sec_read_end,
      boot_done => boot_done, boot_error => boot_error,
      sd_ncs => sd_ncs_i, sd_dclk => sd_dclk_i, sd_mosi_o => sd_mosi_i,
      sd_miso_i => sd_miso, loader_state => loader_state,
      sd_sec_state => sd_sec_state, sd_cmd_state => sd_cmd_state,
      sd_cmd_error => sd_cmd_error,
      usb_connected => '0', usb_keycode => (others => '0'),
      usb_modif => (others => '0'), usb_ascii => (others => '0'),
      usb_phase => (others => '0'),
      uart_busy => uart_tx_busy,
      uart_data => boot_dbg_data, uart_valid => boot_dbg_valid,
      active => boot_dbg_active
    );

  sbc_i : entity work.sbc_t65_boot_top
    generic map (CLK_DIV => 1, UART_CLK_HZ => 25_000_000, VGA_640 => true)
    port map (
      clk => pclk, reset_n => reset_n, boot_done => boot_done,
      rom_load_we => rom_load_we, rom_load_addr => rom_load_addr,
      rom_load_data => rom_load_data,
      vga_r => sbc_r, vga_g => sbc_g, vga_b => sbc_b,
      vga_hs => sbc_hs, vga_vs => sbc_vs, vga_de => sbc_de,
      uart_rx => uart_rx, uart_tx_data => uart_tx_data,
      uart_tx_valid => uart_tx_valid, uart_tx_busy => uart_tx_busy,
      via_portb => via_portb, dbg_cpu_addr => open, dbg_cpu_data => open,
      dbg_cpu_din => open, dbg_cpu_we => open, dbg_cpu_sync => open
    );

  uart_mux_data  <= boot_dbg_data when boot_dbg_active = '1' else uart_tx_data;
  uart_mux_valid <= boot_dbg_valid when boot_dbg_active = '1' else uart_tx_valid;

  uart_ser : entity work.uart_tx_ser
    generic map (CLK_HZ => 25_000_000)
    port map (
      clk => pclk, reset_n => reset_n, data => uart_mux_data,
      valid => uart_mux_valid, tx => uart_tx, busy => uart_tx_busy
    );

  enc_i : entity work.dvi_encoder
    port map (
      clkin => pclk, clkx2in => pclkx2, rstin => video_reset,
      blue_din => out_b8, green_din => out_g8, red_din => out_r8,
      hsync => out_hs, vsync => out_vs, de => out_de,
      tmds_data0 => tmds_data0, tmds_data1 => tmds_data1,
      tmds_data2 => tmds_data2
    );

  ser0 : entity work.serdes_n_to_1
    generic map (SF => 5)
    port map (datain => tmds_data0, gclk => pclkx2, iob_data_out => tmdsint(0),
              ioclk => pclkx10, reset => video_reset, serdesstrobe => serdesstrobe);
  ser1 : entity work.serdes_n_to_1
    generic map (SF => 5)
    port map (datain => tmds_data1, gclk => pclkx2, iob_data_out => tmdsint(1),
              ioclk => pclkx10, reset => video_reset, serdesstrobe => serdesstrobe);
  ser2 : entity work.serdes_n_to_1
    generic map (SF => 5)
    port map (datain => tmds_data2, gclk => pclkx2, iob_data_out => tmdsint(2),
              ioclk => pclkx10, reset => video_reset, serdesstrobe => serdesstrobe);
  serclk : entity work.serdes_n_to_1
    generic map (SF => 5)
    port map (datain => tmdsclkint, gclk => pclkx2, iob_data_out => tmdsclk,
              ioclk => pclkx10, reset => video_reset, serdesstrobe => serdesstrobe);

  process(pclkx2)
  begin
    if rising_edge(pclkx2) then
      if video_reset = '1' then toggle <= '0'; else toggle <= not toggle; end if;
      if toggle = '1' then tmdsclkint <= "11111"; else tmdsclkint <= "00000"; end if;
    end if;
  end process;

  tmds0 : OBUFDS port map (I => tmdsint(0), O => tmds(0), OB => tmdsb(0));
  tmds1 : OBUFDS port map (I => tmdsint(1), O => tmds(1), OB => tmdsb(1));
  tmds2 : OBUFDS port map (I => tmdsint(2), O => tmds(2), OB => tmdsb(2));
  tmds3 : OBUFDS port map (I => tmdsclk, O => tmds(3), OB => tmdsb(3));
end architecture;
