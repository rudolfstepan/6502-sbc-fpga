-- Testbench for the CIA-1 Timer A subset: program a short Timer A period, enable
-- its interrupt, start it continuous, and check that it underflows, raises IRQ,
-- that reading ICR clears the IRQ, and that it reloads and fires again.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.sbc_pkg.all;

entity tb_cia6526 is
end entity;

architecture sim of tb_cia6526 is
  constant CLK_PERIOD : time := 10 ns;
  signal clk     : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal cs      : std_logic := '0';
  signal we      : std_logic := '0';
  signal addr    : std_logic_vector(3 downto 0) := (others => '0');
  signal din     : data_t := (others => '0');
  signal dout    : data_t;
  signal irq_n   : std_logic;
  signal done    : boolean := false;
begin
  clk <= not clk after CLK_PERIOD / 2 when not done else '0';

  dut : entity work.cia6526
    generic map (TICK_DIV => 4)            -- fast PHI2 for simulation
    port map (clk => clk, reset_n => reset_n, cs => cs, we => we,
              addr => addr, din => din, dout => dout, irq_n => irq_n);

  test : process
    procedure wr(a : std_logic_vector(3 downto 0); d : integer) is
    begin
      wait until rising_edge(clk);
      addr <= a; din <= std_logic_vector(to_unsigned(d, 8)); we <= '1'; cs <= '1';
      wait until rising_edge(clk);
      cs <= '0'; we <= '0';
      wait until rising_edge(clk);          -- cs low between accesses
    end procedure;

    procedure rd(a : std_logic_vector(3 downto 0); v : out data_t) is
    begin
      wait until rising_edge(clk);
      addr <= a; we <= '0'; cs <= '1';
      wait for 1 ns;                        -- let combinational dout settle
      v := dout;                            -- sample before the clearing edge
      wait until rising_edge(clk);
      cs <= '0';
      wait until rising_edge(clk);
    end procedure;

    variable v : data_t;
    variable saw_irq : boolean := false;
  begin
    wait for 5 * CLK_PERIOD;
    reset_n <= '1';

    -- Timer A = 3 (period), enable TA interrupt, start continuous.
    wr(x"4", 3);          -- TA latch low
    wr(x"5", 0);          -- TA latch high (reloads counter while stopped)
    wr(x"D", 16#81#);     -- ICR: bit7 set + bit0 -> enable TA interrupt
    wr(x"E", 16#01#);     -- CRA: start, continuous

    -- Wait for the underflow interrupt (period 3 at TICK_DIV=4 -> ~ a few dozen clks)
    for i in 0 to 400 loop
      wait until rising_edge(clk);
      if irq_n = '0' then saw_irq := true; exit; end if;
    end loop;
    assert saw_irq report "Timer A never raised IRQ" severity failure;

    -- ICR read: bit7 (IRQ) and bit0 (TA) set; the read must clear it.
    rd(x"D", v);
    assert v(7) = '1' and v(0) = '1'
      report "ICR did not report TA interrupt" severity failure;
    wait until rising_edge(clk);
    assert irq_n = '1' report "ICR read did not clear the IRQ" severity failure;

    -- Continuous mode: it must fire again after reloading.
    saw_irq := false;
    for i in 0 to 400 loop
      wait until rising_edge(clk);
      if irq_n = '0' then saw_irq := true; exit; end if;
    end loop;
    assert saw_irq report "Timer A did not reload/fire again (continuous)" severity failure;

    report "tb_cia6526 passed" severity note;
    done <= true;
    wait;
  end process;
end architecture;
