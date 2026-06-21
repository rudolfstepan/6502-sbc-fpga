-- Tang Primer 20K board top — 6502 SBC with HDMI output.
--
-- Clock: 27 MHz oscillator -> 270 MHz PLL root -> 135 MHz TMDS,
--   54 MHz SBC system clock, and 27 MHz pixel clock.
--
-- Video: vic_vga runs at CLK_DIV=1 (27 MHz pixel), 858x525 total (CEA 480p),
--   giving 640x480 @ 31.47 kHz H / 59.94 Hz V.  Encoded to DVI TMDS over HDMI.
--
-- KEY[0] = T10 (dock S0, LVCMOS33, active-low reset button):
--                short press  -> CPU soft reset (restart program, keep ROM/boot)
--                long press >1s -> full board reset (re-run SD boot loader)
-- KEY[1] = T6  (PMOD0, LVCMOS33, active-low UART monitor enter / CPU hold).
--                The dock S1 button (T3) is unusable with DDR3 (T3 is in DDR
--                Bank 4 @ 1.5 V), so wire an external momentary button from the
--                T6 header pin to GND; the internal pull-up reads '1' otherwise.
-- LED[0]/LED[1] show boot status until boot_done, then LED[3:0] follow VIA PB[3:0].
library ieee;
use ieee.std_logic_1164.all;
use work.sbc_pkg.all;

entity tang20k_sbc_top is
  generic (
    BAUD          : positive := 115_200
  );
  port (
    clk_27mhz  : in  std_logic;
    key        : in  std_logic_vector(1 downto 0);
    led        : out std_logic_vector(3 downto 0);
    uart_tx    : out std_logic;
    uart_rx    : in  std_logic;
    sd_dclk    : out std_logic;
    sd_ncs     : out std_logic;
    sd_mosi    : out std_logic;
    sd_miso    : in  std_logic;
    -- PS/2 keyboard on PMOD GPIO (directly active-low, open-collector)
    ps2_clk    : in std_logic;
    ps2_data   : in std_logic;
    -- PT8211 audio DAC (dock board)
    dac_bck    : out std_logic;
    dac_ws     : out std_logic;
    dac_din    : out std_logic;
    pa_en      : out std_logic;   -- dock audio power-amplifier enable (active high)
    -- HDMI TMDS differential outputs
    tmds_clk_p : out std_logic;
    tmds_clk_n : out std_logic;
    tmds_d_p   : out std_logic_vector(2 downto 0);
    tmds_d_n   : out std_logic_vector(2 downto 0);

    -- DDR3 SDRAM (on-board, drives main RAM via Gowin DDR3 Memory Interface IP)
    ddr_addr    : out   std_logic_vector(13 downto 0);
    ddr_bank    : out   std_logic_vector(2 downto 0);
    ddr_cs      : out   std_logic;
    ddr_ras     : out   std_logic;
    ddr_cas     : out   std_logic;
    ddr_we      : out   std_logic;
    ddr_ck      : out   std_logic;
    ddr_ck_n    : out   std_logic;
    ddr_cke     : out   std_logic;
    ddr_odt     : out   std_logic;
    ddr_reset_n : out   std_logic;
    ddr_dm      : out   std_logic_vector(1 downto 0);
    ddr_dq      : inout std_logic_vector(15 downto 0);
    ddr_dqs     : inout std_logic_vector(1 downto 0);
    ddr_dqs_n   : inout std_logic_vector(1 downto 0)
  );
end entity;

