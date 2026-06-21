-- sid6581.vhd - compact MOS 6581 playback core for original SID player code.
-- Implements the register and synthesis features used by World_Record_2.sid:
-- three voices, 24-bit oscillators, triangle/saw/pulse/noise, gate and ADSR.
-- The tune does not route voices through the SID filter and does not use sync
-- or ring modulation, so those features are intentionally left for later.

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
  type env_state_t is (E_IDLE, E_ATTACK, E_DECAY, E_SUSTAIN, E_RELEASE);
  type env_state_arr_t is array (0 to 2) of env_state_t;

  signal regs       : regfile_t := (others => (others => '0'));
  signal phase      : phase_arr_t := (others => (others => '0'));
  signal env        : env_arr_t := (others => (others => '0'));
  signal lfsr       : lfsr_arr_t := (others => (others => '1'));
  signal noise_clk_d : bit_arr_t := (others => '0');
  signal gate_d     : bit_arr_t := (others => '0');
  signal env_state  : env_state_arr_t := (others => E_IDLE);

  signal sid_acc : integer range 0 to CLK_HZ-1 := 0;
  signal ms_cnt  : integer range 0 to CLK_HZ/1000-1 := 0;
  signal sid_tick_pulse : std_logic := '0';
  signal ms_tick_pulse  : std_logic := '0';
  attribute syn_keep : integer;
  attribute syn_keep of sid_tick_pulse : signal is 1;
  attribute syn_keep of ms_tick_pulse  : signal is 1;

  function attack_step(n : natural) return natural is
  begin
    case n is
      when 0 => return 128; when 1 => return 32; when 2 => return 16;
      when 3 => return 11;  when 4 => return 7;  when 5 => return 5;
      when 6 => return 4;   when 7 => return 4;  when 8 => return 3;
      when 9 => return 2;   when others => return 1;
    end case;
  end function;

  function decay_step(n : natural) return natural is
  begin
    case n is
      when 0 => return 43; when 1 => return 11; when 2 => return 6;
      when 3 => return 4;  when 4 => return 3;  when 5 => return 2;
      when others => return 1;
    end case;
  end function;
