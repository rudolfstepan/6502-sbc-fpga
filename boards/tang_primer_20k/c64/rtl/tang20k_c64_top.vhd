-- Tang Primer 20K board top -- native C64 over HDMI.
--
-- Reuses the SBC board's proven clock/HDMI plumbing (tang20k_hdmi_tx: 27 MHz ->
-- 135 MHz TMDS + 27 MHz pixel) and the PT8211 audio DAC. The machine itself is
-- c64_core (rtl/c64). No SD boot loader / boot screen here -- the original KERNAL
-- paints its own banner, which saves block RAM and LUTs.
--
-- KEY[0] = T10 (active-low reset button) -> C64 reset.
-- PS/2 keyboard on PMOD0 (T7 clk / T8 data).
-- HDMI TMDS on the on-board connector. Audio on the dock PT8211.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tang20k_c64_top is
  port (
    clk_27mhz  : in  std_logic;
    key        : in  std_logic_vector(0 downto 0);  -- KEY[0] = reset button (T10)

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

    -- SD card in SPI mode (PMOD1 breakout, same pins as the MiSTer probe).
    sd_dclk    : out std_logic;
    sd_ncs     : out std_logic;
    sd_mosi    : out std_logic;
    sd_miso    : in  std_logic;

    -- DIAG heartbeat LEDs -- disabled (placement experiment); re-enable with the
    -- block below, the led pins in the .cst, and dbg_cia1_irq in c64_core.
    -- led     : out std_logic_vector(1 downto 0);

    -- CH340 USB-UART. In normal C64 mode this is the host-disk UART used by
    -- the virtual 1541 server. Sending the monitor wake sequence from the PC
    -- enters the UART monitor/loader, which owns the link until "G".
    uart_tx    : out std_logic;
    uart_rx    : in  std_logic
  );
end entity;

