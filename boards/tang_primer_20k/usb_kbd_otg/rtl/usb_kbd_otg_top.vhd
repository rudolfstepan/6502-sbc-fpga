-- ============================================================================
-- usb_kbd_otg_top -- glue for the USB host on the OTG port.
-- (Roadmap: boards/tang_primer_20k/usb_kbd_otg/ROADMAP.md)
--
-- Chain:  USB3317 --ULPI(60MHz)-- [tristate] -- ulpi_wrapper --UTMI--
--         usbh_host --AXI4-Lite-- usb_host_seq (the sequencer/brain).
--         (A former ulpi_vbus_init pre-init stage was removed: VBUS is
--         board-supplied on the dock, and the half-open handoff could wedge
--         the PHY -- see the note at the ULPI tristate.)
--
-- This top is just wiring: PHY reset, ULPI tristate mux, the vendored wrapper +
-- host core, a small AXI4-Lite master, and the usb_host_seq state machine which
-- brings up the host, resets+detects the device, and (Stage 2) does a control
-- read GET_DESCRIPTOR, printing the device descriptor over UART.
--
--   LEDs (active-low): [0] host running  [1] device present
--                      [2] descriptor OK [3] heartbeat (~1 Hz)
--   UART (115200 8N1, M11): "DESC: <18 hex bytes>" ~1x/second once enumerating.
--
-- Clocks: clk_27mhz drives the PHY-reset power-on timer (ulpi_clk does not
-- exist until the PHY is released); everything else runs on the 60 MHz ulpi_clk.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity usb_kbd_otg_top is
  port (
    clk_27mhz : in    std_logic;

    ulpi_clk  : in    std_logic;                     -- 60 MHz CLKOUT from PHY
    ulpi_dir  : in    std_logic;
    ulpi_nxt  : in    std_logic;
    ulpi_stp  : out   std_logic;
    ulpi_rst  : out   std_logic;                     -- PHY RESETB (active-low)
    ulpi_data : inout std_logic_vector(7 downto 0);

    uart_tx   : out   std_logic;
    led       : out   std_logic_vector(3 downto 0)   -- 4 dock LEDs, active-low
  );
end entity;

