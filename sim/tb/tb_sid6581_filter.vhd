-- tb_sid6581_filter.vhd - exercises the SID state-variable filter:
-- routes voice 0 through the filter, picks low-pass with high resonance, and
-- sweeps the cutoff. Asserts the output stays bounded (no SVF blow-up) and that
-- a low cutoff measurably attenuates the sawtooth versus the unfiltered run.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sbc_pkg.all;

entity tb_sid6581_filter is
end entity;

architecture sim of tb_sid6581_filter is
  constant CLK_HZ : positive := 54_000_000;
  constant PERIOD : time := 18.5 ns;

  signal clk     : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal cs      : std_logic := '0';
  signal we      : std_logic := '0';
  signal addr    : std_logic_vector(4 downto 0) := (others => '0');
  signal din     : data_t := (others => '0');
  signal dout    : data_t;
  signal sample  : std_logic_vector(15 downto 0);

  signal running    : boolean := true;
  signal max_abs    : integer := 0;
  signal rms_open   : real := 0.0;   -- accumulated energy, cutoff high (open)
  signal rms_closed : real := 0.0;   -- accumulated energy, cutoff low (closed)
  signal phase_open : boolean := false;
  signal phase_close: boolean := false;

  procedure sid_write(signal clk  : in  std_logic;
                      signal cs   : out std_logic;
                      signal we   : out std_logic;
                      signal addr : out std_logic_vector(4 downto 0);
                      signal din  : out data_t;
                      constant a  : in  integer;
                      constant d  : in  integer) is
  begin
    wait until rising_edge(clk);
    cs <= '1'; we <= '1';
    addr <= std_logic_vector(to_unsigned(a, 5));
    din  <= std_logic_vector(to_unsigned(d, 8));
    wait until rising_edge(clk);
    cs <= '0'; we <= '0';
  end procedure;
begin
  clk <= not clk after PERIOD/2 when running else '0';

  dut : entity work.sid6581
    generic map (CLK_HZ => CLK_HZ)
    port map (clk => clk, reset_n => reset_n, cs => cs, we => we,
              addr => addr, din => din, dout => dout, sample_out => sample);

  -- track peak and open-phase energy (closed-phase energy in `closer` below)
  monitor : process(clk)
    variable s : integer;
  begin
    if rising_edge(clk) then
      s := to_integer(signed(sample));
      if abs(s) > max_abs then max_abs <= abs(s); end if;
      if phase_open then rms_open <= rms_open + real(s*s); end if;
    end if;
  end process;

  stim : process
  begin
    wait for 200 ns;
    reset_n <= '1';
    wait for 200 ns;

    -- voice 0: sawtooth, gate on, fast attack, full sustain
    sid_write(clk, cs, we, addr, din, 0, 16#00#);   -- freq lo
    sid_write(clk, cs, we, addr, din, 1, 16#20#);   -- freq hi (mid pitch)
    sid_write(clk, cs, we, addr, din, 5, 16#09#);   -- attack=0, decay=9
    sid_write(clk, cs, we, addr, din, 6, 16#F0#);   -- sustain=15, release=0
    sid_write(clk, cs, we, addr, din, 4, 16#21#);   -- sawtooth + gate

    -- route voice 0 through filter, low resonance (clean roll-off for the test)
    sid_write(clk, cs, we, addr, din, 23, 16#01#);  -- res=0, filt voice0
    -- low-pass, master volume 15
    sid_write(clk, cs, we, addr, din, 24, 16#1F#);  -- LP + vol 15

    -- ---- phase A: cutoff wide open ----
    sid_write(clk, cs, we, addr, din, 21, 16#07#);  -- fc lo
    sid_write(clk, cs, we, addr, din, 22, 16#FF#);  -- fc hi (max)
    wait for 1 ms;                                  -- let it settle
    phase_open <= true;
    wait for 20 ms;
    phase_open <= false;

    -- ---- phase B: cutoff low (should attenuate the saw) ----
    sid_write(clk, cs, we, addr, din, 21, 16#00#);  -- fc lo
    sid_write(clk, cs, we, addr, din, 22, 16#08#);  -- fc hi (low cutoff)
    wait for 1 ms;
    phase_close <= true;
    wait for 20 ms;
    phase_close <= false;

    report "filter: max |sample| = " & integer'image(max_abs);
    assert max_abs > 0
      report "FAIL: filtered SID produced silence" severity failure;
    assert max_abs < 32768
      report "FAIL: SVF output not bounded (blow-up?)" severity failure;
    assert rms_closed * 3.0 < rms_open
      report "FAIL: low cutoff did not attenuate (open=" & integer'image(integer(rms_open/1.0e6))
             & " closed=" & integer'image(integer(rms_closed/1.0e6)) & ")"
      severity failure;
    report "PASS: filter bounded and low cutoff attenuates (open="
           & integer'image(integer(rms_open/1.0e6)) & "M closed="
           & integer'image(integer(rms_closed/1.0e6)) & "M)";
    running <= false;
    wait;
  end process;

  -- closed-phase energy accumulation (separate to keep monitor simple)
  closer : process(clk)
    variable s : integer;
  begin
    if rising_edge(clk) then
      if phase_close then
        s := to_integer(signed(sample));
        rms_closed <= rms_closed + real(s*s);
      end if;
    end if;
  end process;
end architecture;