architecture rtl of tang20k_c64_top is
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

  -- UART monitor/loader on/off. This is the SMALL c64_prg_upload_monitor from
  -- the MiSTer probe board (L/./G subset for tools/c64_uart_prg_loader.py,
  -- a few hundred LUTs) -- the full FLAT_64K uart_debug_monitor (~2.1k LUTs)
  -- no longer fits next to the SD floppy.
  constant ENABLE_UART_MONITOR : boolean := true;

  -- Four-byte monitor wake sequence. A single magic byte is unsafe once the
  -- same UART also carries arbitrary D64/PRG binary data for the virtual 1541.
  constant MONITOR_MAGIC0 : std_logic_vector(7 downto 0) := x"A5";
  constant MONITOR_MAGIC1 : std_logic_vector(7 downto 0) := x"5A";
  constant MONITOR_MAGIC2 : std_logic_vector(7 downto 0) := x"C3";
  constant MONITOR_MAGIC3 : std_logic_vector(7 downto 0) := x"3C";
  -- Short press = normal C64 reset. Hold KEY[0] for ~1 s to request a cold
  -- FPGA reset that clears C64 RAM before BASIC/KERNAL restarts.
  constant LONG_RESET_CYCLES      : integer := 27_000_000;
  constant COLD_RESET_HOLD_CYCLES : integer := 70_000;

  signal clk_pix  : std_logic;
  signal clk_sys  : std_logic;
  signal pll_lock : std_logic;

  signal reset_n   : std_logic;
  signal rst_sync  : std_logic_vector(2 downto 0) := (others => '0');
  signal key0_sync : std_logic_vector(2 downto 0) := (others => '1');
  signal reset_press_cnt : integer range 0 to LONG_RESET_CYCLES := 0;
  signal cold_hold_cnt   : integer range 0 to COLD_RESET_HOLD_CYCLES := 0;
  signal cold_reset      : std_logic := '0';

  signal vga_hs, vga_vs, vga_de : std_logic;
  signal vga_r, vga_b : std_logic_vector(4 downto 0);
  signal vga_g        : std_logic_vector(5 downto 0);
  signal audio        : std_logic_vector(15 downto 0);

  signal dbg_addr   : std_logic_vector(15 downto 0);
  signal dbg_we     : std_logic;
  signal dbg_do     : std_logic_vector(7 downto 0);
  signal dbg_di     : std_logic_vector(7 downto 0);
  signal dbg_sync   : std_logic;
  signal dbg_phi    : std_logic;
  signal dbg_status : std_logic_vector(15 downto 0);
  signal dbg_cia1   : std_logic_vector(31 downto 0);
  signal dbg_iec    : std_logic_vector(31 downto 0);
  signal dbg_regs   : std_logic_vector(63 downto 0);

  signal dbg_uart_tx : std_logic;
  signal c64_disk_uart_tx : std_logic;

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
  signal mon_mem_rdata  : std_logic_vector(7 downto 0);
  signal mon_mem_ready  : std_logic;

  -- ---- SD floppy (register map + arbiter identical to the MiSTer probe) ----
  signal sd_init_done   : std_logic;
  signal sd_card_sec_read      : std_logic;
  signal sd_card_sec_read_addr : std_logic_vector(31 downto 0);
  signal sd_sec_read_data  : std_logic_vector(7 downto 0);
  signal sd_sec_read_valid : std_logic;
  signal sd_sec_read_end   : std_logic;
  signal drive_sd_sec_read       : std_logic;
  signal drive_sd_sec_read_addr  : std_logic_vector(31 downto 0);
  signal drive_sd_sec_read_valid : std_logic;
  signal drive_sd_sec_read_end   : std_logic;
  signal drive_led      : std_logic;

  signal exp2_cs    : std_logic;
  signal exp2_we    : std_logic;
  signal exp2_addr  : std_logic_vector(7 downto 0);
  signal exp2_wdata : std_logic_vector(7 downto 0);
  signal exp2_rdata : std_logic_vector(7 downto 0);
  signal disk_io_data : std_logic_vector(7 downto 0);

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
  -- ~0.62 s at 27 MHz; well above a worst-case SPI sector read.
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

  -- ---- SD hook boot loader + write shim onto the c64_core monitor port ----
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
  -- Small FIFO between the boot loader's per-byte writes and the monitor
  -- port's req/ready handshake (SPI bytes arrive ~127 clks apart, the
  -- handshake takes a few clks, so depth 4 is generous).
  constant BQ_DEPTH : integer := 4;
  type bq_addr_t is array (0 to BQ_DEPTH-1) of std_logic_vector(15 downto 0);
  type bq_data_t is array (0 to BQ_DEPTH-1) of std_logic_vector(7 downto 0);
  signal bq_addr : bq_addr_t := (others => (others => '0'));
  signal bq_data : bq_data_t := (others => (others => '0'));
  signal bq_cnt  : integer range 0 to BQ_DEPTH := 0;
  type bq_state_t is (BQ_IDLE, BQ_REQ, BQ_WAIT);
  signal bq_state : bq_state_t := BQ_IDLE;
  signal boot_owns : std_logic;

  -- c64_core monitor port after the boot/monitor mux
  signal core_mon_hold  : std_logic;
  signal core_mon_req   : std_logic;
  signal core_mon_we    : std_logic;
  signal core_mon_addr  : std_logic_vector(15 downto 0);
  signal core_mon_wdata : std_logic_vector(7 downto 0);
  signal core_mon_ready : std_logic;
  signal bq_cur_addr    : std_logic_vector(15 downto 0) := (others => '0');
  signal bq_cur_data    : std_logic_vector(7 downto 0) := (others => '0');

  -- DIAG heartbeat taps -- DISABLED (placement experiment). Re-enable the led port,
  -- the .cst led pins, dbg_cia1_irq in c64_core, and this whole block together.
  -- signal dbg_sync     : std_logic;
  -- signal dbg_cia1_irq : std_logic;
  -- signal sync_d       : std_logic := '0';
  -- signal cpu_cnt      : unsigned(19 downto 0) := (others => '0');
  -- signal irq_low_cnt  : unsigned(21 downto 0) := (others => '0');
  -- signal irq_stuck    : std_logic := '0';
