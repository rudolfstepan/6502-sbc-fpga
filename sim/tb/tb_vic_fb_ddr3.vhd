-- Testbench: vic_fb_ddr3 blitter data paths on the DDR3 app port.
--
-- Embeds a behavioral model of the Gowin DDR3 IP app interface (128-bit
-- beats, masked writes, fixed read latency) with a byte memory. clk_sys and
-- clk_x1 run at 50/100 MHz so every CDC toggle crosses real clock domains.
--
-- Focus: the OP_TEX read path (one-burst read cache + write-combine
-- coherency) with a rotated all-negative-gradient face in UV-clip mode --
-- the access pattern a rotating textured cube produces once per revolution.
-- Also re-checks FILL and an axis-aligned TEX identity map. Every pixel of
-- the destination is verified through the CPU byte port.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_vic_fb_ddr3 is
end entity;

architecture sim of tb_vic_fb_ddr3 is
  constant HIRES_BASE : natural := 262144;

  signal clk_sys : std_logic := '0';
  signal clk_x1  : std_logic := '0';
  signal rst_n   : std_logic := '0';

  signal hires : std_logic := '1';
  signal bpp16 : std_logic := '0';

  signal fb_frame_start : std_logic := '0';
  signal fb_line_adv    : std_logic := '0';
  signal fb_rdaddr      : std_logic_vector(10 downto 0) := (others => '0');
  signal fb_rddata      : std_logic_vector(15 downto 0);

  signal cpu_req  : std_logic := '0';
  signal cpu_we   : std_logic := '0';
  signal cpu_addr : std_logic_vector(17 downto 0) := (others => '0');
  signal cpu_din  : std_logic_vector(7 downto 0) := (others => '0');
  signal cpu_dout : std_logic_vector(7 downto 0);
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
  signal blit_start : std_logic := '0';
  signal blit_busy  : std_logic;

  signal calib_done      : std_logic := '1';
  signal app_cmd_rdy     : std_logic := '1';
  signal app_cmd         : std_logic_vector(2 downto 0);
  signal app_cmd_en      : std_logic;
  signal app_addr        : std_logic_vector(26 downto 0);
  signal app_wdata       : std_logic_vector(127 downto 0);
  signal app_wdata_mask  : std_logic_vector(15 downto 0);
  signal app_wren        : std_logic;
  signal app_wdata_end   : std_logic;
  signal app_wdata_rdy   : std_logic := '1';
  signal app_rdata       : std_logic_vector(127 downto 0) := (others => '0');
  signal app_rdata_valid : std_logic := '0';

  signal done : boolean := false;

  function pat(a : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(((a mod 256) + 5 * ((a / 256) mod 51)) mod 256, 8));
  end function;
