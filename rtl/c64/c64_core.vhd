-- C64 core: board-independent Commodore 64 in one entity.
--
-- Wires the native building blocks into a working machine:
--   cpu6510  -- T65 + processor port ($00/$01) for ROM banking
--   64K DRAM -- single-port BSRAM, time-shared with the VIC steal bus
--   ROMs     -- original BASIC/KERNAL/CHARGEN (rtl/c64/c64_roms.vhd)
--   vic_ii   -- text/bitmap video + raster IRQ (HDMI-ready RGB565)
--   colour_ram, 2x cia6526_full, sid6581, keyboard matrix
--
-- Banking is the PLA decode from c64_pkg (unexpanded machine: GAME=EXROM=1).
-- "RAM under ROM": writes always reach DRAM unless the address is I/O, so the
-- KERNAL's RAM scribbles beneath BASIC/KERNAL work as on real hardware.
--
-- Deliberately NO boot screen / SD boot loader here (saves BSRAM + LUTs, and
-- the original KERNAL paints its own startup banner). D64 LOAD support hooks in
-- at the IEC stub below and reuses the existing d64_subsystem (Milestone 1b).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.c64_pkg.all;

entity c64_core is
  generic (
    -- System clocks per PHI2 (27 -> ~1 MHz CPU). Simulation overrides this with
    -- a small value to boot faster.
    PHI2_DIV : integer := 27;
    -- Keep false for the stable bring-up bitstream.  True makes CIA2 PA6/PA7
    -- see the modeled IEC bus instead of the old PA output loopback; this needs
    -- an active drive responder or KERNAL/fastloaders can wait forever.
    IEC_BUS_MODEL : boolean := false;
    -- Experimental full 1541 IEC responder adapted from the MiSTer C64 core.
    MISTER_1541_ENABLE : boolean := false;
    -- 1541 disk backend: 0 = built-in test image, 2 = virtual 1541 sectors over UART.
    MISTER_1541_BACKEND : integer := 0;
    MISTER_1541_BAUD : integer := 230400;
    -- Legacy KERNAL-hook transport at $DE00/$DE01. Disable when the physical
    -- UART is owned by the IEC/1541 backend.
    HOST_UART_ENABLE : boolean := true;
    -- Simulation-only RAM preload (ADDR VALUE hex); "" = zeroed (synthesis).
    RAM_INIT : string  := ""
  );
  port (
    clk      : in  std_logic;                       -- 27 MHz pixel + system clock
    reset_n  : in  std_logic;
    cold_reset : in std_logic := '0';               -- held high to scrub RAM

    -- Debug taps (leave open in synthesis; used by the testbench).
    dbg_addr : out std_logic_vector(15 downto 0);
    dbg_we   : out std_logic;
    dbg_do   : out std_logic_vector(7 downto 0);
    dbg_di   : out std_logic_vector(7 downto 0);
    dbg_sync : out std_logic;
    dbg_phi  : out std_logic;
    dbg_status : out std_logic_vector(15 downto 0);
    dbg_cia1 : out std_logic_vector(31 downto 0);
    dbg_iec : out std_logic_vector(31 downto 0);
    dbg_regs : out std_logic_vector(63 downto 0);
    -- dbg_cia1_irq : out std_logic;                -- (DIAG heartbeat tap -- disabled)

    -- Video (RGB565 split, to the HDMI encoder).
    vga_hs   : out std_logic;
    vga_vs   : out std_logic;
    vga_de   : out std_logic;
    vga_r    : out std_logic_vector(4 downto 0);
    vga_g    : out std_logic_vector(5 downto 0);
    vga_b    : out std_logic_vector(4 downto 0);

    -- PS/2 keyboard.
    ps2_clk  : in  std_logic;
    ps2_data : in  std_logic;

    -- SID audio sample (signed 16-bit), to the board DAC.
    audio    : out std_logic_vector(15 downto 0);

    -- Host disk link: UART to a PC running a 1541 server (LOAD over serial).
    uart_tx : out std_logic;
    uart_rx : in  std_logic := '1';  -- idle high; default so the TB can leave it open

    -- External UART monitor/loader. While active, the CPU is parked via RDY and
    -- the monitor gets safe byte-wise access to the 64K RAM under ROM/I/O.
    monitor_hold      : in  std_logic := '0';
    monitor_mem_req   : in  std_logic := '0';
    monitor_mem_we    : in  std_logic := '0';
    monitor_mem_addr  : in  std_logic_vector(15 downto 0) := (others => '0');
    monitor_mem_wdata : in  std_logic_vector(7 downto 0) := (others => '0');
    monitor_mem_rdata : out std_logic_vector(7 downto 0);
    monitor_mem_ready : out std_logic
  );
end entity;

