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
-- Ops (matches the emulator blitter opcodes)
--   OP_FILL = 0 : fill the inclusive rectangle (x0,y0)-(x1,y1) with COLOR
--   OP_LINE = 3 : draw a Bresenham line (x0,y0)-(x1,y1) in COLOR
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
    start    : in  std_logic;       -- 1-cycle pulse: latch command and run
    busy     : out std_logic;       -- high while an op is in progress

    -- abstract framebuffer byte write port
    fbo_we   : out std_logic;                                 -- request a byte write
    fbo_addr : out std_logic_vector(ADDR_BITS-1 downto 0);    -- byte index in frame
    fbo_data : out std_logic_vector(7 downto 0);
    fbo_ready: in  std_logic                                  -- write accepted this cycle
  );
end entity;

architecture rtl of vic_blit is

  constant OP_FILL : std_logic_vector(2 downto 0) := "000";
  constant OP_LINE : std_logic_vector(2 downto 0) := "011";

  type st_t is (S_IDLE, S_SETUP, S_ADDR, S_EMIT, S_STEP, S_ADV, S_DONE);
  signal st : st_t := S_IDLE;

  signal is_line : std_logic := '0';
  signal col_reg : std_logic_vector(7 downto 0) := (others => '0');

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

  function abs_diff(a, b : unsigned) return signed is
  begin
    if a >= b then return signed(resize(a - b, 12));
    else           return signed(resize(b - a, 12));
    end if;
  end function;

begin

  busy     <= '0' when st = S_IDLE else '1';
  fbo_we   <= '1' when st = S_EMIT else '0';
  fbo_addr <= std_logic_vector(addr);
  fbo_data <= col_reg;

  process(clk, rst_n)
    variable e2    : signed(13 downto 0);
    variable delta : signed(ADDR_BITS-1 downto 0);
    variable edel  : signed(12 downto 0);
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
    elsif rising_edge(clk) then
      case st is

        when S_IDLE =>
          if start = '1' then
            col_reg <= color;
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
              -- FILL: normalise the rectangle so x0<=x1, y0<=y1
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
                cy <= signed(resize(y0, 12)); fy1 <= signed(resize(y1, 12));
              else
                cy <= signed(resize(y1, 12)); fy1 <= signed(resize(y0, 12));
              end if;
            end if;
            st <= S_SETUP;
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

        when S_DONE =>
          st <= S_IDLE;

        when others =>
          st <= S_IDLE;
      end case;
    end if;
  end process;

end architecture;
