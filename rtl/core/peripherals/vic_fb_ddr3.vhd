-- DDR3 framebuffer controller for the VIC 8bpp / 16bpp bitmap modes.
--
-- Three display geometries share ONE controller (there is only one DDR3 app port;
-- a second master would need an arbiter):
--   * legacy 320x200 8bpp RGB332, shown 2x2  -> $9000 bit 4  (hires=0, bpp16=0)
--   * hi-res 640x400 8bpp RGB332, shown 1:1   -> $9000 bit 5  (hires=1, bpp16=0)
--   * true  320x200 16bpp RGB565, shown 2x2   -> $9000 bit 6  (hires=0, bpp16=1)
-- The three frames live in DIFFERENT DDR3 regions (FB_BASE_WORD / HIRES_BASE_WORD
-- / TRUE_BASE_WORD) so switching modes does not clobber the other images.
--
-- (A 240-line full-height flag was prototyped on top of this and backed out; it
-- only helped RGB565 and needs the DDR3 properly constrained. RGB565 itself costs
-- one extra BSRAM block for the 16-bit line buffer -- keep an eye on the marginal
-- DDR3 calibration.)
--
-- The double line buffer holds ONE 16-bit entry per pixel (widest = 640/half):
-- 8bpp modes store the pixel byte in the low 8 bits (RGB332), the 16bpp mode
-- stores the full RGB565 word. The display read returns the 16-bit entry; vic_vga
-- picks RGB332 (bits 7:0) or RGB565 (bits 15:0) per mode.
--
-- Backend: the Gowin "DDR3 Memory Interface" IP (DDR3_Memory_Interface_Top) in
-- the x16 / 128-bit user configuration (same IP/PLL/pins as the c64_ddr project).
-- 1:4 clock ratio -> BL8 = 8x 16-bit words = 128-bit user beat = 16 bytes,
-- app-style interface (cmd/cmd_en/cmd_rdy, wr_data/wr_data_mask/wr_data_en/
-- wr_data_end/wr_data_rdy, rd_data/rd_data_valid). The IP auto-refreshes.
--
-- Pixel mapping: a BL8 burst is 16 bytes = 16 pixels (8bpp) or 8 pixels (16bpp).
--   app_addr (16-bit words) = ((base+byteAddr)[.. : 4]) & "000"
--   lane = byteAddr[3:0]  (byte within the 128-bit beat; CPU byte ops only)
-- All frame bases are 16-byte aligned. A CPU access is a byte op: the pixel
-- index is a BYTE index (16bpp writes two bytes, low then high). Writes are MASKED
-- single-byte writes (no read-modify-write, so a marginal DDR3 read can't smear
-- neighbour bytes). A scanline prefetch reads bytes_per_line/16 bursts.
--
-- Two masters, arbitrated on clk_x1: line-fetch has priority over the CPU.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity vic_fb_ddr3 is
  generic (
    FB_BASE_WORD    : natural  := 0;       -- byte base of the 320x200 8bpp frame
    LINE_PIX        : positive := 320;     -- legacy pixels per scanline (mult of 16)
    NUM_LINES       : positive := 200;
    -- Hi-res 640x400 8bpp frame. HIRES_LINE_PIX must be 2*LINE_PIX.
    HIRES_BASE_WORD : natural  := 262144;  -- byte base of the 640x400 frame (0x40000)
    HIRES_LINE_PIX  : positive := 640;
    HIRES_NUM_LINES : positive := 400;
    -- True-colour 320x200 16bpp (RGB565) frame; same geometry as the 320x200 8bpp
    -- one but 2 bytes/pixel, so LINE_PIX*NUM_LINES*2 bytes.
    TRUE_BASE_WORD  : natural  := 524288;  -- byte base of the 320x200 16bpp frame (0x80000)
    APP_ADDR_BITS   : positive := 27       -- Gowin IP word-address width (x16 IP: 27)
  );
  port (
    -- ---- clk_sys (6502 / display) side --------------------------------------
    clk_sys   : in  std_logic;
    rst_sys_n : in  std_logic;

    hires     : in  std_logic := '0';                    -- '1' = 640x400 8bpp
    bpp16     : in  std_logic := '0';                    -- '1' = 320x200 16bpp RGB565

    fb_frame_start : in  std_logic;                      -- pulse at frame start
    fb_line_adv    : in  std_logic;                      -- pulse per logical line
    fb_rdaddr      : in  std_logic_vector(10 downto 0);  -- (disp_line mod 2)*640 + col
    fb_rddata      : out std_logic_vector(15 downto 0);  -- RGB565 (16bpp) / low 8 = RGB332

    cpu_req   : in  std_logic;
    cpu_we    : in  std_logic;
    cpu_addr  : in  std_logic_vector(17 downto 0);       -- byte index into the frame
    cpu_din   : in  std_logic_vector(7 downto 0);
    cpu_dout  : out std_logic_vector(7 downto 0);
    cpu_ack   : out std_logic;

    -- ---- hardware 2D blitter command interface (clk_sys) ---------------------
    -- Registers are held stable by the CPU; blit_start is a 1-cycle pulse that
    -- launches the op. The engine runs in clk_x1 and streams pixel writes to the
    -- app port as a third master (priority: line-fetch > blitter > CPU byte op).
    blit_op    : in  std_logic_vector(2 downto 0) := (others => '0');
    blit_x0    : in  unsigned(9 downto 0) := (others => '0');
    blit_y0    : in  unsigned(9 downto 0) := (others => '0');
    blit_x1    : in  unsigned(9 downto 0) := (others => '0');
    blit_y1    : in  unsigned(9 downto 0) := (others => '0');
    blit_color : in  std_logic_vector(7 downto 0) := (others => '0');
    blit_page  : in  std_logic := '0';
    blit_gap_cfg : in std_logic_vector(7 downto 0) := x"0C";  -- write pacing ($884B)
    blit_dstx  : in  unsigned(9 downto 0) := (others => '0'); -- COPY destination
    blit_dsty  : in  unsigned(9 downto 0) := (others => '0');
    blit_tex_base  : in  unsigned(17 downto 0) := (others => '0');
    blit_tex_u0    : in  signed(15 downto 0) := (others => '0');
    blit_tex_v0    : in  signed(15 downto 0) := (others => '0');
    blit_tex_dudx  : in  signed(15 downto 0) := (others => '0');
    blit_tex_dvdx  : in  signed(15 downto 0) := (others => '0');
    blit_tex_dudy  : in  signed(15 downto 0) := (others => '0');
    blit_tex_dvdy  : in  signed(15 downto 0) := (others => '0');
    blit_tex_flags : in  std_logic_vector(7 downto 0) := (others => '0');
    blit_start : in  std_logic := '0';
    blit_busy  : out std_logic;

    -- ---- clk_x1 = Gowin DDR3 IP clk_out (app interface, 128-bit) -------------
    clk_x1          : in  std_logic;
    calib_done      : in  std_logic;
    app_cmd_rdy     : in  std_logic;
    app_cmd         : out std_logic_vector(2 downto 0);
    app_cmd_en      : out std_logic;
    app_addr        : out std_logic_vector(APP_ADDR_BITS-1 downto 0);
    app_wdata       : out std_logic_vector(127 downto 0);
    app_wdata_mask  : out std_logic_vector(15 downto 0);
    app_wren        : out std_logic;
    app_wdata_end   : out std_logic;
    app_wdata_rdy   : in  std_logic;
    app_rdata       : in  std_logic_vector(127 downto 0);
    app_rdata_valid : in  std_logic
  );
