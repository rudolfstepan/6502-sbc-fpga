-- Testbench: sdram_fb chunked full-page line prefetch + CPU byte port.
--
-- Embeds a small behavioral SDR-SDRAM model (CL=3, sequential full-page read
-- bursts, single-location writes, DQM byte masking). The model memory powers
-- up with a deterministic pattern so the TB can check that:
--   * the hi-res (640x400) and legacy (320x200) line prefetch deliver the
--     right bytes into both line-buffer halves, with read bursts split at the
--     512-word SDRAM page boundary;
--   * a single-cycle CPU request pulse issued while a line fetch is in flight
--     is latched (not dropped), acknowledged, and lands in memory;
--   * the written pixel is visible when its line is refetched.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sbc_pkg.all;

entity tb_sdram_fb is
end entity;

architecture sim of tb_sdram_fb is
  constant CLK_HALF : time    := 10 ns;   -- 50 MHz
  constant SCANLINE : natural := 1600;    -- 50 MHz clocks per 640x480 scanline

  signal clk     : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal ready   : std_logic;

  signal fb_frame_start : std_logic := '0';
  signal fb_line_adv    : std_logic := '0';
  signal fb_rdaddr      : std_logic_vector(10 downto 0) := (others => '0');
  signal fb_rddata      : std_logic_vector(15 downto 0);
  signal hires          : std_logic := '1';

  signal cpu_req  : std_logic := '0';
  signal cpu_we   : std_logic := '0';
  signal cpu_addr : std_logic_vector(17 downto 0) := (others => '0');
  signal cpu_din  : data_t := (others => '0');
  signal cpu_dout : data_t;
  signal cpu_ack  : std_logic;

  signal blit_op   : std_logic_vector(2 downto 0) := (others => '0');
  signal blit_x0   : unsigned(9 downto 0) := (others => '0');
  signal blit_y0   : unsigned(9 downto 0) := (others => '0');
  signal blit_x1   : unsigned(9 downto 0) := (others => '0');
  signal blit_y1   : unsigned(9 downto 0) := (others => '0');
  signal blit_color: std_logic_vector(7 downto 0) := (others => '0');
  signal blit_dstx : unsigned(9 downto 0) := (others => '0');
  signal blit_dsty : unsigned(9 downto 0) := (others => '0');
  signal blit_tex_base  : unsigned(17 downto 0) := (others => '0');
  signal blit_tex_u0    : signed(15 downto 0) := (others => '0');
  signal blit_tex_v0    : signed(15 downto 0) := (others => '0');
  signal blit_tex_dudx  : signed(15 downto 0) := (others => '0');
  signal blit_tex_dvdx  : signed(15 downto 0) := (others => '0');
  signal blit_tex_dudy  : signed(15 downto 0) := (others => '0');
  signal blit_tex_dvdy  : signed(15 downto 0) := (others => '0');
  signal blit_tex_flags : std_logic_vector(7 downto 0) := (others => '0');
  signal blit_start: std_logic := '0';
  signal blit_busy : std_logic;

  signal sdram_cke   : std_logic;
  signal sdram_cs_n  : std_logic;
  signal sdram_ras_n : std_logic;
  signal sdram_cas_n : std_logic;
  signal sdram_we_n  : std_logic;
  signal sdram_ba    : std_logic_vector(1 downto 0);
  signal sdram_addr  : std_logic_vector(12 downto 0);
  signal sdram_dqm   : std_logic_vector(1 downto 0);
  signal sdram_dq    : std_logic_vector(15 downto 0);

  signal model_dq : std_logic_vector(15 downto 0) := (others => 'Z');

  signal done : boolean := false;
  signal trlog : boolean := false;     -- log blit read/write ops (debug)

  -- Deterministic power-up pattern, distinct across neighbouring addresses
  -- and across the 512-word page boundary.
  function pat(a : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(((a mod 256) + 5 * ((a / 256) mod 51)) mod 256, 8));
  end function;
