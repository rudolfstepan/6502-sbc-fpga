-- Verifies the blitter integrated into vic_fb_ddr3: drives the CPU blit command
-- registers to run a FILL and a LINE, models the Gowin DDR3 app port with a byte
-- array, and compares every framebuffer byte against a reference. The hi-res
-- frame base is moved to 0 (generic) so the memory model stays small.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_vic_fb_ddr3_blit is
end entity;

architecture sim of tb_vic_fb_ddr3_blit is
  constant LINE_PIX : natural := 640;
  constant NBYTES   : natural := 4096;   -- test coords kept in this range

  signal clk_sys, clk_x1 : std_logic := '0';
  signal rst_n           : std_logic := '0';

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

  signal blit_op    : std_logic_vector(2 downto 0) := (others => '0');
  signal blit_x0, blit_y0, blit_x1, blit_y1 : unsigned(9 downto 0) := (others => '0');
  signal blit_color : std_logic_vector(7 downto 0) := (others => '0');
  signal blit_page  : std_logic := '0';
  signal blit_start : std_logic := '0';
  signal blit_busy  : std_logic;

  signal calib_done      : std_logic := '0';
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

  type mem_t is array (0 to NBYTES-1) of std_logic_vector(7 downto 0);
  signal ddr3 : mem_t := (others => (others => '0'));

  constant OP_FILL : std_logic_vector(2 downto 0) := "000";
  constant OP_LINE : std_logic_vector(2 downto 0) := "011";