end entity;

architecture rtl of vic_fb_ddr3 is

  constant CMD_WRITE : std_logic_vector(2 downto 0) := "000";
  constant CMD_READ  : std_logic_vector(2 downto 0) := "001";
  constant HALF      : natural := HIRES_LINE_PIX;   -- line-buffer stride (widest)

  -- Double line buffer: 2 halves x HALF pixels, ONE 16-bit entry per pixel, dual-
  -- clock block RAM (write clk_x1 fill, read clk_sys registered). 8bpp modes store
  -- the pixel byte in bits 7:0, the 16bpp mode stores the full RGB565 word.
  type lbuf_t is array (0 to 2*HALF - 1) of std_logic_vector(15 downto 0);
  signal lbuf : lbuf_t := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of lbuf : signal is "block";

  -- CDC sys->x1 single-bit toggles
  signal fs_tgl_sys  : std_logic := '0';
  signal adv_tgl_sys : std_logic := '0';
  signal cpu_tgl_sys : std_logic := '0';
  signal fs_tgl_x1   : std_logic_vector(2 downto 0) := (others => '0');
  signal adv_tgl_x1  : std_logic_vector(2 downto 0) := (others => '0');
  signal cpu_tgl_x1  : std_logic_vector(2 downto 0) := (others => '0');

  -- mode selects, synchronised into clk_x1 (static while drawing)
  signal hires_x1    : std_logic_vector(2 downto 0) := (others => '0');
  signal bpp16_x1    : std_logic_vector(2 downto 0) := (others => '0');

  -- CDC x1->sys ack toggle
  signal ack_tgl_x1  : std_logic := '0';
  signal ack_tgl_sys : std_logic_vector(2 downto 0) := (others => '0');
  signal cpu_dout_x1 : std_logic_vector(7 downto 0) := (others => '0');

  signal cpu_busy_sys : std_logic := '0';
  signal cpu_dout_reg : std_logic_vector(7 downto 0) := (others => '0');

  type st_t is (S_CALIB, S_IDLE, S_SELECT,
                S_FILL_REQ, S_FILL_WAIT, S_FILL_STORE,
                S_CW_RDREQ, S_CW_RDWAIT, S_CW_WRREQ, S_CW_WRDATA,
                S_CR_REQ,   S_CR_WAIT,
                S_BLIT_WRREQ, S_BLIT_WRDATA, S_BLIT_WAIT,
                S_BLITRD_REQ, S_BLITRD_WAIT, S_BLITRD_ACK);
  signal st : st_t := S_CALIB;
  signal cw_data : std_logic_vector(127 downto 0) := (others => '0');

  signal disp_idx   : unsigned(8 downto 0) := (others => '0');
  type half_line_t is array (0 to 1) of unsigned(8 downto 0);
  signal half_line  : half_line_t := (others => (others => '0'));
  signal half_valid : std_logic_vector(1 downto 0) := (others => '0');
  signal cur_line   : unsigned(8 downto 0) := (others => '0');
  signal cur_half   : std_logic := '0';
  signal col        : natural range 0 to HIRES_LINE_PIX := 0;   -- pixel column
  signal fetch_cur_need  : std_logic := '0';
  signal fetch_next_need : std_logic := '0';
  signal fetch_cur_line  : unsigned(8 downto 0) := (others => '0');
  signal fetch_next_line : unsigned(8 downto 0) := (others => '0');
  signal fetch_cur_half  : std_logic := '0';
  signal fetch_next_half : std_logic := '0';
  signal fill_data  : std_logic_vector(127 downto 0) := (others => '0');
  signal store_idx  : natural range 0 to 15 := 0;   -- byte index within the burst
  signal lo_latch   : std_logic_vector(7 downto 0) := (others => '0');  -- 16bpp low byte

  signal cpu_pending : std_logic := '0';
  signal cpu_op_we   : std_logic := '0';
  signal cpu_op_addr : std_logic_vector(17 downto 0) := (others => '0');
  signal cpu_op_din  : std_logic_vector(7 downto 0) := (others => '0');
  signal cpu_lane    : natural range 0 to 15 := 0;

  signal wd_cnt   : unsigned(13 downto 0) := (others => '0');

  -- CPU framebuffer write-combine buffer. While dirty, CPU writes to the same
  -- 16-byte burst are absorbed here and acknowledged immediately; before any
  -- conflicting access the whole burst is written back unmasked.
  signal cpu_wc_dirty : std_logic := '0';
  signal cpu_wc_addr  : std_logic_vector(13 downto 0) := (others => '0');

  -- ---- hardware blitter (engine runs in clk_x1) ----
  signal blit_we      : std_logic;
  signal blit_addr    : std_logic_vector(17 downto 0);   -- byte index (y*640+x)
  signal blit_data    : std_logic_vector(7 downto 0);
  signal blit_ready   : std_logic := '0';
  signal blit_busy_x1 : std_logic;
  -- COPY source read channel + one-burst read cache. The copy walks the
  -- source sequentially, so caching the last 16-byte burst turns ~15 of 16
  -- reads into same-cycle hits. The cache is invalidated whenever any write
  -- path touches its burst (rare during a direction-correct copy).
  signal blit_rd         : std_logic;
  signal blit_rd_addr    : std_logic_vector(17 downto 0);
  signal blit_rdata_r    : std_logic_vector(7 downto 0) := (others => '0');
  signal blit_rd_ready_r : std_logic := '0';
  signal rc_valid : std_logic := '0';
  signal rc_addr  : std_logic_vector(13 downto 0) := (others => '0');
  signal rc_data  : std_logic_vector(127 downto 0) := (others => '0');
  -- start-pulse CDC: clk_sys toggle -> clk_x1 edge; busy CDC: clk_x1 -> clk_sys.
  -- clk_sys and clk_x1 are declared asynchronous clock groups in the board SDC,
  -- so only the toggle/level synchronisers below cross domains.
  signal blit_start_tgl_sys : std_logic := '0';
  signal blit_start_tgl_x1  : std_logic_vector(2 downto 0) := (others => '0');
  signal blit_busy_sync     : std_logic_vector(2 downto 0) := (others => '0');
  -- clk_x1 capture of the quasi-static command registers. They are written by
  -- the CPU before the trigger and held stable until busy clears (the register
  -- file's sticky busy guarantees it), so capturing them on the synchronised
  -- start edge is safe -- and the engine's inputs then never cross domains.
  signal bl_op_x1    : std_logic_vector(2 downto 0) := (others => '0');
  signal bl_x0_x1    : unsigned(9 downto 0) := (others => '0');
  signal bl_y0_x1    : unsigned(9 downto 0) := (others => '0');
  signal bl_x1_x1    : unsigned(9 downto 0) := (others => '0');
  signal bl_y1_x1    : unsigned(9 downto 0) := (others => '0');
  signal bl_color_x1 : std_logic_vector(7 downto 0) := (others => '0');
  signal bl_dstx_x1  : unsigned(9 downto 0) := (others => '0');
  signal bl_dsty_x1  : unsigned(9 downto 0) := (others => '0');
  signal bl_tex_base_x1  : unsigned(17 downto 0) := (others => '0');
  signal bl_tex_u0_x1    : signed(15 downto 0) := (others => '0');
  signal bl_tex_v0_x1    : signed(15 downto 0) := (others => '0');
  signal bl_tex_dudx_x1  : signed(15 downto 0) := (others => '0');
  signal bl_tex_dvdx_x1  : signed(15 downto 0) := (others => '0');
  signal bl_tex_dudy_x1  : signed(15 downto 0) := (others => '0');
  signal bl_tex_dvdy_x1  : signed(15 downto 0) := (others => '0');
  signal bl_tex_flags_x1 : std_logic_vector(7 downto 0) := (others => '0');
  signal blit_go     : std_logic := '0';
  -- pixel latched while the combine buffer is being flushed for it
  signal blit_lat_addr : std_logic_vector(17 downto 0) := (others => '0');
  signal blit_lat_data : std_logic_vector(7 downto 0) := (others => '0');
  -- Write-combine buffer: pixels that fall into the same 16-byte burst are
  -- collected here and written to DDR3 as ONE masked write. Back-to-back
  -- masked single-byte writes to the SAME burst were dropped by the DDR3
  -- backend under load (visible as broken shallow lines / dashed fills, while
  -- steep lines -- one burst per pixel -- stayed clean). Combining removes
  -- that access pattern entirely and cuts blit DDR3 writes up to 16x.
  -- The buffer flushes when a pixel targets a different burst, and lazily
  -- (next arbiter visit) once the engine goes idle.
  signal wc_valid : std_logic := '0';
  signal wc_pend  : std_logic := '0';                        -- flush, then load lat pixel
  signal wc_addr  : std_logic_vector(13 downto 0) := (others => '0');  -- addr(17:4)
  signal wc_data  : std_logic_vector(127 downto 0) := (others => '0');
  signal wc_mask  : std_logic_vector(15 downto 0) := (others => '1');
  -- Pacing between blit writes: sustained back-to-back masked writes are a load
  -- profile the DDR3 write FIFOs never see from the (sparse) CPU path, and on
  -- hardware they showed periodically dropped bytes. The gap gives the IP the
  -- same breathing room the proven CPU path has; the display fetch and the CPU
  -- keep full access to the arbiter while the gap runs. The value comes from
  -- blit register $884B (captured with the command) so drop-out experiments can
  -- be tuned from software without re-synthesis; it resets to 12.
  signal bl_gap_x1 : unsigned(7 downto 0) := x"0C";   -- captured $884B
  signal blit_gap  : unsigned(7 downto 0) := (others => '0');

  -- app word address (16-bit words) for a byte offset within a 16-byte-aligned
  -- frame base. lane = byte within the beat.
  function burst_addr(base : natural; byteoff : natural) return std_logic_vector is
    variable ba : unsigned(24 downto 0);
  begin
    ba := to_unsigned(base + byteoff, 25);
    return std_logic_vector(resize(ba(24 downto 4) & "000", APP_ADDR_BITS));
  end function;

  function lane_of(byteoff : natural) return natural is
    variable ba : unsigned(24 downto 0);
  begin
    ba := to_unsigned(byteoff, 25);
    return to_integer(ba(3 downto 0));
  end function;

begin

  -- Blitter engine (runs in the DDR3 app clock domain). Its command registers
  -- are quasi-static (held by the CPU across a whole op), launched by the CDC'd
  -- start pulse; it streams pixel writes which the FSM below turns into masked
  -- app-port byte writes.
  blit_i : entity work.vic_blit
    generic map (LINE_PIX => HIRES_LINE_PIX, ADDR_BITS => 18)
    port map (
      clk       => clk_x1,
      rst_n     => rst_sys_n,
      op        => bl_op_x1,
      x0        => bl_x0_x1,
      y0        => bl_y0_x1,
      x1        => bl_x1_x1,
      y1        => bl_y1_x1,
      color     => bl_color_x1,
      dst_x     => bl_dstx_x1,
      dst_y     => bl_dsty_x1,
      tex_base  => bl_tex_base_x1,
      tex_u0    => bl_tex_u0_x1,
      tex_v0    => bl_tex_v0_x1,
      tex_dudx  => bl_tex_dudx_x1,
      tex_dvdx  => bl_tex_dvdx_x1,
      tex_dudy  => bl_tex_dudy_x1,
      tex_dvdy  => bl_tex_dvdy_x1,
      tex_flags => bl_tex_flags_x1,
      start     => blit_go,
      busy      => blit_busy_x1,
      fbo_we    => blit_we,
      fbo_addr  => blit_addr,
      fbo_data  => blit_data,
      fbo_ready => blit_ready,
      fbi_re    => blit_rd,
      fbi_addr  => blit_rd_addr,
      fbi_data  => blit_rdata_r,
      fbi_ready => blit_rd_ready_r);

  blit_busy <= blit_busy_sync(2);

  -- display read (registered, clk_sys)
  process(clk_sys)
  begin
    if rising_edge(clk_sys) then
      fb_rddata <= lbuf(to_integer(unsigned(fb_rdaddr)));
    end if;
  end process;

  cpu_dout <= cpu_dout_reg;

  -- clk_sys: pulse->toggle, CPU req/ack handshake
  process(clk_sys)
  begin
    if rising_edge(clk_sys) then
      if rst_sys_n = '0' then
        fs_tgl_sys <= '0'; adv_tgl_sys <= '0'; cpu_tgl_sys <= '0';
        cpu_busy_sys <= '0'; ack_tgl_sys <= (others => '0');
        cpu_ack <= '0'; cpu_dout_reg <= (others => '0');
        blit_start_tgl_sys <= '0'; blit_busy_sync <= (others => '0');
      else
        cpu_ack <= '0';
        ack_tgl_sys <= ack_tgl_sys(1 downto 0) & ack_tgl_x1;
        blit_busy_sync <= blit_busy_sync(1 downto 0) & blit_busy_x1;
        if blit_start = '1' then
          blit_start_tgl_sys <= not blit_start_tgl_sys;
        end if;
        if fb_frame_start = '1' then fs_tgl_sys  <= not fs_tgl_sys;  end if;
        if fb_line_adv   = '1' then adv_tgl_sys <= not adv_tgl_sys; end if;
        if cpu_busy_sys = '0' then
          if cpu_req = '1' then
            cpu_tgl_sys  <= not cpu_tgl_sys;
            cpu_busy_sys <= '1';
          end if;
        else
          if ack_tgl_sys(2) /= ack_tgl_sys(1) then
            cpu_dout_reg <= cpu_dout_x1;
            cpu_ack      <= '1';
            cpu_busy_sys <= '0';
          end if;
        end if;
      end if;
    end if;
  end process;

  -- clk_x1: main FSM (Gowin IP app interface, 128-bit)
  process(clk_x1, rst_sys_n)
    variable ln     : natural range 0 to 15;
    variable ew     : std_logic;               -- effective 640-wide (hires, not 16bpp)
    variable b16    : std_logic;               -- effective 16bpp
    variable nlines : natural;                 -- active line count (200 / 400)
    variable lp     : natural;                 -- active line width in pixels (320/640)
    variable base   : natural;                 -- active frame byte base
    variable advance: natural;                 -- pixels covered per burst (16 / 8)
    variable lstart : natural;                 -- cur_line * lp (pixels)
    variable pixoff : natural;                 -- pixel offset in the frame
    variable byteoff: natural;                 -- byte offset in the frame
    variable hidx   : natural range 0 to 1;
    variable nidx   : natural range 0 to 1;
  begin
    if rst_sys_n = '0' then
      st <= S_CALIB;
      app_cmd <= CMD_READ; app_cmd_en <= '0';
      app_addr <= (others => '0'); app_wren <= '0'; app_wdata_end <= '0';
      app_wdata <= (others => '0'); app_wdata_mask <= (others => '0');
      disp_idx <= (others => '0');
      half_line <= (others => (others => '0'));
      half_valid <= (others => '0');
      cur_line <= (others => '0'); cur_half <= '0'; col <= 0;
      fetch_cur_need <= '0'; fetch_next_need <= '0';
      fetch_cur_line <= (others => '0'); fetch_next_line <= (others => '0');
      fetch_cur_half <= '0'; fetch_next_half <= '0';
      fill_data <= (others => '0'); store_idx <= 0; lo_latch <= (others => '0');
      cpu_pending <= '0'; cpu_op_we <= '0';
      cpu_op_addr <= (others => '0'); cpu_op_din <= (others => '0');
      cpu_lane <= 0; cpu_dout_x1 <= (others => '0'); ack_tgl_x1 <= '0';
      cpu_wc_dirty <= '0'; cpu_wc_addr <= (others => '0');
      wd_cnt <= (others => '0');
      fs_tgl_x1 <= (others => '0'); adv_tgl_x1 <= (others => '0');
      cpu_tgl_x1 <= (others => '0');
      hires_x1 <= (others => '0'); bpp16_x1 <= (others => '0');
      blit_start_tgl_x1 <= (others => '0');
      blit_ready <= '0'; blit_go <= '0';
      bl_op_x1 <= (others => '0'); bl_color_x1 <= (others => '0');
      bl_x0_x1 <= (others => '0'); bl_y0_x1 <= (others => '0');
      bl_x1_x1 <= (others => '0'); bl_y1_x1 <= (others => '0');
      blit_lat_addr <= (others => '0'); blit_lat_data <= (others => '0');
      blit_gap <= (others => '0'); bl_gap_x1 <= x"0C";
      wc_valid <= '0'; wc_pend <= '0'; wc_addr <= (others => '0');
      wc_data <= (others => '0'); wc_mask <= (others => '1');
      bl_dstx_x1 <= (others => '0'); bl_dsty_x1 <= (others => '0');
      bl_tex_base_x1 <= (others => '0'); bl_tex_flags_x1 <= (others => '0');
      bl_tex_u0_x1 <= (others => '0'); bl_tex_v0_x1 <= (others => '0');
      bl_tex_dudx_x1 <= (others => '0'); bl_tex_dvdx_x1 <= (others => '0');
      bl_tex_dudy_x1 <= (others => '0'); bl_tex_dvdy_x1 <= (others => '0');
      blit_rdata_r <= (others => '0'); blit_rd_ready_r <= '0';
      rc_valid <= '0'; rc_addr <= (others => '0'); rc_data <= (others => '0');
    elsif rising_edge(clk_x1) then
      app_cmd_en <= '0'; app_wren <= '0'; app_wdata_end <= '0';  -- 1-cycle pulses
      blit_ready <= '0'; blit_go <= '0'; blit_rd_ready_r <= '0';

      fs_tgl_x1  <= fs_tgl_x1(1 downto 0)  & fs_tgl_sys;
      adv_tgl_x1 <= adv_tgl_x1(1 downto 0) & adv_tgl_sys;
      cpu_tgl_x1 <= cpu_tgl_x1(1 downto 0) & cpu_tgl_sys;
      hires_x1   <= hires_x1(1 downto 0)   & hires;
      bpp16_x1   <= bpp16_x1(1 downto 0)   & bpp16;
      blit_start_tgl_x1 <= blit_start_tgl_x1(1 downto 0) & blit_start_tgl_sys;

      -- blit command: capture the (quasi-static, sticky-busy-guarded) registers
      -- into this domain on the synchronised start edge, then kick the engine.
      if blit_start_tgl_x1(2) /= blit_start_tgl_x1(1) then
        bl_op_x1    <= blit_op;
        bl_x0_x1    <= blit_x0;
        bl_y0_x1    <= blit_y0;
        bl_x1_x1    <= blit_x1;
        bl_y1_x1    <= blit_y1;
        bl_color_x1 <= blit_color;
        bl_dstx_x1  <= blit_dstx;
        bl_dsty_x1  <= blit_dsty;
        bl_tex_base_x1 <= blit_tex_base;
        bl_tex_u0_x1 <= blit_tex_u0;
        bl_tex_v0_x1 <= blit_tex_v0;
        bl_tex_dudx_x1 <= blit_tex_dudx;
        bl_tex_dvdx_x1 <= blit_tex_dvdx;
        bl_tex_dudy_x1 <= blit_tex_dudy;
        bl_tex_dvdy_x1 <= blit_tex_dvdy;
        bl_tex_flags_x1 <= blit_tex_flags;
        bl_gap_x1   <= unsigned(blit_gap_cfg);
        blit_go     <= '1';
      end if;

      -- active geometry from the synced mode selects (modes are exclusive).
      b16 := bpp16_x1(2);
      ew  := hires_x1(2) and not b16;
      -- Each 16-byte burst covers 16 pixels in 8bpp, 8 pixels in 16bpp; the fill
      -- always walks 16 bytes (store_idx 0..15) so every fill_data slice is bounded.
      if b16 = '1' then
        base := TRUE_BASE_WORD;  lp := LINE_PIX;       nlines := NUM_LINES;
        advance := 8;
      elsif ew = '1' then
        base := HIRES_BASE_WORD; lp := HIRES_LINE_PIX; nlines := HIRES_NUM_LINES;
        advance := 16;
      else
        base := FB_BASE_WORD;    lp := LINE_PIX;       nlines := NUM_LINES;
        advance := 16;
      end if;

      if cpu_tgl_x1(2) /= cpu_tgl_x1(1) then cpu_pending <= '1'; end if;

      if fs_tgl_x1(2) /= fs_tgl_x1(1) then
        disp_idx <= (others => '0'); half_valid <= (others => '0');
      elsif adv_tgl_x1(2) /= adv_tgl_x1(1) then
        if to_integer(disp_idx) + 1 < nlines then disp_idx <= disp_idx + 1; end if;
      end if;

      if st = S_IDLE or st = S_CALIB then wd_cnt <= (others => '0');
      else wd_cnt <= wd_cnt + 1; end if;

      if blit_gap /= 0 then blit_gap <= blit_gap - 1; end if;

      case st is
        when S_CALIB =>
          if calib_done = '1' then st <= S_IDLE; end if;

        when S_IDLE =>
          -- Register line-buffer miss checks before arbitrating.  This keeps
          -- disp_idx/half_line comparisons out of the same 100 MHz path that
          -- drives the FSM state and DDR command request.
          hidx := to_integer(disp_idx(0 downto 0));
          nidx := 1 - hidx;
          fetch_cur_line <= disp_idx;
          fetch_cur_half <= disp_idx(0);
          if half_valid(hidx) = '0' or half_line(hidx) /= disp_idx then
            fetch_cur_need <= '1';
          else
            fetch_cur_need <= '0';
          end if;
          if to_integer(disp_idx) + 1 < nlines then
            fetch_next_line <= disp_idx + 1;
            fetch_next_half <= not disp_idx(0);
            if half_valid(nidx) = '0' or half_line(nidx) /= disp_idx + 1 then
              fetch_next_need <= '1';
            else
              fetch_next_need <= '0';
            end if;
          else
            fetch_next_line <= disp_idx;
            fetch_next_half <= not disp_idx(0);
            fetch_next_need <= '0';
          end if;
          st <= S_SELECT;

        when S_SELECT =>
          -- Default: bounce back to S_IDLE so the registered fetch-need flags
          -- are refreshed every other cycle. Without this the FSM idled here
          -- with STALE flags until the 16384-cycle watchdog (~5 scanlines) and
          -- the display repeated stale lines -- visible as broken shallow
          -- wireframe edges. Dispatch branches below override the bounce.
          st <= S_IDLE;
          if cpu_wc_dirty = '1' and (fetch_cur_need = '1' or fetch_next_need = '1') then
            -- Display fetch must see the latest CPU pixels, so commit the
            -- buffered burst before servicing the line-buffer miss.
            st <= S_CW_WRREQ;
          elsif fetch_cur_need = '1' then
            cur_line <= fetch_cur_line; cur_half <= fetch_cur_half; col <= 0;
            blit_gap <= bl_gap_x1;   -- read->write turnaround guard: space the
                                     -- first blit write after a fetch burst
            st <= S_FILL_REQ;
          elsif fetch_next_need = '1' then
            cur_line <= fetch_next_line; cur_half <= fetch_next_half; col <= 0;
            blit_gap <= bl_gap_x1;
            st <= S_FILL_REQ;
          elsif cpu_wc_dirty = '1' and blit_we = '1' then
            -- Keep the blitter and CPU byte window coherent in DDR3.
            st <= S_CW_WRREQ;
          elsif blit_we = '1' then
            -- any blit write into the read-cached burst invalidates the cache
            if rc_valid = '1' and blit_addr(17 downto 4) = rc_addr then
              rc_valid <= '0';
            end if;
            if wc_valid = '1' and blit_addr(17 downto 4) = wc_addr then
              -- same burst: merge into the combine buffer, no DDR3 traffic
              ln := lane_of(to_integer(unsigned(blit_addr)));
              wc_data(ln*8 + 7 downto ln*8) <= blit_data;
              wc_mask(ln) <= '0';
              blit_ready <= '1';
              st <= S_BLIT_WAIT;
            elsif blit_gap = 0 then
              if wc_valid = '0' then
                -- start a fresh combine buffer with this pixel, no DDR3 traffic
                ln := lane_of(to_integer(unsigned(blit_addr)));
                wc_addr <= blit_addr(17 downto 4);
                wc_mask <= (others => '1');
                wc_mask(ln) <= '0';
                wc_data(ln*8 + 7 downto ln*8) <= blit_data;
                wc_valid <= '1';
                blit_ready <= '1';
                st <= S_BLIT_WAIT;
              else
                -- different burst: flush the buffer first, keep the pixel
                blit_lat_addr <= blit_addr;
                blit_lat_data <= blit_data;
                wc_pend <= '1';
                st <= S_BLIT_WRREQ;
              end if;
            end if;
          elsif blit_rd = '1' then
            -- blitter COPY source read. Serve from the one-burst read cache
            -- when possible; otherwise make the source coherent first (flush
            -- whichever combine buffer covers it) and then read the burst.
            if rc_valid = '1' and blit_rd_addr(17 downto 4) = rc_addr then
              ln := lane_of(to_integer(unsigned(blit_rd_addr)));
              blit_rdata_r    <= rc_data(ln*8 + 7 downto ln*8);
              blit_rd_ready_r <= '1';
              st <= S_BLITRD_ACK;
            elsif cpu_wc_dirty = '1' and blit_rd_addr(17 downto 4) = cpu_wc_addr then
              st <= S_CW_WRREQ;
            elsif wc_valid = '1' and blit_rd_addr(17 downto 4) = wc_addr then
              wc_pend <= '0';
              st <= S_BLIT_WRREQ;
            else
              st <= S_BLITRD_REQ;
            end if;
          elsif wc_valid = '1' and blit_busy_x1 = '0' and blit_gap = 0 then
            -- engine finished its op: flush the last combine buffer lazily
            wc_pend <= '0';
            st <= S_BLIT_WRREQ;
          elsif cpu_pending = '1' then
            cpu_op_we   <= cpu_we;
            cpu_op_addr <= cpu_addr;
            cpu_op_din  <= cpu_din;
            cpu_lane    <= lane_of(to_integer(unsigned(cpu_addr)));
            if cpu_we = '1' then
              if cpu_wc_dirty = '1' and cpu_addr(17 downto 4) = cpu_wc_addr then
                ln := lane_of(to_integer(unsigned(cpu_addr)));
                cw_data(ln*8 + 7 downto ln*8) <= cpu_din;
                if rc_valid = '1' and cpu_addr(17 downto 4) = rc_addr then
                  rc_valid <= '0';   -- keep the blit read cache coherent
                end if;
                ack_tgl_x1  <= not ack_tgl_x1;
                cpu_pending <= '0';
              elsif cpu_wc_dirty = '1' then
                st <= S_CW_WRREQ;
              else
                st <= S_CW_RDREQ;
              end if;
            else
              if cpu_wc_dirty = '1' and cpu_addr(17 downto 4) = cpu_wc_addr then
                ln := lane_of(to_integer(unsigned(cpu_addr)));
                cpu_dout_x1 <= cw_data(ln*8 + 7 downto ln*8);
                ack_tgl_x1  <= not ack_tgl_x1;
                cpu_pending <= '0';
              elsif cpu_wc_dirty = '1' then
                st <= S_CW_WRREQ;
              else
                st <= S_CR_REQ;
              end if;
            end if;
          end if;

        -- line fetch: one BL8 burst (16 bytes) per request
        when S_FILL_REQ =>
          if app_cmd_rdy = '1' then
            lstart := to_integer(cur_line) * LINE_PIX;      -- cur_line * 320
            if ew = '1' then lstart := lstart + lstart; end if;  -- *2 -> 640-wide
            pixoff := lstart + col;
            if b16 = '1' then byteoff := pixoff + pixoff;   -- *2 bytes/pixel
            else              byteoff := pixoff;
            end if;
            app_addr   <= burst_addr(base, byteoff);
            app_cmd    <= CMD_READ;
            app_cmd_en <= '1';
            st <= S_FILL_WAIT;
          end if;
        when S_FILL_WAIT =>
          if app_rdata_valid = '1' then
            fill_data <= app_rdata;
            store_idx <= 0;
            st <= S_FILL_STORE;
          end if;
        when S_FILL_STORE =>
          -- Walk the burst byte by byte (store_idx 0..15). 8bpp: one pixel per byte
          -- into bits 7:0. 16bpp: even byte latches the low half, odd byte writes the
          -- full RGB565 entry {high,low}. Buffer half stride is HALF (=640) pixels.
          if b16 = '1' then
            if (store_idx mod 2) = 0 then
              lo_latch <= fill_data(store_idx*8 + 7 downto store_idx*8);
            else
              lbuf(to_integer(unsigned'('0' & cur_half)) * HALF + col + store_idx/2)
                <= fill_data(store_idx*8 + 7 downto store_idx*8) & lo_latch;
            end if;
          else
            lbuf(to_integer(unsigned'('0' & cur_half)) * HALF + col + store_idx)
              <= x"00" & fill_data(store_idx*8 + 7 downto store_idx*8);
          end if;
          if store_idx = 15 then
            if col + advance >= lp then
              half_line(to_integer(unsigned'('0' & cur_half)))  <= cur_line;
              half_valid(to_integer(unsigned'('0' & cur_half))) <= '1';
              st <= S_IDLE;
            else
              col <= col + advance;
              st <= S_FILL_REQ;
            end if;
          else
            store_idx <= store_idx + 1;
          end if;

        -- CPU pixel write-combine: load one 16-byte burst, patch the requested
        -- byte in cw_data, then acknowledge the CPU. The dirty burst is written
        -- back later as one complete, unmasked DDR3 write.
        when S_CW_RDREQ =>
          if app_cmd_rdy = '1' then
            app_addr   <= burst_addr(base, to_integer(unsigned(cpu_op_addr)));
            app_cmd    <= CMD_READ;
            app_cmd_en <= '1';
            st <= S_CW_RDWAIT;
          end if;
        when S_CW_RDWAIT =>
          if app_rdata_valid = '1' then
            ln := cpu_lane;
            cw_data <= app_rdata;
            cw_data(ln*8 + 7 downto ln*8) <= cpu_op_din;
            cpu_wc_addr <= cpu_op_addr(17 downto 4);
            cpu_wc_dirty <= '1';
            if rc_valid = '1' and cpu_op_addr(17 downto 4) = rc_addr then
              rc_valid <= '0';   -- CPU wrote into the blit read-cached burst
            end if;
            ack_tgl_x1  <= not ack_tgl_x1;
            cpu_pending <= '0';
            st <= S_IDLE;
          end if;
        when S_CW_WRREQ =>
          if app_cmd_rdy = '1' then
            app_addr   <= burst_addr(base, to_integer(unsigned(cpu_wc_addr)) * 16);
            app_cmd    <= CMD_WRITE;
            app_cmd_en <= '1';
            st <= S_CW_WRDATA;
          end if;
        when S_CW_WRDATA =>
          if app_wdata_rdy = '1' then
            app_wdata      <= cw_data;
            app_wdata_mask <= (others => '0');
            app_wren       <= '1';
            app_wdata_end  <= '1';
            cpu_wc_dirty <= '0';
            st <= S_IDLE;
          end if;

        -- CPU pixel read: read the burst, extract the lane byte
        when S_CR_REQ =>
          if app_cmd_rdy = '1' then
            app_addr   <= burst_addr(base, to_integer(unsigned(cpu_op_addr)));
            app_cmd    <= CMD_READ;
            app_cmd_en <= '1';
            st <= S_CR_WAIT;
          end if;
        when S_CR_WAIT =>
          if app_rdata_valid = '1' then
            ln := cpu_lane;
            cpu_dout_x1 <= app_rdata(ln*8 + 7 downto ln*8);
            ack_tgl_x1  <= not ack_tgl_x1;
            cpu_pending <= '0';
            st <= S_IDLE;
          end if;

        -- flush the write-combine buffer: ONE masked BL8 write carrying every
        -- pixel collected for this 16-byte burst.
        when S_BLIT_WRREQ =>
          if app_cmd_rdy = '1' then
            app_addr   <= burst_addr(HIRES_BASE_WORD,
                                     to_integer(unsigned(wc_addr)) * 16);
            app_cmd    <= CMD_WRITE;
            app_cmd_en <= '1';
            st <= S_BLIT_WRDATA;
          end if;
        when S_BLIT_WRDATA =>
          if app_wdata_rdy = '1' then
            app_wdata      <= wc_data;
            app_wdata_mask <= wc_mask;        -- '0' = byte written
            app_wren       <= '1';
            app_wdata_end  <= '1';
            -- Unlike the CPU byte port, a blit does NOT invalidate the line
            -- buffer per write: the display refetches every scanline each frame
            -- anyway (half_valid clears at fb_frame_start), so blit writes appear
            -- next frame.
            blit_gap <= bl_gap_x1;
            if wc_pend = '1' then
              -- restart the buffer with the pixel that forced this flush
              ln := lane_of(to_integer(unsigned(blit_lat_addr)));
              wc_addr <= blit_lat_addr(17 downto 4);
              wc_mask <= (others => '1');
              wc_mask(ln) <= '0';
              wc_data(ln*8 + 7 downto ln*8) <= blit_lat_data;
              wc_pend <= '0';
              blit_ready <= '1';              -- pixel absorbed, release the engine
              st <= S_BLIT_WAIT;
            else
              wc_valid <= '0';                -- final flush after the op ended
              st <= S_IDLE;
            end if;
          end if;
        when S_BLIT_WAIT =>
          if blit_we = '0' then               -- engine consumed ready, advanced
            st <= S_IDLE;
          end if;

        -- blitter COPY source read: one BL8 burst read fills the read cache,
        -- the requested lane byte goes to the engine immediately
        when S_BLITRD_REQ =>
          if app_cmd_rdy = '1' then
            app_addr   <= burst_addr(HIRES_BASE_WORD,
                                     to_integer(unsigned(blit_rd_addr)));
            app_cmd    <= CMD_READ;
            app_cmd_en <= '1';
            st <= S_BLITRD_WAIT;
          end if;
        when S_BLITRD_WAIT =>
          if app_rdata_valid = '1' then
            rc_data  <= app_rdata;
            rc_addr  <= blit_rd_addr(17 downto 4);
            rc_valid <= '1';
            ln := lane_of(to_integer(unsigned(blit_rd_addr)));
            blit_rdata_r    <= app_rdata(ln*8 + 7 downto ln*8);
            blit_rd_ready_r <= '1';
            st <= S_BLITRD_ACK;
          end if;
        when S_BLITRD_ACK =>
          if blit_rd = '0' then               -- engine consumed ready, advanced
            st <= S_IDLE;
          end if;

        when others =>
          st <= S_IDLE;
      end case;

      -- watchdog: abort a stuck op so the CPU never hangs forever
      if wd_cnt = "11111111111111" and st /= S_IDLE and st /= S_CALIB then
        if st = S_CR_REQ or st = S_CR_WAIT
           or st = S_CW_RDREQ or st = S_CW_RDWAIT
           or st = S_CW_WRREQ or st = S_CW_WRDATA then
          ack_tgl_x1  <= not ack_tgl_x1;
          cpu_pending <= '0';
        end if;
        st <= S_IDLE;
      end if;

      if calib_done = '0' then st <= S_CALIB; end if;
    end if;
  end process;

end architecture;
