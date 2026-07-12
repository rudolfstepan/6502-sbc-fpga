-- Testbench for sys16_fb_ddr3 (system16 DDR3 framebuffer backend).
--
-- Models the Gowin DDR3 IP app interface (128-bit view) as a beat-
-- addressed memory with a fixed read latency and always-ready command/
-- write handshakes, then exercises:
--   1. CPU access while uncalibrated (must ack, write dropped, read 0)
--   2. CPU word write / read-back through the 50<->100 MHz handshake
--   3. byte-enable write (masked burst, no read-modify-write)
--   4. line prefetch into both buffer halves + pixel-side read-back
--      with the 2-cycle port-B latency
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_sys16_fb_ddr3 is
end entity;

architecture sim of tb_sys16_fb_ddr3 is
  constant LINE_WORDS : natural := 240;

  signal clk_bus : std_logic := '0';
  signal clk_x1  : std_logic := '0';
  signal clk_pix : std_logic := '0';
  signal done    : boolean := false;

  signal rst_bus_n : std_logic := '0';
  signal cpu_req   : std_logic := '0';
  signal cpu_we    : std_logic := '0';
  signal cpu_addr  : std_logic_vector(16 downto 0) := (others => '0');
  signal cpu_be    : std_logic_vector(3 downto 0) := (others => '0');
  signal cpu_wdata : std_logic_vector(31 downto 0) := (others => '0');
  signal cpu_rdata : std_logic_vector(31 downto 0);
  signal cpu_ack   : std_logic;
  signal calib_bus : std_logic;

  signal line_req : std_logic := '0';
  signal line_num : std_logic_vector(8 downto 0) := (others => '0');
  signal rd_addr  : std_logic_vector(8 downto 0) := (others => '0');
  signal rd_data  : std_logic_vector(31 downto 0);

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

  -- beat-addressed memory model: 1024 beats of 16 bytes
  type mem_t is array (0 to 1023) of std_logic_vector(127 downto 0);

  -- default beat content: word j of beat b reads b*4+j
  function beat_init(b : natural) return std_logic_vector is
    variable v : std_logic_vector(127 downto 0);
  begin
    for j in 0 to 3 loop
      v(j*32 + 31 downto j*32) :=
        std_logic_vector(to_unsigned(b*4 + j, 32));
    end loop;
    return v;
  end function;

  function mem_init return mem_t is
    variable m : mem_t;
  begin
    for b in 0 to 1023 loop
      m(b) := beat_init(b);
    end loop;
    return m;
  end function;

  signal mem : mem_t := mem_init;

  signal err_cnt : natural := 0;

  procedure cpu_op(signal req   : out std_logic;
                   signal wen   : out std_logic;
                   signal a     : out std_logic_vector(16 downto 0);
                   signal ben   : out std_logic_vector(3 downto 0);
                   signal wdat  : out std_logic_vector(31 downto 0);
                   we_v   : in std_logic;
                   addr_v : in natural;
                   be_v   : in std_logic_vector(3 downto 0);
                   dat_v  : in std_logic_vector(31 downto 0)) is
  begin
    wait until rising_edge(clk_bus);
    a    <= std_logic_vector(to_unsigned(addr_v, 17));
    wen  <= we_v;
    ben  <= be_v;
    wdat <= dat_v;
    req  <= '1';
    loop
      wait until rising_edge(clk_bus);
      if cpu_ack = '1' then
        exit;
      end if;
    end loop;
    req <= '0';
    wait until rising_edge(clk_bus);
  end procedure;

