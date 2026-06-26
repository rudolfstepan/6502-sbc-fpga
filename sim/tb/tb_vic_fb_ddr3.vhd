-- Testbench for vic_fb_ddr3 against a behavioural model of the Gowin DDR3
-- Memory Interface IP (1:4, x8 -> 64-bit BL8 app interface): cmd/cmd_en/cmd_ready,
-- wr_data/wr_data_mask/wr_data_en/wr_data_end, rd_data/rd_data_valid.
-- Verifies CPU pixel write (masked byte) -> read-back, and scanline prefetch
-- (8-pixel bursts) into the line buffer. mem is owned solely by the IP model
-- (pre-loaded with a line-0 pattern); the CPU r/w test uses a separate region.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_vic_fb_ddr3 is end entity;

architecture sim of tb_vic_fb_ddr3 is
  signal clk_sys : std_logic := '0';
  signal clk_x1  : std_logic := '0';
  signal rst_n   : std_logic := '0';

  signal fb_frame_start : std_logic := '0';
  signal fb_line_adv    : std_logic := '0';
  signal fb_rdaddr      : std_logic_vector(9 downto 0) := (others => '0');
  signal fb_rddata      : std_logic_vector(7 downto 0);

  signal cpu_req  : std_logic := '0';
  signal cpu_we   : std_logic := '0';
  signal cpu_addr : std_logic_vector(16 downto 0) := (others => '0');
  signal cpu_din  : std_logic_vector(7 downto 0) := (others => '0');
  signal cpu_dout : std_logic_vector(7 downto 0);
  signal cpu_ack  : std_logic;

  signal calib          : std_logic := '0';
  signal app_cmd_rdy    : std_logic := '1';
  signal app_cmd        : std_logic_vector(2 downto 0);
  signal app_cmd_en     : std_logic;
  signal app_addr       : std_logic_vector(27 downto 0);
  signal app_wdata      : std_logic_vector(63 downto 0);
  signal app_wdata_mask : std_logic_vector(7 downto 0);
  signal app_wren       : std_logic;
  signal app_wdata_end  : std_logic;
  signal app_wdata_rdy  : std_logic := '0';
  signal app_rdata      : std_logic_vector(63 downto 0) := (others => '0');
  signal app_rdata_valid : std_logic := '0';

  type mem_t is array (0 to 8191) of std_logic_vector(7 downto 0);

  function pat(p : natural) return natural is
  begin
    return (p*7 + 3) mod 256;
  end function;

  function init_mem return mem_t is
    variable m : mem_t := (others => (others => '0'));
  begin
    for p in 0 to 319 loop                 -- line 0 pattern, one byte per pixel
      m(p) := std_logic_vector(to_unsigned(pat(p), 8));
    end loop;
    return m;
  end function;

  signal mem : mem_t := init_mem;
  signal done : boolean := false;
