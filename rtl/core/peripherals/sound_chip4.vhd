-- sound_chip4.vhd — the "large" 4-voice sound chip (full ADSR + 5 waveforms).
--
-- Wraps four sound_voice_full instances and mixes them, matching the C
-- emulator's 4-voice model (src/soundchip.c). This is an independent second
-- sound-chip version alongside the bring-up single voice (sound_voice.vhd +
-- pt8211_dac.vhd); both can be implemented/selected on the board.
--
-- Each voice has its own 10-register window and one chip-select line. In the
-- emulator the voice base addresses are:
--   Voice 0 $8830, Voice 1 $8890, Voice 2 $889A, Voice 3 $88A4.
-- The bus decoder selects one voice via cs(i); addr(3:0) is the register offset.
--
-- Mixing: each voice already outputs a signed 16-bit sample pre-scaled by
-- volume, envelope and a 0.25 headroom factor (>>10 inside the voice), so the
-- four can be summed without clipping. A hard clip guards against corner cases.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity sound_chip4 is
  generic (
    CLK_HZ : positive := 27_000_000
  );
  port (
    clk      : in  std_logic;
    reset_n  : in  std_logic;

    cs       : in  std_logic_vector(3 downto 0);  -- one chip-select per voice
    we       : in  std_logic;
    addr     : in  std_logic_vector(3 downto 0);  -- register offset 0..9
    din      : in  data_t;
    dout     : out data_t;                         -- muxed from the selected voice

    sample_out : out std_logic_vector(15 downto 0);  -- signed mixed output
    active     : out std_logic
  );
end entity;

architecture rtl of sound_chip4 is
  constant MS_DIV : positive := CLK_HZ / 1000;
  type dout_arr   is array (0 to 3) of data_t;
  type sample_arr is array (0 to 3) of std_logic_vector(15 downto 0);

  signal v_dout   : dout_arr;
  signal v_sample : sample_arr;
  signal v_active : std_logic_vector(3 downto 0);
  signal pulse_width : dout_arr := (others => x"80");
  signal ms_div_count : natural range 0 to MS_DIV-1 := 0;
  signal ms_counter   : unsigned(7 downto 0) := (others => '0');
begin

  -- SID compatibility extension in voice-0's spare register space:
  -- $883B/$883C/$883D set the upper eight bits of the 12-bit pulse width for
  -- voices 0/1/2. $80 is the traditional 50% duty cycle.
  pulse_reg_proc : process(clk)
    variable idx : integer range 0 to 2;
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        pulse_width <= (others => x"80");
      elsif cs(0) = '1' and we = '1' and unsigned(addr) >= 11 and unsigned(addr) <= 13 then
        idx := to_integer(unsigned(addr)) - 11;
        pulse_width(idx) <= din;
      end if;
    end if;
  end process;

  -- CPU-independent timebase.  Voice 0 offset 10 ($883A) exposes the low
  -- byte of a free-running millisecond counter for tempo/delay generation.
  timebase_proc : process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        ms_div_count <= 0;
        ms_counter <= (others => '0');
      elsif ms_div_count = MS_DIV-1 then
        ms_div_count <= 0;
        ms_counter <= ms_counter + 1;
      else
        ms_div_count <= ms_div_count + 1;
      end if;
    end if;
  end process;

  gen_voices : for i in 0 to 3 generate
    voice_i : entity work.sound_voice_full
      generic map (CLK_HZ => CLK_HZ)
      port map (
        clk        => clk,
        reset_n    => reset_n,
        cs         => cs(i),
        we         => we,
        addr       => addr,
        din        => din,
        dout       => v_dout(i),
        pulse_width => pulse_width(i),
        sample_out => v_sample(i),
        active     => v_active(i)
      );
  end generate;

  -- read mux: return the selected voice's register, else $FF
  dout <= std_logic_vector(ms_counter) when cs(0) = '1' and addr = "1010" else
          pulse_width(to_integer(unsigned(addr)) - 11)
            when cs(0) = '1' and unsigned(addr) >= 11 and unsigned(addr) <= 13 else
          v_dout(0) when cs(0) = '1' else
          v_dout(1) when cs(1) = '1' else
          v_dout(2) when cs(2) = '1' else
          v_dout(3) when cs(3) = '1' else
          x"FF";

  active <= v_active(0) or v_active(1) or v_active(2) or v_active(3);

  -- mixer: sum the four signed voices, then hard-clip to signed 16-bit
  mix_proc : process(clk)
    variable sum : signed(17 downto 0);
  begin
    if rising_edge(clk) then
      sum := resize(signed(v_sample(0)), 18)
           + resize(signed(v_sample(1)), 18)
           + resize(signed(v_sample(2)), 18)
           + resize(signed(v_sample(3)), 18);
      if sum > to_signed(32767, 18) then
        sample_out <= std_logic_vector(to_signed(32767, 16));
      elsif sum < to_signed(-32768, 18) then
        sample_out <= std_logic_vector(to_signed(-32768, 16));
      else
        sample_out <= std_logic_vector(resize(sum, 16));
      end if;
    end if;
  end process;

end architecture;
