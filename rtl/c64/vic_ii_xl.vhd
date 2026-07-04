-- MOS 6569 VIC-II "XL" -- cycle-based PAL model for the native C64.
--
-- Unlike the line-buffer scan converter in vic_ii.vhd (which prefetches a whole
-- line during H-blank), this implementation models the 6569 as the cycle stream
-- it really is, following Christian Bauer's "The MOS 6567/6569 video controller"
-- text (vic-ii.txt):
--
--   * 63 PHI2 cycles per raster line + 1 pad cycle (see TIMING below), 312
--     raster lines, 8 pixels per cycle rendered into a 2-line ping-pong buffer.
--   * Real badlines: the VC/RC/VCBASE/VMLI state machine per Bauer 3.7.2,
--     badline condition evaluated live (raster $30-$F7, DEN latched in line
--     $30, raster[2:0] = YSCROLL) -> FLD / linecrunch style tricks behave.
--   * BA to the CPU at the real cycles: 12..54 on badlines, plus the per-sprite
--     windows around the sprite pointer/data fetches.
--   * Registers act IMMEDIATELY (mid-line splits work at cycle granularity):
--     $D011/$D016 mode+scroll bits, colours, $D018 bases are all read live by
--     the pixel pipeline; XSCROLL is a true shift-register reload condition.
--   * Border unit with the real main/vertical flip-flops (RSEL/CSEL compare
--     points, DEN handling) -> border opening tricks, sprites in the border.
--   * Sprite engine per Bauer 3.8: per-sprite DMA state (MC/MCBASE), Y
--     expansion flip-flop (Y-crunch works), X expansion flip-flop, multicolour,
--     priority and both collision registers WITH working IRQs.
--   * Idle state g-accesses at $3FFF/$39FF, invalid modes (ECM+BMM / ECM+MCM)
--     render black but still produce foreground for collisions.
--   * Light pen $D013/$D014 are a constant stub.
--
-- TIMING / deviations from a real 6569 (documented, deliberate):
--   * The CPU runs at exactly 1.000 MHz (27 MHz / 27) and a C64 line here is
--     2 HDMI lines = 64 us = 64 cycles, not 63 (0.985 MHz). Cycle-counted
--     demo timing is therefore off by 1 cycle/line; the extra cycle is a pad
--     inserted between Bauer cycles 63 and 1 in which nothing is fetched.
--   * The HDMI frame is 625 lines = 312.5 C64 lines, so one raster line per
--     frame (a top-border line) is generated 1.5x; the raster IRQ deduplicates.
--   * Fetches don't share the CPU bus: main RAM/colour RAM give the VIC a
--     dedicated read port (c64_ram_dp/colour_ram_dp), so BA only emulates the
--     CPU stall timing. Refresh accesses are omitted (no DRAM to refresh).
--
-- Display window: 720x576 output shows C64 pixels X=4..363 (20px border left/
-- right of the 320px window) and rasters 16..303 (35 lines above the top text
-- edge), each C64 pixel doubled 2x2. Sprites and border tricks are visible in
-- the whole shown area.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vic_ii_xl is
  port (
    clk        : in  std_logic;                     -- 27 MHz system/pixel clock
    reset_n    : in  std_logic;

    -- CPU cycle tick from c64_core (1 clk pulse per PHI2, at the END of the
    -- CPU cycle). Only used to keep the engine's cycle grid phase-checked; the
    -- engine itself derives its grid from the HDMI counters (same clock, both
    -- released from the same reset, 864 = 32*27 keeps them locked).
    phi2_en    : in  std_logic;

    -- CPU register interface ($D000-$D03F, mirrored every $40).
    cs         : in  std_logic;
    we         : in  std_logic;                     -- 1-clk strobe (io_we)
    addr       : in  std_logic_vector(5 downto 0);
    din        : in  std_logic_vector(7 downto 0);
    dout       : out std_logic_vector(7 downto 0);
    irq_n      : out std_logic;

    -- Dedicated VIC read port into main RAM (c64_ram_dp port B, 1-clk latency).
    vic_addr   : out std_logic_vector(15 downto 0);
    vic_data   : in  std_logic_vector(7 downto 0);
    ba         : out std_logic;     -- '0' = CPU must stall (badline/sprite DMA)

    -- VIC bank from CIA-2 PRA[1:0] (already inverted to a bank number).
    vic_bank   : in  std_logic_vector(1 downto 0);

    -- Colour RAM read port (colour_ram_dp port B, 1-clk latency).
    color_addr : out std_logic_vector(9 downto 0);
    color_data : in  std_logic_vector(3 downto 0);

    -- Character generator ROM port (1-clk latency). The VIC sees CHARGEN at
    -- $1000-$1FFF in banks 0/2 for EVERY fetch (g-accesses AND sprite data).
    -- char_busy marks the sub-cycle window in which the VIC drives/reads this
    -- port; outside it the core may time-share the same ROM port with the CPU
    -- (the CPU samples at the END of the PHI2 cycle, long after the window).
    char_addr  : out std_logic_vector(11 downto 0);
    char_data  : in  std_logic_vector(7 downto 0);
    char_busy  : out std_logic;

    -- HDMI/VGA output (RGB565 split, 720x576p50).
    vga_hs     : out std_logic;
    vga_vs     : out std_logic;
    vga_de     : out std_logic;
    vga_r      : out std_logic_vector(4 downto 0);
    vga_g      : out std_logic_vector(5 downto 0);
    vga_b      : out std_logic_vector(4 downto 0)
  );
end entity;