begin
  pa_en <= '1';   -- enable dock audio power amplifier

  -- process(clk_pix)
  -- begin
  --   if rising_edge(clk_pix) then
  --     sync_d <= dbg_sync;
  --     if dbg_sync = '1' and sync_d = '0' then
  --       cpu_cnt <= cpu_cnt + 1;
  --     end if;
  --     if dbg_cia1_irq = '1' then
  --       irq_low_cnt <= (others => '0');
  --     elsif irq_low_cnt(21) = '1' then
  --       irq_stuck <= '1';
  --     else
  --       irq_low_cnt <= irq_low_cnt + 1;
  --     end if;
  --   end if;
  -- end process;
  -- led(0) <= not irq_stuck;
  -- led(1) <= cpu_cnt(19);

  -- The virtual 1541 protocol is binary, so the debug stream must not share the
  -- line while the C64 is running. The monitor still preempts the link after the
  -- wake-sequence handshake.
  uart_tx <= mon_uart_tx when mon_active = '1' else c64_disk_uart_tx;

  -- Reset: hold until the PLL locks and the button is released, in the pixel domain.
  -- A long button press requests a cold reset and keeps the core reset long
  -- enough for c64_core to scrub 64K RAM + colour RAM.
  process(clk_pix)
  begin
    if rising_edge(clk_pix) then
      key0_sync <= key0_sync(1 downto 0) & key(0);
      rst_sync  <= rst_sync(1 downto 0) & (pll_lock and key0_sync(2) and not cold_reset);

      if pll_lock = '0' then
        reset_press_cnt <= 0;
        cold_hold_cnt   <= 0;
        cold_reset      <= '0';
      elsif key0_sync(2) = '0' then
        if reset_press_cnt < LONG_RESET_CYCLES then
          reset_press_cnt <= reset_press_cnt + 1;
        end if;

        if reset_press_cnt = LONG_RESET_CYCLES - 1 then
          cold_reset    <= '1';
          cold_hold_cnt <= COLD_RESET_HOLD_CYCLES;
        elsif cold_reset = '1' then
          cold_hold_cnt <= COLD_RESET_HOLD_CYCLES;
        end if;
      else
        reset_press_cnt <= 0;
        if cold_hold_cnt > 0 then
          cold_reset    <= '1';
          cold_hold_cnt <= cold_hold_cnt - 1;
        else
          cold_reset <= '0';
        end if;
      end if;
    end if;
  end process;
  reset_n <= rst_sync(2);

  -- ===================== SD floppy =====================
  -- Register map, arbiter and boot flow are identical to the MiSTer C64 probe
  -- board (tang20k_mister_c64_probe_top), so the same FAT16 card, resident SD
  -- hook and disk menu work unchanged.
  --
  -- SD D64 mount register window in C64 I/O2:
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
  exp2_rdata <= disk_io_data when exp2_addr(7 downto 4) = "0000" else x"FF";
  process(exp2_addr, sd_mount_lba_reg, sd_init_done, drive_led, sd_mounted,
          fast_track_reg, fast_sector_reg, fast_offset_reg, fast_ready,
          fast_error, fast_state, fast_buf, boot_status)
  begin
    case to_integer(unsigned(exp2_addr(3 downto 0))) is
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

  -- SD access arbiter: the 1541 drive backend, the $DF08 fastload window and
  -- the power-up boot loader all read whole 512-byte blocks from sd_card_top.
  -- Requests are latched and the controller is granted to one owner per
  -- complete transfer, so no side can steal another's data stream mid-sector.
  sd_card_sec_read      <= sd_issue_read;
  sd_card_sec_read_addr <= sd_issue_addr;
  drive_sd_sec_read_valid <= sd_sec_read_valid when sd_owner_fast = '0' and sd_owner_boot = '0' and sd_xfer_busy = '1' else '0';
  drive_sd_sec_read_end   <= sd_sec_read_end   when sd_owner_fast = '0' and sd_owner_boot = '0' and sd_xfer_busy = '1' else '0';
  boot_sd_valid <= sd_sec_read_valid when sd_owner_boot = '1' and sd_xfer_busy = '1' else '0';
  boot_sd_end   <= sd_sec_read_end   when sd_owner_boot = '1' and sd_xfer_busy = '1' else '0';

  process(clk_pix)
  begin
    if rising_edge(clk_pix) then
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

        if exp2_we = '1' and exp2_addr(7 downto 4) = "0000" then
          case to_integer(unsigned(exp2_addr(3 downto 0))) is
            when 0 => sd_mount_lba_reg(7 downto 0) <= exp2_wdata;
            when 1 => sd_mount_lba_reg(15 downto 8) <= exp2_wdata;
            when 2 => sd_mount_lba_reg(23 downto 16) <= exp2_wdata;
            when 3 => sd_mount_lba_reg(31 downto 24) <= exp2_wdata;
            when 4 =>
              if exp2_wdata(0) = '1' then
                sd_mount_strobe <= '1';
                sd_mounted <= '1';
              end if;
            when 8 =>
              fast_track_reg <= exp2_wdata;
            when 9 =>
              fast_sector_reg <= exp2_wdata(4 downto 0);
            when 10 =>
              fast_offset_reg <= unsigned(exp2_wdata);
            when 11 =>
              if exp2_wdata(1) = '1' then
                fast_error <= '0';
              end if;
              if exp2_wdata(0) = '1' and fast_state = FAST_IDLE then
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
              if exp2_wdata(0) = '1' and fast_state = FAST_IDLE then
                fast_ready <= '0';
                if sd_init_done = '1'
                   and not (sd_xfer_busy = '1' and sd_owner_fast = '1') then
                  fast_req_addr <= sd_mount_lba_reg;
                  fast_upper_half <= exp2_wdata(1);
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
        -- The power-up boot loader goes first (the C64 is parked anyway),
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

  -- Standalone power-up loader: pulls the resident SD hook from the card
  -- (LBA 8, "C64HOOK1" header written by make_fat16_d64_card.py) into C64
  -- RAM while the CPU is parked, so no UART upload is needed.
  boot_i : entity work.c64_sd_hook_boot_loader
    generic map (
      HOOK_LBA => x"00000008",
      CLK_HZ   => 27_000_000
    )
    port map (
      clk     => clk_pix,
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

  -- Boot-write shim: the boot loader emits one RAM write per SD byte; the
  -- c64_core monitor port wants a req/ready handshake. Queue a few bytes and
  -- replay them through the monitor port (which also parks the CPU via RDY,
  -- the native-core equivalent of the probe's whole-core pause).
  boot_owns <= '1' when boot_active = '1' or bq_cnt > 0 or bq_state /= BQ_IDLE
               else '0';
  core_mon_hold  <= boot_owns or mon_active;
  core_mon_req   <= '1' when bq_state = BQ_REQ else
                    (mon_mem_req and mon_active and not boot_owns);
  core_mon_we    <= '1' when boot_owns = '1' else mon_mem_we;
  core_mon_addr  <= bq_cur_addr when boot_owns = '1' else mon_mem_addr;
  core_mon_wdata <= bq_cur_data when boot_owns = '1' else mon_mem_wdata;
  mon_mem_ready  <= core_mon_ready when boot_owns = '0' else '0';

  process(clk_pix)
    variable cnt_v : integer range 0 to BQ_DEPTH;
  begin
    if rising_edge(clk_pix) then
      if reset_n = '0' then
        bq_cnt <= 0;
        bq_state <= BQ_IDLE;
      else
        cnt_v := bq_cnt;
        case bq_state is
          when BQ_IDLE =>
            if cnt_v > 0 then
              bq_cur_addr <= bq_addr(0);
              bq_cur_data <= bq_data(0);
              for i in 0 to BQ_DEPTH-2 loop
                bq_addr(i) <= bq_addr(i+1);
                bq_data(i) <= bq_data(i+1);
              end loop;
              cnt_v := cnt_v - 1;
              bq_state <= BQ_REQ;
            end if;
          when BQ_REQ =>
            bq_state <= BQ_WAIT;
          when BQ_WAIT =>
            if core_mon_ready = '1' then
              bq_state <= BQ_IDLE;
            end if;
        end case;
        if boot_mem_we = '1' and cnt_v < BQ_DEPTH then
          bq_addr(cnt_v) <= boot_mem_addr;
          bq_data(cnt_v) <= boot_mem_wdata;
          cnt_v := cnt_v + 1;
        end if;
        bq_cnt <= cnt_v;
      end if;
    end if;
  end process;

  sd_i : sd_card_top
    generic map (
      SPI_LOW_SPEED_DIV  => 268,
      SPI_HIGH_SPEED_DIV => 8
    )
    port map (
      clk                    => clk_pix,
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

  -- HDMI TX also generates the system/pixel clocks from the 27 MHz oscillator.
  hdmi_i : entity work.tang20k_hdmi_tx
    generic map (
      HDMI_H_TOT   => 864,
      HDMI_V_TOT   => 625,
      HDMI_H_ACT   => 720,
      HDMI_V_ACT   => 576,
      HDMI_V_SYNC  => 581,
      HDMI_DI_LINE => 578,
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

  -- The C64 itself, clocked by the 27 MHz pixel clock (PHI2_DIV=27 -> ~1 MHz CPU,
  -- authentic C64 speed; the half-speed test (54) proved the hang is NOT a setup-
  -- margin path, so back to the correct rate).
  c64_i : entity work.c64_core
    generic map (
      -- true  = vic_ii_xl: cycle-based 6569 (badlines, border flip-flops,
      --         YSCROLL/RSEL, mid-line register effects, sprite Y-crunch,
      --         collision IRQs; dual-port RAM for the VIC fetch path).
      -- false = vic_ii: the proven line-buffer VIC of the frozen bring-up
      --         bitstream (single-port RAM + steal bus). Flip back here if
      --         the XL VIC misbehaves on hardware.
      VIC_XL => true,
      IEC_BUS_MODEL => true,
      MISTER_1541_ENABLE => true,
      MISTER_1541_BACKEND => 3,      -- SD-card D64 (was 2 = virtual 1541 UART)
      MISTER_1541_BAUD => 230400,
      HOST_UART_ENABLE => false
    )
    port map (
      clk      => clk_pix,
      reset_n  => reset_n,
      cold_reset => cold_reset,
      sd_init_done           => sd_init_done,
      sd_sec_read            => drive_sd_sec_read,
      sd_sec_read_addr       => drive_sd_sec_read_addr,
      sd_sec_read_data       => sd_sec_read_data,
      sd_sec_read_data_valid => drive_sd_sec_read_valid,
      sd_sec_read_end        => drive_sd_sec_read_end,
      sd_mount_lba           => sd_mount_lba_reg,
      sd_mount_strobe        => sd_mount_strobe,
      drive_act_led          => drive_led,
      exp2_cs    => exp2_cs,
      exp2_we    => exp2_we,
      exp2_addr  => exp2_addr,
      exp2_wdata => exp2_wdata,
      exp2_rdata => exp2_rdata,
      dbg_addr => dbg_addr,
      dbg_we   => dbg_we,
      dbg_do   => dbg_do,
      dbg_di   => dbg_di,
      dbg_sync => dbg_sync,
      dbg_phi  => dbg_phi,
      dbg_status => dbg_status,
      dbg_cia1 => dbg_cia1,
      dbg_iec => dbg_iec,
      dbg_regs => dbg_regs,
      -- dbg_cia1_irq => open,   -- (DIAG heartbeat tap -- disabled)
      vga_hs   => vga_hs,
      vga_vs   => vga_vs,
      vga_de   => vga_de,
      vga_r    => vga_r,
      vga_g    => vga_g,
      vga_b    => vga_b,
      ps2_clk  => ps2_clk,
      ps2_data => ps2_data,
      audio    => audio,
      uart_tx  => c64_disk_uart_tx,
      uart_rx  => uart_rx,
      monitor_hold      => core_mon_hold,
      monitor_mem_req   => core_mon_req,
      monitor_mem_we    => core_mon_we,
      monitor_mem_addr  => core_mon_addr,
      monitor_mem_wdata => core_mon_wdata,
      monitor_mem_rdata => mon_mem_rdata,
      monitor_mem_ready => core_mon_ready
    );

  dbg_uart_i : entity work.c64_dbg_uart
    generic map (CLK_HZ => 27_000_000, BAUD => 115_200)
    port map (
      clk        => clk_pix,
      reset_n    => reset_n,
      snp_addr   => dbg_addr,
      snp_we     => dbg_we,
      snp_do     => dbg_do,
      snp_di     => dbg_di,
      snp_sync   => dbg_sync,
      snp_phi    => dbg_phi,
      snp_status => dbg_status,
      snp_cia1   => dbg_cia1,
      snp_regs   => dbg_regs,
      uart_tx    => dbg_uart_tx
    );

  gen_no_monitor : if not ENABLE_UART_MONITOR generate
    mon_rx_data  <= (others => '0');
    mon_rx_valid <= '0';
    mon_tx_busy  <= '0';
    mon_uart_tx  <= '1';
    mon_active   <= '0';
    mon_mem_req  <= '0';
    mon_mem_we   <= '0';
    mon_mem_addr <= (others => '0');
    mon_mem_wdata <= (others => '0');
  end generate;

  gen_monitor : if ENABLE_UART_MONITOR generate

  mon_rx_i : entity work.uart_rx_ser
    generic map (CLK_HZ => 27_000_000, BAUD => 115_200)
    port map (
      clk     => clk_pix,
      reset_n => reset_n,
      rx      => uart_rx,
      data    => mon_rx_data,
      valid   => mon_rx_valid
    );

  mon_tx_i : entity work.uart_tx_ser
    generic map (CLK_HZ => 27_000_000, BAUD => 115_200)
    port map (
      clk     => clk_pix,
      reset_n => reset_n,
      data    => mon_tx_data,
      valid   => mon_tx_valid,
      tx      => mon_uart_tx,
      busy    => mon_tx_busy
    );

  -- A magic sequence acts as a soft monitor button. It must be longer than one
  -- byte because normal C64 mode now uses the same UART for arbitrary binary
  -- PRG/D64 traffic, and a single wake byte can naturally occur in game data.
  process(clk_pix)
  begin
    if rising_edge(clk_pix) then
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

  -- Small PRG upload monitor from the MiSTer probe (L aaaa / . / G), here
  -- with the M aaaa bbbb hex dump enabled (reads RAM under ROM/I/O through
  -- the same monitor memory port).
  monitor_i : entity work.c64_prg_upload_monitor
    generic map (ENABLE_DUMP => true)
    port map (
      clk       => clk_pix,
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
      mem_rdata => mon_mem_rdata,
      mem_ready => mon_mem_ready
    );

  end generate;

  -- Audio DAC (PT8211), pixel-clock domain (BCK_HALF=4 -> ~27/8 MHz BCK).
  dac_i : entity work.pt8211_dac
    generic map (BCK_HALF => 4)
    port map (
      clk     => clk_pix,
      reset_n => reset_n,
      sample  => audio,
      dac_bck => dac_bck,
      dac_ws  => dac_ws,
      dac_din => dac_din
    );
end architecture;