begin
  dout <= regs(to_integer(unsigned(addr))) when unsigned(addr) < 25 else x"FF";

  timebase_proc : process(clk)
  begin
    if rising_edge(clk) then
      sid_tick_pulse <= '0';
      ms_tick_pulse <= '0';
      if reset_n = '0' then
        sid_acc <= 0;
        ms_cnt <= 0;
      else
        if sid_acc >= CLK_HZ-SID_HZ then
          sid_acc <= sid_acc - (CLK_HZ-SID_HZ);
          sid_tick_pulse <= '1';
        else
          sid_acc <= sid_acc + SID_HZ;
        end if;
        if ms_cnt = CLK_HZ/1000-1 then
          ms_cnt <= 0;
          ms_tick_pulse <= '1';
        else
          ms_cnt <= ms_cnt + 1;
        end if;
      end if;
    end if;
  end process;

  synth_proc : process(clk)
    variable idx, base : integer;
    variable f : unsigned(15 downto 0);
    variable ctrl : data_t;
    variable target, step : natural;
    variable e : integer;
    variable feedback : std_logic;
    variable gate_change : boolean;
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        regs <= (others => (others => '0'));
        phase <= (others => (others => '0'));
        env <= (others => (others => '0'));
        lfsr <= (others => (others => '1'));
        noise_clk_d <= (others => '0');
        gate_d <= (others => '0');
        env_state <= (others => E_IDLE);
      else
        if cs = '1' and we = '1' then
          idx := to_integer(unsigned(addr));
          if idx < 25 then regs(idx) <= din; end if;
        end if;

        for v in 0 to 2 loop
          base := v*7;
          ctrl := regs(base+4);
          gate_change := false;

          if ctrl(0) = '1' and gate_d(v) = '0' then
            env_state(v) <= E_ATTACK;
            gate_change := true;
          elsif ctrl(0) = '0' and gate_d(v) = '1' then
            env_state(v) <= E_RELEASE;
            gate_change := true;
          end if;
          gate_d(v) <= ctrl(0);

          if sid_tick_pulse = '1' then
            f := unsigned(regs(base+1)) & unsigned(regs(base));
            if ctrl(3) = '1' then
              phase(v) <= (others => '0');
            else
              phase(v) <= phase(v) + resize(f, 24);
            end if;

            if phase(v)(19) = '1' and noise_clk_d(v) = '0' then
              feedback := lfsr(v)(22) xor lfsr(v)(17);
              lfsr(v) <= lfsr(v)(21 downto 0) & feedback;
            end if;
            noise_clk_d(v) <= phase(v)(19);
          end if;

          if ms_tick_pulse = '1' and not gate_change then
            e := to_integer(env(v));
            target := to_integer(unsigned(regs(base+6)(7 downto 4))) * 17;
            case env_state(v) is
              when E_ATTACK =>
                step := attack_step(to_integer(unsigned(regs(base+5)(7 downto 4))));
                if e + integer(step) >= 255 then
                  env(v) <= to_unsigned(255, 8); env_state(v) <= E_DECAY;
                else env(v) <= to_unsigned(e + integer(step), 8); end if;
              when E_DECAY =>
                step := decay_step(to_integer(unsigned(regs(base+5)(3 downto 0))));
                if e <= integer(target + step) then
                  env(v) <= to_unsigned(target, 8); env_state(v) <= E_SUSTAIN;
                else env(v) <= to_unsigned(e - integer(step), 8); end if;
              when E_SUSTAIN => env(v) <= to_unsigned(target, 8);
              when E_RELEASE =>
                step := decay_step(to_integer(unsigned(regs(base+6)(3 downto 0))));
                if e <= integer(step) then
                  env(v) <= (others => '0'); env_state(v) <= E_IDLE;
                else env(v) <= to_unsigned(e - integer(step), 8); end if;
              when others => env(v) <= (others => '0');
            end case;
          end if;
        end loop;
      end if;
    end if;
  end process;

  out_proc : process(clk)
    variable sum : signed(19 downto 0);
    variable raw : signed(9 downto 0);
    variable amp : signed(18 downto 0);
    variable p12, pw, p8, base : integer;
    variable ctrl : data_t;
    variable master : unsigned(4 downto 0);
    variable scaled : signed(25 downto 0);
  begin
    if rising_edge(clk) then
      sum := (others => '0');
      for v in 0 to 2 loop
        base := v*7; ctrl := regs(base+4);
        p8 := to_integer(phase(v)(23 downto 16));
        p12 := to_integer(phase(v)(23 downto 12));
        pw := to_integer(unsigned(regs(base+3)(3 downto 0)) & unsigned(regs(base+2)));

        if ctrl(7) = '1' then
          raw := resize(signed(std_logic_vector(lfsr(v)(22 downto 15))), 10);
        elsif ctrl(6) = '1' then
          if p12 < pw then raw := to_signed((4096-pw)/16, 10);
          else raw := to_signed(-pw/16, 10); end if;
        elsif ctrl(5) = '1' then
          raw := to_signed(127-p8, 10);
        elsif ctrl(4) = '1' then
          if p8 < 128 then raw := to_signed(2*p8-128, 10);
          else raw := to_signed(383-2*p8, 10); end if;
        else
          raw := (others => '0');
        end if;
        amp := raw * signed('0' & std_logic_vector(env(v)));
        sum := sum + resize(shift_right(amp, 2), 20);
      end loop;

      master := '0' & unsigned(regs(24)(3 downto 0));
      scaled := sum * signed('0' & std_logic_vector(master));
      if scaled > to_signed(32767*16, scaled'length) then
        sample_out <= std_logic_vector(to_signed(32767, 16));
      elsif scaled < to_signed(-32768*16, scaled'length) then
        sample_out <= std_logic_vector(to_signed(-32768, 16));
      else
        sample_out <= std_logic_vector(resize(shift_right(scaled, 4), 16));
      end if;
    end if;
  end process;
end architecture;