architecture rtl of vic_ii_xl is
  -- ----- CEA-861 720x576p50 output timing (identical to vic_ii) -----
  constant H_TOT : natural := 864;
  constant H_VIS : natural := 720;
  constant H_SS  : natural := 732;
  constant H_SE  : natural := 796;
  constant V_TOT : natural := 625;
  constant V_VIS : natural := 576;
  constant V_SS  : natural := 581;
  constant V_SE  : natural := 586;

  -- ----- C64 geometry -----
  constant RASTER_LINES : natural := 312;
  -- First raster line shown at the top of the 576-line output (288 C64 lines
  -- shown: 16..303; text window is rasters 51..250).
  constant RVIS_TOP  : natural := 16;
  -- First C64 X shown at the left of the 720px output (360 px shown: 4..363;
  -- text window is X 24..343).
  constant XVIS_LEFT : natural := 4;

  constant PHI_PER_CYC : natural := 27;   -- 27 MHz clks per engine cycle

  -- ----- HDMI-side raster counters -----
  signal hc : natural range 0 to H_TOT - 1 := 0;
  signal vc : natural range 0 to V_TOT - 1 := 0;

  -- ----- register file (owned by the register process) -----
  type sprite_byte_t is array (0 to 7) of std_logic_vector(7 downto 0);
  type sprite_col_t  is array (0 to 7) of std_logic_vector(3 downto 0);
  signal reg_spr_x_lo : sprite_byte_t := (others => (others => '0'));
  signal reg_spr_y    : sprite_byte_t := (others => (others => '0'));
  signal reg_d010 : std_logic_vector(7 downto 0) := x"00";
  signal reg_d011 : std_logic_vector(7 downto 0) := x"1B";  -- DEN=1 RSEL=1 Y=3
  signal reg_d015 : std_logic_vector(7 downto 0) := x"00";
  signal reg_d016 : std_logic_vector(7 downto 0) := x"08";  -- CSEL=1
  signal reg_d017 : std_logic_vector(7 downto 0) := x"00";  -- Y expand
  signal reg_d018 : std_logic_vector(7 downto 0) := x"15";
  signal reg_d01b : std_logic_vector(7 downto 0) := x"00";  -- priority
  signal reg_d01c : std_logic_vector(7 downto 0) := x"00";  -- sprite MC
  signal reg_d01d : std_logic_vector(7 downto 0) := x"00";  -- X expand
  signal reg_d01e : std_logic_vector(7 downto 0) := x"00";  -- ss collision
  signal reg_d01f : std_logic_vector(7 downto 0) := x"00";  -- sb collision
  signal reg_d020 : std_logic_vector(3 downto 0) := x"E";
  signal reg_d021 : std_logic_vector(3 downto 0) := x"6";
  signal reg_d022 : std_logic_vector(3 downto 0) := x"0";
  signal reg_d023 : std_logic_vector(3 downto 0) := x"0";
  signal reg_d024 : std_logic_vector(3 downto 0) := x"0";
  signal reg_d025 : std_logic_vector(3 downto 0) := x"0";
  signal reg_d026 : std_logic_vector(3 downto 0) := x"0";
  signal reg_spr_col : sprite_col_t := (others => x"0");
  signal raster_cmp : unsigned(8 downto 0) := (others => '0');
  -- IRQ latches/enables: 0=raster, 1=sprite-bg, 2=sprite-sprite, 3=lightpen.
  signal irq_latch : std_logic_vector(3 downto 0) := (others => '0');
  signal irq_en    : std_logic_vector(3 downto 0) := (others => '0');
  signal irq_out   : std_logic;
  -- Collision registers clear at the END of a CPU read (when cs drops), so the
  -- CPU -- which samples the bus up to a full PHI2 after cs asserts -- still
  -- reads the pre-clear value.
  signal d01e_pend_clr : std_logic := '0';
  signal d01f_pend_clr : std_logic := '0';

  -- ----- engine state (owned by the engine process) -----
  signal ph  : natural range 0 to PHI_PER_CYC - 1 := 0;
  -- Bauer cycle numbering 1..63, 64 = our pad cycle.
  signal cyc : natural range 1 to 64 := 1;
  -- C64 X coordinate of this cycle's first pixel (cycle 14 -> X 0).
  signal xbase : natural range 0 to 511 := 408;
  -- Raster line the engine is generating (mapped from vc, see line start).
  signal r_line : natural range 0 to RASTER_LINES - 1 := RVIS_TOP + 1;

  signal den_frame  : std_logic := '0';   -- DEN seen during raster $30
  signal disp_state : std_logic := '0';   -- display (vs idle) state
  signal badline_cyc: std_logic := '0';   -- badline condition, this cycle
  signal vcbase : natural range 0 to 1023 := 0;
  signal vcnt   : natural range 0 to 1023 := 0;
  signal rc     : natural range 0 to 7 := 7;
  signal vmli   : natural range 0 to 40 := 0;
  type vm_t is array (0 to 39) of std_logic_vector(11 downto 0);
  signal vmbuf : vm_t := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of vmbuf : signal is "distributed";

  -- g-access pipeline: fetched in cycle c, loaded into the shifter in c+1.
  signal gdata_pend, gdata_cur : std_logic_vector(7 downto 0) := (others => '0');
  signal cdata_pend, cdata_cur : std_logic_vector(11 downto 0) := (others => '0');
  -- pixel shifter
  signal gsr    : std_logic_vector(7 downto 0) := (others => '0');
  signal g_mcff : std_logic := '0';
  signal cd_act : std_logic_vector(11 downto 0) := (others => '0');

  -- fetch routing
  signal rom_sel1, rom_sel2 : std_logic := '0';
  type f1_t is (F1_NONE, F1_G, F1_P, F1_S1);
  type f2_t is (F2_NONE, F2_C, F2_S0, F2_S2);
  signal f1_kind : f1_t := F1_NONE;
  signal f2_kind : f2_t := F2_NONE;
  signal f_spr   : natural range 0 to 7 := 0;   -- sprite index for P/S fetches

  -- sprites
  type spr_u6_t  is array (0 to 7) of natural range 0 to 63;
  type spr_pos_t is array (0 to 7) of natural range 0 to 23;
  type spr_dat_t is array (0 to 7) of std_logic_vector(23 downto 0);
  signal spr_ptr    : sprite_byte_t := (others => (others => '0'));
  signal spr_dat    : spr_dat_t := (others => (others => '0'));
  signal spr_dma    : std_logic_vector(7 downto 0) := (others => '0');
  signal spr_disp   : std_logic_vector(7 downto 0) := (others => '0');
  signal spr_expff  : std_logic_vector(7 downto 0) := (others => '1');
  signal spr_mcbase : spr_u6_t := (others => 0);
  signal spr_mc     : spr_u6_t := (others => 0);
  signal spr_act    : std_logic_vector(7 downto 0) := (others => '0');
  signal spr_trig   : std_logic_vector(7 downto 0) := (others => '0');
  signal spr_pos    : spr_pos_t := (others => 0);
  signal spr_xet    : std_logic_vector(7 downto 0) := (others => '0');
  -- Bauer p-access cycles per sprite (sprites 3..7 fetch on the NEXT line).
  type spr_cyc_t is array (0 to 7) of natural range 1 to 63;
  constant PCYC : spr_cyc_t := (58, 60, 62, 1, 3, 5, 7, 9);

  -- border unit
  signal mbff : std_logic := '1';   -- main border flip-flop
  signal vbff : std_logic := '1';   -- vertical border flip-flop

  -- engine -> register process event pulses
  signal raster_irq_set : std_logic := '0';
  signal coll_ss_set : std_logic_vector(7 downto 0) := (others => '0');
  signal coll_sb_set : std_logic_vector(7 downto 0) := (others => '0');

  -- ----- 2-line ping-pong pixel buffer (indexed by raster parity & X) -----
  type lb_t is array (0 to 1023) of std_logic_vector(3 downto 0);
  signal lb : lb_t := (others => (others => '0'));
  attribute ram_style of lb : signal is "block";
  -- Gowin honours syn_ramstyle; without it the buffer lands in SSRAM (LUTs).
  attribute syn_ramstyle : string;
  attribute syn_ramstyle of lb : signal is "block_ram";
  signal lb_we    : std_logic := '0';
  signal lb_waddr : natural range 0 to 1023 := 0;
  signal lb_wdata : std_logic_vector(3 downto 0) := (others => '0');
  signal lb_q     : std_logic_vector(3 downto 0) := (others => '0');

  -- display pipeline
  signal hs_d, vs_d, de_d : std_logic := '1';

  -- Pepto palette in RGB565 split (same constants as vic_ii).
  type pal5_t is array (0 to 15) of std_logic_vector(4 downto 0);
  type pal6_t is array (0 to 15) of std_logic_vector(5 downto 0);
  constant PAL_R : pal5_t := (
    "00000","11111","10001","01101","10001","01011","01000","11000",
    "10001","01011","10111","01010","01111","10011","01111","10100");
  constant PAL_G : pal6_t := (
    "000000","111111","001110","101110","010000","101000","001100","110100",
    "011001","010010","011010","010100","011110","111000","011010","101000");
  constant PAL_B : pal5_t := (
    "00000","11111","00110","11000","10011","01001","10010","01110",
    "00110","00000","01100","01010","01111","10001","11001","10100");