begin
  clk_sys <= not clk_sys after 10 ns when not done else '0';
  clk_x1  <= not clk_x1 after 5 ns when not done else '0';

  dut : entity work.vic_fb_ddr3
    generic map (FB_BASE_WORD => 0, LINE_PIX => 320, NUM_LINES => 200,
                 HIRES_BASE_WORD => HIRES_BASE, HIRES_LINE_PIX => 640,
                 HIRES_NUM_LINES => 400, TRUE_BASE_WORD => 524288,
                 APP_ADDR_BITS => 27)
    port map (
      clk_sys   => clk_sys,
      rst_sys_n => rst_n,
      hires     => hires,
      bpp16     => bpp16,
      fb_frame_start => fb_frame_start,
      fb_line_adv    => fb_line_adv,
      fb_rdaddr      => fb_rdaddr,
      fb_rddata      => fb_rddata,
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
      clk_x1          => clk_x1,
      calib_done      => calib_done,
      app_cmd_rdy     => app_cmd_rdy,
      app_cmd         => app_cmd,
      app_cmd_en      => app_cmd_en,
      app_addr        => app_addr,
      app_wdata       => app_wdata,
      app_wdata_mask  => app_wdata_mask,
      app_wren        => app_wren,
      app_wdata_end   => app_wdata_end,
      app_wdata_rdy   => app_wdata_rdy,
      app_rdata       => app_rdata,
      app_rdata_valid => app_rdata_valid
    );

  -- ── Gowin DDR3 app-port model ─────────────────────────────────────────────
  -- app_addr is a 16-bit-word address, one BL8 beat = 16 bytes. Reads answer
  -- after a fixed latency; writes take the next app_wren beat and apply the
  -- byte mask ('0' = write). Memory covers the hires frame + texture pad.
  app_model : process(clk_x1)
    type mem_t is array (0 to 3 * 262144 - 1) of std_logic_vector(7 downto 0);
    function init_mem return mem_t is
      variable m : mem_t;
    begin
      for i in m'range loop
        m(i) := pat(i mod 262144);   -- pattern within each 256 KiB region
      end loop;
      return m;
    end function;
    variable mem      : mem_t := init_mem;
    variable rd_pend  : integer := -1;   -- pending read byte base, -1 = none
    variable rd_delay : natural := 0;
    variable wr_pend  : integer := -1;   -- pending write byte base
    variable byte_base: natural;
  begin
    if rising_edge(clk_x1) then
      app_rdata_valid <= '0';
      -- serve a pending read after the latency
      if rd_pend >= 0 then
        if rd_delay = 0 then
          for k in 0 to 15 loop
            app_rdata(k*8 + 7 downto k*8) <= mem(rd_pend + k);
          end loop;
          app_rdata_valid <= '1';
          rd_pend := -1;
        else
          rd_delay := rd_delay - 1;
        end if;
      end if;
      -- accept a command
      if app_cmd_en = '1' then
        byte_base := to_integer(unsigned(app_addr)) * 2;
        byte_base := (byte_base / 16) * 16;
        if app_cmd = "001" then          -- read
          assert rd_pend = -1 report "model: read overrun" severity failure;
          rd_pend  := byte_base;
          rd_delay := 11;
        else                             -- write
          wr_pend := byte_base;
        end if;
      end if;
      -- accept write data
      if app_wren = '1' then
        assert wr_pend >= 0 report "model: wren without command" severity failure;
        for k in 0 to 15 loop
          if app_wdata_mask(k) = '0' then
            mem(wr_pend + k) := app_wdata(k*8 + 7 downto k*8);
          end if;
        end loop;
        wr_pend := -1;
      end if;
    end if;
  end process;

  -- ── stimulus ──────────────────────────────────────────────────────────────
  stim : process
    variable tr_ru, tr_rv, tr_u, tr_v : integer;
    variable tr_uw, tr_vw : integer;

    procedure tick(n : natural) is
    begin
      for i in 1 to n loop
        wait until rising_edge(clk_sys);
      end loop;
    end procedure;

    procedure blit_wait is
    begin
      blit_start <= '1';
      tick(1);
      blit_start <= '0';
      tick(8);
      wait until blit_busy = '0' for 10 ms;
      assert blit_busy = '0' report "blit busy timeout" severity failure;
      wait until rising_edge(clk_sys);
    end procedure;

    procedure cpu_write(a : natural; d : std_logic_vector(7 downto 0)) is
    begin
      -- like the core's fbw port: we/addr/din stay stable until the ack
      cpu_addr <= std_logic_vector(to_unsigned(a, 18));
      cpu_din  <= d;
      cpu_we   <= '1';
      cpu_req  <= '1';
      tick(1);
      cpu_req  <= '0';
      wait until cpu_ack = '1' for 1 ms;
      assert cpu_ack = '1' report "cpu write ack timeout" severity failure;
      wait until rising_edge(clk_sys);
      cpu_we   <= '0';
    end procedure;

    procedure cpu_read(a : natural; exp : std_logic_vector(7 downto 0);
                       msg : string) is
    begin
      cpu_addr <= std_logic_vector(to_unsigned(a, 18));
      cpu_we   <= '0';
      cpu_req  <= '1';
      tick(1);
      cpu_req  <= '0';
      wait until cpu_ack = '1' for 1 ms;
      assert cpu_ack = '1' report "cpu read ack timeout" severity failure;
      -- cpu_dout is one delta behind cpu_ack in this DUT (concurrent copy of
      -- cpu_dout_reg); sample after the next edge like the real CPU does
      wait until rising_edge(clk_sys);
      assert cpu_dout = exp
        report msg & ": read " & integer'image(to_integer(unsigned(cpu_dout))) &
               ", expected " & integer'image(to_integer(unsigned(exp)))
        severity failure;
    end procedure;

    procedure blit_fill(x0, y0, x1, y1 : natural;
                        col : std_logic_vector(7 downto 0)) is
    begin
      blit_x0 <= to_unsigned(x0, 10);
      blit_y0 <= to_unsigned(y0, 10);
      blit_x1 <= to_unsigned(x1, 10);
      blit_y1 <= to_unsigned(y1, 10);
      blit_color <= col;
      blit_op <= "000";
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
      blit_op <= "100";
      blit_wait;
    end procedure;
  begin
    rst_n <= '0';
    tick(10);
    rst_n <= '1';
    tick(20);
    pulse_fs : fb_frame_start <= '1';
    tick(1);
    fb_frame_start <= '0';
    tick(400);                  -- let the initial line fetches drain

    -- CPU byte port sanity in the hires frame (base + pattern)
    cpu_read(1234, pat(1234), "cpu pattern read");
    cpu_write(1234, x"5A");
    cpu_read(1234, x"5A", "cpu write readback");

    -- ── axis-aligned TEX identity: texture block at pixel index 256000
    -- (the demo's hidden pad), 1 texel per pixel ─────────────────────────────
    blit_tex(40, 80, 55, 87, 256000, 0, 0, 256, 0, 0, 256, x"00");
    cpu_read(80 * 640 + 40, pat(256000),            "ddr3 tex identity (0,0)");
    cpu_read(87 * 640 + 55, pat(256000 + 7*64 + 15),"ddr3 tex identity (15,7)");

    -- ── rotated face, all-negative gradients, clip mode: full pixel check ──
    blit_fill(30, 125, 59, 162, x"33");
    blit_tex(30, 125, 59, 162, 256000, 30280, 30895, -1044, -501, -376, -835,
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
                   pat(256000 + (tr_vw / 256) * 64 + (tr_uw / 256)),
                   "ddr3 texrot inside (" & integer'image(xx) & "," &
                   integer'image(yy) & ")");
        else
          cpu_read(yy * 640 + xx, x"33",
                   "ddr3 texrot clipped (" & integer'image(xx) & "," &
                   integer'image(yy) & ")");
        end if;
        tr_u := tr_u - 1044;
        tr_v := tr_v - 501;
      end loop;
      tr_ru := tr_ru - 376;
      tr_rv := tr_rv - 835;
    end loop;

    report "TB PASSED: vic_fb_ddr3 CPU port, FILL + TEX (identity/rotated clip) OK";
    done <= true;
    wait;
  end process;

end architecture;