architecture rtl of usb_kbd_otg_top is

  -- Vendored Verilog cores ----------------------------------------------------
  component ulpi_wrapper is
    port (
      ulpi_clk60_i      : in  std_logic;
      ulpi_rst_i        : in  std_logic;             -- active high
      ulpi_data_out_i   : in  std_logic_vector(7 downto 0);
      ulpi_dir_i        : in  std_logic;
      ulpi_nxt_i        : in  std_logic;
      utmi_data_out_i   : in  std_logic_vector(7 downto 0);
      utmi_txvalid_i    : in  std_logic;
      utmi_op_mode_i    : in  std_logic_vector(1 downto 0);
      utmi_xcvrselect_i : in  std_logic_vector(1 downto 0);
      utmi_termselect_i : in  std_logic;
      utmi_dppulldown_i : in  std_logic;
      utmi_dmpulldown_i : in  std_logic;
      ulpi_data_in_o    : out std_logic_vector(7 downto 0);
      ulpi_stp_o        : out std_logic;
      utmi_data_in_o    : out std_logic_vector(7 downto 0);
      utmi_txready_o    : out std_logic;
      utmi_rxvalid_o    : out std_logic;
      utmi_rxactive_o   : out std_logic;
      utmi_rxerror_o    : out std_logic;
      utmi_linestate_o  : out std_logic_vector(1 downto 0)
    );
  end component;

  component usbh_host is
    generic ( USB_CLK_FREQ : integer := 48000000 );
    port (
      clk_i             : in  std_logic;
      rst_i             : in  std_logic;             -- active high
      cfg_awvalid_i     : in  std_logic;
      cfg_awaddr_i      : in  std_logic_vector(31 downto 0);
      cfg_wvalid_i      : in  std_logic;
      cfg_wdata_i       : in  std_logic_vector(31 downto 0);
      cfg_wstrb_i       : in  std_logic_vector(3 downto 0);
      cfg_bready_i      : in  std_logic;
      cfg_arvalid_i     : in  std_logic;
      cfg_araddr_i      : in  std_logic_vector(31 downto 0);
      cfg_rready_i      : in  std_logic;
      utmi_data_in_i    : in  std_logic_vector(7 downto 0);
      utmi_txready_i    : in  std_logic;
      utmi_rxvalid_i    : in  std_logic;
      utmi_rxactive_i   : in  std_logic;
      utmi_rxerror_i    : in  std_logic;
      utmi_linestate_i  : in  std_logic_vector(1 downto 0);
      cfg_awready_o     : out std_logic;
      cfg_wready_o      : out std_logic;
      cfg_bvalid_o      : out std_logic;
      cfg_bresp_o       : out std_logic_vector(1 downto 0);
      cfg_arready_o     : out std_logic;
      cfg_rvalid_o      : out std_logic;
      cfg_rdata_o       : out std_logic_vector(31 downto 0);
      cfg_rresp_o       : out std_logic_vector(1 downto 0);
      intr_o            : out std_logic;
      utmi_data_out_o   : out std_logic_vector(7 downto 0);
      utmi_txvalid_o    : out std_logic;
      utmi_op_mode_o    : out std_logic_vector(1 downto 0);
      utmi_xcvrselect_o : out std_logic_vector(1 downto 0);
      utmi_termselect_o : out std_logic;
      utmi_dppulldown_o : out std_logic;
      utmi_dmpulldown_o : out std_logic
    );
  end component;

  -- (host bring-up / register values now live in usb_host_seq)

  -- PHY reset (27 MHz domain) -------------------------------------------------
  signal por27       : unsigned(15 downto 0) := (others => '0');
  signal phy_rst_n   : std_logic := '0';

  -- ULPI-domain reset (self-times off the first ulpi clocks)
  signal ur_cnt      : unsigned(11 downto 0) := (others => '0');
  signal rst_ulpi_n  : std_logic := '0';

  -- vbus init + handoff
  -- (ulpi_vbus_init stage removed -- see note at the ULPI tristate below)
  signal rst_wrap_n  : std_logic;                    -- wrapper/host reset (sync)

  -- wrapper <-> host UTMI
  signal wr_data_in     : std_logic_vector(7 downto 0);  -- wrapper drive to pins
  signal wr_stp         : std_logic;
  signal u_data_in      : std_logic_vector(7 downto 0);  -- wrapper -> host
  signal u_txready      : std_logic;
  signal u_rxvalid      : std_logic;
  signal u_rxactive     : std_logic;
  signal u_rxerror      : std_logic;
  signal u_linestate    : std_logic_vector(1 downto 0);
  signal h_data_out     : std_logic_vector(7 downto 0);  -- host -> wrapper
  signal h_txvalid      : std_logic;
  signal h_op_mode      : std_logic_vector(1 downto 0);
  signal h_xcvrselect   : std_logic_vector(1 downto 0);
  signal h_termselect   : std_logic;
  signal h_dppulldown   : std_logic;
  signal h_dmpulldown   : std_logic;

  -- AXI4-Lite master (cfg_*) --------------------------------------------------
  signal awvalid_r, wvalid_r, bready_r, arvalid_r, rready_r : std_logic := '0';
  signal ax_addr_r  : std_logic_vector(31 downto 0) := (others => '0');
  signal ax_wdata_r : std_logic_vector(31 downto 0) := (others => '0');
  signal c_awready, c_wready, c_bvalid, c_arready, c_rvalid : std_logic;
  signal c_rdata    : std_logic_vector(31 downto 0);

  type axi_st_t is (AX_IDLE, AX_W, AX_B, AX_AR, AX_R, AX_WAITLOW);
  signal axi_st : axi_st_t := AX_IDLE;

  -- register-access request handshake (seq <-> axi)
  signal rq_valid, rq_we, rq_done : std_logic := '0';
  signal rq_addr  : std_logic_vector(7 downto 0)  := (others => '0');
  signal rq_wdata : std_logic_vector(31 downto 0) := (others => '0');
  signal rq_rdata : std_logic_vector(31 downto 0) := (others => '0');

  -- heartbeat + UART + diagnostics (UART/dbg driven by the host sequencer)
  signal hb_cnt   : unsigned(25 downto 0) := (others => '0');
  signal tx_data  : std_logic_vector(7 downto 0);   -- muxed UART stream
  signal tx_valid : std_logic;
  signal tx_busy  : std_logic;
  -- engine vs recorder UART sources (recorder wins while dumping)
  signal eng_tx_data  : std_logic_vector(7 downto 0);
  signal eng_tx_valid : std_logic;
  signal eng_tx_busy  : std_logic;
  signal rec_tx_data  : std_logic_vector(7 downto 0);
  signal rec_tx_valid : std_logic;
  signal rec_active   : std_logic;
  signal rec_sample   : std_logic_vector(10 downto 0);
  signal dbg      : std_logic_vector(3 downto 0);  -- [0]run [1]present [2]descok [3]err

  -- sticky wrapper-signal probes (to diagnose the SIE TX stall)
  signal rxa_low  : std_logic := '0';   -- utmi_rxactive was ever low
  signal rxa_high : std_logic := '0';   -- utmi_rxactive was ever high
  signal txr_high : std_logic := '0';   -- utmi_txready  was ever high
  signal dir_high : std_logic := '0';   -- ulpi_dir      was ever high
  -- live pulse counters: if SOFs are flowing these tick between status lines
  signal cnt_txr  : unsigned(3 downto 0) := (others => '0');  -- txready pulses
  signal cnt_nxt  : unsigned(3 downto 0) := (others => '0');  -- ULPI NXT pulses
  signal cnt_stp  : unsigned(3 downto 0) := (others => '0');  -- ULPI STP pulses
  signal txr_d, nxt_d, stp_d : std_logic := '0';
  signal probes   : std_logic_vector(15 downto 0);

