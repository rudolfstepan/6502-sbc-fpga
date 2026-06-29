-- sid6581.vhd - compact MOS 6581 playback core for original SID player code.
-- Three voices, 24-bit oscillators, 12-bit triangle/saw/pulse + noise, gate and
-- a cycle-accurate ADSR (reSID rate-counter periods with the exponential
-- decay/release divider), a 2-pole state-variable filter (LP/BP/HP with
-- cutoff/resonance/routing and a non-linear "dark 6581" cutoff curve), hard
-- oscillator sync, ring modulation, AND-combined waveforms and a $D418 volume
-- DAC high-pass path for sample digis. The 6581's analog DAC non-linearity and
-- sample-ROM-exact combined waveforms are not modelled yet.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sbc_pkg.all;

entity sid6581 is
  generic (
    CLK_HZ : positive := 54_000_000;
    SID_HZ : positive := 985_248
  );
  port (
    clk        : in  std_logic;
    reset_n    : in  std_logic;
    cs         : in  std_logic;
    we         : in  std_logic;
    addr       : in  std_logic_vector(4 downto 0);
    din        : in  data_t;
    dout       : out data_t;
    sample_out : out std_logic_vector(15 downto 0)
  );
end entity;

architecture rtl of sid6581 is
  type regfile_t is array (0 to 24) of data_t;
  type phase_arr_t is array (0 to 2) of unsigned(23 downto 0);
  type env_arr_t is array (0 to 2) of unsigned(7 downto 0);
  type lfsr_arr_t is array (0 to 2) of unsigned(22 downto 0);
  type bit_arr_t is array (0 to 2) of std_logic;
  type rate_arr_t is array (0 to 2) of unsigned(14 downto 0);
  type exp_arr_t is array (0 to 2) of unsigned(4 downto 0);
  type env_state_t is (E_IDLE, E_ATTACK, E_DECAY, E_SUSTAIN, E_RELEASE);
  type env_state_arr_t is array (0 to 2) of env_state_t;

  signal regs       : regfile_t := (others => (others => '0'));
  signal phase      : phase_arr_t := (others => (others => '0'));
  signal env        : env_arr_t := (others => (others => '0'));
  signal lfsr       : lfsr_arr_t := (others => (others => '1'));
  signal noise_clk_d : bit_arr_t := (others => '0');
  signal osc_msb_d  : bit_arr_t := (others => '0');  -- prev osc MSB, for hard sync
  signal gate_d     : bit_arr_t := (others => '0');
  signal env_state  : env_state_arr_t := (others => E_IDLE);
  signal rate_cnt   : rate_arr_t := (others => (others => '0'));
  signal exp_cnt    : exp_arr_t := (others => (others => '0'));

  signal sid_acc : integer range 0 to CLK_HZ-1 := 0;
  signal sid_tick_pulse : std_logic := '0';
  attribute syn_keep : integer;
  attribute syn_keep of sid_tick_pulse : signal is 1;

  -- State-variable filter ($D415-$D418): cutoff/resonance/routing + LP/BP/HP.
  -- Updated once per SID tick over a 5-step pipeline (voice-mix, HP, BP, LP,
  -- output) so no multiply+add chain sits in one 54 MHz path.  ~54 system
  -- clocks are available per SID tick, far more than the 5 stages used.
  constant FLT_BND : integer := 2097152;          -- state saturation (+/-2^21)
  constant D418_DAC_STEP : integer := 512;        -- final-sample units per volume LSB
  constant D418_DC_SHIFT : natural := 12;         -- ~4 ms DC blocker at SID rate
  signal lp_s, bp_s : signed(23 downto 0) := (others => '0');
  signal hp_s       : signed(25 downto 0) := (others => '0');
  signal fcoef_s    : signed(14 downto 0) := (others => '0');
  signal dcoef_s    : signed(17 downto 0) := (others => '0');
  signal d418_lp_s   : signed(17 downto 0) := (others => '0');
  signal dir_lat    : signed(21 downto 0) := (others => '0');
  signal flt_lat    : signed(21 downto 0) := (others => '0');
  signal total_lat  : signed(27 downto 0) := (others => '0');
  signal modev_lat  : data_t := (others => '0');
  signal fstage     : integer range 0 to 5 := 0;

  -- phi2 cycles between envelope steps (reSID rate-counter periods, ADSR nibble)
  function rate_period(n : natural) return natural is
  begin
    case n is
      when 0  => return 9;     when 1  => return 32;    when 2  => return 63;
      when 3  => return 95;    when 4  => return 149;   when 5  => return 220;
      when 6  => return 267;   when 7  => return 313;   when 8  => return 392;
      when 9  => return 977;   when 10 => return 1954;  when 11 => return 3126;
      when 12 => return 3907;  when 13 => return 11720; when 14 => return 19532;
      when others => return 31251;
    end case;
  end function;

  -- decay/release exponential divider, selected by the current envelope level
  function exp_period(e : natural) return natural is
  begin
    if    e > 16#5D# then return 1;
    elsif e > 16#35# then return 2;
    elsif e > 16#19# then return 4;
    elsif e > 16#0D# then return 8;
    elsif e > 16#05# then return 16;
    else                  return 30;
    end if;
  end function;

  -- 11-bit cutoff register -> Q16 filter coefficient (2*pi*fc/fs, fs=phi2).
  -- Piecewise-linear approximation of an exponential "dark 6581" curve so that
  -- mid-range register values stay genuinely low (e.g. FC=1240 -> ~2 kHz, not
  -- ~7.5 kHz of a linear map). 8 equal 256-wide segments, endpoints at 2048.
  function cutoff_coeff(cut11 : natural) return natural is
    type y_arr is array (0 to 8) of natural;
    constant YB  : y_arr := (50, 89, 159, 282, 502, 891, 1586, 2819, 5015);
    variable seg : natural;
    variable frac : natural;
  begin
    seg  := cut11 / 256;            -- 0..7 (top 3 bits)
    frac := cut11 mod 256;          -- 0..255 within the segment
    return YB(seg) + (YB(seg+1) - YB(seg)) * frac / 256;
  end function;
