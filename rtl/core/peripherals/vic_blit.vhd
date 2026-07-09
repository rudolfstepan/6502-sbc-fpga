-- ---------------------------------------------------------------------------
-- vic_blit - hardware 2D blitter engine for the DDR3 framebuffer
--
-- Purpose
--   The CPU cannot draw into the DDR3 framebuffer fast enough: every pixel is a
--   masked single-byte write pushed across a clk_sys<->clk_x1 handshake, so the
--   6502 stalls for a full DDR3 round-trip PER PIXEL. This engine runs the
--   rasterizer itself in the DDR3 app-clock domain and streams pixel writes
--   back-to-back, so the CPU only issues a high-level command (line / fill) and
--   polls a busy flag.
--
--   It is written against an abstract byte write port (fbo_we / fbo_addr /
--   fbo_data / fbo_ready) so it can be verified stand-alone in simulation and
--   then bound to the vic_fb_ddr3 app-port arbiter. fbo_addr is a byte index
--   into the active frame (same 18-bit pixel index the CPU port uses).
--
-- Timing discipline (this domain is the 100 MHz DDR3 app clock -- 10 ns):
--   * NO per-pixel address arithmetic beyond one 18-bit add: fbo_addr is a
--     REGISTER walked incrementally with precomputed step constants
--     (+/-1, +/-LINE_PIX and their sum). The start address y0*LINE_PIX+x0 is
--     computed once per op, spread over dedicated setup states.
--   * The Bresenham decision and the state updates are split into two states
--     (S_STEP decides, S_ADV applies), so every state has at most two short
--     carry chains. Cost: ~3 cycles per pixel = ~33 Mpix/s, far more than the
--     wireframe demo needs.
--
-- Ops (FILL/LINE match the emulator blitter opcodes; COPY is FPGA-first)
--   OP_FILL  = 0 : fill the inclusive rectangle (x0,y0)-(x1,y1) with COLOR
--   OP_COPY  = 1 : copy the inclusive source rect (x0,y0)-(x1,y1) to the
--                  destination top-left (dst_x,dst_y). Overlap-safe: the walk
--                  direction is chosen per axis like memmove (this doubles as
--                  the Amiga blitter's descending mode), so it is also a MOVE.
--   OP_COPYT = 2 : same, but source bytes of $00 are skipped (transparent
--                  copy for sprites; the skipped write also saves the cycle)
--   OP_LINE  = 3 : draw a Bresenham line (x0,y0)-(x1,y1) in COLOR
--   OP_TEX   = 4 : affine 64x64 texture fill into the inclusive destination
--                  rectangle.  The source texture is read through the same
--                  framebuffer read port as COPY. U/V are signed 8.8 and wrap
--                  through 64 texels via bits 13:8.
--                  tex_flags(1) = UV CLIP mode: instead of wrapping, pixels
--                  whose U or V lies outside [0, 64.0) are skipped entirely
--                  (no read, no write). Filling a face's screen bounding box
--                  in clip mode therefore rasterizes an arbitrary rotated
--                  parallelogram -- this is what makes textured cube faces
--                  possible with a rectangle-walking engine.
--
-- COPY reads through the abstract byte read port (fbi_re / fbi_addr /
-- fbi_data / fbi_ready), mirroring the write port protocol: fbi_re is held
-- until the backend answers with fbi_ready + data.
--
-- Amiga reuse: src_stride / dst_stride are runtime inputs (defaulting to
-- LINE_PIX) so a future Amiga-style core can drive per-channel modulos with
-- its own register file around this engine; A/B/C channel combine (minterms)
-- would slot into the S_CWR data path.
--
-- Coordinates are clamped to the frame by the caller (the cube keeps every
-- vertex on-screen), so this engine does no clipping.
-- ---------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vic_blit is
  generic (
    LINE_PIX   : positive := 640;   -- bytes (pixels) per framebuffer scanline
    ADDR_BITS  : positive := 18     -- byte index width into the frame
  );
  port (
    clk      : in  std_logic;       -- DDR3 app clock domain (clk_x1)
    rst_n    : in  std_logic;

    -- command interface (already captured into this clock domain)
    op       : in  std_logic_vector(2 downto 0);
    x0       : in  unsigned(9 downto 0);
    y0       : in  unsigned(9 downto 0);
    x1       : in  unsigned(9 downto 0);
    y1       : in  unsigned(9 downto 0);
    color    : in  std_logic_vector(7 downto 0);
    -- COPY destination top-left and per-channel strides (Amiga-style modulos;
    -- the SBC leaves both at the LINE_PIX default)
    dst_x      : in  unsigned(9 downto 0) := (others => '0');
    dst_y      : in  unsigned(9 downto 0) := (others => '0');
    src_stride : in  unsigned(9 downto 0) := to_unsigned(LINE_PIX, 10);
    dst_stride : in  unsigned(9 downto 0) := to_unsigned(LINE_PIX, 10);
    tex_base   : in  unsigned(17 downto 0) := (others => '0');
    tex_u0     : in  signed(15 downto 0) := (others => '0');
    tex_v0     : in  signed(15 downto 0) := (others => '0');
    tex_dudx   : in  signed(15 downto 0) := (others => '0');
    tex_dvdx   : in  signed(15 downto 0) := (others => '0');
    tex_dudy   : in  signed(15 downto 0) := (others => '0');
    tex_dvdy   : in  signed(15 downto 0) := (others => '0');
    tex_flags  : in  std_logic_vector(7 downto 0) := (others => '0');
    start    : in  std_logic;       -- 1-cycle pulse: latch command and run
    busy     : out std_logic;       -- high while an op is in progress

    -- abstract framebuffer byte write port
    fbo_we   : out std_logic;                                 -- request a byte write
    fbo_addr : out std_logic_vector(ADDR_BITS-1 downto 0);    -- byte index in frame
    fbo_data : out std_logic_vector(7 downto 0);
    fbo_ready: in  std_logic;                                 -- write accepted this cycle

    -- abstract framebuffer byte read port (COPY source channel)
    fbi_re   : out std_logic;                                 -- request a byte read
    fbi_addr : out std_logic_vector(ADDR_BITS-1 downto 0);    -- byte index in frame
    fbi_data : in  std_logic_vector(7 downto 0) := (others => '0');
    fbi_ready: in  std_logic := '0'                           -- data valid this cycle
  );
end entity;

architecture rtl of vic_blit is

  constant OP_FILL  : std_logic_vector(2 downto 0) := "000";
  constant OP_COPY  : std_logic_vector(2 downto 0) := "001";
  constant OP_COPYT : std_logic_vector(2 downto 0) := "010";
  constant OP_LINE  : std_logic_vector(2 downto 0) := "011";
  constant OP_TEX   : std_logic_vector(2 downto 0) := "100";

  type st_t is (S_IDLE, S_SETUP, S_ADDR, S_EMIT, S_STEP, S_ADV,
                S_CSET1, S_CSET2, S_CSET3, S_CSET4, S_CRD, S_CWR, S_CSTEP,
                S_TSET1, S_TSET2, S_TRD, S_TWR, S_TSTEP,
                S_DONE);
  signal st : st_t := S_IDLE;

  signal is_line : std_logic := '0';
  signal col_reg : std_logic_vector(7 downto 0) := (others => '0');

  -- COPY state: source address walker, per-axis direction, row/column
  -- down-counters and the precomputed row-wrap deltas for both channels
  signal tflag    : std_logic := '0';                        -- transparent copy
  signal saddr    : unsigned(ADDR_BITS-1 downto 0) := (others => '0');
  signal fy0      : signed(11 downto 0) := (others => '0');  -- normalized top
  signal fheight  : signed(11 downto 0) := (others => '0');
  signal xback    : std_logic := '0';                        -- walk right-to-left
  signal ydown    : std_logic := '0';                        -- walk bottom-up
  signal dcx, dcy : unsigned(11 downto 0) := (others => '0');-- dst start corner
  signal cstep    : signed(ADDR_BITS-1 downto 0) := (others => '0');  -- +/-1
  signal swrap    : signed(ADDR_BITS-1 downto 0) := (others => '0');
  signal dwrap    : signed(ADDR_BITS-1 downto 0) := (others => '0');
  signal wcnt     : signed(11 downto 0) := (others => '0');
  signal hcnt     : signed(11 downto 0) := (others => '0');

  -- current pixel + endpoint (signed so +/-1 stepping and compares are clean)
  signal cx, cy   : signed(11 downto 0) := (others => '0');
  signal ex, ey   : signed(11 downto 0) := (others => '0');
  -- fill rectangle left/right/bottom and width
  signal fx0, fx1 : signed(11 downto 0) := (others => '0');
  signal fy1      : signed(11 downto 0) := (others => '0');
  signal fwidth   : signed(11 downto 0) := (others => '0');
  -- Bresenham state
  signal dx, dy   : signed(11 downto 0) := (others => '0');  -- dx>=0, dy>=0
  signal sx, sy   : signed(1 downto 0)  := (others => '0');  -- +1 / -1
  signal err      : signed(12 downto 0) := (others => '0');
  signal xgo, ygo : std_logic := '0';        -- registered step decisions
  -- precomputed err deltas (registered in S_SETUP, muxed with one add in S_ADV)
  signal ndy      : signed(12 downto 0) := (others => '0');  -- -dy
  signal pdx      : signed(12 downto 0) := (others => '0');  -- +dx
  signal dxmdy    : signed(12 downto 0) := (others => '0');  -- dx-dy

  -- incrementally walked byte address + precomputed address deltas
  signal addr     : unsigned(ADDR_BITS-1 downto 0) := (others => '0');
  signal step_x   : signed(ADDR_BITS-1 downto 0) := (others => '0');  -- +/-1
  signal step_y   : signed(ADDR_BITS-1 downto 0) := (others => '0');  -- +/-LINE_PIX
  signal step_xy  : signed(ADDR_BITS-1 downto 0) := (others => '0');  -- step_x+step_y
  signal fillwrap : signed(ADDR_BITS-1 downto 0) := (others => '0');  -- LINE_PIX-width

  -- OP_TEX affine texture state. U/V are 8.8, texture is 64x64 and addressed by
  -- {v[13:8], u[13:8]} so values wrap naturally.
  signal tu, tv       : signed(15 downto 0) := (others => '0');
  signal row_tu, row_tv : signed(15 downto 0) := (others => '0');
  signal tflag_tex    : std_logic := '0';
  -- UV clip mode: tex_skip is REGISTERED alongside tu/tv so S_TRD never
  -- glitches a one-cycle fbi_re for a pixel that is then skipped (the backend
  -- would dispatch the read and its late ready pulse could be consumed by the
  -- following pixel with a stale address).
  signal tclip        : std_logic := '0';
  signal tex_skip     : std_logic := '0';

  function uv_outside(u, v : signed(15 downto 0)) return std_logic is
  begin
    -- inside = both U and V in [0, 16384): top two bits clear
    if u(15) = '1' or u(14) = '1' or v(15) = '1' or v(14) = '1' then
      return '1';
    else
      return '0';
    end if;
  end function;

  function abs_diff(a, b : unsigned) return signed is
  begin
    if a >= b then return signed(resize(a - b, 12));
    else           return signed(resize(b - a, 12));
    end if;
  end function;

  subtype tex_off_t is unsigned(11 downto 0);
  function tex_offset(u, v : signed(15 downto 0)) return tex_off_t is
    variable uv : std_logic_vector(11 downto 0);
  begin
    uv := std_logic_vector(v(13 downto 8)) & std_logic_vector(u(13 downto 8));
    return unsigned(uv);
  end function;

begin

  busy     <= '0' when st = S_IDLE else '1';
  fbo_we   <= '1' when st = S_EMIT or st = S_CWR or st = S_TWR else '0';
  fbo_addr <= std_logic_vector(addr);
  fbo_data <= col_reg;
  fbi_re   <= '1' when st = S_CRD or (st = S_TRD and tex_skip = '0') else '0';
  fbi_addr <= std_logic_vector(saddr);

  process(clk, rst_n)
    variable e2    : signed(13 downto 0);
    variable delta : signed(ADDR_BITS-1 downto 0);
    variable edel  : signed(12 downto 0);
    variable next_tu : signed(15 downto 0);
    variable next_tv : signed(15 downto 0);
  begin
    if rst_n = '0' then
      st <= S_IDLE;
      is_line <= '0'; col_reg <= (others => '0');
      cx <= (others => '0'); cy <= (others => '0');
      ex <= (others => '0'); ey <= (others => '0');
      fx0 <= (others => '0'); fx1 <= (others => '0'); fy1 <= (others => '0');
      fwidth <= (others => '0');
      dx <= (others => '0'); dy <= (others => '0');
      sx <= (others => '0'); sy <= (others => '0'); err <= (others => '0');
      xgo <= '0'; ygo <= '0';
      ndy <= (others => '0'); pdx <= (others => '0'); dxmdy <= (others => '0');
      addr <= (others => '0');
      step_x <= (others => '0'); step_y <= (others => '0');
      step_xy <= (others => '0'); fillwrap <= (others => '0');
      tflag <= '0'; saddr <= (others => '0');
      fy0 <= (others => '0'); fheight <= (others => '0');
      xback <= '0'; ydown <= '0';
      dcx <= (others => '0'); dcy <= (others => '0');
      cstep <= (others => '0'); swrap <= (others => '0'); dwrap <= (others => '0');
      wcnt <= (others => '0'); hcnt <= (others => '0');
      tu <= (others => '0'); tv <= (others => '0');
      row_tu <= (others => '0'); row_tv <= (others => '0');
      tflag_tex <= '0'; tclip <= '0'; tex_skip <= '0';
    elsif rising_edge(clk) then
      case st is

        when S_IDLE =>
          if start = '1' then
            col_reg <= color;
            tflag   <= '0';
            if op = OP_LINE then
              is_line <= '1';
              cx <= signed(resize(x0, 12));
              cy <= signed(resize(y0, 12));
              ex <= signed(resize(x1, 12));
              ey <= signed(resize(y1, 12));
              dx <= abs_diff(x1, x0);
              dy <= abs_diff(y1, y0);
              if x1 >= x0 then
                sx     <= to_signed(1, 2);
                step_x <= to_signed(1, ADDR_BITS);
              else
                sx     <= to_signed(-1, 2);
                step_x <= to_signed(-1, ADDR_BITS);
              end if;
              if y1 >= y0 then
                sy     <= to_signed(1, 2);
                step_y <= to_signed(LINE_PIX, ADDR_BITS);
              else
                sy     <= to_signed(-1, 2);
                step_y <= to_signed(-LINE_PIX, ADDR_BITS);
              end if;
            else
              -- FILL/COPY: normalise the rectangle so x0<=x1, y0<=y1
              is_line <= '0';
              if x0 <= x1 then
                cx  <= signed(resize(x0, 12)); fx0 <= signed(resize(x0, 12));
                fx1 <= signed(resize(x1, 12));
                fwidth <= abs_diff(x1, x0);
              else
                cx  <= signed(resize(x1, 12)); fx0 <= signed(resize(x1, 12));
                fx1 <= signed(resize(x0, 12));
                fwidth <= abs_diff(x0, x1);
              end if;
              if y0 <= y1 then
                cy  <= signed(resize(y0, 12)); fy0 <= signed(resize(y0, 12));
                fy1 <= signed(resize(y1, 12));
                fheight <= abs_diff(y1, y0);
              else
                cy  <= signed(resize(y1, 12)); fy0 <= signed(resize(y1, 12));
                fy1 <= signed(resize(y0, 12));
                fheight <= abs_diff(y0, y1);
              end if;
            end if;
            if op = OP_COPY or op = OP_COPYT then
              if op = OP_COPYT then
                tflag <= '1';
              end if;
              st <= S_CSET1;
            elsif op = OP_TEX then
              tflag_tex <= tex_flags(0);
              tclip     <= tex_flags(1);
              st <= S_TSET1;
            else
              st <= S_SETUP;
            end if;
          end if;

        -- one-time precomputation, deliberately spread over two states so no
        -- state carries more than one multiply or a couple of short adds
        when S_SETUP =>
          -- start row base: cy*LINE_PIX (LINE_PIX is a generic constant, so this
          -- reduces to shift-adds; it is registered and runs once per op)
          addr <= resize(unsigned(cy(9 downto 0)) * to_unsigned(LINE_PIX, 10),
                         ADDR_BITS);
          step_xy  <= step_x + step_y;
          fillwrap <= to_signed(LINE_PIX, ADDR_BITS) - resize(fwidth, ADDR_BITS);
          ndy   <= -resize(dy, 13);
          pdx   <=  resize(dx, 13);
          dxmdy <=  resize(dx, 13) - resize(dy, 13);
          err   <=  resize(dx, 13) - resize(dy, 13);
          st <= S_ADDR;

        when S_ADDR =>
          addr <= addr + resize(unsigned(cx(9 downto 0)), ADDR_BITS);
          st <= S_EMIT;

        -- hold the write request until the framebuffer accepts it
        when S_EMIT =>
          if fbo_ready = '1' then
            st <= S_STEP;
          end if;

        when S_STEP =>
          if is_line = '1' then
            if cx = ex and cy = ey then
              st <= S_DONE;
            else
              -- decide only; apply in S_ADV so each state stays shallow
              e2 := resize(err, 14) + resize(err, 14);   -- 2*err
              if e2 > -resize(dy, 14) then xgo <= '1'; else xgo <= '0'; end if;
              if e2 <  resize(dx, 14) then ygo <= '1'; else ygo <= '0'; end if;
              st <= S_ADV;
            end if;
          else
            -- FILL walk: advance along the row, then to the next row
            if cx = fx1 then
              if cy = fy1 then
                st <= S_DONE;
              else
                cx   <= fx0;
                cy   <= cy + 1;
                addr <= unsigned(signed(addr) + fillwrap);
                st   <= S_EMIT;
              end if;
            else
              cx   <= cx + 1;
              addr <= addr + 1;
              st   <= S_EMIT;
            end if;
          end if;

        -- apply the registered Bresenham step: single mux + single add each for
        -- err, cx, cy and addr
        when S_ADV =>
          if xgo = '1' and ygo = '1' then
            edel  := dxmdy;
            delta := step_xy;
          elsif xgo = '1' then
            edel  := ndy;
            delta := step_x;
          else
            edel  := pdx;
            delta := step_y;
          end if;
          err  <= err + edel;
          addr <= unsigned(signed(addr) + delta);
          if xgo = '1' then cx <= cx + resize(sx, 12); end if;
          if ygo = '1' then cy <= cy + resize(sy, 12); end if;
          st <= S_EMIT;

        -- ── COPY setup: directions, start corners, address bases, wraps ─────
        -- (one compare pair / one multiply per state, same discipline as
        -- S_SETUP/S_ADDR)
        when S_CSET1 =>
          -- memmove rule per axis: destination beyond source -> walk backwards
          if signed(resize(dst_x, 12)) > fx0 then
            xback <= '1';
            cx    <= fx1;
            dcx   <= unsigned(resize(dst_x, 12)) + unsigned(fwidth);
            cstep <= to_signed(-1, ADDR_BITS);
          else
            xback <= '0';
            cx    <= fx0;
            dcx   <= unsigned(resize(dst_x, 12));
            cstep <= to_signed(1, ADDR_BITS);
          end if;
          if signed(resize(dst_y, 12)) > fy0 then
            ydown <= '1';
            cy    <= fy1;
            dcy   <= unsigned(resize(dst_y, 12)) + unsigned(fheight);
          else
            ydown <= '0';
            cy    <= fy0;
            dcy   <= unsigned(resize(dst_y, 12));
          end if;
          wcnt <= fwidth;
          hcnt <= fheight;
          st <= S_CSET2;

        when S_CSET2 =>
          -- source row base + source row-wrap delta
          saddr <= resize(unsigned(cy(9 downto 0)) * src_stride, ADDR_BITS);
          if ydown = '1' then
            if xback = '1' then
              swrap <= -signed(resize(src_stride, ADDR_BITS)) + resize(fwidth, ADDR_BITS);
            else
              swrap <= -signed(resize(src_stride, ADDR_BITS)) - resize(fwidth, ADDR_BITS);
            end if;
          else
            if xback = '1' then
              swrap <= signed(resize(src_stride, ADDR_BITS)) + resize(fwidth, ADDR_BITS);
            else
              swrap <= signed(resize(src_stride, ADDR_BITS)) - resize(fwidth, ADDR_BITS);
            end if;
          end if;
          st <= S_CSET3;

        when S_CSET3 =>
          -- destination row base + destination row-wrap delta
          addr <= resize(dcy(9 downto 0) * dst_stride, ADDR_BITS);
          if ydown = '1' then
            if xback = '1' then
              dwrap <= -signed(resize(dst_stride, ADDR_BITS)) + resize(fwidth, ADDR_BITS);
            else
              dwrap <= -signed(resize(dst_stride, ADDR_BITS)) - resize(fwidth, ADDR_BITS);
            end if;
          else
            if xback = '1' then
              dwrap <= signed(resize(dst_stride, ADDR_BITS)) + resize(fwidth, ADDR_BITS);
            else
              dwrap <= signed(resize(dst_stride, ADDR_BITS)) - resize(fwidth, ADDR_BITS);
            end if;
          end if;
          st <= S_CSET4;

        when S_CSET4 =>
          saddr <= saddr + resize(unsigned(cx(9 downto 0)), ADDR_BITS);
          addr  <= addr + resize(dcx(9 downto 0), ADDR_BITS);
          st <= S_CRD;

        -- ── COPY loop: read source byte, write destination byte, step ───────
        when S_CRD =>
          if fbi_ready = '1' then
            col_reg <= fbi_data;
            if tflag = '1' and fbi_data = x"00" then
              st <= S_CSTEP;               -- transparent: skip the write
            else
              st <= S_CWR;
            end if;
          end if;

        when S_CWR =>
          if fbo_ready = '1' then
            st <= S_CSTEP;
          end if;

        when S_CSTEP =>
          if wcnt = 0 then
            if hcnt = 0 then
              st <= S_DONE;
            else
              hcnt  <= hcnt - 1;
              wcnt  <= fwidth;
              saddr <= unsigned(signed(saddr) + swrap);
              addr  <= unsigned(signed(addr) + dwrap);
              st    <= S_CRD;
            end if;
          else
            wcnt  <= wcnt - 1;
            saddr <= unsigned(signed(saddr) + cstep);
            addr  <= unsigned(signed(addr) + cstep);
            st    <= S_CRD;
          end if;

        -- ── Affine 64x64 texture fill: destination walks like FILL, source
        -- address is recomputed from U/V for each pixel and read like COPY.
        when S_TSET1 =>
          addr <= resize(unsigned(cy(9 downto 0)) * to_unsigned(LINE_PIX, 10),
                         ADDR_BITS);
          fillwrap <= to_signed(LINE_PIX, ADDR_BITS) - resize(fwidth, ADDR_BITS);
          row_tu <= tex_u0;
          row_tv <= tex_v0;
          tu <= tex_u0;
          tv <= tex_v0;
          wcnt <= fwidth;
          hcnt <= fheight;
          st <= S_TSET2;

        when S_TSET2 =>
          addr <= addr + resize(unsigned(cx(9 downto 0)), ADDR_BITS);
          saddr <= tex_base + resize(tex_offset(tu, tv), ADDR_BITS);
          tex_skip <= tclip and uv_outside(tu, tv);
          st <= S_TRD;

        when S_TRD =>
          if tex_skip = '1' then
            st <= S_TSTEP;               -- clip: outside the texture, no pixel
          elsif fbi_ready = '1' then
            col_reg <= fbi_data;
            if tflag_tex = '1' and fbi_data = x"00" then
              st <= S_TSTEP;
            else
              st <= S_TWR;
            end if;
          end if;

        when S_TWR =>
          if fbo_ready = '1' then
            st <= S_TSTEP;
          end if;

        when S_TSTEP =>
          if wcnt = 0 then
            if hcnt = 0 then
              st <= S_DONE;
            else
              hcnt <= hcnt - 1;
              wcnt <= fwidth;
              cx <= fx0;
              cy <= cy + 1;
              addr <= unsigned(signed(addr) + fillwrap);
              next_tu := row_tu + tex_dudy;
              next_tv := row_tv + tex_dvdy;
              row_tu <= next_tu;
              row_tv <= next_tv;
              tu <= next_tu;
              tv <= next_tv;
              saddr <= tex_base + resize(tex_offset(next_tu, next_tv), ADDR_BITS);
              tex_skip <= tclip and uv_outside(next_tu, next_tv);
              st <= S_TRD;
            end if;
          else
            wcnt <= wcnt - 1;
            cx <= cx + 1;
            addr <= addr + 1;
            next_tu := tu + tex_dudx;
            next_tv := tv + tex_dvdx;
            tu <= next_tu;
            tv <= next_tv;
            saddr <= tex_base + resize(tex_offset(next_tu, next_tv), ADDR_BITS);
            tex_skip <= tclip and uv_outside(next_tu, next_tv);
            st <= S_TRD;
          end if;

        when S_DONE =>
          st <= S_IDLE;

        when others =>
          st <= S_IDLE;
      end case;
    end if;
  end process;

end architecture;