begin

  dut : entity work.vic_fb_ddr3
    generic map (HIRES_BASE_WORD => 0)   -- put the hi-res frame at byte 0
    port map (
      clk_sys => clk_sys, rst_sys_n => rst_n,
      hires => hires, bpp16 => bpp16,
      fb_frame_start => fb_frame_start, fb_line_adv => fb_line_adv,
      fb_rdaddr => fb_rdaddr, fb_rddata => fb_rddata,
      cpu_req => cpu_req, cpu_we => cpu_we, cpu_addr => cpu_addr,
      cpu_din => cpu_din, cpu_dout => cpu_dout, cpu_ack => cpu_ack,
      blit_op => blit_op, blit_x0 => blit_x0, blit_y0 => blit_y0,
      blit_x1 => blit_x1, blit_y1 => blit_y1, blit_color => blit_color,
      blit_page => blit_page, blit_start => blit_start, blit_busy => blit_busy,
      clk_x1 => clk_x1, calib_done => calib_done,
      app_cmd_rdy => app_cmd_rdy, app_cmd => app_cmd, app_cmd_en => app_cmd_en,
      app_addr => app_addr, app_wdata => app_wdata, app_wdata_mask => app_wdata_mask,
      app_wren => app_wren, app_wdata_end => app_wdata_end,
      app_wdata_rdy => app_wdata_rdy, app_rdata => app_rdata,
      app_rdata_valid => app_rdata_valid);

  clk_sys <= not clk_sys after 15 ns;   -- ~33 MHz
  clk_x1  <= not clk_x1  after 5 ns;    -- 100 MHz

  -- Mock Gowin DDR3 app port: always ready; a BL8 write masks 16 bytes into the
  -- array at (app_addr*2); a read returns the 16 bytes after 2 cycles.
  mem : process(clk_x1)
    variable waddr : natural := 0;
    variable raddr : natural := 0;
    variable rcnt  : integer := -1;
  begin
    if rising_edge(clk_x1) then
      app_rdata_valid <= '0';
      if app_cmd_en = '1' then
        if app_cmd = "000" then
          waddr := to_integer(unsigned(app_addr)) * 2;
        else
          raddr := to_integer(unsigned(app_addr)) * 2;
          rcnt  := 2;
        end if;
      end if;
      if app_wren = '1' then
        for i in 0 to 15 loop
          if app_wdata_mask(i) = '0' and (waddr + i) < NBYTES then
            ddr3(waddr + i) <= app_wdata(i*8 + 7 downto i*8);
          end if;
        end loop;
      end if;
      if rcnt = 0 then
        for i in 0 to 15 loop
          if (raddr + i) < NBYTES then
            app_rdata(i*8 + 7 downto i*8) <= ddr3(raddr + i);
          else
            app_rdata(i*8 + 7 downto i*8) <= (others => '0');
          end if;
        end loop;
        app_rdata_valid <= '1';
      end if;
      if rcnt >= 0 then rcnt := rcnt - 1; end if;
    end if;
  end process;

  stim : process
    variable ref : mem_t := (others => (others => '0'));
    variable mism : integer := 0;

    procedure ref_fill(variable m : inout mem_t; ax0,ay0,ax1,ay1:integer; c:std_logic_vector) is
      variable a : integer;
    begin
      for yy in minimum(ay0,ay1) to maximum(ay0,ay1) loop
        for xx in minimum(ax0,ax1) to maximum(ax0,ax1) loop
          a := yy*LINE_PIX+xx; if a < NBYTES then m(a) := c; end if;
        end loop;
      end loop;
    end procedure;

    procedure ref_line(variable m : inout mem_t; ax0,ay0,ax1,ay1:integer; c:std_logic_vector) is
      variable x,y,dx,dy,sx,sy,e,e2,a : integer;
    begin
      dx := abs(ax1-ax0); dy := abs(ay1-ay0);
      if ax0<ax1 then sx:=1; else sx:=-1; end if;
      if ay0<ay1 then sy:=1; else sy:=-1; end if;
      x:=ax0; y:=ay0; e:=dx-dy;
      loop
        a := y*LINE_PIX+x; if a < NBYTES then m(a) := c; end if;
        exit when x=ax1 and y=ay1;
        e2:=2*e;
        if e2 > -dy then e:=e-dy; x:=x+sx; end if;
        if e2 <  dx then e:=e+dx; y:=y+sy; end if;
      end loop;
    end procedure;

    procedure do_blit(o:std_logic_vector(2 downto 0); ax0,ay0,ax1,ay1:integer; c:std_logic_vector) is
    begin
      blit_op    <= o;
      blit_x0 <= to_unsigned(ax0,10); blit_y0 <= to_unsigned(ay0,10);
      blit_x1 <= to_unsigned(ax1,10); blit_y1 <= to_unsigned(ay1,10);
      blit_color <= c;
      wait until rising_edge(clk_sys);
      blit_start <= '1';
      wait until rising_edge(clk_sys);
      blit_start <= '0';
      wait until blit_busy = '1';
      wait until blit_busy = '0';
      wait until rising_edge(clk_sys);
    end procedure;
  begin
    rst_n <= '0';
    for i in 0 to 4 loop wait until rising_edge(clk_x1); end loop;
    rst_n <= '1';
    calib_done <= '1';
    for i in 0 to 8 loop wait until rising_edge(clk_x1); end loop;

    do_blit(OP_FILL, 1,1, 5,3, x"AB"); ref_fill(ref, 1,1, 5,3, x"AB");
    do_blit(OP_LINE, 0,0, 9,5, x"FF"); ref_line(ref, 0,0, 9,5, x"FF");
    do_blit(OP_LINE, 8,0, 0,4, x"55"); ref_line(ref, 8,0, 0,4, x"55");
    -- a long shallow line: heavy write-combining incl. burst crossings
    do_blit(OP_LINE, 0,1, 200,3, x"77"); ref_line(ref, 0,1, 200,3, x"77");

    -- the last combine buffer flushes lazily after the engine goes idle
    for i in 1 to 300 loop wait until rising_edge(clk_x1); end loop;

    for i in 0 to NBYTES-1 loop
      if ddr3(i) /= ref(i) then
        mism := mism + 1;
        if mism <= 8 then
          report "MISMATCH byte " & integer'image(i) &
                 " x=" & integer'image(i mod LINE_PIX) & " y=" & integer'image(i / LINE_PIX) &
                 " dut=" & to_hstring(ddr3(i)) & " ref=" & to_hstring(ref(i)) severity warning;
        end if;
      end if;
    end loop;

    if mism = 0 then
      report "tb_vic_fb_ddr3_blit: PASS (blitter FILL+LINE wrote correct DDR3 bytes)" severity note;
    else
      report "tb_vic_fb_ddr3_blit: FAIL, " & integer'image(mism) & " bytes differ" severity failure;
    end if;
    std.env.stop;
  end process;

end architecture;
