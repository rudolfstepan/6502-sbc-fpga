-- Verifies CPU framebuffer byte writes through vic_fb_ddr3. The hardware path
-- uses a DDR3 read-modify-write burst so sustained CPU pixel streams do not
-- rely on Gowin byte masks for every single pixel.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_vic_fb_ddr3_cpu_write is
end entity;

architecture sim of tb_vic_fb_ddr3_cpu_write is
  constant NBYTES : natural := 128;

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
  signal blit_busy : std_logic;

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
  signal ddr3 : mem_t := (others => x"A5");
begin

  dut : entity work.vic_fb_ddr3
    generic map (HIRES_BASE_WORD => 0)
    port map (
      clk_sys => clk_sys, rst_sys_n => rst_n,
      hires => hires, bpp16 => bpp16,
      fb_frame_start => fb_frame_start, fb_line_adv => fb_line_adv,
      fb_rdaddr => fb_rdaddr, fb_rddata => fb_rddata,
      cpu_req => cpu_req, cpu_we => cpu_we, cpu_addr => cpu_addr,
      cpu_din => cpu_din, cpu_dout => cpu_dout, cpu_ack => cpu_ack,
      blit_busy => blit_busy,
      clk_x1 => clk_x1, calib_done => calib_done,
      app_cmd_rdy => app_cmd_rdy, app_cmd => app_cmd, app_cmd_en => app_cmd_en,
      app_addr => app_addr, app_wdata => app_wdata, app_wdata_mask => app_wdata_mask,
      app_wren => app_wren, app_wdata_end => app_wdata_end,
      app_wdata_rdy => app_wdata_rdy, app_rdata => app_rdata,
      app_rdata_valid => app_rdata_valid);

  clk_sys <= not clk_sys after 15 ns;
  clk_x1  <= not clk_x1  after 5 ns;

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
          rcnt := 2;
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
    procedure cpu_write(a : natural; d : std_logic_vector(7 downto 0)) is
    begin
      wait until rising_edge(clk_sys);
      cpu_addr <= std_logic_vector(to_unsigned(a, cpu_addr'length));
      cpu_din <= d;
      cpu_we <= '1';
      cpu_req <= '1';
      wait until rising_edge(clk_sys);
      cpu_req <= '0';
      loop
        wait until rising_edge(clk_sys);
        exit when cpu_ack = '1';
      end loop;
      cpu_we <= '0';
    end procedure;

    procedure cpu_read_expect(a : natural; d : std_logic_vector(7 downto 0)) is
    begin
      wait until rising_edge(clk_sys);
      cpu_addr <= std_logic_vector(to_unsigned(a, cpu_addr'length));
      cpu_we <= '0';
      cpu_req <= '1';
      wait until rising_edge(clk_sys);
      cpu_req <= '0';
      loop
        wait until rising_edge(clk_sys);
        exit when cpu_ack = '1';
      end loop;
      wait for 1 ns;
      assert cpu_dout = d
        report "CPU read mismatch at " & integer'image(a) &
               ": got " & to_hstring(cpu_dout) &
               " expected " & to_hstring(d)
        severity failure;
    end procedure;
  begin
    rst_n <= '0';
    for i in 1 to 5 loop wait until rising_edge(clk_x1); end loop;
    rst_n <= '1';
    calib_done <= '1';
    for i in 1 to 8 loop wait until rising_edge(clk_x1); end loop;

    cpu_write(1,  x"11");
    cpu_write(5,  x"55");
    cpu_write(15, x"FF");
    cpu_write(16, x"10");

    wait until rising_edge(clk_sys);
    fb_frame_start <= '1';
    wait until rising_edge(clk_sys);
    fb_frame_start <= '0';
    for i in 1 to 80 loop wait until rising_edge(clk_x1); end loop;

    assert ddr3(0) = x"A5" report "lane 0 was corrupted" severity failure;
    assert ddr3(1) = x"11" report "lane 1 write missing" severity failure;
    assert ddr3(5) = x"55" report "lane 5 write missing" severity failure;
    assert ddr3(15) = x"FF" report "lane 15 write missing" severity failure;
    assert ddr3(16) = x"10" report "next burst lane 0 write missing" severity failure;
    assert ddr3(17) = x"A5" report "next burst lane 1 was corrupted" severity failure;

    cpu_read_expect(1,  x"11");
    cpu_read_expect(5,  x"55");
    cpu_read_expect(15, x"FF");
    cpu_read_expect(16, x"10");

    report "tb_vic_fb_ddr3_cpu_write: PASS (CPU byte writes preserve burst neighbours)" severity note;
    std.env.stop;
  end process;

end architecture;