architecture rtl of c64_core is
  component mos6526 is
    port (
      mode    : in  std_logic;
      clk     : in  std_logic;
      phi2_p  : in  std_logic;
      phi2_n  : in  std_logic;
      res_n   : in  std_logic;
      cs_n    : in  std_logic;
      rw      : in  std_logic;
      rs      : in  std_logic_vector(3 downto 0);
      db_in   : in  std_logic_vector(7 downto 0);
      db_out  : out std_logic_vector(7 downto 0);
      pa_in   : in  std_logic_vector(7 downto 0);
      pa_out  : out std_logic_vector(7 downto 0);
      pa_oe   : out std_logic_vector(7 downto 0);
      pb_in   : in  std_logic_vector(7 downto 0);
      pb_out  : out std_logic_vector(7 downto 0);
      pb_oe   : out std_logic_vector(7 downto 0);
      flag_n  : in  std_logic;
      pc_n    : out std_logic;
      tod     : in  std_logic;
      sp_in   : in  std_logic;
      sp_out  : out std_logic;
      cnt_in  : in  std_logic;
      cnt_out : out std_logic;
      irq_n   : out std_logic;
      dbg_state : out std_logic_vector(31 downto 0)
    );
  end component;

  -- ---- clocking ----
  signal core_reset_n : std_logic;
  signal phi2_cnt   : integer range 0 to PHI2_DIV - 1 := 0;
  signal phi2_en    : std_logic := '0';
  signal cia_bus_en : std_logic := '0';
  signal tod_tick   : std_logic := '0';

  -- ---- CPU ----
  signal cpu_addr  : std_logic_vector(15 downto 0);
  signal cpu_dout  : std_logic_vector(7 downto 0);
  signal cpu_din   : std_logic_vector(7 downto 0);   -- combinational read mux
  signal other_din : std_logic_vector(7 downto 0);   -- everything except stolen RAM
  signal cpu_we    : std_logic;
  signal cpu_sync  : std_logic;
  signal cpu_rdy   : std_logic;
  signal cpu_irq_n : std_logic;
  signal cpu_nmi_n : std_logic;
  signal cpu_regs  : std_logic_vector(63 downto 0);
  signal io_we     : std_logic;
  signal loram, hiram, charen : std_logic;
  signal ctrl      : std_logic_vector(2 downto 0);

  -- ---- banking decode ----
  signal sel : c64_sel_t;
  signal io  : c64_io_t;

  -- ---- DRAM ----
  signal ram_addr  : std_logic_vector(15 downto 0);
  signal dram_dout : std_logic_vector(7 downto 0);
  signal dram_we   : std_logic;
  signal cpu_en    : std_logic;
  signal ram_settle : integer range 0 to 7 := 7;
  signal vic_ba_d  : std_logic := '1';
  signal vic_ba_d2 : std_logic := '1';
  signal vic_ba_d3 : std_logic := '1';
  signal vic_ba_d4 : std_logic := '1';
  -- Deferred CPU writes the 6502 completes after BA drops. RDY only stalls reads,
  -- so the CPU keeps running write cycles until it parks on the next read -- and a
  -- 6502 can emit up to THREE consecutive writes (JSR pushes PCH+PCL, an interrupt
  -- pushes PCH+PCL+P). A 1-deep latch keeps only the last of those and silently
  -- drops the rest -> corrupted stack -> RTS/RTI into the weeds (the marginal hang
  -- that wandered with code timing). So buffer the whole burst in a small FIFO and
  -- drain it (one entry per clk) once the steal returns the bus.
  constant WQ_DEPTH : integer := 4;
  type wq_addr_t is array (0 to WQ_DEPTH-1) of std_logic_vector(15 downto 0);
  type wq_data_t is array (0 to WQ_DEPTH-1) of std_logic_vector(7 downto 0);
  signal wq_addr  : wq_addr_t;
  signal wq_data  : wq_data_t;
  signal wq_cnt   : integer range 0 to WQ_DEPTH := 0;
  signal dram_din : std_logic_vector(7 downto 0);
  signal cold_ram_addr : unsigned(15 downto 0) := (others => '0');
  signal cold_ram_done : std_logic := '0';

  type cwq_addr_t is array (0 to WQ_DEPTH-1) of std_logic_vector(9 downto 0);
  type cwq_data_t is array (0 to WQ_DEPTH-1) of std_logic_vector(3 downto 0);
  signal cwq_addr : cwq_addr_t;
  signal cwq_data : cwq_data_t;
  signal cwq_cnt  : integer range 0 to WQ_DEPTH := 0;
  signal col_din  : std_logic_vector(3 downto 0);
  signal cold_col_addr : unsigned(9 downto 0) := (others => '0');
  signal cold_col_done : std_logic := '0';

  -- UART monitor RAM master. It waits until the VIC and both deferred write
  -- queues have released the single-port RAM, then performs one byte transfer.
  type mon_mem_state_t is (MON_IDLE, MON_WAIT_SAFE, MON_ACCESS, MON_READY);
  signal mon_mem_state : mon_mem_state_t := MON_IDLE;
  signal mon_addr_lat  : std_logic_vector(15 downto 0) := (others => '0');
  signal mon_wdata_lat : std_logic_vector(7 downto 0) := (others => '0');
  signal mon_we_lat    : std_logic := '0';
  signal mon_owner     : std_logic := '0';
  signal mon_ready_reg : std_logic := '0';
  signal mon_rdata_reg : std_logic_vector(7 downto 0) := (others => '0');
  signal monitor_safe  : std_logic;

  -- ---- ROMs ----
  signal basic_dout   : std_logic_vector(7 downto 0);
  signal kernal_dout  : std_logic_vector(7 downto 0);
  signal cg_cpu_dout  : std_logic_vector(7 downto 0);
  signal cg_vic_dout  : std_logic_vector(7 downto 0);

  -- ---- VIC ----
  signal vic_dout  : std_logic_vector(7 downto 0);
  signal vic_irq_n : std_logic;
  signal vic_addr  : std_logic_vector(15 downto 0);
  signal vic_data  : std_logic_vector(7 downto 0);
  signal vic_ba    : std_logic;
  signal vic_bank  : std_logic_vector(1 downto 0);
  signal vic_col_addr : std_logic_vector(9 downto 0);
  signal vic_col_data : std_logic_vector(3 downto 0);
  signal vic_char_addr: std_logic_vector(11 downto 0);

  -- ---- colour RAM ----
  signal col_a_dout : std_logic_vector(3 downto 0);
  signal col_addr   : std_logic_vector(9 downto 0);
  signal col_dout   : std_logic_vector(3 downto 0);

  -- ---- CIAs ----
  signal cia1_dout, cia2_dout : std_logic_vector(7 downto 0);
  signal cia1_irq_n, cia2_irq_n : std_logic;
  signal cia1_pa_out, cia1_pb_out : std_logic_vector(7 downto 0);
  signal cia2_pa_out, cia2_pb_out : std_logic_vector(7 downto 0);
  signal cia2_pa_in : std_logic_vector(7 downto 0);
  signal cia2_pa_bus_in : std_logic_vector(7 downto 0);
  signal cia1_pa_oe, cia1_pb_oe : std_logic_vector(7 downto 0);
  signal cia2_pa_oe, cia2_pb_oe : std_logic_vector(7 downto 0);
  signal cia1_cs_n, cia2_cs_n, cia_rw : std_logic;
  signal cia1_pc_n, cia2_pc_n : std_logic;
  signal cia1_sp_out, cia2_sp_out : std_logic;
  signal cia1_cnt_out, cia2_cnt_out : std_logic;
  signal cia1_dbg_state, cia2_dbg_state : std_logic_vector(31 downto 0);
  signal kb_col, kb_row : std_logic_vector(7 downto 0);
  signal restore_n : std_logic;
  signal iec_atn_n  : std_logic;
  signal iec_clk_n  : std_logic;
  signal iec_data_n : std_logic;
  signal iec_drive_clk_pull_n  : std_logic := '1';
  signal iec_drive_data_pull_n : std_logic := '1';
  signal iec_probe_clk_pull_n  : std_logic := '1';
  signal iec_probe_data_pull_n : std_logic := '1';
  signal iec_m1541_clk_pull_n  : std_logic := '1';
  signal iec_m1541_data_pull_n : std_logic := '1';
  signal iec_dbg_state : std_logic_vector(31 downto 0);
  signal m1541_led : std_logic;

  -- ---- SID ----
  signal sid_dout : std_logic_vector(7 downto 0);

  -- internal video (so the TOD generator can observe vsync)
  signal s_hs, s_vs, s_de : std_logic;
  signal s_r, s_b : std_logic_vector(4 downto 0);
  signal s_g      : std_logic_vector(5 downto 0);

  -- chip selects
  signal cs_vic, cs_sid, cs_cia1, cs_cia2, cs_col : std_logic;
  signal col_we : std_logic;

  -- ---- Host disk UART ($DE00) ----
  signal cs_uart   : std_logic;
  signal uart_dout : std_logic_vector(7 downto 0);
  signal legacy_uart_tx : std_logic;
  signal m1541_uart_tx : std_logic := '1';
  signal urx_data  : std_logic_vector(7 downto 0);
  signal urx_valid : std_logic;
  constant RX_FIFO_DEPTH : integer := 256;
  type rx_fifo_t is array (0 to RX_FIFO_DEPTH-1) of std_logic_vector(7 downto 0);
  signal rx_fifo     : rx_fifo_t;
  signal rx_rd_ptr   : unsigned(7 downto 0) := (others => '0');
  signal rx_wr_ptr   : unsigned(7 downto 0) := (others => '0');
  signal rx_count    : integer range 0 to RX_FIFO_DEPTH := 0;
  signal rx_avail    : std_logic;
  signal rx_overflow : std_logic := '0';
  signal rx_pop      : std_logic;
  signal uart_read_sel   : std_logic;
  signal uart_read_held  : std_logic := '0';
  signal uart_data_latch : std_logic_vector(7 downto 0) := (others => '0');
  signal uart_data_dout  : std_logic_vector(7 downto 0);
  signal utx_busy    : std_logic;
  signal utx_send  : std_logic;

  -- Packed for the board debug UART:
  -- 15 phi2_en, 14 VIC cs, 13 CIA1 cs, 12 cwq full, 11 wq full,
  -- 10 cwq non-empty, 9 wq non-empty, 8 CPU we, 7 CPU sync,
  -- 6 RESTORE_n, 5 CIA2 IRQ_n, 4 VIC IRQ_n, 3 CIA1 IRQ_n,
  -- 2 CPU IRQ_n, 1 VIC BA, 0 CPU RDY.
  signal dbg_wq_nonempty  : std_logic;
  signal dbg_cwq_nonempty : std_logic;
  signal dbg_wq_full      : std_logic;
  signal dbg_cwq_full     : std_logic;
