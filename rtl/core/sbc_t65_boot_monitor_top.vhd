-- T65 SBC with internal RAM, SD-loaded 16 KB shadow ROM, and UART monitor bus master.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity sbc_t65_boot_monitor_top is
  generic (
    CLK_HZ : positive := 27_000_000;
    BAUD   : positive := 115_200;
    -- Forwarded to vic_vga: true selects exact CEA-861 720x480p (pillarboxed).
    CEA_480P : boolean := false;
    -- Forwarded to vic_vga: true selects standard 640x480 VGA timings.
    VGA_640  : boolean := false;
    -- PS/2 keyboard layout: "DE" (German QWERTZ) or "US" (US QWERTY).
    KBD_LAYOUT : string := "DE";
    -- true: use the low-speed nand2mario USB HID host instead of PS/2.
    USE_USB_HID : boolean := false;
    -- Optional synthesis-time preload for the 16 KiB split ROM image.
    ROM_INIT_BUILTIN : boolean := false
  );
  port (
    clk          : in  std_logic;
    reset_n      : in  std_logic;
    boot_done    : in  std_logic;
    -- CPU-only soft reset: restarts the 6502 via its reset vector while leaving
    -- boot_done / ROM / SRAM contents intact (unlike the full reset_n).
    soft_reset   : in  std_logic := '0';
    monitor_hold : in  std_logic := '0';
    monitor_mem_req   : in  std_logic := '0';
    monitor_mem_we    : in  std_logic := '0';
    monitor_mem_addr  : in  addr_t := (others => '0');
    monitor_mem_wdata : in  data_t := (others => '0');
    monitor_mem_rdata : out data_t;
    monitor_mem_ready : out std_logic;
    monitor_jump_req  : in  std_logic := '0';
    monitor_jump_addr : in  addr_t := (others => '0');

    rom_load_we   : in  std_logic;
    rom_load_addr : in  std_logic_vector(13 downto 0);
    rom_load_data : in  data_t;

    vga_r       : out std_logic_vector(4 downto 0);
    vga_g       : out std_logic_vector(5 downto 0);
    vga_b       : out std_logic_vector(4 downto 0);
    vga_hs      : out std_logic;
    vga_vs      : out std_logic;
    vga_de      : out std_logic;

    uart_rx       : in  std_logic;
    uart_tx_data  : out data_t;
    uart_tx_valid : out std_logic;
    uart_tx_busy  : in  std_logic := '0';

    via_portb   : out data_t;

    -- External main-RAM byte port (DDR3 via ddr3_byte_bridge on the board).
    -- Covers the SRAM device region except the BRAM-backed zero page. The CPU is
    -- held (cpu_rdy='0') for the whole access; payload is latched at sram_ext_req.
    sram_ext_req  : out std_logic;                      -- 1-clk pulse: start access
    sram_ext_we   : out std_logic;                      -- 1=write, 0=read
    sram_ext_addr : out std_logic_vector(14 downto 0);  -- byte address (latched)
    sram_ext_din  : out data_t;                         -- write byte (latched)
    sram_ext_dout : in  data_t := (others => '0');      -- read byte (held by bridge)
    sram_ext_ack  : in  std_logic := '0';               -- 1-clk pulse: access complete

    -- DDR3 framebuffer (vic_fb_ddr3 lives at the board top, next to the DDR3 IP).
    -- CPU pixel-byte port uses the SAME req/ack contract as sram_ext: the CPU is
    -- held (cpu_rdy='0') for the whole access; payload latched at fbw_req.
    fbw_req   : out std_logic;                           -- 1-clk pulse: start access
    fbw_we    : out std_logic;                           -- 1=write pixel, 0=read
    fbw_addr  : out std_logic_vector(17 downto 0);       -- pixel index (latched)
    fbw_din   : out data_t;                              -- write byte (latched)
    fbw_dout  : in  data_t := (others => '0');           -- read byte (held)
    fbw_ack   : in  std_logic := '0';                    -- 1-clk pulse: complete
    -- DDR3 framebuffer geometry selects: fb_hires = 640x400 8bpp, fb_true = 320x200
    -- 16bpp RGB565 (both feed vic_fb_ddr3 at the board top). 320x200 8bpp = neither.
    fb_hires  : out std_logic;
    fb_true   : out std_logic;
    -- Runtime framebuffer backend select ($884C bit 0 in the blitter window):
    -- '1' routes the fbw port, blitter and display fetch to the DDR3 backend,
    -- '0' to the board's default backend (e.g. SDRAM0). Only effective while
    -- fb_ddr3_ready is high; $884C reads back bit7 = DDR3 ready, bit6 =
    -- effective backend, bit0 = the latch. ($9007 is NOT used: existing
    -- software writes frame acks to the emulator's ISR there.)
    fb_ddr3_sel   : out std_logic;
    fb_ddr3_ready : in  std_logic := '0';
    -- Video streaming port: drives vic_fb_ddr3's double-buffer prefetch and reads
    -- the current scanline's pixels back for display (16-bit: RGB565, or low byte).
    fb_frame_start : out std_logic;                      -- 1-clk pulse, frame top
    fb_line_adv    : out std_logic;                      -- 1-clk pulse per source line
    fb_rdaddr      : out std_logic_vector(10 downto 0);  -- (line mod 2)*640 + col
    fb_rddata      : in  std_logic_vector(15 downto 0) := (others => '0');

    -- Hardware 2D blitter command interface, wired to vic_fb_ddr3 at the board
    -- top. Decoded from CPU writes to $8840-$884F; blit_busy read back at $884F.
    blit_op    : out std_logic_vector(2 downto 0);
    blit_x0    : out unsigned(9 downto 0);
    blit_y0    : out unsigned(9 downto 0);
    blit_x1    : out unsigned(9 downto 0);
    blit_y1    : out unsigned(9 downto 0);
    blit_color : out std_logic_vector(7 downto 0);
    blit_page  : out std_logic;
    blit_gap   : out std_logic_vector(7 downto 0);  -- $884B: DDR3 write pacing
    blit_dstx  : out unsigned(9 downto 0);          -- $884D + COLOR(1:0): COPY dst
    blit_dsty  : out unsigned(9 downto 0);          -- $884E + COLOR(2)
    blit_start : out std_logic;
    blit_busy  : in  std_logic := '0';

    -- PT8211 audio DAC (I2S-style serial output)
    dac_bck     : out std_logic;
    dac_ws      : out std_logic;
    dac_din     : out std_logic;

    -- PS/2 keyboard (directly on PMOD GPIO pins)
    ps2_clk  : in std_logic;
    ps2_data : in std_logic;
    -- Optional low-speed USB HID keyboard (nand2mario bit-bang core).
    usb_clk : in std_logic := '0';
    usb_dm  : inout std_logic := 'Z';
    usb_dp  : inout std_logic := 'Z';

    -- Keyboard diagnostic outputs (for boot debug display)
    usb_connected : out std_logic;
    usb_keycode   : out std_logic_vector(7 downto 0);
    usb_modif     : out std_logic_vector(7 downto 0);
    usb_ascii     : out std_logic_vector(7 downto 0);
    usb_phase     : out std_logic_vector(3 downto 0);
    usb_key_event : out std_logic;
    usb_polling   : out std_logic;

    -- ULPI bus capture (stubbed — was ULPI debug; kept for backward compat)
    usb_cap_addr  : in  std_logic_vector(6 downto 0) := (others => '0');
    usb_cap_data  : out std_logic_vector(15 downto 0);
    usb_cap_ready : out std_logic;

    -- Second SD card (data disk) — directly exposed SPI signals
    sd2_init_done           : in  std_logic := '0';
    sd2_sec_read            : out std_logic;
    sd2_sec_read_addr       : out std_logic_vector(31 downto 0);
    sd2_sec_read_data       : in  data_t := (others => '0');
    sd2_sec_read_data_valid : in  std_logic := '0';
    sd2_sec_read_end        : in  std_logic := '0';
    sd2_sec_write           : out std_logic;
    sd2_sec_write_addr      : out std_logic_vector(31 downto 0);
    sd2_sec_write_data      : out data_t;
    sd2_sec_write_data_req  : in  std_logic := '0';
    sd2_sec_write_end       : in  std_logic := '0';

    dbg_cpu_addr : out addr_t;
    dbg_cpu_data : out data_t;
    dbg_cpu_din  : out data_t;
    dbg_cpu_we   : out std_logic;
    dbg_cpu_sync : out std_logic
  );
end entity;

architecture rtl of sbc_t65_boot_monitor_top is
  constant VIC_CLK_DIV : positive := (CLK_HZ + 26_999_999) / 27_000_000;

  signal cpu_reset_n : std_logic;
  signal cpu_reset_base_n : std_logic;
  signal cpu_addr    : addr_t := (others => '0');
  signal cpu_dout    : data_t := (others => '0');
  signal cpu_din     : data_t := (others => '0');
  signal cpu_we      : std_logic := '0';
  signal cpu_bus_we  : std_logic := '0';
  signal cpu_sync    : std_logic := '0';
  signal cpu_enable  : std_logic := '0';
  signal cpu_rdy     : std_logic := '1';
  signal cpu_irq_n   : std_logic := '1';
  signal usb_cs      : std_logic;
  signal dev_sel     : device_sel_t;

  signal zp_dout     : data_t;
  signal sram_dout   : data_t;
  signal rom_dout    : data_t;
  signal vram_dout   : data_t;
  signal vic_reg_dout : data_t;
  signal via_dout    : data_t;
  signal uart_dout   : data_t;
  signal math_dout   : data_t;
  signal math_cs     : std_logic;
  signal math_we     : std_logic;

  -- 4-voice sound chip (sound_chip4). One chip-select per voice; the voices
  -- live at $8830, $8890, $889A, $88A4 (not all 16-aligned) so the register
  -- offset is computed as cpu_addr - base for the selected voice.
  signal sound_cs     : std_logic_vector(3 downto 0);
  signal sound_we     : std_logic;
  signal sound_addr   : std_logic_vector(3 downto 0);
  signal sound_dout   : data_t;
  signal ms_div       : integer range 0 to CLK_HZ/1000 - 1 := 0;
  signal ms_count     : unsigned(7 downto 0) := (others => '0');
  signal sid_cs       : std_logic;
  signal sid_we       : std_logic;
  signal sid_dout     : data_t;
  signal sid_sample   : std_logic_vector(15 downto 0);
  signal sid_addr     : std_logic_vector(4 downto 0);
  signal cia1_cs      : std_logic;
  signal cia1_we      : std_logic;
  signal cia1_dout    : data_t;
  signal cia1_irq_n   : std_logic;
  signal cia1_irq     : std_logic;

  signal zp_cs       : std_logic;
  signal zp_we       : std_logic;
  signal zp_we_mux   : std_logic;
  signal zp_addr_mux : std_logic_vector(13 downto 0);
  signal zp_din_mux  : data_t;
  signal sram_we     : std_logic;
  signal sram_we_mux : std_logic;
  signal sram_addr_mux : std_logic_vector(14 downto 0);
  signal sram_din_mux  : data_t;

  -- External main-RAM (DDR3) access controller.  sram_dout now comes from the
  -- bridge instead of an internal BSRAM.
  --
  -- CPU writes are captured into a one-deep deferred latch the moment the write
  -- strobe fires (T65 write cycles cannot be reliably stretched with RDY — see
  -- sdram_if.vhd / the bitmap deferred-write mechanism), then drained to the
  -- bridge with priority.  CPU reads and all monitor accesses stall via cpu_rdy
  -- until the bridge acknowledges.  Reads are held off while a write is pending
  -- so a read-after-write never returns stale data.
  signal cpu_rd_acc    : std_logic;                       -- CPU read of the DDR region
  signal mon_acc       : std_logic;                       -- monitor SRAM access pending
  signal cpu_wr_strobe : std_logic;                       -- CPU write strobe to DDR region
  signal sram_busy     : std_logic := '0';                -- req issued, awaiting ack
  signal sram_complete : std_logic := '0';                -- current read/monitor access done
  signal sram_stall    : std_logic;                       -- hold CPU for RAM
  signal sram_rd_addr  : std_logic_vector(14 downto 0) := (others => '0');  -- served CPU read addr
  signal serving_mon   : std_logic := '0';                -- current access is the monitor's
  signal serving_write : std_logic := '0';                -- current in-flight op is a write drain
  signal sram_wr_pending : std_logic := '0';              -- a CPU write awaits drain
  signal sram_wr_addr    : std_logic_vector(14 downto 0) := (others => '0');
  signal sram_wr_data    : data_t := (others => '0');
  signal sram_wr_overflow : std_logic := '0';             -- debug: write lost (should never set)
  signal rom_addr_mux : std_logic_vector(13 downto 0);
  signal rom_load_we_mux   : std_logic;
  signal rom_load_addr_mux : std_logic_vector(13 downto 0);
  signal rom_load_data_mux : data_t;
  -- "RAM under BASIC": let the running CPU write the $A000-$CFFF shadow-ROM
  -- window so it becomes 12 KB of usable RAM (reusing the existing BSRAM, no new
  -- block RAM). The kernel window $F000-$FFFF stays read-only (vectors). EhBASIC
  -- never writes its own code region, so normal operation is unaffected.
  signal cpu_rom_we        : std_logic;
  signal vram_we     : std_logic;
  signal vram_we_mux : std_logic;
  signal vic_reg_we  : std_logic;
  signal blit_wr     : std_logic;      -- CPU write strobe to $8840-$884F
  signal blit_dout   : data_t;         -- blitter register read-back
  signal via_cs      : std_logic;
  signal via_cs_mux  : std_logic;
  signal via_we_mux  : std_logic;
  signal via_addr_mux : addr_t;
  signal via_din_mux : data_t;
  signal uart_cs     : std_logic;
  signal uart_cs_mux : std_logic;
  signal uart_we_mux : std_logic;
  signal uart_addr_mux : addr_t;
  signal uart_din_mux : data_t;

  signal vram_addr    : std_logic_vector(10 downto 0);
  signal vram_addr_mux : std_logic_vector(10 downto 0);
  signal vram_din_mux  : data_t;
  signal vram_wr_pending : std_logic := '0';
  signal vram_wr_addr    : std_logic_vector(10 downto 0) := (others => '0');
  signal vram_wr_data    : data_t := (others => '0');
  signal vic_addr     : addr_t;
  signal vic_stealing : std_logic;
  signal vic_stealing_d : std_logic := '0';  -- steal delayed 1 clk (read-latency cushion)
  signal vic_cursor_x : std_logic_vector(6 downto 0) := (others => '0');
  signal vic_cursor_y : std_logic_vector(4 downto 0) := (others => '0');
  signal vic_text_color : data_t := x"01";
  signal vic_bg_color   : data_t := x"00";
  signal vic_mode_reg     : data_t := x"00";
  -- $9005 TEXT_ATTR: bit0 = per-cell text background (colour-RAM high nibble)
  -- instead of the global $D021 background; bit1 = 80x25 text mode. Cleared on
  -- cpu_reset_n like the mode register so a returning BASIC text screen keeps
  -- the C64-style global bg and 40-column layout unless software enables it.
  signal vic_text_attr  : data_t := x"00";
  -- VIC-II register block ($D000-$D03F). $20 = border, $21 = background (drive
  -- the display); $11/$12 read back the current raster line; the rest are a
  -- read/write register file for compatibility.
  type vic2_regs_t is array (0 to 63) of data_t;
  signal vic2_regs : vic2_regs_t := (others => (others => '0'));
  signal vic2_we   : std_logic;
  signal vic2_dout : data_t;
  signal vic_raster : std_logic_vector(9 downto 0);
  signal vic_fetch_bitmap : std_logic;
  -- Framebuffer read byte (latched from the DDR3 controller on a read/monitor
  -- completion). Consumed by the CPU read mux and the monitor peek path.
  signal bitmap_dout      : data_t := (others => '0');
  -- CPU/monitor bank into the framebuffer. The 320x200 mode (mode bit 4) uses 3
  -- bank bits (vic_mode_reg(7:5)) -> 8x 8 KiB = 64 KiB >= 64000 pixels. The 640x400
  -- hi-res mode (mode bit 5) needs 256000 bytes = 32 banks, so it takes a full
  -- 5-bit bank from a dedicated register ($9006) instead. fb_pix_bank is the
  -- effective 5-bit bank feeding the 18-bit pixel index.
  signal bmp_bank         : std_logic_vector(2 downto 0);
  signal fb_pix_bank      : std_logic_vector(4 downto 0);
  signal fb_hires_mode    : std_logic;                       -- mode bit5, gated
  signal fb_true_mode     : std_logic;                       -- mode bit6, gated (16bpp)
  signal vic_fb_bank      : std_logic_vector(4 downto 0) := (others => '0');  -- $9006
  signal vic_fb_backend   : std_logic := '0';                -- $9007 bit 0
  signal vram_data_sel    : std_logic := '0';
  signal vram_data_mux    : data_t;

  -- DDR3 framebuffer CPU byte port controller (mirrors sram_acc_ctrl): a CPU
  -- write is captured into a one-deep latch and drained with priority; CPU reads
  -- and monitor peeks issue a request and complete on fbw_ack.
  signal fbw_busy         : std_logic := '0';
  signal fbw_complete     : std_logic := '0';
  signal fbw_serving_mon  : std_logic := '0';
  signal fbw_serving_write : std_logic := '0';
  signal fbw_wr_pending   : std_logic := '0';
  signal fbw_wr_addr      : std_logic_vector(17 downto 0) := (others => '0');
  signal fbw_wr_data      : data_t := (others => '0');
  signal fbw_rd_addr      : std_logic_vector(17 downto 0) := (others => '0');
  signal fbw_stall        : std_logic;
  signal fb_rd_acc        : std_logic;
  signal fb_wr_strobe     : std_logic;
  signal mon_fb_acc       : std_logic;
  signal fbw_cpu_pix      : std_logic_vector(17 downto 0);
  signal fbw_mon_pix      : std_logic_vector(17 downto 0);

  signal char_addr   : std_logic_vector(9 downto 0);
  signal char_glyph_hi : std_logic;
  signal char_data   : data_t;

  signal disk_cs     : std_logic;
  signal disk_we     : std_logic;
  signal disk_dout   : data_t;
  signal disk_irq    : std_logic;
  signal disk_sd2_sec_read      : std_logic;
  signal disk_sd2_sec_read_addr : std_logic_vector(31 downto 0);
  signal sdraw_cs     : std_logic;
  signal sdraw_we     : std_logic;
  signal sdraw_dout   : data_t;
  signal sdraw_irq    : std_logic;
  signal sdraw_sd2_sec_read       : std_logic;
  signal sdraw_sd2_sec_read_addr  : std_logic_vector(31 downto 0);
  signal sdraw_sd2_sec_write      : std_logic;
  signal sdraw_sd2_sec_write_addr : std_logic_vector(31 downto 0);
  signal sdraw_sd2_sec_write_data : data_t;

  signal via_irq     : std_logic;
  signal uart_irq    : std_logic;
  signal usb_irq     : std_logic;
  signal usb_dout    : data_t;
  signal uart_rx_data  : data_t;
  signal uart_rx_valid : std_logic;

  signal kbd_ascii_i     : data_t := (others => '0');
  signal kbd_event_tog_i : std_logic := '0';
  signal uart_rx_valid_cpu : std_logic;
  signal mon_jump_vector        : addr_t := (others => '0');
  signal mon_jump_reset_cnt     : natural range 0 to 31 := 0;
  signal mon_jump_vector_active : std_logic := '0';

  type mon_mem_state_t is (
    M_IDLE, M_ZP_WAIT, M_ZP_READY,
    M_SRAM_WAIT, M_SRAM_READY,
    M_ROM_RD_WAIT, M_ROM_RD_READY, M_ROM_WR_WAIT,
    M_VRAM_RD_WAIT, M_VRAM_RD_READY, M_VRAM_WR_WAIT,
    M_BITMAP_RD_WAIT, M_BITMAP_RD_READY, M_BITMAP_WR_WAIT,
    M_VIA_WAIT, M_VIA_READY,
    M_UART_WAIT, M_UART_READY,
    M_READY
  );
  signal mon_mem_state       : mon_mem_state_t := M_IDLE;
  signal mon_addr_lat        : addr_t := (others => '0');
  signal mon_wdata_lat       : data_t := (others => '0');
  signal mon_we_lat          : std_logic := '0';
  signal mon_rdata_reg       : data_t := (others => '0');
  signal mon_ready_reg       : std_logic := '0';
begin
  cpu_reset_base_n <= reset_n and boot_done and not soft_reset;
  cpu_reset_n <= cpu_reset_base_n when mon_jump_reset_cnt = 0 else '0';

  process(clk)
  begin
    if rising_edge(clk) then
      if cpu_reset_n = '0' or monitor_hold = '1' then
        cpu_enable <= '0';
      else
        cpu_enable <= not cpu_enable;
      end if;
      -- One-cycle-delayed copy of the steal flag. The VRAM/bitmap RAMs are
      -- single-port with one cycle of read latency, so after a steal ends the
      -- RAM still presents the VIC's address for one more cycle. Holding the CPU
      -- stalled that extra cycle prevents it from latching the VIC's fetched byte
      -- (e.g. a colour value $01) as its own VRAM read — the bug that scrolled
      -- stray 'A' characters onto the screen. Proven by tb_vram_read_steal.
      vic_stealing_d <= vic_stealing;
    end if;
  end process;

  cpu_bus_we <= cpu_we and not cpu_enable;

  -- External main-RAM (DDR3) access classification.
  cpu_rd_acc    <= '1' when monitor_hold = '0' and dev_sel = DEV_SRAM and zp_cs = '0'
                            and cpu_we = '0' else '0';
  cpu_wr_strobe <= '1' when monitor_hold = '0' and cpu_bus_we = '1'
                            and dev_sel = DEV_SRAM and zp_cs = '0' else '0';
  mon_acc       <= '1' when monitor_hold = '1' and mon_mem_state = M_SRAM_WAIT else '0';

  -- Stall the CPU while: its read has not completed; a write is queued/draining
  -- (so reads see committed data and a second write cannot be lost); or any
  -- bridge op is in flight.
  sram_stall <= '1' when (cpu_rd_acc = '1' and sram_complete = '0')
                      or sram_wr_pending = '1'
                      or sram_busy = '1'
                else '0';

  cpu_rdy    <= not vic_stealing and not vic_stealing_d and
                not vram_wr_pending and not fbw_stall and not monitor_hold
                and not sram_stall;

  sram_dout  <= sram_ext_dout;
  -- Test build: SD2 and audio IRQ sources are disabled to free placement
  -- resources while debugging the framebuffer/blitter path.
  cpu_irq_n  <= not (via_irq or uart_irq or usb_irq);
  usb_cs     <= '1' when monitor_hold = '0' and dev_sel = DEV_USB else '0';

  -- Low 16 KB ($0000-$3FFF) is on-chip BRAM. $4000-$5FFF is served through
  -- the board byte backend (BSRAM by default, optional DDR3); $6000-$7FFF is VIC.
  zp_cs   <= '1' when dev_sel = DEV_SRAM and cpu_addr(15 downto 14) = "00" else '0';
  zp_we   <= cpu_bus_we when monitor_hold = '0' and zp_cs = '1' else '0';
  sram_we <= cpu_bus_we when monitor_hold = '0' and dev_sel = DEV_SRAM and zp_cs = '0' else '0';
  vram_we <= cpu_bus_we when monitor_hold = '0' and dev_sel = DEV_VIC_TEXT else '0';
  vic_reg_we <= cpu_bus_we when monitor_hold = '0' and dev_sel = DEV_VIC_REG else '0';
  vic2_we    <= cpu_bus_we when monitor_hold = '0' and dev_sel = DEV_VICII   else '0';
  blit_wr    <= cpu_bus_we when monitor_hold = '0' and dev_sel = DEV_VIC_BLIT else '0';

  -- Hardware 2D blitter register file ($8840-$884F). Decodes CPU writes into the
  -- wide blit command for vic_fb_ddr3 (wired at the board top) and reads BUSY back.
  blit_regs_i : entity work.vic_blit_regs
    port map (
      clk => clk, rst_n => reset_n,
      wr => blit_wr, addr => cpu_addr(3 downto 0), wdata => cpu_dout,
      rdata => blit_dout, busy => blit_busy,
      blit_op => blit_op, blit_x0 => blit_x0, blit_y0 => blit_y0,
      blit_x1 => blit_x1, blit_y1 => blit_y1, blit_color => blit_color,
      blit_page => blit_page, blit_gap => blit_gap,
      blit_dstx => blit_dstx, blit_dsty => blit_dsty,
      blit_start => blit_start);
  via_cs  <= '1'        when monitor_hold = '0' and dev_sel = DEV_VIA      else '0';
  uart_cs <= '1'        when monitor_hold = '0' and dev_sel = DEV_UART     else '0';
  disk_cs <= '1'        when monitor_hold = '0' and dev_sel = DEV_DISK     else '0';
  disk_we <= cpu_bus_we when monitor_hold = '0' and dev_sel = DEV_DISK     else '0';
  sdraw_cs <= '1'        when monitor_hold = '0' and dev_sel = DEV_SDRAW    else '0';
  sdraw_we <= cpu_bus_we when monitor_hold = '0' and dev_sel = DEV_SDRAW    else '0';
  math_cs <= '1'        when monitor_hold = '0' and dev_sel = DEV_MATH     else '0';
  math_we <= cpu_bus_we when monitor_hold = '0' and dev_sel = DEV_MATH     else '0';
  sid_cs  <= '1'        when monitor_hold = '0' and dev_sel = DEV_SID      else '0';
  sid_we  <= cpu_bus_we when monitor_hold = '0' and dev_sel = DEV_SID      else '0';
  cia1_cs <= '1'        when monitor_hold = '0' and dev_sel = DEV_CIA1     else '0';
  cia1_we <= cpu_bus_we when monitor_hold = '0' and dev_sel = DEV_CIA1     else '0';
  cia1_irq <= not cia1_irq_n;
  sid_addr <= std_logic_vector(resize(unsigned(cpu_addr) - ADDR_SID_BASE, 5));

  -- Per-voice chip-selects, shared write strobe, and the register offset for
  -- whichever voice is currently addressed (cpu_addr - voice base).
  sound_cs(0) <= '1' when monitor_hold = '0' and dev_sel = DEV_SOUND0 else '0';
  sound_cs(1) <= '1' when monitor_hold = '0' and dev_sel = DEV_SOUND1 else '0';
  sound_cs(2) <= '1' when monitor_hold = '0' and dev_sel = DEV_SOUND2 else '0';
  sound_cs(3) <= '1' when monitor_hold = '0' and dev_sel = DEV_SOUND3 else '0';
  sound_we    <= cpu_bus_we when monitor_hold = '0' else '0';

  sound_addr <=
    std_logic_vector(resize(unsigned(cpu_addr) - ADDR_SOUND0_BASE, 4)) when dev_sel = DEV_SOUND0 else
    std_logic_vector(resize(unsigned(cpu_addr) - ADDR_SOUND1_BASE, 4)) when dev_sel = DEV_SOUND1 else
    std_logic_vector(resize(unsigned(cpu_addr) - ADDR_SOUND2_BASE, 4)) when dev_sel = DEV_SOUND2 else
    std_logic_vector(resize(unsigned(cpu_addr) - ADDR_SOUND3_BASE, 4)) when dev_sel = DEV_SOUND3 else
    (others => '0');

  zp_we_mux   <= '1' when monitor_hold = '1' and mon_mem_state = M_ZP_WAIT and mon_we_lat = '1' else zp_we;
  zp_addr_mux <= mon_addr_lat(13 downto 0) when monitor_hold = '1' and
                 (mon_mem_state = M_ZP_WAIT or mon_mem_state = M_ZP_READY) else cpu_addr(13 downto 0);
  zp_din_mux  <= mon_wdata_lat when monitor_hold = '1' and mon_mem_state = M_ZP_WAIT else cpu_dout;

  sram_we_mux <= '1' when monitor_hold = '1' and mon_mem_state = M_SRAM_WAIT and mon_we_lat = '1' else sram_we;
  sram_addr_mux <= mon_addr_lat(14 downto 0) when monitor_hold = '1' and
                   (mon_mem_state = M_SRAM_WAIT or mon_mem_state = M_SRAM_READY) else cpu_addr(14 downto 0);
  sram_din_mux <= mon_wdata_lat when monitor_hold = '1' and mon_mem_state = M_SRAM_WAIT else cpu_dout;

  rom_addr_mux <= rom_offset(mon_addr_lat) when monitor_hold = '1' and
                  (mon_mem_state = M_ROM_RD_WAIT or mon_mem_state = M_ROM_RD_READY) else
                  rom_offset(cpu_addr);
  -- CPU write to the $A000-$CFFF BASIC window (RAM-under-BASIC). Kernel window
  -- ($F000-$FFFF) is excluded so its vectors cannot be clobbered.
  cpu_rom_we <= cpu_bus_we when monitor_hold = '0' and dev_sel = DEV_ROM
                             and in_range(cpu_addr, ADDR_BASROM_BASE, ADDR_BASROM_LAST)
                else '0';

  rom_load_we_mux <= '1' when monitor_hold = '1' and mon_mem_state = M_ROM_WR_WAIT and mon_we_lat = '1' else
                     cpu_rom_we when cpu_rom_we = '1' else
                     rom_load_we;
  rom_load_addr_mux <= rom_offset(mon_addr_lat) when monitor_hold = '1' and mon_mem_state = M_ROM_WR_WAIT else
                       rom_offset(cpu_addr) when cpu_rom_we = '1' else
                       rom_load_addr;
  rom_load_data_mux <= mon_wdata_lat when monitor_hold = '1' and mon_mem_state = M_ROM_WR_WAIT else
                       cpu_dout when cpu_rom_we = '1' else
                       rom_load_data;

  vram_addr   <= vic_addr(10 downto 0) when vic_stealing = '1' and vic_fetch_bitmap = '0' else cpu_addr(10 downto 0);
  vram_addr_mux <= mon_addr_lat(10 downto 0) when monitor_hold = '1' and
                   (mon_mem_state = M_VRAM_RD_WAIT or mon_mem_state = M_VRAM_RD_READY or
                    mon_mem_state = M_VRAM_WR_WAIT) else
                   vram_wr_addr when vram_wr_pending = '1' and vic_stealing = '0' else
                   vram_addr;
  vram_we_mux <= '1' when monitor_hold = '1' and mon_mem_state = M_VRAM_WR_WAIT and mon_we_lat = '1' else
                 '1' when vram_wr_pending = '1' and vic_stealing = '0' else
                 '0' when vic_stealing = '1' else vram_we;

  -- ── DDR3 framebuffer CPU byte port ($6000-$7FFF window) ───────────────────
  -- The framebuffer lives in DDR3 (vic_fb_ddr3 at the board top). The CPU reaches
  -- it one pixel byte at a time through this req/ack controller, banked through the
  -- $6000-$7FFF (8 KiB) window. 320x200 (mode bit 4) banks with vic_mode_reg(7:5)
  -- = 8 banks = 64 KiB >= 64000; 640x400 hi-res (mode bit 5) needs 32 banks, so it
  -- banks with the full 5-bit $9006 register (vic_fb_bank).
  fb_hires_mode <= vic_mode_reg(5) and not vic_mode_reg(4);
  fb_true_mode  <= vic_mode_reg(6) and not vic_mode_reg(5) and not vic_mode_reg(4);
  fb_hires       <= fb_hires_mode;   -- geometry selects to vic_fb_ddr3 (board top)
  fb_true        <= fb_true_mode;
  -- Effective backend select: the $9007 latch only takes effect while the DDR3
  -- controller reports ready, so software can never strand the fbw port on an
  -- uncalibrated backend.
  fb_ddr3_sel    <= vic_fb_backend and fb_ddr3_ready;
  bmp_bank <= vic_mode_reg(7 downto 5) when vic_mode_reg(4) = '1'
              else "00" & vic_mode_reg(2);
  -- 640x400 (32 banks) and 320x200 16bpp (128000 B = 16 banks) both bank via the
  -- dedicated $9006 register; only 320x200 8bpp uses the $9000 bits 7:5 window.
  fb_pix_bank <= vic_fb_bank when (fb_hires_mode = '1' or fb_true_mode = '1')
                 else "00" & bmp_bank;

  -- 18-bit pixel index = 5 bank bits & 13-bit offset into the $6000 window.
  fbw_cpu_pix <= fb_pix_bank &
                 std_logic_vector(resize(unsigned(cpu_addr) - ADDR_VIC_BMP_BASE, 13));
  fbw_mon_pix <= fb_pix_bank &
                 std_logic_vector(resize(unsigned(mon_addr_lat) - ADDR_VIC_BMP_BASE, 13));

  -- Access classification (mirrors the sram_ext $4000-$5FFF byte port).
  fb_rd_acc    <= '1' when monitor_hold = '0' and dev_sel = DEV_VIC_BMP and cpu_we = '0' else '0';
  fb_wr_strobe <= '1' when monitor_hold = '0' and cpu_bus_we = '1' and dev_sel = DEV_VIC_BMP else '0';
  mon_fb_acc   <= '1' when monitor_hold = '1' and
                          (mon_mem_state = M_BITMAP_RD_WAIT or mon_mem_state = M_BITMAP_WR_WAIT) else '0';

  -- Stall the CPU while its framebuffer read is outstanding, a write is queued or
  -- draining, or the controller is busy with any op.
  fbw_stall <= '1' when (fb_rd_acc = '1' and fbw_complete = '0')
                     or fbw_wr_pending = '1'
                     or fbw_busy = '1'
               else '0';

  fbw_acc_ctrl : process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        fbw_busy          <= '0';
        fbw_complete      <= '0';
        fbw_serving_mon   <= '0';
        fbw_serving_write <= '0';
        fbw_req           <= '0';
        fbw_we            <= '0';
        fbw_addr          <= (others => '0');
        fbw_din           <= (others => '0');
        fbw_rd_addr       <= (others => '0');
        fbw_wr_pending    <= '0';
        fbw_wr_addr       <= (others => '0');
        fbw_wr_data       <= (others => '0');
        bitmap_dout       <= (others => '0');
      else
        fbw_req <= '0';

        -- Capture a CPU pixel write the moment its strobe fires.
        if fb_wr_strobe = '1' then
          fbw_wr_pending <= '1';
          fbw_wr_addr    <= fbw_cpu_pix;
          fbw_wr_data    <= cpu_dout;
        end if;

        if fbw_busy = '0' then
          if fbw_complete = '0' then
            if fbw_wr_pending = '1' then
              -- drain queued write first (priority)
              fbw_req           <= '1';
              fbw_we            <= '1';
              fbw_addr          <= fbw_wr_addr;
              fbw_din           <= fbw_wr_data;
              fbw_busy          <= '1';
              fbw_serving_mon   <= '0';
              fbw_serving_write <= '1';
            elsif fb_rd_acc = '1' then
              fbw_req           <= '1';
              fbw_we            <= '0';
              fbw_addr          <= fbw_cpu_pix;
              fbw_rd_addr       <= fbw_cpu_pix;
              fbw_busy          <= '1';
              fbw_serving_mon   <= '0';
              fbw_serving_write <= '0';
            elsif mon_fb_acc = '1' then
              fbw_req           <= '1';
              fbw_we            <= mon_we_lat;
              fbw_addr          <= fbw_mon_pix;
              fbw_din           <= mon_wdata_lat;
              fbw_busy          <= '1';
              fbw_serving_mon   <= '1';
              fbw_serving_write <= '0';
            end if;
          end if;
        else
          if fbw_ack = '1' then
            fbw_busy    <= '0';
            bitmap_dout <= fbw_dout;   -- latch read byte (ignored for writes)
            if fbw_serving_write = '1' then
              fbw_wr_pending <= '0';
            else
              fbw_complete <= '1';
            end if;
          end if;
        end if;

        -- Release completion once the requester has moved on.
        if fbw_complete = '1' then
          if fbw_serving_mon = '1' then
            if mon_fb_acc = '0' then
              fbw_complete    <= '0';
              fbw_serving_mon <= '0';
            end if;
          elsif fb_rd_acc = '0' or fbw_cpu_pix /= fbw_rd_addr then
            fbw_complete <= '0';
          end if;
        end if;
      end if;
    end if;
  end process;

  -- VIC data mux: select bitmap or VRAM data (registered to match sync RAM latency)
  process(clk)
  begin
    if rising_edge(clk) then
      vram_data_sel <= vic_fetch_bitmap;
    end if;
  end process;
  vram_data_mux <= bitmap_dout when vram_data_sel = '1' else vram_dout;

  vram_din_mux <= mon_wdata_lat when monitor_hold = '1' and mon_mem_state = M_VRAM_WR_WAIT else
                  vram_wr_data when vram_wr_pending = '1' and vic_stealing = '0' else
                  cpu_dout;

  process(clk)
  begin
    if rising_edge(clk) then
      if cpu_reset_n = '0' or monitor_hold = '1' then
        vram_wr_pending <= '0';
        vram_wr_addr    <= (others => '0');
        vram_wr_data    <= (others => '0');
      elsif vram_wr_pending = '1' and vic_stealing = '0' then
        -- Commit the deferred write through vram_*_mux on this edge.
        vram_wr_pending <= '0';
      elsif vram_we = '1' and vic_stealing = '1' then
        -- A CPU write pulse would otherwise be masked while the VIC owns VRAM.
        vram_wr_pending <= '1';
        vram_wr_addr    <= cpu_addr(10 downto 0);
        vram_wr_data    <= cpu_dout;
      end if;
    end if;
  end process;

  via_cs_mux <= '1' when monitor_hold = '1' and
                (mon_mem_state = M_VIA_WAIT or
                 (mon_mem_state = M_VIA_READY and mon_we_lat = '0')) else via_cs;
  via_we_mux <= '1' when monitor_hold = '1' and mon_mem_state = M_VIA_WAIT and mon_we_lat = '1' else cpu_bus_we;
  via_addr_mux <= mon_addr_lat when monitor_hold = '1' and
                  (mon_mem_state = M_VIA_WAIT or mon_mem_state = M_VIA_READY) else cpu_addr;
  via_din_mux <= mon_wdata_lat when monitor_hold = '1' and mon_mem_state = M_VIA_WAIT else cpu_dout;

  uart_cs_mux <= '1' when monitor_hold = '1' and
                 (mon_mem_state = M_UART_WAIT or
                  (mon_mem_state = M_UART_READY and mon_we_lat = '0')) else uart_cs;
  uart_we_mux <= '1' when monitor_hold = '1' and mon_mem_state = M_UART_WAIT and mon_we_lat = '1' else cpu_bus_we;
  uart_addr_mux <= mon_addr_lat when monitor_hold = '1' and
                   (mon_mem_state = M_UART_WAIT or mon_mem_state = M_UART_READY) else cpu_addr;
  uart_din_mux <= mon_wdata_lat when monitor_hold = '1' and mon_mem_state = M_UART_WAIT else cpu_dout;

  monitor_mem_rdata <= mon_rdata_reg;
  monitor_mem_ready <= mon_ready_reg;
  uart_rx_valid_cpu <= uart_rx_valid when monitor_hold = '0' else '0';

  process(dev_sel, zp_cs, zp_dout, sram_dout, rom_dout, vram_dout, vic_reg_dout, via_dout,
          uart_dout, mon_jump_vector_active, mon_jump_vector, cpu_addr, bitmap_dout,
          sound_dout, math_dout, sdraw_dout, sid_dout, disk_dout, vic2_dout, cia1_dout,
          blit_dout, vic_fb_backend, fb_ddr3_ready)
  begin
    case dev_sel is
      when DEV_SRAM =>
        if zp_cs = '1' then
          cpu_din <= zp_dout;
        else
          cpu_din <= sram_dout;
        end if;
      when DEV_ROM =>
        if mon_jump_vector_active = '1' and cpu_addr = x"FFFC" then
          cpu_din <= mon_jump_vector(7 downto 0);
        elsif mon_jump_vector_active = '1' and cpu_addr = x"FFFD" then
          cpu_din <= mon_jump_vector(15 downto 8);
        else
          cpu_din <= rom_dout;
        end if;
      when DEV_VIC_TEXT =>
        cpu_din <= vram_dout;
      when DEV_VIC_REG =>
        cpu_din <= vic_reg_dout;
      when DEV_VIA =>
        cpu_din <= via_dout;
      when DEV_UART =>
        cpu_din <= uart_dout;
      when DEV_USB =>
        cpu_din <= usb_dout;
      when DEV_DISK =>
        cpu_din <= disk_dout;
      when DEV_VIC_BLIT =>
        -- $884C = framebuffer backend select/status: bit7 = DDR3 ready, bit6 =
        -- effective backend, bit0 = select latch. Other offsets read the
        -- blitter register file ($884F = busy).
        if cpu_addr(3 downto 0) = x"C" then
          cpu_din <= fb_ddr3_ready & (vic_fb_backend and fb_ddr3_ready) &
                     "00000" & vic_fb_backend;
        else
          cpu_din <= blit_dout;
        end if;
      when DEV_VIC_BMP =>
        cpu_din <= bitmap_dout;
      when DEV_SOUND0 | DEV_SOUND1 | DEV_SOUND2 | DEV_SOUND3 =>
        cpu_din <= sound_dout;
      when DEV_MATH =>
        cpu_din <= math_dout;
      when DEV_SDRAW =>
        cpu_din <= sdraw_dout;
      when DEV_SID =>
        -- SID now lives in the free I/O region ($D400), no longer overlapping the
        -- ROM, so reads return the SID register file again.
        cpu_din <= sid_dout;
      when DEV_VICII =>
        cpu_din <= vic2_dout;
      when DEV_CIA1 =>
        cpu_din <= cia1_dout;
      when others =>
        cpu_din <= x"FF";
    end case;
  end process;

  -- Reset the VIC control registers on any CPU reset (short soft reset OR full
  -- board reset = cpu_reset_n), not just the full reset.  Otherwise a program
  -- that switched the VIC to bitmap mode (e.g. the Mandelbrot demo writing
  -- vic_mode_reg) would leave it in bitmap mode after reset, so the returning
  -- BASIC text screen would stay hidden behind the old bitmap image.
  process(clk)
  begin
    if rising_edge(clk) then
      if cpu_reset_n = '0' then
        vic_cursor_x <= (others => '0');
        vic_cursor_y <= (others => '0');
        vic_mode_reg <= (others => '0');   -- back to text mode
        vic_text_attr <= (others => '0');  -- back to global background
        vic_fb_bank  <= (others => '0');   -- hi-res framebuffer bank -> 0
        vic_fb_backend <= '0';             -- back to the default (SDRAM0) backend
      else
        if vic_reg_we = '1' then
          case cpu_addr(3 downto 0) is
            when x"0" =>
              vic_mode_reg <= cpu_dout;
            when x"1" =>
              if unsigned(cpu_dout(6 downto 0)) < to_unsigned(80, 7) then
                vic_cursor_x <= cpu_dout(6 downto 0);
              end if;
            when x"2" =>
              if unsigned(cpu_dout(4 downto 0)) < to_unsigned(25, 5) then
                vic_cursor_y <= cpu_dout(4 downto 0);
              end if;
            when x"3" =>
              vic_text_color <= cpu_dout;
            when x"4" =>
              vic_bg_color <= cpu_dout;
            when x"5" =>
              vic_text_attr <= cpu_dout;
            when x"6" =>
              vic_fb_bank <= cpu_dout(4 downto 0);   -- 640x400 framebuffer bank 0..31
            when others =>
              -- $9007 stays untouched: existing software treats it as the
              -- emulator's VIC interrupt-status register and writes frame
              -- acks there (the water demo does, every frame).
              null;
          end case;
        end if;
        -- Framebuffer backend select moved to the blitter window: $884C bit 0
        -- (1 = DDR3, 0 = board default). $9007 was the wrong home for it.
        if blit_wr = '1' and cpu_addr(3 downto 0) = x"C" then
          vic_fb_backend <= cpu_dout(0);
        end if;
      end if;
    end if;
  end process;

  process(cpu_addr, vic_cursor_x, vic_cursor_y, vic_text_color, vic_bg_color,
          vic_mode_reg, vic_text_attr, vic_fb_bank)
  begin
    case cpu_addr(3 downto 0) is
      when x"0" =>
        vic_reg_dout <= vic_mode_reg;
      when x"1" =>
        vic_reg_dout <= '0' & vic_cursor_x;
      when x"2" =>
        vic_reg_dout <= "000" & vic_cursor_y;
      when x"3" =>
        vic_reg_dout <= vic_text_color;
      when x"4" =>
        vic_reg_dout <= vic_bg_color;
      when x"5" =>
        vic_reg_dout <= vic_text_attr;
      when x"6" =>
        vic_reg_dout <= "000" & vic_fb_bank;
      when others =>
        vic_reg_dout <= x"00";
    end case;
  end process;

  -- VIC-II register file ($D000-$D03F): write-through array; reads return the
  -- live raster line for $D012 (low 8 bits) and $D011 (bit 7 = raster bit 8),
  -- else the stored value. $D020 = border, $D021 = background.
  process(clk)
  begin
    if rising_edge(clk) then
      if cpu_reset_n = '0' then
        vic2_regs <= (others => (others => '0'));
      elsif vic2_we = '1' then
        vic2_regs(to_integer(unsigned(cpu_addr(5 downto 0)))) <= cpu_dout;
      end if;
    end if;
  end process;
  vic2_dout <= vic_raster(7 downto 0) when cpu_addr(5 downto 0) = "010010" else        -- $D012
               vic_raster(8) & vic2_regs(16#11#)(6 downto 0)
                 when cpu_addr(5 downto 0) = "010001" else                              -- $D011
               vic2_regs(to_integer(unsigned(cpu_addr(5 downto 0))));

  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        mon_jump_vector <= (others => '0');
        mon_jump_reset_cnt <= 0;
        mon_jump_vector_active <= '0';
      else
        if monitor_jump_req = '1' then
          mon_jump_vector <= monitor_jump_addr;
          mon_jump_reset_cnt <= 16;
          mon_jump_vector_active <= '1';
        elsif mon_jump_reset_cnt > 0 then
          mon_jump_reset_cnt <= mon_jump_reset_cnt - 1;
        elsif mon_jump_vector_active = '1' and cpu_addr = x"FFFD" and cpu_sync = '0' then
          mon_jump_vector_active <= '0';
        end if;
      end if;
    end if;
  end process;

  decode_i : entity work.bus_decode
    port map (addr => cpu_addr, sel => dev_sel);

  cpu_i : entity work.t65_adapter
    port map (
      clk      => clk,
      reset_n  => cpu_reset_n,
      enable   => cpu_enable,
      rdy      => cpu_rdy,
      irq_n    => cpu_irq_n,
      nmi_n    => '1',
      data_in  => cpu_din,
      addr     => cpu_addr,
      data_out => cpu_dout,
      we       => cpu_we,
      sync     => cpu_sync
    );

  zp_ram_i : entity work.sync_ram
    generic map (ADDR_WIDTH => 14, ASYNC_READ => false)
    port map (clk => clk, we => zp_we_mux,
              addr => zp_addr_mux, din => zp_din_mux, dout => zp_dout);

  -- Main RAM is external DDR3 via ddr3_byte_bridge (instantiated at board top).
  -- This controller drives the bridge req/ack byte port:
  --   * CPU writes are captured into a one-deep latch the instant the strobe
  --     fires and drained to the bridge with priority (never lost / stretched).
  --   * CPU reads and monitor accesses issue a request and complete on ack;
  --     the requester stalls (cpu_rdy / mon FSM) until then.
  sram_acc_ctrl : process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        sram_busy        <= '0';
        sram_complete    <= '0';
        serving_mon      <= '0';
        serving_write    <= '0';
        sram_ext_req     <= '0';
        sram_ext_we      <= '0';
        sram_ext_addr    <= (others => '0');
        sram_ext_din     <= (others => '0');
        sram_rd_addr     <= (others => '0');
        sram_wr_pending  <= '0';
        sram_wr_addr     <= (others => '0');
        sram_wr_data     <= (others => '0');
        sram_wr_overflow <= '0';
      else
        sram_ext_req <= '0';

        -- Capture a CPU write the moment its strobe fires (independent of FSM
        -- state).  Spacing of 6502 stores far exceeds DDR latency, so the
        -- one-deep latch never overflows in practice; flag it if it ever does.
        if cpu_wr_strobe = '1' then
          if sram_wr_pending = '0' then
            sram_wr_pending <= '1';
            sram_wr_addr    <= cpu_addr(14 downto 0);
            sram_wr_data    <= cpu_dout;
          else
            sram_wr_overflow <= '1';
          end if;
        end if;

        if sram_busy = '0' then
          if sram_complete = '0' then
            if sram_wr_pending = '1' then
              -- drain queued write first (priority)
              sram_ext_req <= '1';
              sram_ext_we  <= '1';
              sram_ext_addr <= sram_wr_addr;
              sram_ext_din  <= sram_wr_data;
              sram_busy    <= '1';
              serving_mon  <= '0';
              serving_write <= '1';
            elsif cpu_rd_acc = '1' then
              sram_ext_req  <= '1';
              sram_ext_we   <= '0';
              sram_ext_addr <= cpu_addr(14 downto 0);
              sram_rd_addr  <= cpu_addr(14 downto 0);
              sram_busy     <= '1';
              serving_mon   <= '0';
              serving_write <= '0';
            elsif mon_acc = '1' then
              sram_ext_req  <= '1';
              sram_ext_we   <= mon_we_lat;
              sram_ext_addr <= mon_addr_lat(14 downto 0);
              sram_ext_din  <= mon_wdata_lat;
              sram_busy     <= '1';
              serving_mon   <= '1';
              serving_write <= '0';
            end if;
          end if;
        else
          if sram_ext_ack = '1' then
            sram_busy <= '0';
            if serving_write = '1' then
              -- write drain finished
              sram_wr_pending <= '0';
            else
              -- CPU read or monitor access finished
              sram_complete <= '1';
            end if;
          end if;
        end if;

        -- Release the completion flag once the requester has moved on.
        if sram_complete = '1' then
          if serving_mon = '1' then
            if mon_acc = '0' then
              sram_complete <= '0';
              serving_mon   <= '0';
            end if;
          elsif cpu_rd_acc = '0' or cpu_addr(14 downto 0) /= sram_rd_addr then
            sram_complete <= '0';
          end if;
        end if;
      end if;
    end if;
  end process;

  rom_i : entity work.boot_shadow_rom
    generic map (ADDR_WIDTH => 14, INIT_BUILTIN => ROM_INIT_BUILTIN)
    port map (
      clk       => clk,
      cpu_addr  => rom_addr_mux,
      cpu_dout  => rom_dout,
      load_we   => rom_load_we_mux,
      load_addr => rom_load_addr_mux,
      load_data => rom_load_data_mux
    );

  vram_i : entity work.sync_ram
    generic map (ADDR_WIDTH => 11, ASYNC_READ => false)
    port map (clk => clk, we => vram_we_mux,
              addr => vram_addr_mux, din => vram_din_mux, dout => vram_dout);

  -- The framebuffer no longer lives in BSRAM: it moved to DDR3 (vic_fb_ddr3 at
  -- the board top), which frees the ~19 BSRAM blocks the old 38400-byte fb_ram
  -- consumed so the DDR3 IP's own FIFOs can take BSRAM instead of spilling to
  -- registers. The CPU reaches the frame through the fbw_* req/ack port above;
  -- the VIC streams pixels through fb_frame_start/fb_line_adv/fb_rdaddr/fb_rddata.

  via_i : entity work.via6522
    port map (
      clk       => clk,
      reset_n   => cpu_reset_n,
      cs        => via_cs_mux,
      we        => via_we_mux,
      addr      => via_addr_mux,
      din       => via_din_mux,
      dout      => via_dout,
      porta_in  => (others => '0'),
      portb_in  => (others => '0'),
      porta_out => open,
      portb_out => via_portb,
      irq       => via_irq
    );

  -- Math coprocessor: signed 32x32 fixed-point multiplier ($88B0-$88BF).
  -- Off-loads the fixed-point multiply that dominates Mandelbrot/DSP code.
  math_i : entity work.math_copro
    port map (
      clk     => clk,
      reset_n => cpu_reset_n,
      cs      => math_cs,
      we      => math_we,
      addr    => cpu_addr(3 downto 0),
      din     => cpu_dout,
      dout    => math_dout
    );

  -- ── Test build: SD2/D64/raw-sector path removed ───────────────────────
  -- This deliberately disables LOAD/SAVE from the second SD card while checking
  -- whether the design places with the framebuffer/blitter changes.
  sd2_sec_read <= '0';
  sd2_sec_read_addr <= (others => '0');
  sd2_sec_write <= '0';
  sd2_sec_write_addr <= (others => '0');
  sd2_sec_write_data <= (others => '0');
  disk_dout <= x"FF";
  disk_irq <= '0';
  disk_sd2_sec_read <= '0';
  disk_sd2_sec_read_addr <= (others => '0');
  sdraw_dout <= x"FF";
  sdraw_irq <= '0';
  sdraw_sd2_sec_read <= '0';
  sdraw_sd2_sec_read_addr <= (others => '0');
  sdraw_sd2_sec_write <= '0';
  sdraw_sd2_sec_write_addr <= (others => '0');
  sdraw_sd2_sec_write_data <= (others => '0');

  -- ── Test build: sound chip/DAC/CIA audio timer removed ────────────────
  sound_dout <= x"FF";
  sid_dout <= x"FF";
  sid_sample <= (others => '0');
  cia1_dout <= x"FF";
  cia1_irq_n <= '1';
  dac_bck <= '0';
  dac_ws <= '0';
  dac_din <= '0';

  uart_i : entity work.uart6551
    port map (
      clk      => clk,
      reset_n  => cpu_reset_n,
      cs       => uart_cs_mux,
      we       => uart_we_mux,
      addr     => uart_addr_mux,
      din      => uart_din_mux,
      dout     => uart_dout,
      rx_data  => uart_rx_data,
      rx_valid => uart_rx_valid_cpu,
      tx_data  => uart_tx_data,
      tx_valid => uart_tx_valid,
      tx_busy  => uart_tx_busy,
      irq      => uart_irq
    );

  uart_rx_i : entity work.uart_rx_ser
    generic map (CLK_HZ => CLK_HZ, BAUD => BAUD)
    port map (
      clk     => clk,
      reset_n => cpu_reset_n,
      rx      => uart_rx,
      data    => uart_rx_data,
      valid   => uart_rx_valid
    );

  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        mon_mem_state <= M_IDLE;
        mon_addr_lat <= (others => '0');
        mon_wdata_lat <= (others => '0');
        mon_we_lat <= '0';
        mon_rdata_reg <= (others => '0');
        mon_ready_reg <= '0';
      else
        mon_ready_reg <= '0';
        case mon_mem_state is
          when M_IDLE =>
            if monitor_hold = '1' and monitor_mem_req = '1' then
              mon_addr_lat <= monitor_mem_addr;
              mon_wdata_lat <= monitor_mem_wdata;
              mon_we_lat <= monitor_mem_we;
              if in_range(monitor_mem_addr, ADDR_VIC_BMP_BASE, ADDR_VIC_BMP_LAST) then
                if monitor_mem_we = '1' then
                  mon_mem_state <= M_BITMAP_WR_WAIT;
                else
                  mon_mem_state <= M_BITMAP_RD_WAIT;
                end if;
              elsif is_rom_addr(monitor_mem_addr) then
                if monitor_mem_we = '1' then
                  mon_mem_state <= M_ROM_WR_WAIT;
                else
                  mon_mem_state <= M_ROM_RD_WAIT;
                end if;
              elsif unsigned(monitor_mem_addr) >= ADDR_VIC_TEXT_BASE and
                    unsigned(monitor_mem_addr) <= ADDR_VIC_TEXT_LAST then
                if monitor_mem_we = '1' then
                  mon_mem_state <= M_VRAM_WR_WAIT;
                else
                  mon_mem_state <= M_VRAM_RD_WAIT;
                end if;
              elsif unsigned(monitor_mem_addr) >= ADDR_VIA_BASE and
                    unsigned(monitor_mem_addr) <= ADDR_VIA_LAST then
                mon_mem_state <= M_VIA_WAIT;
              elsif unsigned(monitor_mem_addr) >= ADDR_UART_BASE and
                    unsigned(monitor_mem_addr) <= ADDR_UART_LAST then
                mon_mem_state <= M_UART_WAIT;
              elsif monitor_mem_addr(15) = '1' then
                mon_rdata_reg <= x"FF";
                mon_mem_state <= M_READY;
              elsif monitor_mem_addr(15 downto 14) = "00" then
                mon_mem_state <= M_ZP_WAIT;
              elsif monitor_mem_we = '1' then
                mon_mem_state <= M_SRAM_WAIT;
              else
                mon_mem_state <= M_SRAM_WAIT;
              end if;
            end if;

          when M_ZP_WAIT =>
            mon_mem_state <= M_ZP_READY;
          when M_ZP_READY =>
            mon_rdata_reg <= zp_dout;
            mon_mem_state <= M_READY;
          when M_SRAM_WAIT =>
            -- DDR3-backed: hold until the bridge access completes.
            if sram_complete = '1' then
              mon_mem_state <= M_SRAM_READY;
            end if;
          when M_SRAM_READY =>
            mon_rdata_reg <= sram_dout;  -- held by the bridge
            mon_mem_state <= M_READY;
          when M_ROM_RD_WAIT =>
            mon_mem_state <= M_ROM_RD_READY;
          when M_ROM_RD_READY =>
            mon_rdata_reg <= rom_dout;
            mon_mem_state <= M_READY;
          when M_ROM_WR_WAIT =>
            mon_mem_state <= M_READY;
          when M_VRAM_RD_WAIT =>
            mon_mem_state <= M_VRAM_RD_READY;
          when M_VRAM_RD_READY =>
            mon_rdata_reg <= vram_dout;
            mon_mem_state <= M_READY;
          when M_VRAM_WR_WAIT =>
            mon_mem_state <= M_READY;
          when M_BITMAP_RD_WAIT =>
            -- DDR3-backed: hold until the framebuffer controller completes.
            if fbw_complete = '1' then
              mon_mem_state <= M_BITMAP_RD_READY;
            end if;
          when M_BITMAP_RD_READY =>
            mon_rdata_reg <= bitmap_dout;  -- latched by fbw_acc_ctrl on ack
            mon_mem_state <= M_READY;
          when M_BITMAP_WR_WAIT =>
            if fbw_complete = '1' then
              mon_mem_state <= M_READY;
            end if;
          when M_VIA_WAIT =>
            mon_mem_state <= M_VIA_READY;
          when M_VIA_READY =>
            mon_rdata_reg <= via_dout;
            mon_mem_state <= M_READY;
          when M_UART_WAIT =>
            mon_mem_state <= M_UART_READY;
          when M_UART_READY =>
            mon_rdata_reg <= uart_dout;
            mon_mem_state <= M_READY;
          when M_READY =>
            mon_ready_reg <= '1';
            mon_mem_state <= M_IDLE;
          when others =>
            mon_mem_state <= M_IDLE;
        end case;
      end if;
    end if;
  end process;

  uart_kbd_g : if not USE_USB_HID generate
    uart_kbd_i : entity work.uart_keyboard
      port map (
        clk            => clk,
        reset_n        => reset_n,
        rx_data        => uart_rx_data,
        rx_valid       => uart_rx_valid_cpu,
        cs             => usb_cs,
        we             => cpu_bus_we,
        addr           => cpu_addr(1 downto 0),
        dout           => usb_dout,
        irq            => usb_irq,
        diag_connected => usb_connected,
        diag_keycode   => usb_keycode,
        diag_modif     => usb_modif,
        diag_ascii     => kbd_ascii_i,
        diag_phase     => usb_phase,
        diag_key_event => kbd_event_tog_i,
        diag_polling   => usb_polling
      );
  end generate;

  usb_hid_g : if USE_USB_HID generate
    usb_hid_i : entity work.usb_hid_host
      port map (
        clk            => clk,
        reset_n        => reset_n,
        usb_clk        => usb_clk,
        usb_dm         => usb_dm,
        usb_dp         => usb_dp,
        cs             => usb_cs,
        we             => cpu_bus_we,
        addr           => cpu_addr(1 downto 0),
        dout           => usb_dout,
        irq            => usb_irq,
        diag_connected => usb_connected,
        diag_keycode   => usb_keycode,
        diag_modif     => usb_modif,
        diag_ascii     => kbd_ascii_i,
        diag_phase     => usb_phase,
        diag_key_event => kbd_event_tog_i,
        diag_polling   => usb_polling
      );
  end generate;

  usb_ascii     <= kbd_ascii_i;
  usb_key_event <= kbd_event_tog_i;

  -- Bus-capture feature removed (was ULPI-specific); tie off outputs.
  usb_cap_data  <= (others => '0');
  usb_cap_ready <= '0';

  char_i : entity work.char_rom
    port map (addr => char_addr, glyph_hi => char_glyph_hi, dout => char_data);

  vic_i : entity work.vic_vga
    generic map (
      CLK_DIV => VIC_CLK_DIV,
      CURSOR_BLINK_DIV => CLK_HZ / 2,
      CEA_480P => CEA_480P,
      VGA_640  => VGA_640
    )
    port map (
      clk          => clk,
      reset_n      => reset_n,
      vic_addr     => vic_addr,
      vram_data    => vram_data_mux,
      vic_stealing => vic_stealing,
      char_addr    => char_addr,
      char_glyph_hi => char_glyph_hi,
      char_data    => char_data,
      cursor_x     => vic_cursor_x,
      cursor_y     => vic_cursor_y,
      cursor_enable => '1',
      bitmap_mode      => vic_mode_reg(0),
      color256_mode    => vic_mode_reg(1),
      color64_mode     => vic_mode_reg(3),
      -- Mode bit 4 now selects the DDR3 320x200 8bpp framebuffer (was the
      -- BSRAM-backed 320x240 4bpp color16 mode, retired with fb_ram); mode bit 5
      -- selects the 640x400 8bpp hi-res framebuffer (same DDR3 controller).
      color16_mode     => '0',
      fb_ddr3_mode     => vic_mode_reg(4),
      fb_hires_mode    => fb_hires_mode,
      fb_true_mode     => fb_true_mode,
      cell_bg_mode     => vic_text_attr(0),
      text80_mode      => vic_text_attr(1),
      underline_mode   => vic_text_attr(2),
      text_color       => vic_text_color(3 downto 0),
      border_color     => vic2_regs(16#20#)(3 downto 0),
      bg_color         => vic2_regs(16#21#)(3 downto 0),
      raster           => vic_raster,
      vic_fetch_bitmap => vic_fetch_bitmap,
      vga_hs       => vga_hs,
      vga_vs       => vga_vs,
      vga_de       => vga_de,
      vga_r        => vga_r,
      vga_g        => vga_g,
      vga_b        => vga_b,
      -- DDR3 framebuffer streaming to/from vic_fb_ddr3 (at the board top).
      fb_frame_start => fb_frame_start,
      fb_line_adv    => fb_line_adv,
      fb_rdaddr      => fb_rdaddr,
      fb_rddata      => fb_rddata
    );

  dbg_cpu_addr <= cpu_addr;
  dbg_cpu_data <= cpu_dout;
  dbg_cpu_din  <= cpu_din;
  dbg_cpu_we   <= cpu_bus_we;
  dbg_cpu_sync <= cpu_sync;
end architecture;
