-- Smoke test for c64_prg_upload_monitor with ENABLE_DUMP.
--
-- Drives the parallel RX interface directly (no UART serialization), models
-- TX as an 8-clk busy pulse and collects the transcript, and answers memory
-- requests with rdata = low address byte so dump output is predictable.
-- Checks: banner, L-mode write lands at the right address, M dump prints the
-- expected "AAAA: xx xx ..." lines across a line wrap, G releases the core.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_c64_prg_upload_monitor is
end entity;

architecture sim of tb_c64_prg_upload_monitor is
  signal clk     : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal running : boolean := true;

  signal enter_btn : std_logic := '0';
  signal rx_data   : std_logic_vector(7 downto 0) := (others => '0');
  signal rx_valid  : std_logic := '0';
  signal tx_busy   : std_logic := '0';
  signal tx_data   : std_logic_vector(7 downto 0);
  signal tx_valid  : std_logic;
  signal active    : std_logic;
  signal mem_req   : std_logic;
  signal mem_we    : std_logic;
  signal mem_addr  : std_logic_vector(15 downto 0);
  signal mem_wdata : std_logic_vector(7 downto 0);
  signal mem_rdata : std_logic_vector(7 downto 0) := (others => '0');
  signal mem_ready : std_logic := '0';

  -- captured TX transcript
  type ts_t is array (0 to 2047) of character;
  signal ts     : ts_t := (others => ' ');
  signal ts_len : natural := 0;

  -- captured last write
  signal wr_addr : std_logic_vector(15 downto 0) := (others => '0');
  signal wr_data : std_logic_vector(7 downto 0) := (others => '0');
  signal wr_seen : natural := 0;