begin
  core_reset_n <= reset_n and not cold_reset;
  vga_hs <= s_hs; vga_vs <= s_vs; vga_de <= s_de;
  vga_r <= s_r; vga_g <= s_g; vga_b <= s_b;

  -- Debug taps for the testbench.
  dbg_addr <= cpu_addr;
  dbg_we   <= cpu_we;
  dbg_do   <= cpu_dout;
  dbg_di   <= cpu_din;
  dbg_sync <= cpu_sync;
  dbg_phi  <= phi2_en;
  dbg_wq_nonempty  <= '1' when wq_cnt > 0 else '0';
  dbg_cwq_nonempty <= '1' when cwq_cnt > 0 else '0';
  dbg_wq_full      <= '1' when wq_cnt = WQ_DEPTH else '0';
  dbg_cwq_full     <= '1' when cwq_cnt = WQ_DEPTH else '0';
  dbg_status <= phi2_en & cs_vic & cs_cia1 & dbg_cwq_full &
                dbg_wq_full & dbg_cwq_nonempty & dbg_wq_nonempty &
                cpu_we & cpu_sync & restore_n & cia2_irq_n & vic_irq_n &
                cia1_irq_n & cpu_irq_n & vic_ba & cpu_rdy;
  dbg_cia1 <= cia1_dbg_state;
  dbg_iec <= iec_dbg_state;
  dbg_regs <= cpu_regs;
  uart_tx <= m1541_uart_tx when (MISTER_1541_ENABLE and MISTER_1541_BACKEND = 2) else legacy_uart_tx;
  monitor_mem_rdata <= mon_rdata_reg;
  monitor_mem_ready <= mon_ready_reg;
  -- dbg_cia1_irq <= cia1_irq_n;                    -- (DIAG heartbeat tap -- disabled)
  ctrl <= charen & hiram & loram;
  sel  <= pla_decode(cpu_addr, ctrl, '1', '1');     -- unexpanded: GAME=EXROM=1
  io   <= io_decode(cpu_addr) when sel = SEL_IO else IO_NONE;

  -- ---- PHI2 / TOD ----
  process(clk)
  begin
    if rising_edge(clk) then
      if core_reset_n = '0' then
        phi2_cnt <= 0; phi2_en <= '0';
      elsif phi2_cnt = PHI2_DIV - 1 then
        phi2_cnt <= 0; phi2_en <= '1';
      else
        phi2_cnt <= phi2_cnt + 1; phi2_en <= '0';
      end if;
    end if;
  end process;

  -- The MiST/MiSTer CIA registers CPU bus reads/writes on phi2_n and advances
  -- timers/IRQ state on phi2_p. Because the CIA data bus is registered, the bus
  -- strobe must happen just BEFORE the T65 samples data/advances on phi2_en. A
  -- delayed strobe misses ICR reads after the CPU has already moved to the next
  -- address, leaving CIA1 IRQ stuck low.
  cia_bus_en <= '1' when phi2_cnt = PHI2_DIV - 1 else '0';
  -- 60 Hz TOD pulse from the VIC vsync edge.
  process(clk)
    variable vs_d : std_logic := '1';
  begin
    if rising_edge(clk) then
      tod_tick <= '0';
      if s_vs = '0' and vs_d = '1' then tod_tick <= '1'; end if;
      vs_d := s_vs;
    end if;
  end process;

  -- ---- CPU ----
  -- Single-port main RAM, time-shared with the VIC: the CPU clock-enable is gated
  -- off during a VIC steal (BA low) so the two never touch RAM at the same cycle
  -- (no dual-port collision -> no .002 display corruption, no lost writes).
  --
  -- After the VIC or deferred-write FIFO owns the single BSRAM port, ram_addr
  -- switches back to cpu_addr and dout needs a few clocks before it reflects the
  -- CPU read address again. A guard only after BA was not enough: the FIFO can
  -- drain a CPU screen write after the steal, and the KERNAL may immediately read
  -- the screen line back on RETURN. So hold RDY low until the RAM port has been
  -- CPU-owned and idle for several clocks after BOTH steal and write-queue drain.
  -- NOTE: an earlier attempt registered the read (cpu_din_reg) instead -- it
  -- fixed banner/CIA symptoms but DEADLOCKED the CPU under IRQ load (extra read
  -- latency corrupted the T65 IRQ vector/stack fetch). The combinational read
  -- plus explicit RAM-port settle guard keeps the CPU timing intact.
  process(clk) begin
    if rising_edge(clk) then
      vic_ba_d  <= vic_ba;
      vic_ba_d2 <= vic_ba_d;
      vic_ba_d3 <= vic_ba_d2;
      vic_ba_d4 <= vic_ba_d3;
      if core_reset_n = '0' then
        ram_settle <= 7;
      elsif vic_ba = '0' or wq_cnt > 0 or cwq_cnt > 0 or mon_owner = '1' then
        ram_settle <= 7;
      elsif ram_settle > 0 then
        ram_settle <= ram_settle - 1;
      end if;
    end if;
  end process;
  -- The CPU advances every PHI2 tick; the VIC steal is signalled via the 6502's
  -- native RDY (stalls reads), NOT by gating the clock enable. Freezing the T65
  -- mid-cycle during the steal made the CPU timeline DRIFT from the CIA (which
  -- keeps ticking) -> a marginal IRQ-vs-steal beat that wandered with code timing
  -- and rarely corrupted control flow. With RDY the CPU timeline keeps advancing
  -- during the steal (halted but counted), in lockstep with the CIA -- as on real
  -- hardware. RDY stays low while the RAM port is stolen/draining/settling.
  monitor_safe <= '1' when monitor_hold = '1' and vic_ba = '1' and
                           vic_ba_d = '1' and vic_ba_d2 = '1' and
                           vic_ba_d3 = '1' and vic_ba_d4 = '1' and
                           wq_cnt = 0 and cwq_cnt = 0 and ram_settle = 0 and
                           cpu_we = '0'
                  else '0';

  cpu_en  <= phi2_en;
  cpu_rdy <= '1' when (vic_ba = '1' and vic_ba_d = '1' and vic_ba_d2 = '1'
                       and vic_ba_d3 = '1' and vic_ba_d4 = '1'
                       and wq_cnt = 0 and cwq_cnt = 0 and ram_settle = 0
                       and monitor_hold = '0') else '0';

  -- Main-RAM write FIFO: enqueue every write the CPU completes while the steal
  -- holds the bus, then drain one entry per clk once BA returns (CPU stays parked
  -- via RDY until the queue is empty). Depth 4 covers the 6502's longest write
  -- burst (3, an interrupt push) with margin -- no stack push is ever lost.
  process(clk) begin
    if rising_edge(clk) then
      if core_reset_n = '0' then
        wq_cnt <= 0;
      elsif vic_ba = '1' and wq_cnt > 0 then
        for i in 0 to WQ_DEPTH-2 loop
          wq_addr(i) <= wq_addr(i+1);
          wq_data(i) <= wq_data(i+1);
        end loop;
        wq_cnt <= wq_cnt - 1;
      elsif phi2_en = '1' and cpu_we = '1' and vic_ba = '0' and sel /= SEL_IO
            and wq_cnt < WQ_DEPTH then
        wq_addr(wq_cnt) <= cpu_addr;
        wq_data(wq_cnt) <= cpu_dout;
        wq_cnt <= wq_cnt + 1;
      end if;
    end if;
  end process;

  -- Colour-RAM write FIFO (same scheme; colour RAM lives in the I/O page).
  process(clk) begin
    if rising_edge(clk) then
      if core_reset_n = '0' then
        cwq_cnt <= 0;
      elsif vic_ba = '1' and cwq_cnt > 0 then
        for i in 0 to WQ_DEPTH-2 loop
          cwq_addr(i) <= cwq_addr(i+1);
          cwq_data(i) <= cwq_data(i+1);
        end loop;
        cwq_cnt <= cwq_cnt - 1;
      elsif phi2_en = '1' and cpu_we = '1' and cs_col = '1' and vic_ba = '0'
            and cwq_cnt < WQ_DEPTH then
        cwq_addr(cwq_cnt) <= cpu_addr(9 downto 0);
        cwq_data(cwq_cnt) <= cpu_dout(3 downto 0);
        cwq_cnt <= cwq_cnt + 1;
      end if;
    end if;
  end process;
  cpu_irq_n <= cia1_irq_n and vic_irq_n;
  cpu_nmi_n <= cia2_irq_n and restore_n;
  -- Peripheral register writes must be one PHI2 bus strobe, just like RAM.
  -- Keep chip-selects level-based so CIA read side effects can wait until the
  -- CPU leaves the address, even if RDY stretches a read cycle.
  io_we     <= cpu_we and phi2_en;

  cpu_i : entity work.cpu6510
    port map (
      clk => clk, reset_n => core_reset_n, enable => cpu_en, rdy => cpu_rdy,
      irq_n => cpu_irq_n, nmi_n => cpu_nmi_n,
      addr => cpu_addr, data_in => cpu_din, data_out => cpu_dout, we => cpu_we,
      sync => cpu_sync, regs => cpu_regs,
      pa_in => x"FF", pa_out => open,
      loram => loram, hiram => hiram, charen => charen
    );

  process(clk)
  begin
    if rising_edge(clk) then
      if core_reset_n = '0' or monitor_hold = '0' then
        mon_mem_state <= MON_IDLE;
        mon_addr_lat  <= (others => '0');
        mon_wdata_lat <= (others => '0');
        mon_we_lat    <= '0';
        mon_rdata_reg <= (others => '0');
        mon_ready_reg <= '0';
      else
        mon_ready_reg <= '0';
        case mon_mem_state is
          when MON_IDLE =>
            if monitor_mem_req = '1' then
              mon_addr_lat  <= monitor_mem_addr;
              mon_wdata_lat <= monitor_mem_wdata;
              mon_we_lat    <= monitor_mem_we;
              mon_mem_state <= MON_WAIT_SAFE;
            end if;

          when MON_WAIT_SAFE =>
            if monitor_safe = '1' then
              mon_mem_state <= MON_ACCESS;
            end if;

          when MON_ACCESS =>
            if mon_we_lat = '1' then
              mon_ready_reg <= '1';
              mon_mem_state <= MON_IDLE;
            else
              mon_mem_state <= MON_READY;
            end if;

          when MON_READY =>
            mon_rdata_reg <= dram_dout;
            mon_ready_reg <= '1';
            mon_mem_state <= MON_IDLE;
        end case;
      end if;
    end if;
  end process;
  mon_owner <= '1' when monitor_hold = '1' and mon_mem_state = MON_ACCESS else '0';

  -- Cold reset RAM scrub. The board top asserts cold_reset after a long reset
  -- button press while holding core_reset_n low; the single RAM ports are then
  -- free for deterministic clearing before BASIC/KERNAL starts again.
  process(clk)
  begin
    if rising_edge(clk) then
      if cold_reset = '0' then
        cold_ram_addr <= (others => '0');
        cold_ram_done <= '0';
        cold_col_addr <= (others => '0');
        cold_col_done <= '0';
      else
        if cold_ram_done = '0' then
          if cold_ram_addr = to_unsigned(16#FFFF#, cold_ram_addr'length) then
            cold_ram_done <= '1';
          else
            cold_ram_addr <= cold_ram_addr + 1;
          end if;
        end if;

        if cold_col_done = '0' then
          if cold_col_addr = to_unsigned(1023, cold_col_addr'length) then
            cold_col_done <= '1';
          else
            cold_col_addr <= cold_col_addr + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- ---- 64K main RAM: single-port, time-shared CPU <-> VIC (steal) ----
  ram_addr <= std_logic_vector(cold_ram_addr) when cold_reset = '1' and cold_ram_done = '0' else
              mon_addr_lat when mon_owner = '1' else
              vic_addr   when vic_ba = '0' else
              wq_addr(0) when wq_cnt > 0  else
              cpu_addr;
  dram_we  <= '1' when cold_reset = '1' and cold_ram_done = '0' else
              '1' when (mon_owner = '1' and mon_we_lat = '1') else
              '1' when (vic_ba = '1' and wq_cnt > 0) else
              '1' when (vic_ba = '1' and wq_cnt = 0 and phi2_en = '1'
                        and cpu_we = '1' and sel /= SEL_IO) else
              '0';
  dram_din <= (others => '0') when cold_reset = '1' and cold_ram_done = '0' else
              mon_wdata_lat when mon_owner = '1' else
              wq_data(0) when wq_cnt > 0 else cpu_dout;

  ram_i : entity work.c64_ram
    generic map (INIT_FILE => RAM_INIT)
    port map (clk => clk, addr => ram_addr, we => dram_we,
              din => dram_din, dout => dram_dout);
  vic_data <= dram_dout;     -- VIC reads screen codes from RAM during the steal

  -- ---- ROMs ----
  basic_i : entity work.basic_rom
    port map (clk => clk, addr => cpu_addr(12 downto 0), dout => basic_dout);
  kernal_i : entity work.kernal_rom
    port map (clk => clk, addr => cpu_addr(12 downto 0), dout => kernal_dout);
  chargen_i : entity work.chargen_rom
    port map (clk => clk,
              a_addr => cpu_addr(11 downto 0), a_dout => cg_cpu_dout,
              b_addr => vic_char_addr,         b_dout => cg_vic_dout);

  -- ---- colour RAM ----
  -- Colour RAM: single-port, time-shared like main RAM (VIC during the steal, CPU
  -- otherwise) so there is no dual-port collision.
  cs_col   <= '1' when io = IO_COLOR else '0';
  col_we   <= '1' when cold_reset = '1' and cold_col_done = '0' else
              '1' when (vic_ba = '1' and cwq_cnt > 0) else
              '1' when (vic_ba = '1' and cwq_cnt = 0 and phi2_en = '1'
                        and cs_col = '1' and cpu_we = '1') else
              '0';
  col_addr <= std_logic_vector(cold_col_addr) when cold_reset = '1' and cold_col_done = '0' else
              vic_col_addr when vic_ba = '0' else
              cwq_addr(0)  when cwq_cnt > 0  else
              cpu_addr(9 downto 0);
  col_din  <= (others => '0') when cold_reset = '1' and cold_col_done = '0' else
              cwq_data(0) when cwq_cnt > 0 else cpu_dout(3 downto 0);
  colram_i : entity work.colour_ram
    port map (clk => clk, addr => col_addr, we => col_we,
              din => col_din, dout => col_dout);
  vic_col_data <= col_dout;     -- VIC reads colour during the steal
  col_a_dout   <= col_dout;     -- CPU reads colour otherwise

  -- ---- VIC-II ----
  cs_vic <= '1' when io = IO_VIC else '0';
  vic_i : entity work.vic_ii
    port map (
      clk => clk, reset_n => core_reset_n,
      cs => cs_vic, we => io_we, addr => cpu_addr(5 downto 0),
      din => cpu_dout, dout => vic_dout, irq_n => vic_irq_n,
      vic_addr => vic_addr, vic_data => vic_data, ba => vic_ba,
      vic_bank => vic_bank,
      color_addr => vic_col_addr, color_data => vic_col_data,
      char_addr => vic_char_addr, char_data => cg_vic_dout,
      vga_hs => s_hs, vga_vs => s_vs, vga_de => s_de,
      vga_r => s_r, vga_g => s_g, vga_b => s_b
    );
  vic_bank <= not cia2_pa_out(1 downto 0);

  -- ---- CIA-1 (keyboard + Timer A jiffy IRQ) ----
  cs_cia1 <= '1' when io = IO_CIA1 else '0';
  cia1_cs_n <= not cs_cia1;
  cia2_cs_n <= not cs_cia2;
  cia_rw <= not cpu_we;
  cia1_i : mos6526
    port map (
      mode    => '0',
      clk     => clk,
      phi2_p  => phi2_en,
      phi2_n  => cia_bus_en,
      res_n   => core_reset_n,
      cs_n    => cia1_cs_n,
      rw      => cia_rw,
      rs      => cpu_addr(3 downto 0),
      db_in   => cpu_dout,
      db_out  => cia1_dout,
      pa_in   => kb_col,
      pa_out  => cia1_pa_out,
      pa_oe   => cia1_pa_oe,
      pb_in   => kb_row,
      pb_out  => cia1_pb_out,
      pb_oe   => cia1_pb_oe,
      flag_n  => '1',
      pc_n    => cia1_pc_n,
      tod     => tod_tick,
      sp_in   => '1',
      sp_out  => cia1_sp_out,
      cnt_in  => '1',
      cnt_out => cia1_cnt_out,
      irq_n   => cia1_irq_n,
      dbg_state => cia1_dbg_state
    );

  -- ---- CIA-2 (VIC bank + NMI + IEC) ----
  cs_cia2 <= '1' when io = IO_CIA2 else '0';

  -- C64 CIA2 port A:
  --   PA0/PA1: VIC bank select (outputs, inverted by the board wiring)
  --   PA3:     IEC ATN out
  --   PA4/PA5: IEC CLK/DATA out, open-collector style
  --   PA6/PA7: IEC CLK/DATA in
  --
  iec_drive_clk_pull_n  <= iec_probe_clk_pull_n and iec_m1541_clk_pull_n;
  iec_drive_data_pull_n <= iec_probe_data_pull_n and iec_m1541_data_pull_n;

  -- Passive bring-up used non-inverting output-loopback semantics.  The MiSTer
  -- 1541 path switches CIA2 PA3/4/5 to the real C64-style inverted IEC drivers.
  iec_atn_n <= not cia2_pa_out(3) when MISTER_1541_ENABLE else
               '0' when (cia2_pa_oe(3) = '1' and cia2_pa_out(3) = '0') else
               '1';
  iec_clk_n <= '0' when (MISTER_1541_ENABLE and
                         ((cia2_pa_out(4) = '1') or
                          (iec_drive_clk_pull_n = '0'))) else
               '0' when ((not MISTER_1541_ENABLE) and
                         ((cia2_pa_oe(4) = '1' and cia2_pa_out(4) = '0') or
                          (iec_drive_clk_pull_n = '0'))) else
               '1';
  iec_data_n <= '0' when (MISTER_1541_ENABLE and
                          ((cia2_pa_out(5) = '1') or
                           (iec_drive_data_pull_n = '0'))) else
                '0' when ((not MISTER_1541_ENABLE) and
                          ((cia2_pa_oe(5) = '1' and cia2_pa_out(5) = '0') or
                           (iec_drive_data_pull_n = '0'))) else
                '1';

  -- Keep the locally-driven bits on the proven CIA output loopback path.  The
  -- KERNAL mostly needs real IEC sense on PA6/PA7; feeding PA3..PA5 back as
  -- bus pins changes what reads of $DD00 return while those bits are outputs.
  cia2_pa_bus_in(0) <= cia2_pa_out(0);
  cia2_pa_bus_in(1) <= cia2_pa_out(1);
  cia2_pa_bus_in(2) <= cia2_pa_out(2);
  cia2_pa_bus_in(3) <= cia2_pa_out(3);
  cia2_pa_bus_in(4) <= cia2_pa_out(4);
  cia2_pa_bus_in(5) <= cia2_pa_out(5);
  cia2_pa_bus_in(6) <= (iec_clk_n and (not cia2_pa_out(4)))
                       when MISTER_1541_ENABLE else iec_clk_n;
  cia2_pa_bus_in(7) <= (iec_data_n and (not cia2_pa_out(5)))
                       when MISTER_1541_ENABLE else iec_data_n;
  cia2_pa_in <= cia2_pa_bus_in when IEC_BUS_MODEL else cia2_pa_out;

  iec_drive_i : entity work.c64_iec_drive
    generic map (
      ENABLE_ATN_ACK => false
    )
    port map (
      clk     => clk,
      reset_n => core_reset_n,
      atn_n   => iec_atn_n,
      clk_n   => iec_clk_n,
      data_n  => iec_data_n,
      drive_clk_pull_n  => iec_probe_clk_pull_n,
      drive_data_pull_n => iec_probe_data_pull_n,
      dbg_state => iec_dbg_state
    );

  gen_mister_1541 : if MISTER_1541_ENABLE generate
    m1541_i : entity work.mister_c1541_iec
      generic map (
        CLK_HZ       => 27000000,
        DRIVE_CPU_HZ => 1000000,
        BAUD         => MISTER_1541_BAUD,
        GCR_TURBO    => 1,
        D64_BACKEND  => MISTER_1541_BACKEND
      )
      port map (
        clk     => clk,
        reset_n => core_reset_n,
        iec_atn_n  => iec_atn_n,
        iec_clk_n  => iec_clk_n,
        iec_data_n => iec_data_n,
        drive_clk_pull_n  => iec_m1541_clk_pull_n,
        drive_data_pull_n => iec_m1541_data_pull_n,
        uart_rx => uart_rx,
        uart_tx => m1541_uart_tx,
        led => m1541_led
      );
  end generate;

  cia2_i : mos6526
    port map (
      mode    => '0',
      clk     => clk,
      phi2_p  => phi2_en,
      phi2_n  => cia_bus_en,
      res_n   => core_reset_n,
      cs_n    => cia2_cs_n,
      rw      => cia_rw,
      rs      => cpu_addr(3 downto 0),
      db_in   => cpu_dout,
      db_out  => cia2_dout,
      pa_in   => cia2_pa_in,
      pa_out  => cia2_pa_out,
      pa_oe   => cia2_pa_oe,
      pb_in   => cia2_pb_out,
      pb_out  => cia2_pb_out,
      pb_oe   => cia2_pb_oe,
      flag_n  => '1',
      pc_n    => cia2_pc_n,
      tod     => tod_tick,
      sp_in   => '1',
      sp_out  => cia2_sp_out,
      cnt_in  => '1',
      cnt_out => cia2_cnt_out,
      irq_n   => cia2_irq_n,
      dbg_state => cia2_dbg_state
    );

  -- ---- keyboard matrix ----
  -- (Isolation test confirmed the PS/2 module is innocent -- the hang persists with
  -- it removed -- so it stays wired in.)
  kbd_i : entity work.c64_keyboard_matrix
    port map (
      clk => clk, reset_n => core_reset_n,
      ps2_clk => ps2_clk, ps2_data => ps2_data,
      col_drive => cia1_pa_out,
      row_drive => cia1_pb_out,
      col_read => kb_col,
      row_read => kb_row,
      restore_n => restore_n
    );

  -- ---- SID ----
  cs_sid <= '1' when io = IO_SID else '0';
  sid_i : entity work.sid6581
    generic map (CLK_HZ => 27_000_000, SID_HZ => 985_248)
    port map (
      clk => clk, reset_n => core_reset_n,
      cs => cs_sid, we => io_we, addr => cpu_addr(4 downto 0),
      din => cpu_dout, dout => sid_dout, sample_out => audio
    );

  -- ---- Host disk UART (I/O area 1, $DE00-$DE01) ----
  -- A PC runs a "1541 server" on this serial link and LOAD is done over UART.
  --   $DE00 DATA   : write -> transmit a byte; read -> pop one received byte
  --   $DE01 STATUS : bit0 = RX byte available, bit1 = TX busy, bit2 = RX overflow
  -- 115200 8N1 on the CH340 USB-UART; the held-cs C64 bus is handled by pulsing
  -- TX/pop once per CPU access (phi2_en) -- no 27x repeat.
  cs_uart <= '1' when (HOST_UART_ENABLE and io = IO_EXP1) else '0';

  gen_host_uart : if HOST_UART_ENABLE generate
    utx_i : entity work.uart_tx_ser
      generic map (CLK_HZ => 27_000_000, BAUD => 115_200)
      port map (clk => clk, reset_n => core_reset_n,
                data => cpu_dout, valid => utx_send, tx => legacy_uart_tx, busy => utx_busy);

    urx_i : entity work.uart_rx_ser
      generic map (CLK_HZ => 27_000_000, BAUD => 115_200)
      port map (clk => clk, reset_n => core_reset_n,
                rx => uart_rx, data => urx_data, valid => urx_valid);
  end generate;

  gen_no_host_uart : if not HOST_UART_ENABLE generate
    legacy_uart_tx <= '1';
    urx_data  <= (others => '0');
    urx_valid <= '0';
    utx_busy  <= '0';
  end generate;

  -- One TX start pulse per CPU write to $DE00.
  utx_send <= '1' when (cs_uart = '1' and cpu_we = '1' and cpu_addr(0) = '0'
                        and phi2_en = '1') else '0';

  uart_read_sel <= '1' when (cs_uart = '1' and cpu_we = '0' and cpu_addr(0) = '0') else '0';

  rx_pop <= '1' when (uart_read_sel = '1' and phi2_en = '1'
                      and uart_read_held = '0' and rx_count > 0) else '0';
  rx_avail <= '1' when rx_count > 0 else '0';

  -- Buffer PC->C64 bursts. A single-byte latch is enough for PING, but D64 PRG
  -- loads arrive as long serial frames while the 1 MHz CPU is also storing each
  -- payload byte to RAM. While the FPGA monitor owns the same UART link, keep
  -- this FIFO empty so upload commands do not become stale disk bytes.
  process(clk)
    variable count_v : integer range 0 to RX_FIFO_DEPTH;
    variable rd_v    : unsigned(7 downto 0);
    variable wr_v    : unsigned(7 downto 0);
  begin
    if rising_edge(clk) then
      if core_reset_n = '0' or monitor_hold = '1' then
        rx_count    <= 0;
        rx_rd_ptr   <= (others => '0');
        rx_wr_ptr   <= (others => '0');
        rx_overflow <= '0';
      else
        count_v := rx_count;
        rd_v    := rx_rd_ptr;
        wr_v    := rx_wr_ptr;

        if rx_pop = '1' and count_v > 0 then
          rd_v    := rd_v + 1;
          count_v := count_v - 1;
        end if;

        if urx_valid = '1' then
          if count_v < RX_FIFO_DEPTH then
            rx_fifo(to_integer(wr_v)) <= urx_data;
            wr_v    := wr_v + 1;
            count_v := count_v + 1;
          else
            rx_overflow <= '1';
          end if;
        end if;

        rx_count  <= count_v;
        rx_rd_ptr <= rd_v;
        rx_wr_ptr <= wr_v;
      end if;
    end if;
  end process;

  -- Keep a $DE00 read stable after the pop edge. T65 can hold the same read
  -- address across more than one phi2 tick; without this latch the FIFO pointer
  -- may advance while the CPU is still sampling the data bus.
  process(clk)
  begin
    if rising_edge(clk) then
      if core_reset_n = '0' or monitor_hold = '1' then
        uart_read_held  <= '0';
        uart_data_latch <= (others => '0');
      elsif uart_read_sel = '0' then
        uart_read_held <= '0';
      elsif phi2_en = '1' and uart_read_held = '0' then
        uart_read_held <= '1';
        if rx_count > 0 then
          uart_data_latch <= rx_fifo(to_integer(rx_rd_ptr));
        else
          uart_data_latch <= (others => '0');
        end if;
      end if;
    end if;
  end process;

  uart_data_dout <= uart_data_latch when uart_read_held = '1'
                    else rx_fifo(to_integer(rx_rd_ptr));

  uart_dout <= uart_data_dout when cpu_addr(0) = '0'
               else "00000" & rx_overflow & utx_busy & rx_avail;

  -- ---- CPU read data mux ----
  -- The CPU read mux is split so the steal-coupled main-RAM read (dram_dout, from
  -- the single-port BSRAM time-shared with the VIC) stays a SHALLOW final 2:1 mux,
  -- independent of how deep the ROM/I/O mux below gets. That path is single-cycle
  -- constrained (the SDC can't multicycle it -- dram_dout changes every clock at
  -- the steal boundary) and is the placement-critical net; keeping it a 2:1 mux
  -- stops new I/O sources (e.g. the $DE00 UART) from lengthening it via a merged
  -- mux tree. Everything else (ROM/CIA/VIC/SID/UART) has the full CPU cycle and is
  -- multicycled, so its extra depth is harmless.
  process(sel, io, basic_dout, kernal_dout, cg_cpu_dout,
          vic_dout, sid_dout, col_a_dout, cia1_dout, cia2_dout,
          uart_dout)
  begin
    case sel is
      when SEL_BASIC   => other_din <= basic_dout;
      when SEL_KERNAL  => other_din <= kernal_dout;
      when SEL_CHARGEN => other_din <= cg_cpu_dout;
      when SEL_IO =>
        case io is
          when IO_VIC   => other_din <= vic_dout;
          when IO_SID   => other_din <= sid_dout;
          when IO_COLOR => other_din <= "0000" & col_a_dout;
          when IO_CIA1  => other_din <= cia1_dout;
          when IO_CIA2  => other_din <= cia2_dout;
          when IO_EXP1  => other_din <= uart_dout;   -- $DE00 host disk UART
          when others   => other_din <= x"FF";
        end case;
      when others => other_din <= x"FF";
    end case;
  end process;
  cpu_din <= dram_dout when sel = SEL_RAM else other_din;
end architecture;