begin
  -- ===================== HDMI raster counters =====================
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        hc <= 0; vc <= 0;
      elsif hc = H_TOT - 1 then
        hc <= 0;
        if vc = V_TOT - 1 then vc <= 0; else vc <= vc + 1; end if;
      else
        hc <= hc + 1;
      end if;
    end if;
  end process;

  -- The VIC issues chargen addresses at ph 0 and ph 5 and captures the data
  -- at ph 3 and ph 8; outside ph 0..9 the ROM port is free for the CPU.
  char_busy <= '1' when ph <= 9 else '0';

  -- ===================== VIC engine =====================
  -- One PHI2 cycle = 27 clks (ph 0..26). Schedule inside a cycle:
  --   ph 0        : cycle-start rules (Bauer per-cycle actions), phi1 fetch
  --                 address out, BA update
  --   ph 3        : phi1 fetch data captured (g / sprite pointer / sprite s1)
  --   ph 4        : g-data pipelined, VMLI/VC increment after a g-access
  --   ph 5        : phi2 fetch address out (c-access / sprite s0/s2)
  --   ph 8        : phi2 fetch data captured
  --   ph 16..23   : the cycle's 8 pixels (xpix 0..7), 1 pixel per clk
  --   ph 26       : g-data pending -> current handover for the next cycle
  -- The CPU's phi2_en tick falls at ph 26 (same divider, same reset), so BA
  -- changes at ph 0 are seen by the CPU a full cycle before its next tick.
  process(clk)
    variable nv        : natural range 0 to V_TOT - 1;
    variable p_pair    : natural range 0 to V_TOT / 2;
    variable r_new     : natural range 0 to RASTER_LINES - 1;
    variable line_start: boolean;
    variable bl        : std_logic;
    variable a14       : unsigned(13 downto 0);
    variable code_v    : std_logic_vector(7 downto 0);
    variable cap       : std_logic_vector(7 downto 0);
    variable mb_v      : natural range 0 to 63;
    variable ba_v      : std_logic;
    variable in_win    : boolean;
    variable f2_v      : f2_t;
    -- pixel variables
    variable xpix      : natural range 0 to 7;
    variable xcur      : natural range 0 to 511;
    variable xscroll_v : natural range 0 to 7;
    variable gsr_v     : std_logic_vector(7 downto 0);
    variable cd_v      : std_logic_vector(11 downto 0);
    variable mcff_v    : std_logic;
    variable mc_pix    : boolean;
    variable pair_v    : std_logic_vector(1 downto 0);
    variable gcol      : natural range 0 to 15;
    variable gfg       : std_logic;
    variable ecm_v, bmm_v, mcm_v : std_logic;
    variable vb_v, mbf_v : std_logic;
    variable bleft, bright : natural range 0 to 511;
    variable btop, bbot    : natural range 0 to 311;
    variable spr_x     : natural range 0 to 511;
    variable act_v     : std_logic;
    variable pos_v     : natural range 0 to 23;
    variable xet_v     : std_logic;
    variable adv_v     : std_logic;
    variable p2        : natural range 0 to 22;
    variable sbit      : std_logic;
    variable spair     : std_logic_vector(1 downto 0);
    variable svis      : std_logic_vector(7 downto 0);
    variable scol_v    : natural range 0 to 15;
    variable sprio_v   : std_logic;
    variable sfound    : std_logic;
    variable nvis      : natural range 0 to 8;
    variable pix       : natural range 0 to 15;
  begin
    if rising_edge(clk) then
      -- single-clk event pulses back to the register process
      raster_irq_set <= '0';
      coll_ss_set <= (others => '0');
      coll_sb_set <= (others => '0');
      lb_we <= '0';

      if reset_n = '0' then
        ph <= 0; cyc <= 1; xbase <= 408; r_line <= RVIS_TOP + 1;
        den_frame <= '0'; disp_state <= '0'; badline_cyc <= '0';
        vcbase <= 0; vcnt <= 0; rc <= 7; vmli <= 0;
        gdata_pend <= (others => '0'); gdata_cur <= (others => '0');
        cdata_pend <= (others => '0'); cdata_cur <= (others => '0');
        gsr <= (others => '0'); g_mcff <= '0'; cd_act <= (others => '0');
        f1_kind <= F1_NONE; f2_kind <= F2_NONE; f_spr <= 0;
        rom_sel1 <= '0'; rom_sel2 <= '0';
        spr_dma <= (others => '0'); spr_disp <= (others => '0');
        spr_expff <= (others => '1');
        spr_mcbase <= (others => 0); spr_mc <= (others => 0);
        spr_act <= (others => '0'); spr_trig <= (others => '0');
        spr_pos <= (others => 0); spr_xet <= (others => '0');
        mbff <= '1'; vbff <= '1';
        ba <= '1';
        vic_addr <= (others => '0');
        color_addr <= (others => '0');
        char_addr <= (others => '0');
      else
        -- ---------- ph / cyc advance, hard line sync ----------
        -- An engine line starts together with each even HDMI line (vc odd ->
        -- next even, or the 625th line wrapping to 0). 64 cycles * 27 clks =
        -- exactly 2 HDMI lines, so this sync is normally a no-op; it realigns
        -- the phantom half-line at vc 624 (raster r_line generated 1.5x).
        line_start := (hc = H_TOT - 1) and
                      ((vc mod 2) = 1 or vc = V_TOT - 1);
        if line_start then
          ph <= 0; cyc <= 1; xbase <= 408;
          if vc = V_TOT - 1 then nv := 0; else nv := vc + 1; end if;
          p_pair := nv / 2;
          r_new := (p_pair + RVIS_TOP + 1) mod RASTER_LINES;
          r_line <= r_new;
          -- Bauer: VCBASE is cleared in raster 0.
          if r_new = 0 then
            vcbase <= 0;
          end if;
          -- DEN latch for the frame's badlines: re-sampled when entering $30.
          if r_new = 48 then
            den_frame <= reg_d011(4);
          end if;
          -- Raster IRQ once per new raster value (dedups the phantom line).
          if r_new /= r_line and r_new = to_integer(raster_cmp) then
            raster_irq_set <= '1';
          end if;
          -- per-line sprite display bookkeeping
          spr_act  <= (others => '0');
          spr_trig <= (others => '0');
          spr_pos  <= (others => 0);
          -- g-data handover for the first cycle of the line
          gdata_cur <= gdata_pend;
          cdata_cur <= cdata_pend;
        elsif ph = PHI_PER_CYC - 1 then
          ph <= 0;
          if cyc < 64 then cyc <= cyc + 1; else cyc <= 1; end if;
          xbase <= (xbase + 8) mod 512;
          gdata_cur <= gdata_pend;
          cdata_cur <= cdata_pend;
        else
          ph <= ph + 1;
        end if;

        -- ---------- cycle start: Bauer per-cycle rules + phi1 fetch ----------
        if ph = 0 then
          -- Badline condition, evaluated live each cycle (FLD/linecrunch).
          if (den_frame = '1' or (r_line = 48 and reg_d011(4) = '1')) and
             r_line >= 48 and r_line <= 247 and
             (r_line mod 8) = to_integer(unsigned(reg_d011(2 downto 0))) then
            bl := '1';
          else
            bl := '0';
          end if;
          badline_cyc <= bl;
          if bl = '1' then
            disp_state <= '1';
          end if;
          if r_line = 48 and reg_d011(4) = '1' then
            den_frame <= '1';
          end if;

          -- Y expansion flip-flop is forced set while YE is cleared.
          for i in 0 to 7 loop
            if reg_d017(i) = '0' then
              spr_expff(i) <= '1';
            end if;
          end loop;

          case cyc is
            when 14 =>
              -- VC <- VCBASE, VMLI <- 0; on a badline RC <- 0.
              vcnt <= vcbase; vmli <= 0;
              if bl = '1' then rc <= 0; end if;
            when 15 =>
              -- expansion flip-flop set -> MCBASE += 2
              for i in 0 to 7 loop
                if spr_dma(i) = '1' and spr_expff(i) = '1' then
                  spr_mcbase(i) <= (spr_mcbase(i) + 2) mod 64;
                end if;
              end loop;
            when 16 =>
              -- expansion flip-flop set -> MCBASE += 1; MCBASE=63 ends DMA.
              for i in 0 to 7 loop
                if spr_dma(i) = '1' and spr_expff(i) = '1' then
                  mb_v := (spr_mcbase(i) + 1) mod 64;
                  spr_mcbase(i) <= mb_v;
                  if mb_v = 63 then
                    spr_dma(i) <= '0';
                  end if;
                end if;
              end loop;
            when 55 | 56 =>
              -- cycle 55: invert expansion ff for YE sprites (once).
              if cyc = 55 then
                for i in 0 to 7 loop
                  if reg_d017(i) = '1' then
                    spr_expff(i) <= not spr_expff(i);
                  end if;
                end loop;
              end if;
              -- DMA-on check (cycles 55 and 56).
              for i in 0 to 7 loop
                if reg_d015(i) = '1' and spr_dma(i) = '0' and
                   to_integer(unsigned(reg_spr_y(i))) = (r_line mod 256) then
                  spr_dma(i) <= '1';
                  spr_mcbase(i) <= 0;
                  if reg_d017(i) = '1' then
                    spr_expff(i) <= '0';
                  end if;
                end if;
              end loop;
            when 58 =>
              -- sprite display on/off + MC <- MCBASE
              for i in 0 to 7 loop
                spr_mc(i) <= spr_mcbase(i);
                if spr_dma(i) = '0' then
                  spr_disp(i) <= '0';
                elsif to_integer(unsigned(reg_spr_y(i))) = (r_line mod 256) then
                  spr_disp(i) <= '1';
                end if;
              end loop;
              -- graphics: RC=7 -> VCBASE <- VC and idle (unless badline)
              if disp_state = '1' then
                if rc = 7 then
                  vcbase <= vcnt;
                  if bl = '0' then
                    disp_state <= '0';
                  else
                    rc <= 0;
                  end if;
                else
                  rc <= rc + 1;
                end if;
              end if;
            when 63 =>
              -- vertical border flip-flop checks at the line's end
              if reg_d011(3) = '1' then
                btop := 51; bbot := 251;
              else
                btop := 55; bbot := 247;
              end if;
              if r_line = bbot then
                vbff <= '1';
              elsif r_line = btop and reg_d011(4) = '1' then
                vbff <= '0';
              end if;
            when others => null;
          end case;

          -- BA: badline character fetch window + sprite fetch windows.
          if bl = '1' and cyc >= 12 and cyc <= 54 then
            ba_v := '0';
          else
            ba_v := '1';
          end if;
          for i in 0 to 7 loop
            if spr_dma(i) = '1' then
              case i is
                when 0 => in_win := cyc >= 55 and cyc <= 59;
                when 1 => in_win := cyc >= 57 and cyc <= 61;
                when 2 => in_win := cyc >= 59 and cyc <= 63;
                when 3 => in_win := cyc >= 61 or  cyc <= 2;   -- wraps over pad
                when 4 => in_win := cyc >= 63 or  cyc <= 4;
                when 5 => in_win := cyc >= 2  and cyc <= 6;
                when 6 => in_win := cyc >= 4  and cyc <= 8;
                when others => in_win := cyc >= 6 and cyc <= 10;
              end case;
              if in_win then ba_v := '0'; end if;
            end if;
          end loop;
          ba <= ba_v;

          -- phi1 fetch: sprite pointer / sprite data byte 1 / g-access.
          f1_kind <= F1_NONE;
          a14 := (others => '1');                       -- $3FFF idle default
          if cyc = PCYC(0) or cyc = PCYC(1) or cyc = PCYC(2) or
             cyc = PCYC(3) or cyc = PCYC(4) or cyc = PCYC(5) or
             cyc = PCYC(6) or cyc = PCYC(7) then
            for i in 0 to 7 loop
              if cyc = PCYC(i) then
                -- p-access: video matrix + $3F8 + n (always performed)
                a14 := unsigned(reg_d018(7 downto 4)) & "1111111" &
                       to_unsigned(i, 3);
                f1_kind <= F1_P; f_spr <= i;
              end if;
            end loop;
          elsif cyc = PCYC(0)+1 or cyc = PCYC(1)+1 or cyc = PCYC(2)+1 or
                cyc = PCYC(3)+1 or cyc = PCYC(4)+1 or cyc = PCYC(5)+1 or
                cyc = PCYC(6)+1 or cyc = PCYC(7)+1 then
            for i in 0 to 7 loop
              if cyc = PCYC(i) + 1 and spr_dma(i) = '1' then
                a14 := unsigned(spr_ptr(i)) & to_unsigned(spr_mc(i), 6);
                f1_kind <= F1_S1; f_spr <= i;
              end if;
            end loop;
          elsif cyc >= 16 and cyc <= 55 then
            if disp_state = '1' then
              code_v := vmbuf(vmli)(7 downto 0);
              if reg_d011(5) = '1' then                 -- BMM bitmap
                a14 := reg_d018(3) & to_unsigned(vcnt, 10) &
                       to_unsigned(rc, 3);
              else                                      -- text
                a14 := unsigned(reg_d018(3 downto 1)) &
                       unsigned(code_v) & to_unsigned(rc, 3);
              end if;
            end if;                                     -- idle: $3FFF
            if reg_d011(6) = '1' then                   -- ECM clears A10/A9
              a14(10 downto 9) := "00";
            end if;
            f1_kind <= F1_G;
          end if;
          vic_addr <= std_logic_vector(unsigned(vic_bank) & a14);
          char_addr <= std_logic_vector(a14(11 downto 0));
          if (vic_bank = "00" or vic_bank = "10") and
             a14(13 downto 12) = "01" then
            rom_sel1 <= '1';
          else
            rom_sel1 <= '0';
          end if;
        end if;

        -- ---------- ph 3: capture phi1 data ----------
        if ph = 3 then
          if rom_sel1 = '1' then cap := char_data; else cap := vic_data; end if;
          case f1_kind is
            when F1_G  => gdata_pend <= cap;
            when F1_P  => spr_ptr(f_spr) <= cap;
            when F1_S1 =>
              spr_dat(f_spr)(15 downto 8) <= cap;
              spr_mc(f_spr) <= (spr_mc(f_spr) + 1) mod 64;
            when F1_NONE => null;
          end case;
        end if;

        -- ---------- ph 4: g-access pipeline bookkeeping ----------
        if ph = 4 then
          if f1_kind = F1_G then
            if disp_state = '1' then
              cdata_pend <= vmbuf(vmli);
              if vmli < 40 then vmli <= vmli + 1; end if;
              vcnt <= (vcnt + 1) mod 1024;
            else
              cdata_pend <= (others => '0');            -- idle: matrix data 0
            end if;
          else
            gdata_pend <= (others => '0');
            cdata_pend <= (others => '0');
          end if;
        end if;

        -- ---------- ph 5: phi2 fetch address ----------
        if ph = 5 then
          f2_v := F2_NONE;
          a14 := (others => '1');
          for i in 0 to 7 loop
            if spr_dma(i) = '1' then
              if cyc = PCYC(i) then
                a14 := unsigned(spr_ptr(i)) & to_unsigned(spr_mc(i), 6);
                f2_v := F2_S0; f_spr <= i;
              elsif cyc = PCYC(i) + 1 then
                a14 := unsigned(spr_ptr(i)) & to_unsigned(spr_mc(i), 6);
                f2_v := F2_S2; f_spr <= i;
              end if;
            end if;
          end loop;
          if badline_cyc = '1' and cyc >= 15 and cyc <= 54 and
             f2_v = F2_NONE then
            a14 := unsigned(reg_d018(7 downto 4)) & to_unsigned(vcnt, 10);
            f2_v := F2_C;
          end if;
          f2_kind <= f2_v;
          vic_addr <= std_logic_vector(unsigned(vic_bank) & a14);
          char_addr <= std_logic_vector(a14(11 downto 0));
          color_addr <= std_logic_vector(to_unsigned(vcnt, 10));
          if (vic_bank = "00" or vic_bank = "10") and
             a14(13 downto 12) = "01" then
            rom_sel2 <= '1';
          else
            rom_sel2 <= '0';
          end if;
        end if;

        -- ---------- ph 8: capture phi2 data ----------
        if ph = 8 then
          if rom_sel2 = '1' then cap := char_data; else cap := vic_data; end if;
          case f2_kind is
            when F2_C  =>
              if vmli < 40 then
                vmbuf(vmli) <= color_data & cap;
              end if;
            when F2_S0 =>
              spr_dat(f_spr)(23 downto 16) <= cap;
              spr_mc(f_spr) <= (spr_mc(f_spr) + 1) mod 64;
            when F2_S2 =>
              spr_dat(f_spr)(7 downto 0) <= cap;
              spr_mc(f_spr) <= (spr_mc(f_spr) + 1) mod 64;
            when F2_NONE => null;
          end case;
        end if;

        -- ---------- ph 16..23: the cycle's 8 pixels ----------
        if ph >= 16 and ph <= 23 then
          xpix := ph - 16;
          xcur := (xbase + xpix) mod 512;
          ecm_v := reg_d011(6); bmm_v := reg_d011(5); mcm_v := reg_d016(4);
          xscroll_v := to_integer(unsigned(reg_d016(2 downto 0)));

          -- graphics shifter: reload at the XSCROLL match point
          if xpix = xscroll_v then
            gsr_v  := gdata_cur;
            cd_v   := cdata_cur;
            mcff_v := '0';
          else
            gsr_v  := gsr;
            cd_v   := cd_act;
            mcff_v := g_mcff;
          end if;

          -- pixel decode (live mode bits; invalid modes render black)
          pair_v := gsr_v(7 downto 6);
          mc_pix := false;
          gfg := gsr_v(7);
          gcol := to_integer(unsigned(reg_d021));
          if bmm_v = '1' then
            if mcm_v = '1' then
              mc_pix := true;
              gfg := pair_v(1);
              case pair_v is
                when "00" => gcol := to_integer(unsigned(reg_d021));
                when "01" => gcol := to_integer(unsigned(cd_v(7 downto 4)));
                when "10" => gcol := to_integer(unsigned(cd_v(3 downto 0)));
                when others => gcol := to_integer(unsigned(cd_v(11 downto 8)));
              end case;
            else
              if gsr_v(7) = '1' then
                gcol := to_integer(unsigned(cd_v(7 downto 4)));
              else
                gcol := to_integer(unsigned(cd_v(3 downto 0)));
              end if;
            end if;
          elsif mcm_v = '1' and cd_v(11) = '1' then
            -- multicolour text (colour bit 3 set)
            mc_pix := true;
            gfg := pair_v(1);
            case pair_v is
              when "00" => gcol := to_integer(unsigned(reg_d021));
              when "01" => gcol := to_integer(unsigned(reg_d022));
              when "10" => gcol := to_integer(unsigned(reg_d023));
              when others =>
                gcol := to_integer(unsigned('0' & cd_v(10 downto 8)));
            end case;
          else
            -- standard / ECM text (and hires side of MCM text)
            if gsr_v(7) = '1' then
              if mcm_v = '1' then
                gcol := to_integer(unsigned('0' & cd_v(10 downto 8)));
              else
                gcol := to_integer(unsigned(cd_v(11 downto 8)));
              end if;
            else
              if ecm_v = '1' then
                case cd_v(7 downto 6) is
                  when "00" => gcol := to_integer(unsigned(reg_d021));
                  when "01" => gcol := to_integer(unsigned(reg_d022));
                  when "10" => gcol := to_integer(unsigned(reg_d023));
                  when others => gcol := to_integer(unsigned(reg_d024));
                end case;
              else
                gcol := to_integer(unsigned(reg_d021));
              end if;
            end if;
          end if;
          -- invalid modes (ECM with BMM and/or MCM): black, fg kept
          if ecm_v = '1' and (bmm_v = '1' or mcm_v = '1') then
            gcol := 0;
          end if;

          -- advance the shifter
          if mc_pix then
            if mcff_v = '1' then
              gsr_v := gsr_v(5 downto 0) & "00";
            end if;
            mcff_v := not mcff_v;
          else
            gsr_v := gsr_v(6 downto 0) & '0';
          end if;
          gsr <= gsr_v; cd_act <= cd_v; g_mcff <= mcff_v;

          -- ---- sprite units ----
          svis := (others => '0');
          scol_v := 0; sprio_v := '0'; sfound := '0';
          for i in 7 downto 0 loop
            spr_x := to_integer(unsigned(reg_spr_x_lo(i)));
            if reg_d010(i) = '1' then spr_x := spr_x + 256; end if;

            act_v := spr_act(i);
            pos_v := spr_pos(i);
            xet_v := spr_xet(i);
            if act_v = '0' and spr_trig(i) = '0' and spr_disp(i) = '1' and
               xcur < 504 and xcur = spr_x then
              act_v := '1'; pos_v := 0; xet_v := '0';
              spr_trig(i) <= '1';
            end if;

            if act_v = '1' then
              if reg_d01c(i) = '1' then
                p2 := pos_v - (pos_v mod 2);
                spair := spr_dat(i)(23 - p2) & spr_dat(i)(22 - p2);
                if spair /= "00" then
                  svis(i) := '1';
                  sfound := '1';
                  sprio_v := reg_d01b(i);
                  case spair is
                    when "01" => scol_v := to_integer(unsigned(reg_d025));
                    when "10" => scol_v := to_integer(unsigned(reg_spr_col(i)));
                    when others => scol_v := to_integer(unsigned(reg_d026));
                  end case;
                end if;
              else
                sbit := spr_dat(i)(23 - pos_v);
                if sbit = '1' then
                  svis(i) := '1';
                  sfound := '1';
                  sprio_v := reg_d01b(i);
                  scol_v := to_integer(unsigned(reg_spr_col(i)));
                end if;
              end if;

              -- advance (X expansion halves the shift rate)
              if reg_d01d(i) = '1' then
                adv_v := xet_v;
                xet_v := not xet_v;
              else
                adv_v := '1';
              end if;
              if adv_v = '1' then
                if pos_v = 23 then
                  act_v := '0';
                else
                  pos_v := pos_v + 1;
                end if;
              end if;
            end if;

            spr_act(i) <= act_v;
            spr_pos(i) <= pos_v;
            spr_xet(i) <= xet_v;
          end loop;

          -- collisions (registered pulses to the register process)
          nvis := 0;
          for i in 0 to 7 loop
            if svis(i) = '1' then nvis := nvis + 1; end if;
          end loop;
          if nvis >= 2 then
            coll_ss_set <= svis;
          end if;
          if gfg = '1' then
            coll_sb_set <= svis;
          end if;

          -- ---- border unit ----
          vb_v := vbff; mbf_v := mbff;
          if reg_d016(3) = '1' then
            bleft := 24; bright := 344;
          else
            bleft := 31; bright := 335;
          end if;
          if reg_d011(3) = '1' then
            btop := 51; bbot := 251;
          else
            btop := 55; bbot := 247;
          end if;
          if xcur = bright then
            mbf_v := '1';
          end if;
          if xcur = bleft then
            if r_line = bbot then
              vb_v := '1';
            elsif r_line = btop and reg_d011(4) = '1' then
              vb_v := '0';
            end if;
            if vb_v = '0' then
              mbf_v := '0';
            end if;
          end if;
          vbff <= vb_v; mbff <= mbf_v;

          -- ---- priority + final pixel ----
          if mbf_v = '1' then
            pix := to_integer(unsigned(reg_d020));   -- border covers sprites
          elsif sfound = '1' and (sprio_v = '0' or gfg = '0') then
            pix := scol_v;
          else
            pix := gcol;
          end if;

          lb_we <= '1';
          if (r_line mod 2) = 1 then
            lb_waddr <= 512 + xcur;
          else
            lb_waddr <= xcur;
          end if;
          lb_wdata <= std_logic_vector(to_unsigned(pix, 4));
        end if;
      end if;
    end if;
  end process;

  -- line buffer write port (engine) -- registered request from the pixel step
  process(clk)
  begin
    if rising_edge(clk) then
      if lb_we = '1' then
        lb(lb_waddr) <= lb_wdata;
      end if;
    end if;
  end process;

  -- ===================== register file + IRQ =====================
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        reg_spr_x_lo <= (others => (others => '0'));
        reg_spr_y <= (others => (others => '0'));
        reg_d010 <= x"00"; reg_d011 <= x"1B"; reg_d015 <= x"00";
        reg_d016 <= x"08"; reg_d017 <= x"00"; reg_d018 <= x"15";
        reg_d01b <= x"00"; reg_d01c <= x"00"; reg_d01d <= x"00";
        reg_d01e <= x"00"; reg_d01f <= x"00";
        reg_d020 <= x"E"; reg_d021 <= x"6";
        reg_d022 <= x"0"; reg_d023 <= x"0"; reg_d024 <= x"0";
        reg_d025 <= x"0"; reg_d026 <= x"0";
        reg_spr_col <= (others => x"0");
        raster_cmp <= (others => '0');
        irq_latch <= (others => '0'); irq_en <= (others => '0');
        d01e_pend_clr <= '0'; d01f_pend_clr <= '0';
      else
        -- raster IRQ from the engine
        if raster_irq_set = '1' then
          irq_latch(0) <= '1';
        end if;
        -- collision latches: IRQ only on the 0 -> nonzero transition
        if coll_sb_set /= x"00" then
          if reg_d01f = x"00" then
            irq_latch(1) <= '1';
          end if;
          reg_d01f <= reg_d01f or coll_sb_set;
        end if;
        if coll_ss_set /= x"00" then
          if reg_d01e = x"00" then
            irq_latch(2) <= '1';
          end if;
          reg_d01e <= reg_d01e or coll_ss_set;
        end if;

        -- $D01E/$D01F read-clears, executed when the read access ENDS so the
        -- CPU still samples the pre-clear value during the stretched cycle.
        if cs = '1' and we = '0' and addr = "011110" then
          d01e_pend_clr <= '1';
        elsif d01e_pend_clr = '1' then
          reg_d01e <= x"00";
          d01e_pend_clr <= '0';
        end if;
        if cs = '1' and we = '0' and addr = "011111" then
          d01f_pend_clr <= '1';
        elsif d01f_pend_clr = '1' then
          reg_d01f <= x"00";
          d01f_pend_clr <= '0';
        end if;

        if cs = '1' and we = '1' then
          if addr(5 downto 4) = "00" then                    -- $D000-$D00F
            if addr(0) = '0' then
              reg_spr_x_lo(to_integer(unsigned(addr(3 downto 1)))) <= din;
            else
              reg_spr_y(to_integer(unsigned(addr(3 downto 1)))) <= din;
            end if;
          else
            case addr is
              when "010000" => reg_d010 <= din;               -- $D010
              when "010001" => reg_d011 <= din;               -- $D011
                               raster_cmp(8) <= din(7);
              when "010010" => raster_cmp(7 downto 0) <= unsigned(din);
              when "010101" => reg_d015 <= din;               -- $D015
              when "010110" => reg_d016 <= din;               -- $D016
              when "010111" => reg_d017 <= din;               -- $D017
              when "011000" => reg_d018 <= din;               -- $D018
              when "011001" =>                                -- $D019 ack
                irq_latch <= irq_latch and not din(3 downto 0);
              when "011010" => irq_en <= din(3 downto 0);     -- $D01A
              when "011011" => reg_d01b <= din;               -- $D01B
              when "011100" => reg_d01c <= din;               -- $D01C
              when "011101" => reg_d01d <= din;               -- $D01D
              when "100000" => reg_d020 <= din(3 downto 0);   -- $D020
              when "100001" => reg_d021 <= din(3 downto 0);
              when "100010" => reg_d022 <= din(3 downto 0);
              when "100011" => reg_d023 <= din(3 downto 0);
              when "100100" => reg_d024 <= din(3 downto 0);
              when "100101" => reg_d025 <= din(3 downto 0);
              when "100110" => reg_d026 <= din(3 downto 0);
              when "100111" => reg_spr_col(0) <= din(3 downto 0);
              when "101000" => reg_spr_col(1) <= din(3 downto 0);
              when "101001" => reg_spr_col(2) <= din(3 downto 0);
              when "101010" => reg_spr_col(3) <= din(3 downto 0);
              when "101011" => reg_spr_col(4) <= din(3 downto 0);
              when "101100" => reg_spr_col(5) <= din(3 downto 0);
              when "101101" => reg_spr_col(6) <= din(3 downto 0);
              when "101110" => reg_spr_col(7) <= din(3 downto 0);
              when others => null;
            end case;
          end if;
        end if;
      end if;
    end if;
  end process;

  irq_out <= '1' when (irq_latch and irq_en) /= "0000" else '0';
  irq_n <= not irq_out;

  -- register read-back (unused bits read as 1 like the real chip)
  process(addr, reg_spr_x_lo, reg_spr_y, reg_d010, reg_d011, reg_d015,
          reg_d016, reg_d017, reg_d018, reg_d01b, reg_d01c, reg_d01d,
          reg_d01e, reg_d01f, reg_d020, reg_d021, reg_d022, reg_d023,
          reg_d024, reg_d025, reg_d026, reg_spr_col,
          irq_latch, irq_en, irq_out, r_line)
    variable rv : unsigned(8 downto 0);
  begin
    rv := to_unsigned(r_line, 9);
    if addr(5 downto 4) = "00" then
      if addr(0) = '0' then
        dout <= reg_spr_x_lo(to_integer(unsigned(addr(3 downto 1))));
      else
        dout <= reg_spr_y(to_integer(unsigned(addr(3 downto 1))));
      end if;
    else
      case addr is
        when "010000" => dout <= reg_d010;
        when "010001" => dout <= rv(8) & reg_d011(6 downto 0);
        when "010010" => dout <= std_logic_vector(rv(7 downto 0));
        when "010011" => dout <= x"6E";                 -- light pen X (stub)
        when "010100" => dout <= x"8C";                 -- light pen Y (stub)
        when "010101" => dout <= reg_d015;
        when "010110" => dout <= "11" & reg_d016(5 downto 0);
        when "010111" => dout <= reg_d017;
        when "011000" => dout <= reg_d018(7 downto 1) & '1';
        when "011001" => dout <= irq_out & "111" & irq_latch;
        when "011010" => dout <= "1111" & irq_en;
        when "011011" => dout <= reg_d01b;
        when "011100" => dout <= reg_d01c;
        when "011101" => dout <= reg_d01d;
        when "011110" => dout <= reg_d01e;
        when "011111" => dout <= reg_d01f;
        when "100000" => dout <= x"F" & reg_d020;
        when "100001" => dout <= x"F" & reg_d021;
        when "100010" => dout <= x"F" & reg_d022;
        when "100011" => dout <= x"F" & reg_d023;
        when "100100" => dout <= x"F" & reg_d024;
        when "100101" => dout <= x"F" & reg_d025;
        when "100110" => dout <= x"F" & reg_d026;
        when "100111" => dout <= x"F" & reg_spr_col(0);
        when "101000" => dout <= x"F" & reg_spr_col(1);
        when "101001" => dout <= x"F" & reg_spr_col(2);
        when "101010" => dout <= x"F" & reg_spr_col(3);
        when "101011" => dout <= x"F" & reg_spr_col(4);
        when "101100" => dout <= x"F" & reg_spr_col(5);
        when "101101" => dout <= x"F" & reg_spr_col(6);
        when "101110" => dout <= x"F" & reg_spr_col(7);
        when others   => dout <= x"FF";
      end case;
    end if;
  end process;

  -- ===================== display readout =====================
  -- HDMI line pair p shows raster p+RVIS_TOP, which the engine finished during
  -- pair p-1 (it generates raster p+RVIS_TOP+1 during pair p, the opposite
  -- buffer half) -- so read and write never touch the same line.
  process(clk)
    variable xd : natural range 0 to 511;
    variable rd : natural range 0 to RASTER_LINES + RVIS_TOP;
  begin
    if rising_edge(clk) then
      -- stage 1: buffer read + sync, both registered once
      xd := XVIS_LEFT + hc / 2;
      rd := vc / 2 + RVIS_TOP;
      if (rd mod 2) = 1 then
        lb_q <= lb(512 + xd);
      else
        lb_q <= lb(xd);
      end if;
      if hc >= H_SS and hc < H_SE then hs_d <= '0'; else hs_d <= '1'; end if;
      if vc >= V_SS and vc < V_SE then vs_d <= '0'; else vs_d <= '1'; end if;
      if hc < H_VIS and vc < V_VIS then de_d <= '1'; else de_d <= '0'; end if;

      -- stage 2: palette, registered outputs (2-clk latency, sync aligned)
      vga_r  <= PAL_R(to_integer(unsigned(lb_q)));
      vga_g  <= PAL_G(to_integer(unsigned(lb_q)));
      vga_b  <= PAL_B(to_integer(unsigned(lb_q)));
      vga_hs <= hs_d;
      vga_vs <= vs_d;
      vga_de <= de_d;
    end if;
  end process;
end architecture;