begin

  -- --------------------------------------------------------------------------
  -- PHY RESETB: hold low for ~1 ms after configuration (27 MHz domain)
  -- --------------------------------------------------------------------------
  process(clk_27mhz)
  begin
    if rising_edge(clk_27mhz) then
      if por27 /= x"FFFF" then
        por27     <= por27 + 1;
        phy_rst_n <= '0';
      else
        phy_rst_n <= '1';
      end if;
    end if;
  end process;
  ulpi_rst <= phy_rst_n;

  -- --------------------------------------------------------------------------
  -- ULPI-domain reset: only advances once ulpi_clk is actually running
  -- --------------------------------------------------------------------------
  process(ulpi_clk)
  begin
    if rising_edge(ulpi_clk) then
      if ur_cnt /= x"FFF" then
        ur_cnt     <= ur_cnt + 1;
        rst_ulpi_n <= '0';
      else
        rst_ulpi_n <= '1';
      end if;
    end if;
  end process;

  -- NOTE: the ulpi_vbus_init pre-init stage was removed. It was useless (the
  -- wrapper immediately rewrites OTG_CTRL with just the pulldown bits, wiping
  -- DrvVbus) and harmful: on a NXT timeout it could leave the PHY mid register
  -- cycle without an abort STP, after which the PHY never NXT-ed the wrapper's
  -- TXCMDs (observed on hardware: NXT pulse counter stuck at 0). VBUS on the
  -- dock is board-supplied anyway (device detect worked with DrvVbus clear).
  -- The wrapper now owns the ULPI bus from reset, exactly as in simulation.
  rst_wrap_n <= rst_ulpi_n;

  -- ULPI tristate (drive only while the PHY isn't: dir=0)
  ulpi_data <= wr_data_in when ulpi_dir = '0' else (others => 'Z');
  ulpi_stp  <= wr_stp;

  -- --------------------------------------------------------------------------
  -- ULPI<->UTMI wrapper and USB host controller
  -- --------------------------------------------------------------------------
  wrap_i : ulpi_wrapper
    port map (
      ulpi_clk60_i      => ulpi_clk,
      ulpi_rst_i        => not rst_wrap_n,
      ulpi_data_out_i   => ulpi_data,
      ulpi_dir_i        => ulpi_dir,
      ulpi_nxt_i        => ulpi_nxt,
      utmi_data_out_i   => h_data_out,
      utmi_txvalid_i    => h_txvalid,
      utmi_op_mode_i    => h_op_mode,
      utmi_xcvrselect_i => h_xcvrselect,
      utmi_termselect_i => h_termselect,
      utmi_dppulldown_i => h_dppulldown,
      utmi_dmpulldown_i => h_dmpulldown,
      ulpi_data_in_o    => wr_data_in,
      ulpi_stp_o        => wr_stp,
      utmi_data_in_o    => u_data_in,
      utmi_txready_o    => u_txready,
      utmi_rxvalid_o    => u_rxvalid,
      utmi_rxactive_o   => u_rxactive,
      utmi_rxerror_o    => u_rxerror,
      utmi_linestate_o  => u_linestate
    );

  host_i : usbh_host
    generic map ( USB_CLK_FREQ => 60000000 )
    port map (
      clk_i             => ulpi_clk,
      rst_i             => not rst_wrap_n,
      cfg_awvalid_i     => awvalid_r,
      cfg_awaddr_i      => ax_addr_r,
      cfg_wvalid_i      => wvalid_r,
      cfg_wdata_i       => ax_wdata_r,
      cfg_wstrb_i       => "1111",
      cfg_bready_i      => bready_r,
      cfg_arvalid_i     => arvalid_r,
      cfg_araddr_i      => ax_addr_r,
      cfg_rready_i      => rready_r,
      utmi_data_in_i    => u_data_in,
      utmi_txready_i    => u_txready,
      utmi_rxvalid_i    => u_rxvalid,
      utmi_rxactive_i   => u_rxactive,
      utmi_rxerror_i    => u_rxerror,
      utmi_linestate_i  => u_linestate,
      cfg_awready_o     => c_awready,
      cfg_wready_o      => c_wready,
      cfg_bvalid_o      => c_bvalid,
      cfg_bresp_o       => open,
      cfg_arready_o     => c_arready,
      cfg_rvalid_o      => c_rvalid,
      cfg_rdata_o       => c_rdata,
      cfg_rresp_o       => open,
      intr_o            => open,
      utmi_data_out_o   => h_data_out,
      utmi_txvalid_o    => h_txvalid,
      utmi_op_mode_o    => h_op_mode,
      utmi_xcvrselect_o => h_xcvrselect,
      utmi_termselect_o => h_termselect,
      utmi_dppulldown_o => h_dppulldown,
      utmi_dmpulldown_o => h_dmpulldown
    );

  -- --------------------------------------------------------------------------
  -- AXI4-Lite master: serves one rq (read/write) at a time
  -- --------------------------------------------------------------------------
  process(ulpi_clk)
  begin
    if rising_edge(ulpi_clk) then
      rq_done <= '0';
      if rst_wrap_n = '0' then
        axi_st    <= AX_IDLE;
        awvalid_r <= '0'; wvalid_r <= '0'; bready_r <= '0';
        arvalid_r <= '0'; rready_r <= '0';
      else
        case axi_st is
          when AX_IDLE =>
            if rq_valid = '1' then
              ax_addr_r <= x"000000" & rq_addr;
              if rq_we = '1' then
                ax_wdata_r <= rq_wdata;
                awvalid_r  <= '1';
                wvalid_r   <= '1';
                axi_st     <= AX_W;
              else
                arvalid_r <= '1';
                axi_st    <= AX_AR;
              end if;
            end if;

          when AX_W =>
            if awvalid_r = '1' and c_awready = '1' then awvalid_r <= '0'; end if;
            if wvalid_r  = '1' and c_wready  = '1' then wvalid_r  <= '0'; end if;
            if (awvalid_r = '0' or c_awready = '1') and
               (wvalid_r  = '0' or c_wready  = '1') then
              bready_r <= '1';
              axi_st   <= AX_B;
            end if;

          when AX_B =>
            if c_bvalid = '1' then
              bready_r <= '0';
              rq_done  <= '1';
              axi_st   <= AX_WAITLOW;
            end if;

          when AX_AR =>
            if arvalid_r = '1' and c_arready = '1' then
              arvalid_r <= '0';
              rready_r  <= '1';
              axi_st    <= AX_R;
            end if;

          when AX_R =>
            if c_rvalid = '1' then
              rq_rdata <= c_rdata;
              rready_r <= '0';
              rq_done  <= '1';
              axi_st   <= AX_WAITLOW;
            end if;

          when AX_WAITLOW =>
            -- one transaction per rq_valid assertion: wait for it to drop
            if rq_valid = '0' then
              axi_st <= AX_IDLE;
            end if;
        end case;
      end if;
    end if;
  end process;

  -- --------------------------------------------------------------------------
  -- USB host sequencer: bring-up, reset+detect, control-read GET_DESCRIPTOR,
  -- and print the device descriptor over UART. Drives the AXI master via rq_*.
  -- --------------------------------------------------------------------------
  seq_i : entity work.usb_host_seq
    port map (
      clk      => ulpi_clk,
      reset_n  => rst_wrap_n,
      rq_valid => rq_valid,
      rq_we    => rq_we,
      rq_addr  => rq_addr,
      rq_wdata => rq_wdata,
      rq_done  => rq_done,
      rq_rdata => rq_rdata,
      tx_data  => eng_tx_data,
      tx_valid => eng_tx_valid,
      tx_busy  => eng_tx_busy,
      dbg_in   => probes,
      dbg      => dbg
    );

  -- --------------------------------------------------------------------------
  -- On-chip ULPI recorder: captures the bus on the first TX-CMD attempt and
  -- dumps it over UART (owns the UART while dumping). One-shot.
  -- --------------------------------------------------------------------------
  rec_sample <= ulpi_data & wr_stp & ulpi_nxt & ulpi_dir;

  rec_i : entity work.ulpi_rec
    port map (
      clk      => ulpi_clk,
      reset_n  => rst_ulpi_n,
      sample   => rec_sample,
      tx_data  => rec_tx_data,
      tx_valid => rec_tx_valid,
      tx_busy  => tx_busy,
      active   => rec_active
    );

  -- UART source mux: recorder while dumping, else the status engine
  tx_data     <= rec_tx_data  when rec_active = '1' else eng_tx_data;
  tx_valid    <= rec_tx_valid when rec_active = '1' else eng_tx_valid;
  eng_tx_busy <= tx_busy or rec_active;   -- hold the engine off during a dump

  -- Heartbeat + sticky wrapper probes (to see why the SIE TX stalls)
  process(ulpi_clk)
  begin
    if rising_edge(ulpi_clk) then
      hb_cnt <= hb_cnt + 1;
      if rst_wrap_n = '0' then
        rxa_low <= '0'; rxa_high <= '0'; txr_high <= '0'; dir_high <= '0';
      else
        if u_rxactive = '0' then rxa_low  <= '1'; end if;
        if u_rxactive = '1' then rxa_high <= '1'; end if;
        if u_txready  = '1' then txr_high <= '1'; end if;
        if ulpi_dir   = '1' then dir_high <= '1'; end if;
        -- rising-edge pulse counters (roll over; change = activity)
        txr_d <= u_txready;  nxt_d <= ulpi_nxt;  stp_d <= wr_stp;
        if u_txready = '1' and txr_d = '0' then cnt_txr <= cnt_txr + 1; end if;
        if ulpi_nxt  = '1' and nxt_d = '0' then cnt_nxt <= cnt_nxt + 1; end if;
        if wr_stp    = '1' and stp_d = '0' then cnt_stp <= cnt_stp + 1; end if;
      end if;
    end if;
  end process;

  probes <= std_logic_vector(cnt_stp) & std_logic_vector(cnt_nxt) &
            std_logic_vector(cnt_txr) &
            (rxa_low & rxa_high & txr_high & dir_high);

  -- LEDs (active-low), TX-stall diagnostic (same bits also in the UART F digit):
  --   LED0 rxactive-seen-low  (OFF = rxactive stuck HIGH -> blocks TX)
  --   LED1 txready-seen-high  (OFF = wrapper never accepted a TX byte)
  --   LED2 rxactive-seen-high LED3 heartbeat
  led <= not ( hb_cnt(25) & rxa_high & txr_high & rxa_low );

  uart_i : entity work.uart_tx_ser
    generic map ( CLK_HZ => 60_000_000, BAUD => 115_200 )
    port map (
      clk     => ulpi_clk,
      reset_n => rst_ulpi_n,
      data    => tx_data,
      valid   => tx_valid,
      tx      => uart_tx,
      busy    => tx_busy
    );

end architecture;