begin

  clk_sys <= not clk_sys after 9 ns when not done else '0';   -- ~55 MHz
  clk_x1  <= not clk_x1  after 10 ns when not done else '0';   -- 50 MHz

  dut : entity work.vic_fb_ddr3
    generic map (FB_BASE_WORD => 0, LINE_PIX => 320, NUM_LINES => 200,
                 APP_ADDR_BITS => 28)
    port map (
      clk_sys => clk_sys, rst_sys_n => rst_n,
      fb_frame_start => fb_frame_start, fb_line_adv => fb_line_adv,
      fb_rdaddr => fb_rdaddr, fb_rddata => fb_rddata,
      cpu_req => cpu_req, cpu_we => cpu_we, cpu_addr => cpu_addr,
      cpu_din => cpu_din, cpu_dout => cpu_dout, cpu_ack => cpu_ack,
      clk_x1 => clk_x1, calib_done => calib,
      app_cmd_rdy => app_cmd_rdy, app_cmd => app_cmd, app_cmd_en => app_cmd_en,
      app_addr => app_addr, app_wdata => app_wdata, app_wdata_mask => app_wdata_mask,
      app_wren => app_wren, app_wdata_end => app_wdata_end, app_wdata_rdy => app_wdata_rdy,
      app_rdata => app_rdata, app_rdata_valid => app_rdata_valid);

  -- behavioural Gowin DDR3 IP model: BL8 burst at the 8-aligned word app_addr
  ip : process(clk_x1)
    variable lat : integer := -1;
    variable ra  : integer := 0;
    variable wa  : integer := 0;
    variable a   : integer;
  begin
    if rising_edge(clk_x1) then
      app_rdata_valid <= '0';
      -- Decoupled write: a WRITE command latches the address and raises
      -- wr_data_rdy on the NEXT cycle (data is NOT expected with the command).
      -- A controller that needs cmd_rdy AND wr_data_rdy in one cycle deadlocks.
      if app_cmd_en = '1' then
        a := to_integer(unsigned(app_addr));
        if app_cmd = "001" then                        -- READ
          ra := a; lat := 5;
        elsif app_cmd = "000" then                     -- WRITE command
          wa := a; app_wdata_rdy <= '1';
        end if;
      end if;
      if app_wren = '1' then                            -- WRITE data beat
        for b in 0 to 7 loop
          if app_wdata_mask(b) = '0' then
            mem(wa + b) <= app_wdata(b*8+7 downto b*8);
          end if;
        end loop;
        app_wdata_rdy <= '0';
      end if;
      if lat > 0 then
        lat := lat - 1;
      elsif lat = 0 then
        for L in 0 to 7 loop
          app_rdata(L*8+7 downto L*8) <= mem(ra + L);
        end loop;
        app_rdata_valid <= '1';
        lat := -1;
      end if;
    end if;
  end process;

  stim : process
    procedure cpu_write(addr : natural; val : natural) is
    begin
      wait until rising_edge(clk_sys);
      cpu_addr <= std_logic_vector(to_unsigned(addr, 17));
      cpu_din  <= std_logic_vector(to_unsigned(val, 8));
      cpu_we   <= '1'; cpu_req <= '1';
      wait until rising_edge(clk_sys);
      cpu_req <= '0';
      wait until cpu_ack = '1';
      wait until rising_edge(clk_sys);
    end procedure;

    procedure cpu_read(addr : natural; exp : natural; tag : string) is
    begin
      wait until rising_edge(clk_sys);
      cpu_addr <= std_logic_vector(to_unsigned(addr, 17));
      cpu_we   <= '0'; cpu_req <= '1';
      wait until rising_edge(clk_sys);
      cpu_req <= '0';
      wait until cpu_ack = '1';
      wait for 1 ns;   -- let cpu_dout (concurrent assign) settle
      assert to_integer(unsigned(cpu_dout)) = exp
        report "FAIL " & tag & " got=" & integer'image(to_integer(unsigned(cpu_dout)))
             & " exp=" & integer'image(exp) severity error;
      report "PASS " & tag & " = " & integer'image(to_integer(unsigned(cpu_dout)));
      wait until rising_edge(clk_sys);
    end procedure;

    procedure disp_check(col : natural; half : natural; exp : natural; tag : string) is
    begin
      fb_rdaddr <= std_logic_vector(to_unsigned(half*320 + col, 10));
      wait until rising_edge(clk_sys);
      wait until rising_edge(clk_sys);
      assert to_integer(unsigned(fb_rddata)) = exp
        report "FAIL " & tag & " got=" & integer'image(to_integer(unsigned(fb_rddata)))
             & " exp=" & integer'image(exp) severity error;
      report "PASS " & tag & " = " & integer'image(to_integer(unsigned(fb_rddata)));
    end procedure;
  begin
    rst_n <= '0';
    wait for 200 ns;
    rst_n <= '1';
    wait for 100 ns;
    calib <= '1';
    wait for 200 ns;

    -- CPU pixel write/read round-trip in a separate region (1000..) so it does
    -- not disturb the pre-loaded line-0 pattern (0..319).
    cpu_write(1000, 16#BB#);
    cpu_write(1001, 16#11#);
    cpu_write(1007, 16#77#);
    cpu_write(1008, 16#88#);   -- next burst group
    cpu_write(1123, 16#5A#);
    cpu_read(1000, 16#BB#, "cpu rd 1000");
    cpu_read(1001, 16#11#, "cpu rd 1001");
    cpu_read(1007, 16#77#, "cpu rd 1007");
    cpu_read(1008, 16#88#, "cpu rd 1008");
    cpu_read(1123, 16#5A#, "cpu rd 1123");

    -- scanline prefetch (line 0 -> half 0) then display read-back
    fb_frame_start <= '1'; wait until rising_edge(clk_sys); fb_frame_start <= '0';
    wait for 60 us;

    disp_check(0,   0, pat(0),   "L0 col0");
    disp_check(5,   0, pat(5),   "L0 col5");
    disp_check(312, 0, pat(312), "L0 col312");
    disp_check(319, 0, pat(319), "L0 col319");

    report "ALL TESTS PASSED" severity note;
    done <= true;
    wait;
  end process;

end architecture;