begin
  clk <= not clk after CLK_HALF when not done else '0';

  dut : entity work.sdram_fb
    port map (
      clk       => clk,
      reset_n   => reset_n,
      ready     => ready,
      fb_frame_start => fb_frame_start,
      fb_line_adv    => fb_line_adv,
      fb_rdaddr      => fb_rdaddr,
      fb_rddata      => fb_rddata,
      hires          => hires,
      cpu_req   => cpu_req,
      cpu_we    => cpu_we,
      cpu_addr  => cpu_addr,
      cpu_din   => cpu_din,
      cpu_dout  => cpu_dout,
      cpu_ack   => cpu_ack,
      blit_op    => blit_op,
      blit_x0    => blit_x0,
      blit_y0    => blit_y0,
      blit_x1    => blit_x1,
      blit_y1    => blit_y1,
      blit_color => blit_color,
      blit_dstx  => blit_dstx,
      blit_dsty  => blit_dsty,
      blit_tex_base  => blit_tex_base,
      blit_tex_u0    => blit_tex_u0,
      blit_tex_v0    => blit_tex_v0,
      blit_tex_dudx  => blit_tex_dudx,
      blit_tex_dvdx  => blit_tex_dvdx,
      blit_tex_dudy  => blit_tex_dudy,
      blit_tex_dvdy  => blit_tex_dvdy,
      blit_tex_flags => blit_tex_flags,
      blit_start => blit_start,
      blit_busy  => blit_busy,
      sdram_cke   => sdram_cke,
      sdram_cs_n  => sdram_cs_n,
      sdram_ras_n => sdram_ras_n,
      sdram_cas_n => sdram_cas_n,
      sdram_we_n  => sdram_we_n,
      sdram_ba    => sdram_ba,
      sdram_addr  => sdram_addr,
      sdram_dqm   => sdram_dqm,
      sdram_dq    => sdram_dq
    );

  sdram_dq <= model_dq;

  -- debug monitor: log the DUT's internal blit read/write completions
  dbg_mon : process(clk)
  begin
    if rising_edge(clk) then
      if trlog then
        if <<signal dut.blit_rd_ready_r : std_logic>> = '1' then
          report "TRD saddr=" & integer'image(to_integer(unsigned(
            <<signal dut.blit_rd_addr : std_logic_vector(17 downto 0)>>)));
        end if;
        if <<signal dut.blit_ready : std_logic>> = '1' then
          report "TWR addr=" & integer'image(to_integer(unsigned(
            <<signal dut.blit_addr : std_logic_vector(17 downto 0)>>)));
        end if;
      end if;
    end if;
  end process;

  -- ── Behavioral SDR-SDRAM model ────────────────────────────────────────────
  -- CL=3 read pipeline: a READ sampled at edge E delivers the word at column
  -- col0+i so the controller samples it at edge E+3+i. Full-page bursts wrap
  -- the column inside the 512-word page and stream until PRECHARGE.
  model : process(clk)
    type mem_t is array (0 to 512 * 512 - 1) of std_logic_vector(7 downto 0);
    function init_mem return mem_t is
      variable m : mem_t;
    begin
      for i in m'range loop
        m(i) := pat(i);
      end loop;
      return m;
    end function;
    variable mem      : mem_t := init_mem;
    variable row_lat  : natural range 0 to 8191 := 0;
    variable col_cnt  : natural range 0 to 511 := 0;
    variable reading  : boolean := false;
    variable st1, st2 : std_logic_vector(15 downto 0) := (others => '0');
    variable oe1, oe2 : boolean := false;
    variable widx     : natural;
  begin
    if rising_edge(clk) then
      -- two registered stages between the array lookup and the bus give the
      -- CL=3 alignment derived above
      st2 := st1;
      oe2 := oe1;
      if reading then
        st1 := x"00" & mem(row_lat * 512 + col_cnt);
        col_cnt := (col_cnt + 1) mod 512;
      end if;
      oe1 := reading;

      if sdram_cs_n = '0' then
        if sdram_ras_n = '0' and sdram_cas_n = '1' and sdram_we_n = '1' then
          -- ACTIVE
          row_lat := to_integer(unsigned(sdram_addr));
          if trlog then
            report "ACT row=" & integer'image(row_lat);
          end if;
          assert to_integer(unsigned(sdram_ba)) = 0
            report "model: bank /= 0" severity failure;
          assert row_lat < 512
            report "model: row out of modelled range" severity failure;
        elsif sdram_ras_n = '1' and sdram_cas_n = '0' and sdram_we_n = '1' then
          -- READ (full-page burst)
          col_cnt := to_integer(unsigned(sdram_addr(8 downto 0)));
          reading := true;
          if trlog then
            report "RDC col=" & integer'image(col_cnt);
          end if;
        elsif sdram_ras_n = '1' and sdram_cas_n = '0' and sdram_we_n = '0' then
          -- WRITE (single location; DQM masks bytes, low byte carries pixels)
          widx := row_lat * 512 + to_integer(unsigned(sdram_addr(8 downto 0)));
          if trlog then
            report "SDWR a=" & integer'image(widx) & " d=" &
                   integer'image(to_integer(unsigned(sdram_dq(7 downto 0)))) &
                   " m=" & std_logic'image(sdram_dqm(0));
          end if;
          if sdram_dqm(0) = '0' then
            mem(widx) := sdram_dq(7 downto 0);
          end if;
        elsif sdram_ras_n = '0' and sdram_cas_n = '1' and sdram_we_n = '0' then
          -- PRECHARGE terminates the read burst
          reading := false;
        end if;
        -- MRS and AUTO REFRESH are ignored
      end if;

      if oe2 then
        model_dq <= st2;
      else
        model_dq <= (others => 'Z');
      end if;
    end if;
  end process;

  -- ── Stimulus ──────────────────────────────────────────────────────────────
  stim : process
    procedure tick(n : natural) is
    begin
      for i in 1 to n loop
        wait until rising_edge(clk);
      end loop;
    end procedure;

    procedure pulse(signal s : out std_logic) is
    begin
      s <= '1';
      tick(1);
      s <= '0';
    end procedure;

    procedure check_lbuf(idx : natural; exp : std_logic_vector(7 downto 0);
                         msg : string) is
    begin
      fb_rdaddr <= std_logic_vector(to_unsigned(idx, 11));
      tick(2);
      assert fb_rddata(7 downto 0) = exp
        report msg & ": lbuf(" & integer'image(idx) & ") = " &
               integer'image(to_integer(unsigned(fb_rddata(7 downto 0)))) &
               ", expected " & integer'image(to_integer(unsigned(exp)))
        severity failure;
    end procedure;

    procedure cpu_write(a : natural; d : std_logic_vector(7 downto 0)) is
    begin
      cpu_addr <= std_logic_vector(to_unsigned(a, 18));
      cpu_din  <= d;
      cpu_we   <= '1';
      pulse(cpu_req);
      cpu_we   <= '0';
      wait until cpu_ack = '1' for 200 us;
      assert cpu_ack = '1' report "cpu write: ack timeout" severity failure;
      wait until rising_edge(clk);
    end procedure;

    procedure blit_copy(sx0, sy0, sx1, sy1, dx, dy : natural;
                        transparent : boolean) is
    begin
      blit_x0   <= to_unsigned(sx0, 10);
      blit_y0   <= to_unsigned(sy0, 10);
      blit_x1   <= to_unsigned(sx1, 10);
      blit_y1   <= to_unsigned(sy1, 10);
      blit_dstx <= to_unsigned(dx, 10);
      blit_dsty <= to_unsigned(dy, 10);
      if transparent then
        blit_op <= "010";                -- OP_COPYT
      else
        blit_op <= "001";                -- OP_COPY
      end if;
      pulse(blit_start);
      tick(2);
      wait until blit_busy = '0' for 2 ms;
      assert blit_busy = '0' report "blit copy: busy timeout" severity failure;
      wait until rising_edge(clk);
    end procedure;

    procedure blit_wait is
    begin
      pulse(blit_start);
      tick(2);
      wait until blit_busy = '0' for 2 ms;
      assert blit_busy = '0' report "blit: busy timeout" severity failure;
      wait until rising_edge(clk);
    end procedure;

    procedure blit_fill(x0, y0, x1, y1 : natural;
                        col : std_logic_vector(7 downto 0)) is
    begin
      blit_x0 <= to_unsigned(x0, 10);
      blit_y0 <= to_unsigned(y0, 10);
      blit_x1 <= to_unsigned(x1, 10);
      blit_y1 <= to_unsigned(y1, 10);
      blit_color <= col;
      blit_op <= "000";                  -- OP_FILL
      blit_wait;
    end procedure;

    procedure blit_tex(x0, y0, x1, y1, base : natural;
                       u0, v0, dudx, dvdx, dudy, dvdy : integer;
                       flags : std_logic_vector(7 downto 0)) is
    begin
      blit_x0 <= to_unsigned(x0, 10);
      blit_y0 <= to_unsigned(y0, 10);
      blit_x1 <= to_unsigned(x1, 10);
      blit_y1 <= to_unsigned(y1, 10);
      blit_tex_base  <= to_unsigned(base, 18);
      blit_tex_u0    <= to_signed(u0, 16);
      blit_tex_v0    <= to_signed(v0, 16);
      blit_tex_dudx  <= to_signed(dudx, 16);
      blit_tex_dvdx  <= to_signed(dvdx, 16);
      blit_tex_dudy  <= to_signed(dudy, 16);
      blit_tex_dvdy  <= to_signed(dvdy, 16);
      blit_tex_flags <= flags;
      blit_op <= "100";                  -- OP_TEX
      blit_wait;
    end procedure;

    variable tr_ru, tr_rv, tr_u, tr_v : integer;
    variable tr_uw, tr_vw : integer;

    procedure cpu_read(a : natural; exp : std_logic_vector(7 downto 0);
                       msg : string) is
    begin
      cpu_addr <= std_logic_vector(to_unsigned(a, 18));
      cpu_we   <= '0';
      pulse(cpu_req);
      wait until cpu_ack = '1' for 200 us;
      assert cpu_ack = '1' report "cpu read: ack timeout" severity failure;
      assert cpu_dout = exp
        report msg & ": read " & integer'image(to_integer(unsigned(cpu_dout))) &
               ", expected " & integer'image(to_integer(unsigned(exp)))
        severity failure;
      wait until rising_edge(clk);
    end procedure;
  begin
    reset_n <= '0';
    tick(10);
    reset_n <= '1';
    wait until ready = '1' for 1 ms;
    assert ready = '1' report "sdram_fb never became ready" severity failure;
    tick(10);

    -- ── hi-res geometry: frame start prefetches lines 0 and 1 ──────────────
    hires <= '1';
    pulse(fb_frame_start);
    tick(SCANLINE);
    for i in 0 to 639 loop
      check_lbuf(i, pat(i), "hires line0");
      check_lbuf(640 + i, pat(640 + i), "hires line1");
    end loop;

    -- ── CPU write issued while a line fetch is in flight ────────────────────
    pulse(fb_line_adv);              -- display line 1; fetch of line 2 starts
    tick(4);                         -- request lands mid-fetch
    cpu_write(3 * 640 + 7, x"AB");
    cpu_read(3 * 640 + 7, x"AB", "cpu readback");
    cpu_read(3 * 640 + 8, pat(3 * 640 + 8), "cpu readback neighbour");

    -- ── the written pixel appears when line 3 is (re)fetched ────────────────
    pulse(fb_line_adv);              -- display line 2
    tick(SCANLINE);
    pulse(fb_line_adv);              -- display line 3 -> line 3 in half 1
    tick(SCANLINE);
    check_lbuf(640 + 7, x"AB", "hires refetch of written pixel");
    check_lbuf(640 + 8, pat(3 * 640 + 8), "hires refetch neighbour");

    -- ── write INTO the currently buffered line: must invalidate + refetch ───
    -- (writes to other lines no longer invalidate the halves, so this checks
    -- the in-range case explicitly: no line_adv, the refetch happens because
    -- the write hit half 1's buffered range)
    cpu_write(3 * 640 + 9, x"5C");
    tick(SCANLINE);
    check_lbuf(640 + 9, x"5C", "in-range write refetch");
    check_lbuf(640 + 7, x"AB", "in-range write neighbour kept");

    -- ── blitter COPY: non-overlapping rect ──────────────────────────────────
    -- copy the 8x2 source rect (4,1)-(11,2) to destination (100,50)
    blit_copy(4, 1, 11, 2, 100, 50, false);
    for j in 0 to 1 loop
      for i in 0 to 7 loop
        cpu_read((50 + j) * 640 + 100 + i, pat((1 + j) * 640 + 4 + i),
                 "copy dst");
      end loop;
    end loop;
    cpu_read(1 * 640 + 4, pat(1 * 640 + 4), "copy src intact");

    -- ── blitter MOVE: overlapping copy right+down (backward walk required) ──
    -- src rows 5..6 cols 10..17 -> dst (12,6): overlap on row 6 cols 12..17.
    -- A forward walk would read already-overwritten source bytes here.
    blit_copy(10, 5, 17, 6, 12, 6, false);
    for j in 0 to 1 loop
      for i in 0 to 7 loop
        cpu_read((6 + j) * 640 + 12 + i, pat((5 + j) * 640 + 10 + i),
                 "overlap move dst");
      end loop;
    end loop;

    -- ── transparent COPY: source byte $00 leaves the destination alone ──────
    cpu_write(10 * 640 + 200, x"00");
    cpu_write(10 * 640 + 201, x"77");
    cpu_write(20 * 640 + 300, x"55");
    cpu_write(20 * 640 + 301, x"56");
    blit_copy(200, 10, 201, 10, 300, 20, true);
    cpu_read(20 * 640 + 300, x"55", "copyt skipped $00 source");
    cpu_read(20 * 640 + 301, x"77", "copyt copied nonzero source");

    -- ── OP_TEX identity mapping (wrap mode): 16x8 rect, 1 texel per pixel ──
    -- texture = linear 64-stride block at pixel index 96000; memory holds the
    -- power-up pattern there, so texel (u,v) = pat(96000 + v*64 + u)
    blit_tex(40, 80, 55, 87, 96000, 0, 0, 256, 0, 0, 256, x"00");
    cpu_read(80 * 640 + 40,      pat(96000),           "tex identity (0,0)");
    cpu_read(80 * 640 + 55,      pat(96000 + 15),      "tex identity (15,0)");
    cpu_read(87 * 640 + 40,      pat(96000 + 7*64),    "tex identity (0,7)");
    cpu_read(87 * 640 + 55,      pat(96000 + 7*64+15), "tex identity (15,7)");
    cpu_read(83 * 640 + 47,      pat(96000 + 3*64+7),  "tex identity (7,3)");

    -- ── OP_TEX wrap: U0 = 60 texels, wraps to 0 after 4 pixels ─────────────
    blit_tex(40, 90, 55, 91, 96000, 60*256, 0, 256, 0, 0, 256, x"00");
    cpu_read(90 * 640 + 40, pat(96000 + 60),     "tex wrap u=60");
    cpu_read(90 * 640 + 44, pat(96000 + 0),      "tex wrap u=64->0");
    cpu_read(90 * 640 + 55, pat(96000 + 11),     "tex wrap u=75->11");

    -- ── OP_TEX clip: U starts at -4 texels; the first 4 columns must be
    -- skipped (destination keeps its fill colour), the rest maps texels 0.. ──
    blit_fill(70, 80, 85, 87, x"22");
    blit_tex(70, 80, 85, 87, 96000, -4*256, 0, 256, 0, 0, 256, x"02");
    cpu_read(80 * 640 + 70, x"22",               "tex clip col 0 skipped");
    cpu_read(80 * 640 + 73, x"22",               "tex clip col 3 skipped");
    cpu_read(80 * 640 + 74, pat(96000),          "tex clip col 4 = texel 0");
    cpu_read(87 * 640 + 85, pat(96000 + 7*64+11),"tex clip col 15 = texel 11");

    -- ── OP_TEX rotated face: ALL-negative gradients, u0/v0 near the i16
    -- limit, clip mode -- the quadrant case a rotating cube hits once per
    -- revolution. Every pixel of the bounding box is checked against the
    -- same affine walk computed here in the TB. ─────────────────────────────
    -- texture block at 153600 (row 240+): must NOT overlap the destination
    -- rect -- the first version of this test placed it at 96000 = row 150 and
    -- the preparation fill painted over its own texture
    blit_fill(30, 125, 59, 162, x"33");
    blit_tex(30, 125, 59, 162, 153600, 30280, 30895, -1044, -501, -376, -835,
             x"02");
    tr_ru := 30280;
    tr_rv := 30895;
    for yy in 125 to 162 loop
      tr_u := tr_ru;
      tr_v := tr_rv;
      for xx in 30 to 59 loop
        tr_uw := tr_u mod 65536;
        tr_vw := tr_v mod 65536;
        if tr_uw < 16384 and tr_vw < 16384 then
          cpu_read(yy * 640 + xx,
                   pat(153600 + (tr_vw / 256) * 64 + (tr_uw / 256)),
                   "texrot inside (" & integer'image(xx) & "," &
                   integer'image(yy) & ") u=" & integer'image(tr_uw) &
                   " v=" & integer'image(tr_vw));
        else
          cpu_read(yy * 640 + xx, x"33",
                   "texrot clipped (" & integer'image(xx) & "," &
                   integer'image(yy) & ")");
        end if;
        tr_u := tr_u - 1044;
        tr_v := tr_v - 501;
      end loop;
      tr_ru := tr_ru - 376;
      tr_rv := tr_rv - 835;
    end loop;

    -- ── legacy 320x200 geometry ─────────────────────────────────────────────
    hires <= '0';
    pulse(fb_frame_start);
    tick(SCANLINE);
    for i in 0 to 319 loop
      check_lbuf(i, pat(i), "lores line0");
      check_lbuf(640 + i, pat(320 + i), "lores line1");
    end loop;

    report "TB PASSED: sdram_fb line fetch, CPU port, COPY/MOVE + TEX (wrap/clip) OK";
    done <= true;
    wait;
  end process;

end architecture;
