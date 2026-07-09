-- ---------------------------------------------------------------------------
-- vic_blit_regs - CPU register file for the hardware 2D blitter ($8840-$884F).
--
-- Captures byte writes into the 16-entry register bank, decodes them into the
-- wide blit command fields for vic_fb_ddr3, and pulses blit_start for one cycle
-- on a write to $884F (offset 15). A read of $884F returns BUSY in bit 7.
--
-- Register map (offset within $8840):
--   0 X0_LO  1 X0_HI(9:8)  2 Y0_LO  3 Y0_HI(8)
--   4 X1_LO  5 X1_HI       6 Y1_LO  7 Y1_HI
--   8 COLOR  9 OP(FILL=0,COPY=1,COPYT=2,LINE=3)  10 PAGE(0)
--   11 GAP (idle clk_x1 cycles inserted between blit pixel writes; DDR3 write
--      pacing -- tunable from software so drop-out experiments need no
--      re-synthesis; resets to 12)
--   12 (read/write handled by the core: framebuffer backend select/status)
--   13 DST_X_LO  14 DST_Y_LO (COPY destination top-left; the high bits ride
--      in the otherwise unused COLOR register: COLOR(1:0) = DST_X(9:8),
--      COLOR(2) = DST_Y(8))
--   15 TRIGGER/BUSY
--
-- COPY/COPYT copy the inclusive source rect (x0,y0)-(x1,y1) to the DST
-- top-left, overlap-safe (usable as MOVE); COPYT skips $00 source bytes.
-- ---------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vic_blit_regs is
  port (
    clk   : in  std_logic;
    rst_n : in  std_logic;

    wr    : in  std_logic;                       -- CPU write strobe (this device)
    addr  : in  std_logic_vector(3 downto 0);    -- offset within $8840-$884F
    wdata : in  std_logic_vector(7 downto 0);    -- CPU write byte
    rdata : out std_logic_vector(7 downto 0);    -- CPU read byte ($884F -> busy)
    busy  : in  std_logic;                       -- from vic_fb_ddr3

    -- decoded command to vic_fb_ddr3
    blit_op    : out std_logic_vector(2 downto 0);
    blit_x0    : out unsigned(9 downto 0);
    blit_y0    : out unsigned(9 downto 0);
    blit_x1    : out unsigned(9 downto 0);
    blit_y1    : out unsigned(9 downto 0);
    blit_color : out std_logic_vector(7 downto 0);
    blit_page  : out std_logic;
    blit_gap   : out std_logic_vector(7 downto 0);
    blit_dstx  : out unsigned(9 downto 0);
    blit_dsty  : out unsigned(9 downto 0);
    blit_start : out std_logic
  );
end entity;

architecture rtl of vic_blit_regs is
  type regbank_t is array (0 to 15) of std_logic_vector(7 downto 0);
  -- reg 11 (GAP) resets to 12 so software that never writes it keeps the
  -- proven pacing default
  signal regs        : regbank_t := (11 => x"0C", others => (others => '0'));
  signal wr_d        : std_logic := '0';
  signal start_i     : std_logic := '0';
  -- "Sticky" busy: asserted in clk_sys the instant $884F is written, so the CPU
  -- polling loop sees BUSY immediately -- the engine's own busy only arrives a
  -- few cycles later through the CDC, which the CPU would otherwise race past.
  -- Cleared once the engine busy has actually gone high (seen) and then low.
  signal busy_sticky : std_logic := '0';
  signal seen        : std_logic := '0';
begin

  process(clk)
  begin
    if rising_edge(clk) then
      start_i <= '0';
      if rst_n = '0' then
        regs <= (11 => x"0C", others => (others => '0'));
        wr_d <= '0';
        busy_sticky <= '0';
        seen <= '0';
      else
        wr_d <= wr;
        if wr = '1' then
          regs(to_integer(unsigned(addr))) <= wdata;
        end if;
        -- track the engine busy so sticky drops after the op has actually run
        if busy = '1' then
          seen <= '1';
        end if;
        if seen = '1' and busy = '0' then
          busy_sticky <= '0';
        end if;
        -- one start pulse on the rising edge of a write to $884F; assert sticky
        -- busy and restart the engine-busy tracking (this overrides the above).
        if wr = '1' and wr_d = '0' and addr = x"F" then
          start_i     <= '1';
          busy_sticky <= '1';
          seen        <= '0';
        end if;
      end if;
    end if;
  end process;

  blit_op    <= regs(9)(2 downto 0);
  blit_x0    <= unsigned(std_logic_vector'(regs(1)(1 downto 0) & regs(0)));
  blit_y0    <= unsigned(std_logic_vector'("0" & regs(3)(0 downto 0) & regs(2)));
  blit_x1    <= unsigned(std_logic_vector'(regs(5)(1 downto 0) & regs(4)));
  blit_y1    <= unsigned(std_logic_vector'("0" & regs(7)(0 downto 0) & regs(6)));
  blit_color <= regs(8);
  blit_page  <= regs(10)(0);
  blit_gap   <= regs(11);
  -- COPY destination: low bytes in 13/14, high bits in COLOR (unused by COPY)
  blit_dstx  <= unsigned(std_logic_vector'(regs(8)(1 downto 0) & regs(13)));
  blit_dsty  <= unsigned(std_logic_vector'("0" & regs(8)(2) & regs(14)));
  blit_start <= start_i;

  rdata <= (7 => busy_sticky, others => '0') when addr = x"F"
           else regs(to_integer(unsigned(addr)));

end architecture;