architecture rtl of tang20k_sbc_top is
  component sd_card_top
    generic (
      SPI_LOW_SPEED_DIV  : integer := 134;
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

  -- Gowin DDR3 memory-interface IP (generated; see project/src/ddr3_memory_interface)
  component DDR3_Memory_Interface_Top
    port (
      clk                 : in    std_logic;
      memory_clk          : in    std_logic;
      pll_lock            : in    std_logic;
      rst_n               : in    std_logic;
      app_burst_number    : in    std_logic_vector(5 downto 0);
      cmd_ready           : out   std_logic;
      cmd                 : in    std_logic_vector(2 downto 0);
      cmd_en              : in    std_logic;
      addr                : in    std_logic_vector(27 downto 0);
      wr_data_rdy         : out   std_logic;
      wr_data             : in    std_logic_vector(127 downto 0);
      wr_data_en          : in    std_logic;
      wr_data_end         : in    std_logic;
      wr_data_mask        : in    std_logic_vector(15 downto 0);
      rd_data             : out   std_logic_vector(127 downto 0);
      rd_data_valid       : out   std_logic;
      rd_data_end         : out   std_logic;
      sr_req              : in    std_logic;
      ref_req             : in    std_logic;
      sr_ack              : out   std_logic;
      ref_ack             : out   std_logic;
      init_calib_complete : out   std_logic;
      clk_out             : out   std_logic;
      ddr_rst             : out   std_logic;
      burst               : in    std_logic;
      O_ddr_addr          : out   std_logic_vector(13 downto 0);
      O_ddr_ba            : out   std_logic_vector(2 downto 0);
      O_ddr_cs_n          : out   std_logic;
      O_ddr_ras_n         : out   std_logic;
      O_ddr_cas_n         : out   std_logic;
      O_ddr_we_n          : out   std_logic;
      O_ddr_clk           : out   std_logic;
      O_ddr_clk_n         : out   std_logic;
      O_ddr_cke           : out   std_logic;
      O_ddr_odt           : out   std_logic;
      O_ddr_reset_n       : out   std_logic;
      O_ddr_dqm           : out   std_logic_vector(1 downto 0);
      IO_ddr_dq           : inout std_logic_vector(15 downto 0);
      IO_ddr_dqs          : inout std_logic_vector(1 downto 0);
      IO_ddr_dqs_n        : inout std_logic_vector(1 downto 0)
    );
  end component;

  -- Generated rPLL wrapper for the DDR3 memory clock (27 MHz -> ~400 MHz)
  component Gowin_rPLL
    port (
      clkout : out std_logic;
      lock   : out std_logic;
      reset  : in  std_logic;
      clkin  : in  std_logic
    );
  end component;

  signal clk_sys      : std_logic;   -- 54 MHz from HDMI clock tree
  signal clk_pix      : std_logic;   -- 27 MHz HDMI pixel clock
  signal pll_lock     : std_logic;
  signal reset_n      : std_logic;
  signal rst          : std_logic;
  -- key(0) reset button: short press = CPU soft reset, long press = full board
  -- reset. Debounced and synchronised in the clk_sys domain.
  constant DB_MAX     : integer := 270_000;     -- ~5 ms debounce  @ 54 MHz
  constant LONG_MAX   : integer := 54_000_000;  -- ~1 s  long-press @ 54 MHz
  signal key0_sync    : std_logic_vector(2 downto 0) := (others => '1');
  signal key0_db      : std_logic := '1';        -- debounced level (1 = released)
  signal db_cnt       : integer range 0 to DB_MAX := 0;
  signal press_cnt    : integer range 0 to LONG_MAX := 0;
  signal soft_reset   : std_logic := '0';        -- CPU-only reset (short press)
  signal long_reset   : std_logic := '0';        -- full board reset (long press)
  signal uart_tx_data : data_t;
  signal uart_tx_valid: std_logic;
  signal uart_tx_busy : std_logic;
  signal uart_mux_data  : data_t;
  signal uart_mux_valid : std_logic;
  signal via_portb    : data_t;
  signal vga_r        : std_logic_vector(4 downto 0);
  signal vga_g        : std_logic_vector(5 downto 0);
  signal vga_b        : std_logic_vector(4 downto 0);
  signal vga_hs       : std_logic;
  signal vga_vs       : std_logic;
  signal vga_de       : std_logic;
  signal vga_mux_r    : std_logic_vector(4 downto 0);
  signal vga_mux_g    : std_logic_vector(5 downto 0);
  signal vga_mux_b    : std_logic_vector(4 downto 0);
  signal vga_mux_hs   : std_logic;
  signal vga_mux_vs   : std_logic;
  signal vga_mux_de   : std_logic;
  signal sbc_vga_r    : std_logic_vector(4 downto 0);
  signal sbc_vga_g    : std_logic_vector(5 downto 0);
  signal sbc_vga_b    : std_logic_vector(4 downto 0);
  signal sbc_vga_hs   : std_logic;
  signal sbc_vga_vs   : std_logic;
  signal sbc_vga_de   : std_logic;
  signal boot_vga_r   : std_logic_vector(4 downto 0);
  signal boot_vga_g   : std_logic_vector(5 downto 0);
  signal boot_vga_b   : std_logic_vector(4 downto 0);
  signal boot_vga_hs  : std_logic;
  signal boot_vga_vs  : std_logic;
  signal boot_vga_de  : std_logic;
  signal boot_vga_active : std_logic;
  signal sd_init_done       : std_logic;
  signal sd_sec_read        : std_logic;
  signal sd_sec_read_addr   : std_logic_vector(31 downto 0);
  signal sd_sec_read_data   : data_t;
  signal sd_sec_read_valid  : std_logic;
  signal sd_sec_read_end    : std_logic;
  signal sd_sec_state       : std_logic_vector(4 downto 0);
  signal sd_cmd_state       : std_logic_vector(3 downto 0);
  signal sd_cmd_error       : std_logic;
  signal sd_ncs_i           : std_logic;
  signal sd_dclk_i          : std_logic;
  signal sd_mosi_i          : std_logic;
  signal rom_load_we        : std_logic;
  signal rom_load_addr      : std_logic_vector(13 downto 0);
  signal rom_load_data      : data_t;
  signal boot_done          : std_logic;
  signal boot_error         : std_logic;
  signal loader_state       : std_logic_vector(3 downto 0);
  signal boot_dbg_data      : data_t;
  signal boot_dbg_valid     : std_logic;
  signal boot_dbg_active    : std_logic;
  signal monitor_rx_data    : data_t;
  signal monitor_rx_valid   : std_logic;
  signal monitor_tx_data    : data_t;
  signal monitor_tx_valid   : std_logic;
  signal monitor_active     : std_logic;
  signal monitor_button     : std_logic;
  signal monitor_mem_req    : std_logic;
  signal monitor_mem_we     : std_logic;
  signal monitor_mem_addr   : addr_t;
  signal monitor_mem_wdata  : data_t;
  signal monitor_mem_rdata  : data_t;
  signal monitor_mem_ready  : std_logic;
  signal monitor_jump_req   : std_logic;
  signal monitor_jump_addr  : addr_t;
  signal sd_seen_read_end   : std_logic := '0';
  signal usb_connected      : std_logic;
  signal usb_keycode        : std_logic_vector(7 downto 0);
  signal usb_modif          : std_logic_vector(7 downto 0);
  signal usb_ascii          : std_logic_vector(7 downto 0);
  signal usb_phase          : std_logic_vector(3 downto 0);
  signal usb_key_event      : std_logic;
  signal usb_polling        : std_logic;
  signal usb_cap_addr       : std_logic_vector(6 downto 0);
  signal usb_cap_data       : std_logic_vector(15 downto 0);
  signal usb_cap_ready      : std_logic;

  -- DDR3 main RAM (Gowin IP + ddr3_byte_bridge)
  signal ddr_memory_clk     : std_logic;
  signal ddr_pll_lock       : std_logic;
  signal ddr_clk_x1         : std_logic;   -- 100 MHz DDR3 user clock
  signal ddr_calib_complete : std_logic;
  signal app_cmd            : std_logic_vector(2 downto 0);
  signal app_cmd_en         : std_logic;
  signal app_cmd_rdy        : std_logic;
  signal app_addr27         : std_logic_vector(26 downto 0);
  signal app_addr28         : std_logic_vector(27 downto 0);
  -- DDR3 controller reset + calibration auto-retry (sequenced on clk_27mhz, the
  -- IP's own reference clock -- no PLL-derived fabric clock is loaded).
  constant DDR_RST_HOLD     : integer := 1023;        -- reset assert width (~38 us @ 27 MHz)
  constant DDR_CAL_WAIT     : integer := 540_000;     -- calibration timeout (~20 ms @ 27 MHz)
  type ddr_rst_state_t is (DR_ASSERT, DR_WAIT_CAL);
  signal ddr_rst_state      : ddr_rst_state_t := DR_ASSERT;
  signal ddr_rst_n          : std_logic := '0';       -- DDR3 controller reset
  signal ddr_lock_sync      : std_logic_vector(1 downto 0) := (others => '0');
  signal ddr_cal_sync       : std_logic_vector(1 downto 0) := (others => '0');
  signal ddr_rst_cnt        : integer range 0 to DDR_CAL_WAIT := 0;
  -- Reference DDR3 IP uses zero for a single 128-bit user-interface beat.
  signal app_wren           : std_logic;
  signal app_wdata          : std_logic_vector(127 downto 0);
  signal app_wdata_end      : std_logic;
  signal app_wdata_mask     : std_logic_vector(15 downto 0);
  signal app_wdata_rdy      : std_logic;
  signal app_rdata          : std_logic_vector(127 downto 0);
  signal app_rdata_valid    : std_logic;
  -- core <-> bridge byte port
  signal sram_ext_req   : std_logic;
  signal sram_ext_we    : std_logic;
  signal sram_ext_addr  : std_logic_vector(14 downto 0);
  signal sram_ext_din   : data_t;
  signal sram_ext_dout  : data_t;
  signal sram_ext_ack   : std_logic;
  signal ram_ready      : std_logic;
  -- self-test status (to boot screen)
  signal ram_test_active    : std_logic;
  signal ram_test_done      : std_logic;
  signal ram_test_error     : std_logic;
  signal ram_test_phase     : std_logic_vector(3 downto 0);
  signal ram_test_addr      : std_logic_vector(14 downto 0);
  signal ram_test_fail_addr : std_logic_vector(14 downto 0);
  signal ram_test_expected  : data_t;
  signal ram_test_actual    : data_t;
  signal sbc_boot_done      : std_logic;
begin
  -- key(0) is the reset button: a short press soft-resets only the CPU (the
  -- running program restarts via its reset vector, ROM/boot/SRAM kept), a long
  -- press (>1 s) asserts a full board reset. Debounced/synchronised on clk_sys,
  -- which stays alive because the HDMI PLL is no longer gated by the button.
  key_reset_proc : process(clk_sys)
  begin
    if rising_edge(clk_sys) then
      if pll_lock = '0' then
        key0_sync  <= (others => '1');
        key0_db    <= '1';
        db_cnt     <= 0;
        press_cnt  <= 0;
        soft_reset <= '0';
        long_reset <= '0';
      else
        key0_sync <= key0_sync(1 downto 0) & key(0);
        -- debounce: the synchronised level must hold steady DB_MAX cycles
        if key0_sync(2) = key0_db then
          db_cnt <= 0;
        elsif db_cnt = DB_MAX then
          key0_db <= key0_sync(2);
          db_cnt  <= 0;
        else
          db_cnt <= db_cnt + 1;
        end if;
        -- press duration: short -> soft_reset (CPU only), held >1 s -> full reset
        if key0_db = '0' then            -- pressed (active low)
          soft_reset <= '1';
          if press_cnt = LONG_MAX then
            long_reset <= '1';
          else
            press_cnt <= press_cnt + 1;
          end if;
        else                             -- released
          soft_reset <= '0';
          long_reset <= '0';
          press_cnt  <= 0;
        end if;
      end if;
    end if;
  end process;

  -- Full board reset on long press; also held until the PLL locks at power-on.
  reset_n <= (not long_reset) and pll_lock;
  rst <= not reset_n;
  monitor_button <= not key(1);
  pa_en <= '1';  -- keep dock audio power amplifier enabled (PT8211 PA_EN, active high)
  sd_ncs <= sd_ncs_i;
  sd_dclk <= sd_dclk_i;
  sd_mosi <= sd_mosi_i;
  -- Hold the CPU until both the SD ROM load (boot_done) and the DDR3 main RAM
  -- (calibration + self-test, ram_ready) are ready.
  sbc_boot_done   <= boot_done and ram_ready;
  boot_vga_active <= (not sbc_boot_done) or boot_error or monitor_active;

  vga_mux_r  <= boot_vga_r  when boot_vga_active = '1' else sbc_vga_r;
  vga_mux_g  <= boot_vga_g  when boot_vga_active = '1' else sbc_vga_g;
  vga_mux_b  <= boot_vga_b  when boot_vga_active = '1' else sbc_vga_b;
  vga_mux_hs <= boot_vga_hs when boot_vga_active = '1' else sbc_vga_hs;
  vga_mux_vs <= boot_vga_vs when boot_vga_active = '1' else sbc_vga_vs;
  vga_mux_de <= boot_vga_de when boot_vga_active = '1' else sbc_vga_de;

  -- Register the complete renderer output together before the related-clock
  -- handoff in tang20k_hdmi_tx. This removes long combinational 54->27 MHz
  -- paths while preserving RGB/sync/data-enable alignment.
  process(clk_sys)
  begin
    if rising_edge(clk_sys) then
      if reset_n = '0' then
        vga_r  <= (others => '0');
        vga_g  <= (others => '0');
        vga_b  <= (others => '0');
        vga_hs <= '1';
        vga_vs <= '1';
        vga_de <= '0';
      else
        vga_r  <= vga_mux_r;
        vga_g  <= vga_mux_g;
        vga_b  <= vga_mux_b;
        vga_hs <= vga_mux_hs;
        vga_vs <= vga_mux_vs;
        vga_de <= vga_mux_de;
      end if;
    end if;
  end process;

  process(clk_sys)
  begin
    if rising_edge(clk_sys) then
      if reset_n = '0' then
        sd_seen_read_end <= '0';
      elsif sd_sec_read_end = '1' then
        sd_seen_read_end <= '1';
      end if;
    end if;
  end process;

  sd_i : sd_card_top
    generic map (
      SPI_LOW_SPEED_DIV  => 268,
      SPI_HIGH_SPEED_DIV => 2
    )
    port map (
      clk                    => clk_sys,
      rst                    => rst,
      SD_nCS                 => sd_ncs_i,
      SD_DCLK                => sd_dclk_i,
      SD_MOSI                => sd_mosi_i,
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
      debug_sec_state        => sd_sec_state,
      debug_cmd_state        => sd_cmd_state,
      debug_cmd_error        => sd_cmd_error
    );

  loader_i : sd_rom_loader
    port map (
      clk                    => clk_sys,
      rst                    => rst,
      sd_init_done           => sd_init_done,
      sd_sec_read            => sd_sec_read,
      sd_sec_read_addr       => sd_sec_read_addr,
      sd_sec_read_data       => sd_sec_read_data,
      sd_sec_read_data_valid => sd_sec_read_valid,
      sd_sec_read_end        => sd_sec_read_end,
      rom_load_we            => rom_load_we,
      rom_load_addr          => rom_load_addr,
      rom_load_data          => rom_load_data,
      boot_done              => boot_done,
      boot_error             => boot_error,
      dbg_state              => loader_state
    );

  boot_debug_i : entity work.boot_debug_uart
    generic map (STATUS_DIV => 54_000_000)
    port map (
      clk             => clk_sys,
      reset_n         => reset_n,
      sd_init_done    => sd_init_done,
      sd_sec_read     => sd_sec_read,
      sd_sec_read_end => sd_sec_read_end,
      boot_done       => boot_done,
      boot_error      => boot_error,
      sd_ncs          => sd_ncs_i,
      sd_dclk         => sd_dclk_i,
      sd_mosi_o       => sd_mosi_i,
      sd_miso_i       => sd_miso,
      loader_state    => loader_state,
      sd_sec_state    => sd_sec_state,
      sd_cmd_state    => sd_cmd_state,
      sd_cmd_error    => sd_cmd_error,
      usb_connected   => usb_connected,
      usb_keycode     => usb_keycode,
      usb_modif       => usb_modif,
      usb_ascii       => usb_ascii,
      usb_phase       => usb_phase,
      uart_busy       => uart_tx_busy,
      uart_data       => boot_dbg_data,
      uart_valid      => boot_dbg_valid,
      active          => boot_dbg_active
    );


  monitor_rx_i : entity work.uart_rx_ser
    generic map (CLK_HZ => 54_000_000, BAUD => BAUD)
    port map (
      clk     => clk_sys,
      reset_n => reset_n,
      rx      => uart_rx,
      data    => monitor_rx_data,
      valid   => monitor_rx_valid
    );

  monitor_i : entity work.uart_debug_monitor
    port map (
      clk       => clk_sys,
      reset_n   => reset_n,
      enter_btn => monitor_button,
      rx_data   => monitor_rx_data,
      rx_valid  => monitor_rx_valid,
      tx_busy   => uart_tx_busy,
      tx_data   => monitor_tx_data,
      tx_valid  => monitor_tx_valid,
      active    => monitor_active,
      mem_req   => monitor_mem_req,
      mem_we    => monitor_mem_we,
      mem_addr  => monitor_mem_addr,
      mem_wdata => monitor_mem_wdata,
      mem_rdata => monitor_mem_rdata,
      mem_ready => monitor_mem_ready,
      jump_req  => monitor_jump_req,
      jump_addr => monitor_jump_addr,
      usb_connected => usb_connected,
      usb_keycode   => usb_keycode,
      usb_modif     => usb_modif,
      usb_ascii     => usb_ascii,
      usb_phase     => usb_phase,
      usb_key_event => usb_key_event,
      usb_polling   => usb_polling,
      usb_cap_addr  => usb_cap_addr,
      usb_cap_data  => usb_cap_data,
      usb_cap_ready => usb_cap_ready
    );

  sbc_i : entity work.sbc_t65_boot_monitor_top
    generic map (CLK_HZ => 54_000_000, BAUD => BAUD)
    port map (
      clk           => clk_sys,
      reset_n       => reset_n,
      boot_done     => sbc_boot_done,
      soft_reset    => soft_reset,
      monitor_hold  => monitor_active,
      monitor_mem_req   => monitor_mem_req,
      monitor_mem_we    => monitor_mem_we,
      monitor_mem_addr  => monitor_mem_addr,
      monitor_mem_wdata => monitor_mem_wdata,
      monitor_mem_rdata => monitor_mem_rdata,
      monitor_mem_ready => monitor_mem_ready,
      monitor_jump_req  => monitor_jump_req,
      monitor_jump_addr => monitor_jump_addr,
      rom_load_we   => rom_load_we,
      rom_load_addr => rom_load_addr,
      rom_load_data => rom_load_data,
      vga_r         => sbc_vga_r,
      vga_g         => sbc_vga_g,
      vga_b         => sbc_vga_b,
      vga_hs        => sbc_vga_hs,
      vga_vs        => sbc_vga_vs,
      vga_de        => sbc_vga_de,
      uart_rx       => uart_rx,
      uart_tx_data  => uart_tx_data,
      uart_tx_valid => uart_tx_valid,
      uart_tx_busy  => uart_tx_busy,
      via_portb     => via_portb,
      sram_ext_req  => sram_ext_req,
      sram_ext_we   => sram_ext_we,
      sram_ext_addr => sram_ext_addr,
      sram_ext_din  => sram_ext_din,
      sram_ext_dout => sram_ext_dout,
      sram_ext_ack  => sram_ext_ack,
      dac_bck       => dac_bck,
      dac_ws        => dac_ws,
      dac_din       => dac_din,
      ps2_clk       => ps2_clk,
      ps2_data      => ps2_data,
      usb_connected => usb_connected,
      usb_keycode   => usb_keycode,
      usb_modif     => usb_modif,
      usb_ascii     => usb_ascii,
      usb_phase     => usb_phase,
      usb_key_event => usb_key_event,
      usb_polling   => usb_polling,
      usb_cap_addr  => usb_cap_addr,
      usb_cap_data  => usb_cap_data,
      usb_cap_ready => usb_cap_ready,
      dbg_cpu_addr  => open,
      dbg_cpu_data  => open,
      dbg_cpu_din   => open,
      dbg_cpu_we    => open,
      dbg_cpu_sync  => open
    );

  boot_vga_i : entity work.boot_vga_debug
    generic map (CLK_DIV => 2)
    port map (
      clk             => clk_sys,
      reset_n         => reset_n,
      sd_init_done    => sd_init_done,
      sd_sec_read     => sd_sec_read,
      sd_sec_read_end => sd_sec_read_end,
      boot_done       => boot_done,
      boot_error      => boot_error,
      sd_ncs          => sd_ncs_i,
      sd_dclk         => sd_dclk_i,
      sd_mosi_o       => sd_mosi_i,
      sd_miso_i       => sd_miso,
      loader_state    => loader_state,
      sd_sec_state    => sd_sec_state,
      sd_cmd_state    => sd_cmd_state,
      sd_cmd_error    => sd_cmd_error,
      usb_connected   => usb_connected,
      usb_keycode     => usb_keycode,
      usb_modif       => usb_modif,
      usb_ascii       => usb_ascii,
      usb_phase       => usb_phase,
      usb_key_event   => usb_key_event,
      usb_polling     => usb_polling,
      ram_test_active => ram_test_active,
      ram_test_done   => ram_test_done,
      ram_test_error  => ram_test_error,
      ram_test_phase  => ram_test_phase,
      ram_test_addr   => ram_test_addr,
      ram_test_fail_addr => ram_test_fail_addr,
      ram_test_expected  => ram_test_expected,
      ram_test_actual    => ram_test_actual,
      vga_r           => boot_vga_r,
      vga_g           => boot_vga_g,
      vga_b           => boot_vga_b,
      vga_hs          => boot_vga_hs,
      vga_vs          => boot_vga_vs,
      vga_de          => boot_vga_de
    );

  uart_ser_i : entity work.uart_tx_ser
    generic map (CLK_HZ => 54_000_000, BAUD => BAUD)
    port map (
      clk     => clk_sys,
      reset_n => reset_n,
      data    => uart_mux_data,
      valid   => uart_mux_valid,
      tx      => uart_tx,
      busy    => uart_tx_busy
    );

  uart_mux_data  <= monitor_tx_data when monitor_active = '1' else
                    boot_dbg_data   when boot_dbg_active = '1' else
                    uart_tx_data;
  uart_mux_valid <= monitor_tx_valid when monitor_active = '1' else
                    boot_dbg_valid   when boot_dbg_active = '1' else
                    uart_tx_valid;

  hdmi_i : entity work.tang20k_hdmi_tx
    port map (
      clk_in     => clk_27mhz,
      -- HDMI PLL is decoupled from the reset button so clk_sys keeps running
      -- during a CPU soft reset (and during a full reset, so video stays up).
      reset_n    => '1',
      vga_de     => vga_de,
      vga_hs     => vga_hs,
      vga_vs     => vga_vs,
      vga_r      => vga_r,
      vga_g      => vga_g,
      vga_b      => vga_b,
      clk_sys    => clk_sys,
      clk_pix    => clk_pix,
      pll_lock   => pll_lock,
      tmds_clk_p => tmds_clk_p,
      tmds_clk_n => tmds_clk_n,
      tmds_d_p   => tmds_d_p,
      tmds_d_n   => tmds_d_n
    );

  -- ── DDR3 main RAM ───────────────────────────────────────────────────────
  -- Single-rank board: chip-select tied low (matches Sipeed DDR-test example).
  ddr_cs        <= '0';
  app_addr28    <= '0' & app_addr27;
  -- DDR3 bring-up sequenced like the known-good Sipeed DDR reference, with an
  -- automatic calibration retry:
  --  * the DDR memory PLL free-runs (reset tied '0' in the port map below) so it
  --    locks immediately at power-on, independent of the HDMI PLL and the button.
  --  * the controller reset is held a margin after the memory PLL locks, then
  --    released synchronously on clk_27mhz -- the IP's own reference clock.  This
  --    sequencer runs on the board oscillator only; it loads no PLL-derived
  --    fabric clock, so the exclusive PLL placement stays intact.
  --  * if calibration does not complete within DDR_CAL_WAIT, the controller reset
  --    is re-asserted and calibration retried automatically -- Gowin DDR3 bring-up
  --    is occasionally marginal at power-on, so this replaces the manual reset
  --    presses that were otherwise needed before the RAM test would finish.
  --  * a long-press full reset re-asserts the controller reset without disturbing
  --    the free-running memory PLL.
  ddr_reset_seq : process(clk_27mhz)
  begin
    if rising_edge(clk_27mhz) then
      ddr_lock_sync <= ddr_lock_sync(0) & ddr_pll_lock;
      ddr_cal_sync  <= ddr_cal_sync(0)  & ddr_calib_complete;

      if ddr_lock_sync(1) = '0' or long_reset = '1' then
        -- no stable memory clock yet, or a long-press full reset: hold reset
        ddr_rst_state <= DR_ASSERT;
        ddr_rst_cnt   <= 0;
        ddr_rst_n     <= '0';
      else
        case ddr_rst_state is
          when DR_ASSERT =>
            ddr_rst_n <= '0';
            if ddr_rst_cnt = DDR_RST_HOLD then
              ddr_rst_cnt   <= 0;
              ddr_rst_n     <= '1';
              ddr_rst_state <= DR_WAIT_CAL;
            else
              ddr_rst_cnt <= ddr_rst_cnt + 1;
            end if;

          when DR_WAIT_CAL =>
            ddr_rst_n <= '1';
            if ddr_cal_sync(1) = '1' then
              ddr_rst_cnt <= 0;                 -- calibrated: stay released
            elsif ddr_rst_cnt = DDR_CAL_WAIT then
              ddr_rst_cnt   <= 0;
              ddr_rst_state <= DR_ASSERT;       -- timeout: re-assert and retry
            else
              ddr_rst_cnt <= ddr_rst_cnt + 1;
            end if;
        end case;
      end if;
    end if;
  end process;

  ddr_mem_pll_i : Gowin_rPLL
    port map (
      clkout => ddr_memory_clk,   -- ~400 MHz (DDR-800)
      lock   => ddr_pll_lock,
      reset  => '0',              -- free-running: lock ASAP, like the Sipeed reference
      clkin  => clk_27mhz
    );

  ddr3_ip_i : DDR3_Memory_Interface_Top
    port map (
      clk                 => clk_27mhz,
      memory_clk          => ddr_memory_clk,
      pll_lock            => ddr_pll_lock,
      rst_n               => ddr_rst_n,
      app_burst_number    => (others => '0'), -- one 128-bit user-interface beat
      cmd_ready           => app_cmd_rdy,
      cmd                 => app_cmd,
      cmd_en              => app_cmd_en,
      addr                => app_addr28,
      wr_data_rdy         => app_wdata_rdy,
      wr_data             => app_wdata,
      wr_data_en          => app_wren,
      wr_data_end         => app_wdata_end,
      wr_data_mask        => app_wdata_mask,
      rd_data             => app_rdata,
      rd_data_valid       => app_rdata_valid,
      rd_data_end         => open,
      sr_req              => '0',
      ref_req             => '0',
      sr_ack              => open,
      ref_ack             => open,
      init_calib_complete => ddr_calib_complete,
      clk_out             => ddr_clk_x1,
      ddr_rst             => open,
      burst               => '1',
      O_ddr_addr          => ddr_addr,
      O_ddr_ba            => ddr_bank,
      O_ddr_cs_n          => open,   -- ddr_cs pin tied low above
      O_ddr_ras_n         => ddr_ras,
      O_ddr_cas_n         => ddr_cas,
      O_ddr_we_n          => ddr_we,
      O_ddr_clk           => ddr_ck,
      O_ddr_clk_n         => ddr_ck_n,
      O_ddr_cke           => ddr_cke,
      O_ddr_odt           => ddr_odt,
      O_ddr_reset_n       => ddr_reset_n,
      O_ddr_dqm           => ddr_dm,
      IO_ddr_dq           => ddr_dq,
      IO_ddr_dqs          => ddr_dqs,
      IO_ddr_dqs_n        => ddr_dqs_n
    );

  ddr_bridge_i : entity work.ddr3_byte_bridge
    generic map (ADDR_BITS => 15, MASK_BIT_MASKS => true)
    port map (
      clk_sys   => clk_sys,
      rst_sys_n => reset_n,
      req       => sram_ext_req,
      we        => sram_ext_we,
      addr      => sram_ext_addr,
      din       => sram_ext_din,
      dout      => sram_ext_dout,
      ack       => sram_ext_ack,
      ram_ready => ram_ready,

      ram_test_active    => ram_test_active,
      ram_test_done      => ram_test_done,
      ram_test_error     => ram_test_error,
      ram_test_phase     => ram_test_phase,
      ram_test_addr      => ram_test_addr,
      ram_test_fail_addr => ram_test_fail_addr,
      ram_test_expected  => ram_test_expected,
      ram_test_actual    => ram_test_actual,

      clk_x1              => ddr_clk_x1,
      init_calib_complete => ddr_calib_complete,
      dbg_pll_lock        => ddr_pll_lock,
      app_cmd             => app_cmd,
      app_cmd_en          => app_cmd_en,
      app_cmd_rdy         => app_cmd_rdy,
      app_addr            => app_addr27,
      app_wren            => app_wren,
      app_wdata           => app_wdata,
      app_wdata_end       => app_wdata_end,
      app_wdata_mask      => app_wdata_mask,
      app_wdata_rdy       => app_wdata_rdy,
      app_rdata           => app_rdata,
      app_rdata_valid     => app_rdata_valid
    );

  led(0) <= not (boot_done or sd_init_done) when boot_done = '0' else not via_portb(0);
  led(1) <= not (boot_error or sd_seen_read_end) when boot_done = '0' else not via_portb(1);
  -- DDR3 bring-up diagnostics until the CPU is released:
  --   LED2 lit = DDR memory PLL locked, LED3 lit = DDR3 calibration complete.
  led(2) <= not ddr_pll_lock        when sbc_boot_done = '0' else not via_portb(2);
  led(3) <= not ddr_calib_complete  when sbc_boot_done = '0' else not via_portb(3);

end architecture;