begin
  clk_bus <= not clk_bus after 10 ns when not done else '0';
  clk_x1  <= not clk_x1  after 5 ns  when not done else '0';
  clk_pix <= not clk_pix after 6.734 ns when not done else '0';

  dut : entity work.sys16_fb_ddr3
    generic map (LINE_WORDS => LINE_WORDS, NUM_LINES => 270)
    port map (
      clk_bus => clk_bus, rst_bus_n => rst_bus_n,
      cpu_req => cpu_req, cpu_we => cpu_we, cpu_addr => cpu_addr,
      cpu_be => cpu_be, cpu_wdata => cpu_wdata,
      cpu_rdata => cpu_rdata, cpu_ack => cpu_ack, calib_bus => calib_bus,
      clk_pix => clk_pix, rst_pix_n => rst_bus_n,
      line_req => line_req, line_num => line_num,
      rd_addr => rd_addr, rd_data => rd_data,
      clk_x1 => clk_x1, calib_done => calib_done,
      app_cmd_rdy => app_cmd_rdy, app_cmd => app_cmd,
      app_cmd_en => app_cmd_en, app_addr => app_addr,
      app_wdata => app_wdata, app_wdata_mask => app_wdata_mask,
      app_wren => app_wren, app_wdata_end => app_wdata_end,
      app_wdata_rdy => app_wdata_rdy,
      app_rdata => app_rdata, app_rdata_valid => app_rdata_valid);

  -- app-interface model: 12-cycle read latency, one op in flight (the
  -- DUT serializes; a second overlapping read is a DUT bug -> assert)
  app_model : process(clk_x1)
    variable rd_pend  : boolean := false;
    variable rd_delay : natural := 0;
    variable rd_beat  : natural := 0;
    variable wr_pend  : boolean := false;
    variable wr_beat  : natural := 0;
    variable beat     : natural;
  begin
    if rising_edge(clk_x1) then
      app_rdata_valid <= '0';
      if app_cmd_en = '1' then
        beat := to_integer(unsigned(app_addr)) / 8;
        if app_cmd = "001" then
          assert not rd_pend
            report "overlapping read" severity error;
          rd_pend  := true;
          rd_delay := 12;
          rd_beat  := beat;
          if beat < 100 then
            report "APP: read beat " & integer'image(beat);
          end if;
        else
          wr_pend := true;
          wr_beat := beat;
          report "APP: write cmd beat " & integer'image(beat);
        end if;
      end if;
      if app_wren = '1' then
        assert wr_pend report "wren without write cmd" severity error;
        for i in 0 to 15 loop
          if app_wdata_mask(i) = '0' then
            mem(wr_beat)(i*8 + 7 downto i*8) <=
              app_wdata(i*8 + 7 downto i*8);
          end if;
        end loop;
        wr_pend := false;
      end if;
      if rd_pend then
        if rd_delay = 0 then
          app_rdata       <= mem(rd_beat);
          app_rdata_valid <= '1';
          rd_pend := false;
        else
          rd_delay := rd_delay - 1;
        end if;
      end if;
    end if;
  end process;

  stim : process
    variable exp    : std_logic_vector(31 downto 0);
    variable t0, t1 : time;

    procedure check(name : string;
                    got : std_logic_vector(31 downto 0);
                    expv : std_logic_vector(31 downto 0)) is
    begin
      if got /= expv then
        report name & ": got " & integer'image(to_integer(unsigned(got(30 downto 0)))) &
               " expected " & integer'image(to_integer(unsigned(expv(30 downto 0))))
          severity error;
        err_cnt <= err_cnt + 1;
        wait for 0 ns;
      end if;
    end procedure;

    procedure pix_read(addr_v : natural;
                       expv : std_logic_vector(31 downto 0);
                       name : string) is
    begin
      wait until rising_edge(clk_pix);
      rd_addr <= std_logic_vector(to_unsigned(addr_v, 9));
      wait until rising_edge(clk_pix);  -- address register
      wait until rising_edge(clk_pix);  -- output register
      wait until rising_edge(clk_pix);  -- rd_data settled after this edge
      check(name, rd_data, expv);
    end procedure;
  begin
    wait for 50 ns;
    rst_bus_n <= '1';
    wait for 50 ns;

    -- 1: uncalibrated access must not hang (write dropped, read zero)
    cpu_op(cpu_req, cpu_we, cpu_addr, cpu_be, cpu_wdata,
           '1', 5, "1111", x"DEADBEEF");
    cpu_op(cpu_req, cpu_we, cpu_addr, cpu_be, cpu_wdata,
           '0', 5, "1111", x"00000000");
    check("uncalibrated read", cpu_rdata, x"00000000");

    calib_done <= '1';
    wait for 200 ns;
    assert calib_bus = '1' report "calib_bus not synced" severity error;

    -- 2: word write + read-back (word 5 sits in beat 1, lane 1)
    cpu_op(cpu_req, cpu_we, cpu_addr, cpu_be, cpu_wdata,
           '1', 5, "1111", x"DEADBEEF");
    cpu_op(cpu_req, cpu_we, cpu_addr, cpu_be, cpu_wdata,
           '0', 5, "1111", x"00000000");
    check("word readback", cpu_rdata, x"DEADBEEF");
    -- neighbour word untouched (beat 1 word 0 = 4)
    cpu_op(cpu_req, cpu_we, cpu_addr, cpu_be, cpu_wdata,
           '0', 4, "1111", x"00000000");
    check("neighbour word", cpu_rdata, x"00000004");

    -- 3: byte-enable write patches one byte only
    cpu_op(cpu_req, cpu_we, cpu_addr, cpu_be, cpu_wdata,
           '1', 5, "0010", x"0000A500");
    cpu_op(cpu_req, cpu_we, cpu_addr, cpu_be, cpu_wdata,
           '0', 5, "1111", x"00000000");
    check("byte write", cpu_rdata, x"DEADA5EF");

    -- 4: prefetch line 3 (odd -> buffer half 1). Line 3 starts at byte
    -- 2880 = beat 180, so word w of the line reads 720+w.
    wait until rising_edge(clk_pix);
    line_num <= std_logic_vector(to_unsigned(3, 9));
    line_req <= '1';
    wait until rising_edge(clk_pix);
    line_req <= '0';
    wait for 20 us;  -- 60 bursts at 12-cycle latency
    pix_read(256 + 0,   std_logic_vector(to_unsigned(720, 32)), "line3 w0");
    pix_read(256 + 1,   std_logic_vector(to_unsigned(721, 32)), "line3 w1");
    pix_read(256 + 239, std_logic_vector(to_unsigned(959, 32)), "line3 w239");

    -- 5: prefetch line 4 (even -> buffer half 0), line 3 half untouched
    wait until rising_edge(clk_pix);
    line_num <= std_logic_vector(to_unsigned(4, 9));
    line_req <= '1';
    wait until rising_edge(clk_pix);
    line_req <= '0';
    wait for 20 us;
    pix_read(0,   std_logic_vector(to_unsigned(960, 32)), "line4 w0");
    pix_read(239, std_logic_vector(to_unsigned(1199, 32)), "line4 w239");
    pix_read(256 + 7, std_logic_vector(to_unsigned(727, 32)), "line3 kept");

    -- 6: a CPU write during scanout activity still round-trips
    cpu_op(cpu_req, cpu_we, cpu_addr, cpu_be, cpu_wdata,
           '1', 720, "1111", x"CAFE0000");
    cpu_op(cpu_req, cpu_we, cpu_addr, cpu_be, cpu_wdata,
           '0', 720, "1111", x"00000000");
    check("post-fetch write", cpu_rdata, x"CAFE0000");

    -- 7: the fix under test. Trigger line 6 (60-burst fetch, several
    -- us uncontended), then immediately hammer 6 CPU writes without
    -- waiting for the fetch to finish. Before burst-granular
    -- arbitration these would have queued behind the WHOLE fetch (tens
    -- of us); now each waits at most one burst.
    wait until rising_edge(clk_pix);
    line_num <= std_logic_vector(to_unsigned(6, 9));
    line_req <= '1';
    wait until rising_edge(clk_pix);
    line_req <= '0';

    t0 := now;
    for i in 0 to 5 loop
      cpu_op(cpu_req, cpu_we, cpu_addr, cpu_be, cpu_wdata,
             '1', 800 + i, "1111",
             std_logic_vector(to_unsigned(16#B000# + i, 32)));
    end loop;
    t1 := now;
    report "contended: 6 cpu writes during an active fetch took " &
           time'image(t1 - t0);
    assert (t1 - t0) < 10 us
      report "CPU writes blocked too long behind an in-flight line fetch"
      severity error;

    for i in 0 to 5 loop
      cpu_op(cpu_req, cpu_we, cpu_addr, cpu_be, cpu_wdata,
             '0', 800 + i, "1111", x"00000000");
      check("contended readback " & integer'image(i), cpu_rdata,
            std_logic_vector(to_unsigned(16#B000# + i, 32)));
    end loop;

    wait for 30 us;  -- let the (repeatedly interrupted) line-6 fetch finish
    -- line 6 is even -> half 0; starts at byte 6*960=5760 -> beat 360 ->
    -- word w of the line reads 1440+w (same linear pattern as lines 3/4).
    pix_read(0,   std_logic_vector(to_unsigned(1440, 32)), "line6 w0 (contended)");
    pix_read(239, std_logic_vector(to_unsigned(1679, 32)), "line6 w239 (contended)");

    if err_cnt = 0 then
      report "TB PASSED" severity note;
    else
      report "TB FAILED with " & integer'image(err_cnt) & " errors"
        severity error;
    end if;
    done <= true;
    wait;
  end process;
end architecture;