begin
  dut : entity work.c64_prg_upload_monitor
    generic map (ENABLE_DUMP => true)
    port map (
      clk => clk, reset_n => reset_n, enter_btn => enter_btn,
      rx_data => rx_data, rx_valid => rx_valid,
      tx_busy => tx_busy, tx_data => tx_data, tx_valid => tx_valid,
      active => active,
      mem_req => mem_req, mem_we => mem_we, mem_addr => mem_addr,
      mem_wdata => mem_wdata, mem_rdata => mem_rdata, mem_ready => mem_ready
    );

  clk_p : process
  begin
    while running loop
      clk <= '0'; wait for 5 ns;
      clk <= '1'; wait for 5 ns;
    end loop;
    wait;
  end process;

  -- TX model: accept a char when idle, hold busy for 8 clks, log it.
  tx_p : process(clk)
    variable busy_cnt : natural := 0;
  begin
    if rising_edge(clk) then
      if busy_cnt > 0 then
        busy_cnt := busy_cnt - 1;
        if busy_cnt = 0 then
          tx_busy <= '0';
        end if;
      elsif tx_valid = '1' and tx_busy = '0' then
        if ts_len < ts_t'length then
          ts(ts_len) <= character'val(to_integer(unsigned(tx_data)));
          ts_len <= ts_len + 1;
        end if;
        tx_busy <= '1';
        busy_cnt := 8;
      end if;
    end if;
  end process;

  -- Memory model: 3-clk latency. Address/we/data are latched at REQUEST time,
  -- exactly like the c64_core monitor FSM (so the harmless duplicate request
  -- after ready re-writes the same address, as on the real core).
  mem_p : process(clk)
    variable lat : natural := 0;
    variable pending : boolean := false;
    variable a_lat : std_logic_vector(15 downto 0);
    variable w_lat : std_logic;
    variable d_lat : std_logic_vector(7 downto 0);
  begin
    if rising_edge(clk) then
      mem_ready <= '0';
      if pending then
        if lat > 0 then
          lat := lat - 1;
        else
          if w_lat = '0' then
            mem_rdata <= a_lat(7 downto 0);
          else
            wr_addr <= a_lat;
            wr_data <= d_lat;
            wr_seen <= wr_seen + 1;
          end if;
          mem_ready <= '1';
          pending := false;
        end if;
      elsif mem_req = '1' then
        a_lat := mem_addr;
        w_lat := mem_we;
        d_lat := mem_wdata;
        pending := true;
        lat := 3;
      end if;
    end if;
  end process;

  stim_p : process
    variable q_len : natural;

    procedure send_char(c : character) is
    begin
      wait until rising_edge(clk);
      rx_data <= std_logic_vector(to_unsigned(character'pos(c), 8));
      rx_valid <= '1';
      wait until rising_edge(clk);
      rx_valid <= '0';
      for i in 0 to 199 loop wait until rising_edge(clk); end loop;
    end procedure;

    procedure send_line(s : string) is
    begin
      for i in s'range loop
        send_char(s(i));
      end loop;
      send_char(CR);
    end procedure;

    -- wait until the transcript has been quiet for a while
    procedure wait_quiet is
      variable last : natural;
      variable idle : natural;
    begin
      last := ts_len;
      idle := 0;
      while idle < 5000 loop
        wait until rising_edge(clk);
        if ts_len /= last then
          last := ts_len;
          idle := 0;
        else
          idle := idle + 1;
        end if;
      end loop;
    end procedure;

    impure function ts_has(pat : string) return boolean is
      variable match : boolean;
    begin
      if ts_len < pat'length then
        return false;
      end if;
      for start in 0 to ts_len - pat'length loop
        match := true;
        for k in 0 to pat'length - 1 loop
          if ts(start + k) /= pat(pat'low + k) then
            match := false;
            exit;
          end if;
        end loop;
        if match then
          return true;
        end if;
      end loop;
      return false;
    end function;
  begin
    reset_n <= '0';
    for i in 0 to 9 loop wait until rising_edge(clk); end loop;
    reset_n <= '1';
    for i in 0 to 9 loop wait until rising_edge(clk); end loop;

    -- wake
    enter_btn <= '1';
    wait until rising_edge(clk);
    enter_btn <= '0';
    wait_quiet;
    assert ts_has("FPGA MONITOR") report "banner missing" severity error;
    assert active = '1' report "monitor not active" severity error;

    -- L-mode write: one byte AB at $0400
    send_line("L 0400");
    wait_quiet;
    send_line("AB");
    send_char('.');
    wait_quiet;
    assert wr_seen >= 1 and wr_addr = x"0400" and wr_data = x"AB"
      report "L write did not land at $0400/AB" severity error;

    -- M dump across a line wrap: $000E..$0011 -> one full check string.
    -- With rdata = low address byte the expected line is "000E: 0E 0F 10 11".
    send_line("M 000E 0011");
    wait_quiet;
    assert ts_has("000E: 0E 0F 10 11 ")
      report "M dump output wrong" severity error;

    -- longer dump with line wrap at 8 bytes + ASCII column:
    -- full line: 24 hex chars + 1 pad space, then 8 dots (bytes 00..07 are
    -- non-printable); partial line pads to the same column.
    send_line("M 0000 0009");
    wait_quiet;
    assert ts_has("0000: 00 01 02 03 04 05 06 07  ........")
      report "M dump first line wrong" severity error;
    assert ts_has("0008: 08 09 " & "                   " & "..")
      report "M dump wrapped line wrong" severity error;

    -- printable ASCII range: rdata = low address byte -> "ABCD"
    send_line("M 0041 0044");
    wait_quiet;
    assert ts_has("0041: 41 42 43 44 " & "             " & "ABCD")
      report "M dump ASCII column wrong" severity error;

    -- release
    send_char('G');
    for i in 0 to 99 loop wait until rising_edge(clk); end loop;
    assert active = '0' report "G did not release" severity error;

    report "tb_c64_prg_upload_monitor PASSED" severity note;
    running <= false;
    wait;
  end process;
end architecture;
