-- Proves the display line fetch is serviced promptly: after every fb_line_adv
-- the controller must issue the next line's read bursts within a scanline
-- budget. The S_SELECT arbiter stage only refreshes its registered fetch-need
-- flags in S_IDLE; if nothing is pending the FSM must still bounce back to
-- S_IDLE, otherwise fetches starve until the 16384-cycle watchdog (~5 scan
-- lines) and the display repeats stale lines (the broken-wireframe artifact).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_vic_fb_ddr3_fetch is
end entity;

architecture sim of tb_vic_fb_ddr3_fetch is
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

  signal rd_count : natural := 0;   -- fetch read commands seen
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

  -- mock DDR3: serve every read after 2 cycles; count read commands
  mem : process(clk_x1)
    variable rcnt : integer := -1;
  begin
    if rising_edge(clk_x1) then
      app_rdata_valid <= '0';
      if app_cmd_en = '1' and app_cmd = "001" then
        rd_count <= rd_count + 1;
        rcnt := 2;
      end if;
      if rcnt = 0 then
        app_rdata <= (others => '0');
        app_rdata_valid <= '1';
      end if;
      if rcnt >= 0 then rcnt := rcnt - 1; end if;
    end if;
  end process;

  stim : process
    variable snap  : natural;
    variable waited : natural;
    variable worst : natural := 0;
  begin
    rst_n <= '0';
    for i in 1 to 5 loop wait until rising_edge(clk_x1); end loop;
    rst_n <= '1';
    calib_done <= '1';

    -- frame start: the controller prefetches the first two lines
    wait until rising_edge(clk_sys);
    fb_frame_start <= '1';
    wait until rising_edge(clk_sys);
    fb_frame_start <= '0';
    for i in 1 to 2000 loop wait until rising_edge(clk_x1); end loop;

    -- one scanline advance at a time: the next line's fetch must start well
    -- within a scanline (~3170 clk_x1); the stale-flag stall only ends at the
    -- 16384-cycle watchdog, which this budget catches.
    for l in 1 to 8 loop
      snap := rd_count;
      wait until rising_edge(clk_sys);
      fb_line_adv <= '1';
      wait until rising_edge(clk_sys);
      fb_line_adv <= '0';
      waited := 0;
      while rd_count = snap loop
        wait until rising_edge(clk_x1);
        waited := waited + 1;
        if waited > 20000 then exit; end if;
      end loop;
      if waited > worst then worst := waited; end if;
      report "line " & integer'image(l) & ": fetch started after " &
             integer'image(waited) & " cycles";
      -- let the 40-burst line fetch finish before the next adv
      for i in 1 to 1500 loop wait until rising_edge(clk_x1); end loop;
    end loop;

    if worst <= 1500 then
      report "tb_vic_fb_ddr3_fetch: PASS (worst fetch latency " &
             integer'image(worst) & " cycles)" severity note;
    else
      report "tb_vic_fb_ddr3_fetch: FAIL, fetch starved for " &
             integer'image(worst) & " cycles (display repeats stale lines)"
        severity failure;
    end if;
    std.env.stop;
  end process;

end architecture;
