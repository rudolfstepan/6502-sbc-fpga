-- Self-checking testbench for vic_blit: drives FILL and LINE ops, models the
-- framebuffer byte-write port (with latency), and compares every framebuffer
-- byte against a reference software Bresenham/fill computed here.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_vic_blit is
end entity;

architecture sim of tb_vic_blit is
  constant LINE_PIX : positive := 640;
  constant NBYTES   : natural  := 65536;   -- test coords kept below this addr

  signal clk      : std_logic := '0';
  signal rst_n    : std_logic := '0';
  signal op       : std_logic_vector(2 downto 0) := (others => '0');
  signal x0,y0    : unsigned(9 downto 0) := (others => '0');
  signal x1,y1    : unsigned(9 downto 0) := (others => '0');
  signal color    : std_logic_vector(7 downto 0) := (others => '0');
  signal start    : std_logic := '0';
  signal busy     : std_logic;
  signal fbo_we   : std_logic;
  signal fbo_addr : std_logic_vector(17 downto 0);
  signal fbo_data : std_logic_vector(7 downto 0);
  signal fbo_ready: std_logic := '0';
  signal fbi_re   : std_logic;
  signal fbi_addr : std_logic_vector(17 downto 0);
  signal fbi_data : std_logic_vector(7 downto 0) := (others => '0');
  signal fbi_ready: std_logic := '0';
  signal tex_base : unsigned(17 downto 0) := (others => '0');
  signal tex_u0, tex_v0, tex_dudx, tex_dvdx, tex_dudy, tex_dvdy : signed(15 downto 0) := (others => '0');
  signal tex_flags : std_logic_vector(7 downto 0) := (others => '0');

  type mem_t is array (0 to NBYTES-1) of std_logic_vector(7 downto 0);
  signal fb : mem_t := (others => (others => '0'));

  constant OP_FILL : std_logic_vector(2 downto 0) := "000";
  constant OP_LINE : std_logic_vector(2 downto 0) := "011";
  constant OP_TEX  : std_logic_vector(2 downto 0) := "100";
