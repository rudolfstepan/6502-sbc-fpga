-- tb_sid6581.vhd - decisive "does it make sound" check for the SID core.
-- Drives voice 0 (sawtooth + gate, full ADSR, master volume) and asserts that
-- sample_out leaves zero. If this passes, the core synthesizes audio and the
-- "complete silence" symptom must be in the player/ROM/board path, not the core.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sbc_pkg.all;

entity tb_sid6581 is
end entity;

architecture sim of tb_sid6581 is
  constant CLK_HZ : positive := 54_000_000;
  constant PERIOD : time := 18.5 ns;       -- ~54 MHz

  signal clk     : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal cs      : std_logic := '0';
  signal we      : std_logic := '0';
  signal addr    : std_logic_vector(4 downto 0) := (others => '0');
  signal din     : data_t := (others => '0');
  signal dout    : data_t;
  signal sample  : std_logic_vector(15 downto 0);

  signal running : boolean := true;
  signal max_abs : integer := 0;

  procedure sid_write(signal clk  : in  std_logic;
                      signal cs   : out std_logic;
                      signal we   : out std_logic;
                      signal addr : out std_logic_vector(4 downto 0);
                      signal din  : out data_t;
                      constant a  : in  integer;
                      constant d  : in  integer) is
  begin
    wait until rising_edge(clk);
    cs   <= '1';
    we   <= '1';
    addr <= std_logic_vector(to_unsigned(a, 5));
    din  <= std_logic_vector(to_unsigned(d, 8));
    wait until rising_edge(clk);
    cs <= '0';
    we <= '0';
  end procedure;
begin
  clk <= not clk after PERIOD/2 when running else '0';

  dut : entity work.sid6581
    generic map (CLK_HZ => CLK_HZ)
    port map (
      clk        => clk,
      reset_n    => reset_n,
      cs         => cs,
      we         => we,
      addr       => addr,
      din        => din,
      dout       => dout,
      sample_out => sample
    );

  -- Track the largest magnitude the output ever reaches.
  track : process(clk)
    variable s : integer;
  begin
    if rising_edge(clk) then
      s := to_integer(signed(sample));
      if s < 0 then s := -s; end if;
      if s > max_abs then max_abs <= s; end if;
    end if;
  end process;

  stim : process
  begin
    reset_n <= '0';
    for i in 0 to 9 loop wait until rising_edge(clk); end loop;
    reset_n <= '1';

    -- Voice 0: freq = $2000, sawtooth + gate, fast attack, full sustain.
    sid_write(clk, cs, we, addr, din, 0,  16#00#);  -- FREQ_LO
    sid_write(clk, cs, we, addr, din, 1,  16#20#);  -- FREQ_HI
    sid_write(clk, cs, we, addr, din, 5,  16#00#);  -- ATK/DEC: fastest attack
    sid_write(clk, cs, we, addr, din, 6,  16#F0#);  -- SUS/REL: sustain = 15
    sid_write(clk, cs, we, addr, din, 24, 16#0F#);  -- master volume = 15
    sid_write(clk, cs, we, addr, din, 4,  16#21#);  -- CONTROL: saw + gate on

    -- Let the envelope ramp and the oscillator swing for ~5 ms.
    wait for 5 ms;

    report "sid6581 max |sample| = " & integer'image(max_abs);
    assert max_abs > 100
      report "SID CORE PRODUCES NO OUTPUT (sample stays ~0) -> core bug"
      severity failure;
    report "SID core synthesizes audio OK -> look at player/ROM/board path"
      severity note;

    running <= false;
    wait;
  end process;
end architecture;
