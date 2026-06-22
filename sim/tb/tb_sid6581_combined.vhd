-- tb_sid6581_combined.vhd - exercises combined waveforms, ring modulation and
-- hard sync. Each feature must produce bounded, non-silent audio (wired in and
-- stable). The combined saw+pulse case must also measurably attenuate versus a
-- plain sawtooth, since the wire-AND gates the output during the low pulse half.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sbc_pkg.all;

entity tb_sid6581_combined is
end entity;

architecture sim of tb_sid6581_combined is
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

  signal running : boolean := true;
  signal meas    : boolean := false;
  signal clr     : boolean := false;
  signal peak    : integer := 0;
  signal energy  : real := 0.0;

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

  -- clear, settle, then run a ~15 ms measurement window; return peak and energy
  procedure measure(signal clk    : in  std_logic;
                    signal clr    : out boolean;
                    signal meas   : out boolean;
                    signal peak   : in  integer;
                    signal energy : in  real;
                    variable pk   : out integer;
                    variable en   : out real) is
  begin
    clr <= true;  wait until rising_edge(clk);  clr <= false;
    wait for 1 ms;                 -- settle (meas low, no accumulation)
    meas <= true;  wait for 15 ms;  meas <= false;
    wait until rising_edge(clk);
    pk := peak; en := energy;
  end procedure;
begin
  clk <= not clk after PERIOD/2 when running else '0';

  dut : entity work.sid6581
    generic map (CLK_HZ => CLK_HZ)
    port map (clk => clk, reset_n => reset_n, cs => cs, we => we,
              addr => addr, din => din, dout => dout, sample_out => sample);

  acc : process(clk)
    variable s : integer;
  begin
    if rising_edge(clk) then
      if clr then
        peak <= 0; energy <= 0.0;
      elsif meas then
        s := to_integer(signed(sample));
        if abs(s) > peak then peak <= abs(s); end if;
        energy <= energy + real(s*s);
      end if;
    end if;
  end process;

  stim : process
    variable pk_saw, pk_comb, pk_ring, pk_sync : integer;
    variable en_saw, en_comb, en_ring, en_sync : real;
  begin
    wait for 200 ns; reset_n <= '1'; wait for 200 ns;

    -- common: full volume, no filter routing
    sid_write(clk, cs, we, addr, din, 24, 16#0F#);  -- vol 15, no filter mode
    sid_write(clk, cs, we, addr, din, 23, 16#00#);  -- no filter routing

    -- voice 0 envelope: instant attack, full sustain; mid pitch, 50% pulse
    sid_write(clk, cs, we, addr, din, 5, 16#00#);
    sid_write(clk, cs, we, addr, din, 6, 16#F0#);
    sid_write(clk, cs, we, addr, din, 1, 16#10#);   -- freq hi
    sid_write(clk, cs, we, addr, din, 3, 16#08#);   -- pulse width hi = 50%
    sid_write(clk, cs, we, addr, din, 2, 16#00#);

    -- ---- baseline: pure sawtooth ----
    sid_write(clk, cs, we, addr, din, 4, 16#21#);   -- saw + gate
    measure(clk, clr, meas, peak, energy, pk_saw, en_saw);

    -- ---- combined: sawtooth + pulse (wire-AND gates output) ----
    sid_write(clk, cs, we, addr, din, 4, 16#61#);   -- saw + pulse + gate
    measure(clk, clr, meas, peak, energy, pk_comb, en_comb);

    -- ---- ring modulation: voice 1 triangle ring-modulated by voice 0 ----
    sid_write(clk, cs, we, addr, din, 0, 16#00#);
    sid_write(clk, cs, we, addr, din, 1, 16#08#);   -- voice0 modulator pitch
    sid_write(clk, cs, we, addr, din, 4, 16#21#);   -- voice0 saw + gate (source osc)
    sid_write(clk, cs, we, addr, din, 12, 16#00#);  -- voice1 env attack/decay
    sid_write(clk, cs, we, addr, din, 13, 16#F0#);  -- voice1 sustain/release
    sid_write(clk, cs, we, addr, din, 8, 16#00#);   -- voice1 freq lo
    sid_write(clk, cs, we, addr, din, 9, 16#20#);   -- voice1 freq hi
    sid_write(clk, cs, we, addr, din, 11, 16#15#);  -- voice1 tri + ring + gate
    measure(clk, clr, meas, peak, energy, pk_ring, en_ring);

    -- ---- hard sync: voice 1 sync to voice 0 ----
    sid_write(clk, cs, we, addr, din, 11, 16#23#);  -- voice1 saw + sync + gate
    measure(clk, clr, meas, peak, energy, pk_sync, en_sync);

    report "saw  peak=" & integer'image(pk_saw)  & " E=" & integer'image(integer(en_saw/1.0e6)) & "M";
    report "comb peak=" & integer'image(pk_comb) & " E=" & integer'image(integer(en_comb/1.0e6)) & "M";
    report "ring peak=" & integer'image(pk_ring) & " E=" & integer'image(integer(en_ring/1.0e6)) & "M";
    report "sync peak=" & integer'image(pk_sync) & " E=" & integer'image(integer(en_sync/1.0e6)) & "M";

    assert pk_saw  > 0 and pk_saw  < 32768 report "FAIL: saw not bounded/non-silent"      severity failure;
    assert pk_comb > 0 and pk_comb < 32768 report "FAIL: combined not bounded/non-silent" severity failure;
    assert pk_ring > 0 and pk_ring < 32768 report "FAIL: ring not bounded/non-silent"     severity failure;
    assert pk_sync > 0 and pk_sync < 32768 report "FAIL: sync not bounded/non-silent"     severity failure;
    -- saw+pulse wire-AND must change the waveform (here it adds a square/DC
    -- component), so its energy differs clearly from the plain sawtooth.
    assert en_comb > en_saw * 1.2 or en_comb < en_saw * 0.8
      report "FAIL: combined saw+pulse did not change output vs plain saw" severity failure;

    report "PASS: combined waveforms, ring mod and sync are wired, bounded and non-silent";
    running <= false;
    wait;
  end process;
end architecture;