begin

  dut : entity work.vic_blit
    generic map (LINE_PIX => LINE_PIX, ADDR_BITS => 18)
    port map (
      clk => clk, rst_n => rst_n,
      op => op, x0 => x0, y0 => y0, x1 => x1, y1 => y1,
      color => color, start => start, busy => busy,
      tex_base => tex_base, tex_u0 => tex_u0, tex_v0 => tex_v0,
      tex_dudx => tex_dudx, tex_dvdx => tex_dvdx,
      tex_dudy => tex_dudy, tex_dvdy => tex_dvdy, tex_flags => tex_flags,
      fbo_we => fbo_we, fbo_addr => fbo_addr, fbo_data => fbo_data,
      fbo_ready => fbo_ready,
      fbi_re => fbi_re, fbi_addr => fbi_addr, fbi_data => fbi_data,
      fbi_ready => fbi_ready);

  clk <= not clk after 5 ns;

  -- framebuffer write model: accept a byte after 2 wait cycles (exercises the
  -- engine's S_EMIT handshake) and store it.
  mem : process(clk)
    variable wc : integer := 0;
    variable rc : integer := 0;
  begin
    if rising_edge(clk) then
      fbo_ready <= '0';
      fbi_ready <= '0';
      if fbo_we = '1' then
        if wc >= 2 then
          fb(to_integer(unsigned(fbo_addr))) <= fbo_data;
          fbo_ready <= '1';
          wc := 0;
        else
          wc := wc + 1;
        end if;
      else
        wc := 0;
      end if;
      if fbi_re = '1' then
        if rc >= 1 then
          fbi_data <= fbi_addr(7 downto 0);
          fbi_ready <= '1';
          rc := 0;
        else
          rc := rc + 1;
        end if;
      else
        rc := 0;
      end if;
    end if;
  end process;

  stim : process
    variable ref : mem_t := (others => (others => '0'));
    variable mism : integer := 0;

    procedure ref_fill(variable m : inout mem_t;
                       ax0, ay0, ax1, ay1 : integer; c : std_logic_vector) is
      variable lx0, lx1, ly0, ly1, xx, yy : integer;
    begin
      lx0 := minimum(ax0, ax1); lx1 := maximum(ax0, ax1);
      ly0 := minimum(ay0, ay1); ly1 := maximum(ay0, ay1);
      yy := ly0;
      while yy <= ly1 loop
        xx := lx0;
        while xx <= lx1 loop
          m(yy * LINE_PIX + xx) := c;
          xx := xx + 1;
        end loop;
        yy := yy + 1;
      end loop;
    end procedure;

    procedure ref_line(variable m : inout mem_t;
                       ax0, ay0, ax1, ay1 : integer; c : std_logic_vector) is
      variable x, y, dx, dy, sx, sy, e, e2 : integer;
    begin
      dx := abs(ax1 - ax0); dy := abs(ay1 - ay0);
      if ax0 < ax1 then sx := 1; else sx := -1; end if;
      if ay0 < ay1 then sy := 1; else sy := -1; end if;
      x := ax0; y := ay0; e := dx - dy;
      loop
        m(y * LINE_PIX + x) := c;
        exit when x = ax1 and y = ay1;
        e2 := 2 * e;
        if e2 > -dy then e := e - dy; x := x + sx; end if;
        if e2 <  dx then e := e + dx; y := y + sy; end if;
      end loop;
    end procedure;

    procedure ref_tex_identity(variable m : inout mem_t;
                               ax0, ay0, ax1, ay1 : integer) is
      variable x, y : integer;
    begin
      y := ay0;
      while y <= ay1 loop
        x := ax0;
        while x <= ax1 loop
          m(y * LINE_PIX + x) := std_logic_vector(to_unsigned(((y - ay0) * 64 + (x - ax0)) mod 256, 8));
          x := x + 1;
        end loop;
        y := y + 1;
      end loop;
    end procedure;

    procedure do_cmd(o : std_logic_vector(2 downto 0);
                     ax0, ay0, ax1, ay1 : integer; c : std_logic_vector) is
    begin
      op    <= o;
      x0    <= to_unsigned(ax0, 10); y0 <= to_unsigned(ay0, 10);
      x1    <= to_unsigned(ax1, 10); y1 <= to_unsigned(ay1, 10);
      color <= c;
      wait until rising_edge(clk);
      start <= '1';
      wait until rising_edge(clk);
      start <= '0';
      wait until busy = '1';
      wait until busy = '0';
      wait until rising_edge(clk);
    end procedure;
  begin
    rst_n <= '0';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst_n <= '1';
    wait until rising_edge(clk);

    -- a filled rectangle, then lines in several octants (incl. steep & reversed)
    do_cmd(OP_FILL, 2,  3,  9,  6, x"AB"); ref_fill(ref, 2,  3,  9,  6, x"AB");
    do_cmd(OP_LINE, 0,  0, 20, 10, x"FF"); ref_line(ref, 0,  0, 20, 10, x"FF");
    do_cmd(OP_LINE, 30, 5,  5, 25, x"55"); ref_line(ref, 30, 5,  5, 25, x"55");
    do_cmd(OP_LINE, 5, 40, 45, 42, x"11"); ref_line(ref, 5, 40, 45, 42, x"11");
    do_cmd(OP_LINE, 12, 12, 12, 30, x"22"); ref_line(ref, 12, 12, 12, 30, x"22"); -- vertical
    do_cmd(OP_LINE, 8, 50, 40, 50, x"33"); ref_line(ref, 8, 50, 40, 50, x"33");   -- horizontal
    do_cmd(OP_LINE, 33, 33, 33, 33, x"44"); ref_line(ref, 33, 33, 33, 33, x"44"); -- single pixel
    tex_base <= to_unsigned(0, 18);
    tex_u0 <= to_signed(0, 16); tex_v0 <= to_signed(0, 16);
    tex_dudx <= to_signed(256, 16); tex_dvdx <= to_signed(0, 16);
    tex_dudy <= to_signed(0, 16); tex_dvdy <= to_signed(256, 16);
    tex_flags <= x"00";
    do_cmd(OP_TEX, 50, 8, 55, 11, x"00"); ref_tex_identity(ref, 50, 8, 55, 11);

    -- compare every byte
    for i in 0 to NBYTES-1 loop
      if fb(i) /= ref(i) then
        mism := mism + 1;
        if mism <= 8 then
          report "MISMATCH addr=" & integer'image(i) &
                 " x=" & integer'image(i mod LINE_PIX) &
                 " y=" & integer'image(i / LINE_PIX) &
                 " dut=" & to_hstring(fb(i)) & " ref=" & to_hstring(ref(i))
            severity warning;
        end if;
      end if;
    end loop;

    if mism = 0 then
      report "tb_vic_blit: PASS (fill + lines + texture fill match reference)" severity note;
    else
      report "tb_vic_blit: FAIL, " & integer'image(mism) & " mismatched bytes"
        severity failure;
    end if;
    std.env.stop;
  end process;

end architecture;