begin
  -- Write registers ($00-$18) read back the last written value; $19/$1A (POTX/
  -- POTY) have no paddle hardware -> $FF; $1B = OSC3 (voice-3 oscillator MSB, the
  -- classic $D41B RNG / sawtooth source) and $1C = ENV3 (voice-3 envelope).
  dout <= regs(to_integer(unsigned(addr)))         when unsigned(addr) < 25 else
          std_logic_vector(phase(2)(23 downto 16)) when unsigned(addr) = 27 else
          std_logic_vector(env(2))                 when unsigned(addr) = 28 else
          x"FF";

  timebase_proc : process(clk)
  begin
    if rising_edge(clk) then
      sid_tick_pulse <= '0';
      if reset_n = '0' then
        sid_acc <= 0;
      else
        if sid_acc >= CLK_HZ-SID_HZ then
          sid_acc <= sid_acc - (CLK_HZ-SID_HZ);
          sid_tick_pulse <= '1';
        else
          sid_acc <= sid_acc + SID_HZ;
        end if;
      end if;
    end if;
  end process;

  synth_proc : process(clk)
    variable idx, base, src : integer;
    variable f : unsigned(15 downto 0);
    variable ctrl : data_t;
    variable target, rate_nib, e : integer;
    variable feedback : std_logic;
    variable np : phase_arr_t;                 -- advanced accumulators this tick
    variable mnow : std_logic_vector(2 downto 0);  -- their MSBs (sync sources)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        regs <= (others => (others => '0'));
        phase <= (others => (others => '0'));
        env <= (others => (others => '0'));
        lfsr <= (others => (others => '1'));
        noise_clk_d <= (others => '0');
        osc_msb_d <= (others => '0');
        gate_d <= (others => '0');
        env_state <= (others => E_IDLE);
        rate_cnt <= (others => (others => '0'));
        exp_cnt <= (others => (others => '0'));
      else
        if cs = '1' and we = '1' then
          idx := to_integer(unsigned(addr));
          if idx < 25 then regs(idx) <= din; end if;
        end if;

        -- ===== oscillators: advance, hard sync, noise clock (on SID tick) =====
        if sid_tick_pulse = '1' then
          for v in 0 to 2 loop                 -- pass 1: advance accumulators
            base := v*7; ctrl := regs(base+4);
            f := unsigned(regs(base+1)) & unsigned(regs(base));
            if ctrl(3) = '1' then np(v) := (others => '0');
            else np(v) := phase(v) + resize(f, 24); end if;
            mnow(v) := np(v)(23);
          end loop;
          for v in 0 to 2 loop                 -- pass 2: hard sync from voice v-1
            src := (v + 2) mod 3;
            if regs(v*7+4)(1) = '1' and osc_msb_d(src) = '0' and mnow(src) = '1' then
              np(v) := (others => '0');
            end if;
          end loop;
          for v in 0 to 2 loop                 -- commit phase, MSB history, noise
            phase(v) <= np(v);
            osc_msb_d(v) <= mnow(v);
            if np(v)(19) = '1' and noise_clk_d(v) = '0' then
              feedback := lfsr(v)(22) xor lfsr(v)(17);
              lfsr(v) <= lfsr(v)(21 downto 0) & feedback;
            end if;
            noise_clk_d(v) <= np(v)(19);
          end loop;
        end if;

        for v in 0 to 2 loop
          base := v*7;
          ctrl := regs(base+4);

          -- gate edge: (re)start attack or release, restart rate/exp counters
          if ctrl(0) = '1' and gate_d(v) = '0' then
            env_state(v) <= E_ATTACK;
            rate_cnt(v) <= (others => '0');
            exp_cnt(v) <= (others => '0');
          elsif ctrl(0) = '0' and gate_d(v) = '1' then
            env_state(v) <= E_RELEASE;
            rate_cnt(v) <= (others => '0');
            exp_cnt(v) <= (others => '0');
          end if;
          gate_d(v) <= ctrl(0);

          if sid_tick_pulse = '1' then
            -- envelope: cycle-accurate rate counter + exponential divider
            case env_state(v) is
              when E_ATTACK          => rate_nib := to_integer(unsigned(regs(base+5)(7 downto 4)));
              when E_DECAY | E_SUSTAIN => rate_nib := to_integer(unsigned(regs(base+5)(3 downto 0)));
              when E_RELEASE         => rate_nib := to_integer(unsigned(regs(base+6)(3 downto 0)));
              when others            => rate_nib := 0;
            end case;

            if to_integer(rate_cnt(v)) >= rate_period(rate_nib) then
              rate_cnt(v) <= (others => '0');
              e := to_integer(env(v));
              target := to_integer(unsigned(regs(base+6)(7 downto 4))) * 17;
              case env_state(v) is
                when E_ATTACK =>
                  -- attack is linear: one step per rate match
                  if e >= 255 then
                    env_state(v) <= E_DECAY; exp_cnt(v) <= (others => '0');
                  else
                    env(v) <= to_unsigned(e + 1, 8);
                  end if;
                when E_DECAY =>
                  if e <= target then
                    env(v) <= to_unsigned(target, 8);
                    env_state(v) <= E_SUSTAIN; exp_cnt(v) <= (others => '0');
                  elsif to_integer(exp_cnt(v)) >= exp_period(e) - 1 then
                    exp_cnt(v) <= (others => '0');
                    env(v) <= to_unsigned(e - 1, 8);
                  else
                    exp_cnt(v) <= exp_cnt(v) + 1;
                  end if;
                when E_SUSTAIN =>
                  -- resume decay if the sustain level was lowered
                  if e > target then env_state(v) <= E_DECAY; end if;
                when E_RELEASE =>
                  if e = 0 then
                    env_state(v) <= E_IDLE;
                  elsif to_integer(exp_cnt(v)) >= exp_period(e) - 1 then
                    exp_cnt(v) <= (others => '0');
                    env(v) <= to_unsigned(e - 1, 8);
                  else
                    exp_cnt(v) <= exp_cnt(v) + 1;
                  end if;
                when others =>
                  env(v) <= (others => '0');
              end case;
            else
              rate_cnt(v) <= rate_cnt(v) + 1;
            end if;
          end if;
        end loop;
      end if;
    end if;
  end process;

  -- Voice mixing + state-variable filter, advanced once per SID tick.
  -- Stage 0: mix routed/direct voices, derive coefficients, compute HP.
  -- Stage 1: integrate BP (needs HP).  Stage 2: integrate LP, mix, output.
  out_proc : process(clk)
    variable base, p12, pw, wav12, src, lower : integer;
    variable msb : std_logic;
    variable any : boolean;
    variable wacc, wtmp : unsigned(11 downto 0);
    variable ctrl : data_t;
    variable raw  : signed(11 downto 0);
    variable amp  : signed(20 downto 0);
    variable c    : signed(19 downto 0);
    variable dir_v, flt_v : signed(21 downto 0);
    variable cut11, res4, dcoef_i : integer;
    variable dcoef : signed(17 downto 0);
    variable dbp  : signed(43 downto 0);
    variable fhp, fbp : signed(40 downto 0);
    variable bp_sum, lp_sum : signed(26 downto 0);
    variable lp_new : signed(23 downto 0);
    variable filt_out, total : signed(27 downto 0);
    variable scaled, scaled_mix : signed(33 downto 0);
    variable digi_in, digi_hp : signed(17 downto 0);
    variable master : unsigned(4 downto 0);
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        lp_s <= (others => '0'); bp_s <= (others => '0'); hp_s <= (others => '0');
        d418_lp_s <= (others => '0');
        sample_out <= (others => '0');
        fstage <= 0;
      else
        case fstage is
          when 0 =>
            if sid_tick_pulse = '1' then
              -- ---- mix all voices into direct + filter-routed sums ----
              dir_v := (others => '0'); flt_v := (others => '0');
              for v in 0 to 2 loop
                base := v*7; ctrl := regs(base+4);
                src := (v + 2) mod 3;                       -- ring/sync source
                p12 := to_integer(phase(v)(23 downto 12));
                pw  := to_integer(unsigned(regs(base+3)(3 downto 0)) & unsigned(regs(base+2)));

                -- Combined waveforms approximated by wire-ANDing the enabled
                -- generators (full-scale 12-bit). A single waveform ANDs with
                -- all-ones, so it is unchanged.
                wacc := (others => '1'); any := false;
                if ctrl(4) = '1' then                       -- triangle (+ ring mod)
                  msb := phase(v)(23);
                  if ctrl(2) = '1' then msb := msb xor phase(src)(23); end if;
                  lower := to_integer(phase(v)(22 downto 12));   -- 0..2047
                  if msb = '0' then wtmp := to_unsigned(lower * 2, 12);
                  else wtmp := to_unsigned((2047 - lower) * 2, 12); end if;
                  wacc := wacc and wtmp; any := true;
                end if;
                if ctrl(5) = '1' then                       -- sawtooth
                  wacc := wacc and to_unsigned(p12, 12); any := true;
                end if;
                if ctrl(6) = '1' then                       -- pulse
                  if p12 < pw then wacc := (others => '0'); end if;
                  any := true;
                end if;
                if ctrl(7) = '1' then                       -- noise (8-bit, top bits)
                  wacc := wacc and (lfsr(v)(22 downto 15) & to_unsigned(0, 4)); any := true;
                end if;
                if any then wav12 := to_integer(wacc); else wav12 := 2048; end if;
                raw := to_signed(wav12 - 2048, raw'length);
                amp := raw * signed('0' & std_logic_vector(env(v)));
                c   := resize(shift_right(amp, 6), 20);
                if regs(23)(v) = '1' then                   -- routed through filter
                  flt_v := flt_v + resize(c, flt_v'length);
                elsif not (v = 2 and regs(24)(7) = '1') then -- direct (unless 3OFF)
                  dir_v := dir_v + resize(c, dir_v'length);
                end if;
              end loop;
              dir_lat   <= dir_v;
              flt_lat   <= flt_v;
              modev_lat <= regs(24);

              -- ---- coefficients (Q16): nonlinear cutoff, resonance -> damping.
              -- The 6581 resonance is weak: map res 0..15 to Q ~0.7..2 (damping
              -- 1.41..0.5) so resonant peaks colour the tone without slamming the
              -- output limiter into hard clipping.
              cut11 := to_integer(unsigned(regs(22)) & unsigned(regs(21)(2 downto 0)));
              fcoef_s <= to_signed(cutoff_coeff(cut11), fcoef_s'length);
              res4  := to_integer(unsigned(regs(23)(7 downto 4)));
              dcoef_i := 92000 - res4 * 3949;
              dcoef_s <= to_signed(dcoef_i, dcoef_s'length);
              fstage <= 1;
            end if;

          when 1 =>
            -- ---- HP = in - LP - damping*BP ----
            -- Split out from voice mixing so the regs -> waveform -> flt_v ->
            -- hp_s chain (the new worst path after the first pipeline split)
            -- no longer settles in one 54 MHz cycle.  flt_lat/dcoef_s are now
            -- registered inputs.
            dbp := resize(dcoef_s * bp_s, dbp'length);
            hp_s <= resize(flt_lat, hp_s'length) - resize(lp_s, hp_s'length)
                    - resize(shift_right(dbp, 16), hp_s'length);
            fstage <= 2;

          when 2 =>
            -- ---- BP += f*HP, with saturation ----
            fhp := resize(fcoef_s * hp_s, fhp'length);
            bp_sum := resize(bp_s, bp_sum'length)
                      + resize(shift_right(fhp, 16), bp_sum'length);
            if bp_sum > FLT_BND then
              bp_s <= to_signed(FLT_BND, bp_s'length);
            elsif bp_sum < -FLT_BND then
              bp_s <= to_signed(-FLT_BND, bp_s'length);
            else
              bp_s <= resize(bp_sum, bp_s'length);
            end if;
            fstage <= 3;

          when 3 =>
            -- ---- LP += f*BP, with saturation ----
            -- This stage ends here (register lp_s) to keep the multiply+add+
            -- saturate path short.  The output mixing/scaling/clipping moves to
            -- stage 3 so the long bp_s -> sample_out path no longer all settles
            -- in one 54 MHz cycle (it was the design's worst critical path).
            fbp := resize(fcoef_s * bp_s, fbp'length);
            lp_sum := resize(lp_s, lp_sum'length)
                      + resize(shift_right(fbp, 16), lp_sum'length);
            if lp_sum > FLT_BND then
              lp_new := to_signed(FLT_BND, lp_new'length);
            elsif lp_sum < -FLT_BND then
              lp_new := to_signed(-FLT_BND, lp_new'length);
            else
              lp_new := resize(lp_sum, lp_new'length);
            end if;
            lp_s <= lp_new;
            fstage <= 4;

          when 4 =>
            -- ---- select filter modes, mix with direct path ----
            -- Ends here (register total) so the mode-sum + master multiply +
            -- clip no longer all sit in one 54 MHz path.
            filt_out := (others => '0');
            if modev_lat(4) = '1' then filt_out := filt_out + resize(lp_s,  filt_out'length); end if;
            if modev_lat(5) = '1' then filt_out := filt_out + resize(bp_s,  filt_out'length); end if;
            if modev_lat(6) = '1' then filt_out := filt_out + resize(hp_s,  filt_out'length); end if;
            total_lat <= resize(dir_lat, total_lat'length) + filt_out;
            fstage <= 5;

          when 5 =>
            -- ---- scale by master volume, add $D418 digi DAC, clip to 16-bit ----
            master := '0' & unsigned(modev_lat(3 downto 0));
            scaled := resize(total_lat * signed('0' & std_logic_vector(master)), scaled'length);
            -- Real 6581 volume changes move the output DC bias; after the audio
            -- coupling cap this becomes the classic 4-bit sample/Digi path.
            digi_in := to_signed(to_integer(master) * D418_DAC_STEP, digi_in'length);
            digi_hp := digi_in - d418_lp_s;
            d418_lp_s <= d418_lp_s + resize(shift_right(digi_hp, D418_DC_SHIFT),
                                            d418_lp_s'length);
            scaled_mix := scaled + shift_left(resize(digi_hp, scaled_mix'length), 4);
            if scaled_mix > to_signed(32767*16, scaled_mix'length) then
              sample_out <= std_logic_vector(to_signed(32767, 16));
            elsif scaled_mix < to_signed(-32768*16, scaled_mix'length) then
              sample_out <= std_logic_vector(to_signed(-32768, 16));
            else
              sample_out <= std_logic_vector(resize(shift_right(scaled_mix, 4), 16));
            end if;
            fstage <= 0;
        end case;
      end if;
    end if;
  end process;
end architecture;
