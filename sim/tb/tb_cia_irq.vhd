-- Focused CIA Timer-A IRQ test at a held-bus (PHI2_DIV>1) timing.
--
-- Mimics how the real CPU drives the bus when clock-enabled at 1/27: cs/we/addr
-- stay asserted for HOLD system clocks per CPU cycle. Verifies that the Timer-A
-- underflow IRQ asserts, that reading ICR returns bit7=1 *and* clears it, and
-- that it re-fires periodically -- i.e. that the keyboard/cursor jiffy IRQ would
-- actually reach the CPU on hardware.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_cia_irq is
end entity;

architecture sim of tb_cia_irq is
  signal clk     : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal tick    : std_logic := '0';
  signal cs, we  : std_logic := '0';
  signal addr    : std_logic_vector(3 downto 0) := (others => '0');
  signal din     : std_logic_vector(7 downto 0) := (others => '0');
  signal dout    : std_logic_vector(7 downto 0);
  signal irq_n   : std_logic;
  signal running : boolean := true;

  constant HOLD : integer := 27;   -- system clocks the CPU holds the bus
begin
  dut : entity work.cia6526_full
    port map (
      clk => clk, reset_n => reset_n, tick => tick, tod_tick => '0',
      cs => cs, we => we, addr => addr, din => din, dout => dout,
      pa_in => x"FF", pa_out => open, pa_ddr => open,
      pb_in => x"FF", pb_out => open, pb_ddr => open,
      flag_n => '1', irq_n => irq_n
    );

  clk_p : process
  begin
    while running loop clk <= '0'; wait for 5 ns; clk <= '1'; wait for 5 ns; end loop;
    wait;
  end process;

  -- PHI2 tick every 27 clocks (1 MHz-like).
  tick_p : process(clk)
    variable c : integer := 0;
  begin
    if rising_edge(clk) then
      tick <= '0';
      if c = 26 then c := 0; tick <= '1'; else c := c + 1; end if;
    end if;
  end process;

  stim : process
    variable l : line;
    variable irq_seen : integer := 0;
    variable read_val : std_logic_vector(7 downto 0);

    procedure bus_write(a : integer; d : integer) is
    begin
      wait until rising_edge(clk);
      addr <= std_logic_vector(to_unsigned(a, 4));
      din  <= std_logic_vector(to_unsigned(d, 8));
      we <= '1'; cs <= '1';
      for i in 1 to HOLD loop wait until rising_edge(clk); end loop;
      cs <= '0'; we <= '0';
      for i in 1 to HOLD loop wait until rising_edge(clk); end loop;
    end procedure;

    procedure bus_read(a : integer; res : out std_logic_vector(7 downto 0)) is
    begin
      wait until rising_edge(clk);
      addr <= std_logic_vector(to_unsigned(a, 4));
      we <= '0'; cs <= '1';
      -- sample at the END of the held cycle, like the CPU does
      for i in 1 to HOLD loop wait until rising_edge(clk); end loop;
      res := dout;
      cs <= '0';
      for i in 1 to HOLD loop wait until rising_edge(clk); end loop;
    end procedure;
  begin
    reset_n <= '0';
    for i in 1 to 10 loop wait until rising_edge(clk); end loop;
    reset_n <= '1';

    -- Set Timer A latch = $0040, start (force load), enable TA IRQ.
    bus_write(16#4#, 16#40#);   -- TA lo
    bus_write(16#5#, 16#00#);   -- TA hi
    bus_write(16#E#, 16#11#);   -- CRA: start + force load
    bus_write(16#D#, 16#81#);   -- ICR: set TA IRQ enable

    -- Watch for several IRQs; ack each by reading ICR.
    for k in 1 to 5 loop
      -- wait for irq_n low (with timeout)
      for w in 1 to 20000 loop
        wait until rising_edge(clk);
        exit when irq_n = '0';
      end loop;
      if irq_n = '0' then
        bus_read(16#D#, read_val);
        write(l, string'("IRQ #")); write(l, k);
        write(l, string'("  ICR read = ")); hwrite(l, read_val);
        write(l, string'("  irq_n after ack = ")); write(l, irq_n);
        writeline(output, l);
        irq_seen := irq_seen + 1;
      else
        write(l, string'("IRQ #")); write(l, k); write(l, string'(" TIMEOUT (no IRQ)"));
        writeline(output, l);
      end if;
    end loop;

    write(l, string'("==== total IRQs seen: ")); write(l, irq_seen);
    write(l, string'(" of 5 ====")); writeline(output, l);
    running <= false;
    wait;
  end process;
end architecture;
