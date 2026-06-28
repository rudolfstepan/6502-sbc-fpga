-- MOS 6526 CIA -- full version for the native C64 core.
--
-- Implements the parts the C64 KERNAL/BASIC and most software rely on:
--   * Ports A/B with per-bit data-direction (DDRA/DDRB). Output bits drive the
--     pins; input bits read the external level ANDed onto the pin. This is what
--     CIA-1 uses to scan the keyboard matrix (PRA = column drive, PRB = rows)
--     and what CIA-2 uses for the VIC bank select (PRA bits 0-1).
--   * Timer A and Timer B, 16-bit down-counters at the PHI2 rate, one-shot or
--     continuous, force-load, and Timer B cascade off Timer A underflow.
--   * Interrupt control register (ICR) with mask and read-to-clear; the IRQ/NMI
--     output is active-low and open-drain style (asserted while enabled+latched).
--   * Time-of-day clock (10ths/sec/min/hr BCD), free-running; latched on hour
--     read, unlatched on 10ths read (enough for the KERNAL jiffy fallback).
--
-- PHI2 is modelled by the `tick` clock-enable (one system clock wide), so the
-- whole CIA runs in the system clock domain like the rest of the core.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cia6526_full is
  port (
    clk     : in  std_logic;
    reset_n : in  std_logic;
    tick    : in  std_logic;                       -- PHI2 clock-enable (1 sysclk)
    tod_tick: in  std_logic := '0';                -- 60/50 Hz TOD pulse (1 sysclk)

    cs      : in  std_logic;                        -- chip select
    we      : in  std_logic;                        -- 1 = write
    addr    : in  std_logic_vector(3 downto 0);
    din     : in  std_logic_vector(7 downto 0);
    dout    : out std_logic_vector(7 downto 0);

    -- Port A/B: pin level in, driven value + direction out.
    pa_in   : in  std_logic_vector(7 downto 0) := (others => '1');
    pa_out  : out std_logic_vector(7 downto 0);
    pa_ddr  : out std_logic_vector(7 downto 0);
    pb_in   : in  std_logic_vector(7 downto 0) := (others => '1');
    pb_out  : out std_logic_vector(7 downto 0);
    pb_ddr  : out std_logic_vector(7 downto 0);

    flag_n  : in  std_logic := '1';                 -- FLAG input (falling edge -> ICR bit 4)
    irq_n   : out std_logic                          -- active-low IRQ/NMI
  );
end entity;

architecture rtl of cia6526_full is
  signal pra, prb   : std_logic_vector(7 downto 0) := (others => '0');
  signal ddra, ddrb : std_logic_vector(7 downto 0) := (others => '0');

  signal ta_latch, ta_cnt : unsigned(15 downto 0) := (others => '1');
  signal tb_latch, tb_cnt : unsigned(15 downto 0) := (others => '1');
  signal cra, crb         : std_logic_vector(7 downto 0) := (others => '0');

  signal icr_mask : std_logic_vector(4 downto 0) := (others => '0');
  signal icr_stat : std_logic_vector(4 downto 0) := (others => '0');
  -- ICR read-clear must happen when the (possibly multi-clock) read cycle ENDS,
  -- not on its first clock -- otherwise a CPU clock-enabled at 1/N reads back 0
  -- (status already cleared) and never sees the IRQ flag (bit 7).
  signal icr_rd_pend : std_logic := '0';

  signal ta_uf, tb_uf : std_logic;                  -- underflow strobes
  signal flag_d       : std_logic := '1';

  -- TOD (BCD): 10ths, seconds, minutes, hours(+AM/PM in bit7).
  signal tod_t, tod_s, tod_m, tod_h : std_logic_vector(7 downto 0) := (others => '0');
  signal tod_latched                : std_logic := '0';
  signal tod_lt, tod_ls, tod_lm, tod_lh : std_logic_vector(7 downto 0) := (others => '0');
  signal tod_div : integer range 0 to 5 := 0;       -- 6 ticks per 10th @60Hz

  -- Pin levels: output bits show the register, input bits show the external pin.
  signal pa_pin, pb_pin : std_logic_vector(7 downto 0);
begin
  pa_ddr <= ddra;
  pb_ddr <= ddrb;
  pa_out <= pra;
  pb_out <= prb;

  -- Open-drain / wired-AND pin model (6526 + matrix): a bit reads low if it is
  -- driven low (DDR=1, PR=0) OR pulled low externally; an input bit (DDR=0) just
  -- follows the external level. Equivalent to the simple mux for our keyboard
  -- wiring (pa_in/pb_in tied high, ddra=$FF/ddrb=$00) but correct for joystick/
  -- multi-key cases too.
  pin_gen : for i in 0 to 7 generate
    pa_pin(i) <= (pra(i) or not ddra(i)) and pa_in(i);
    pb_pin(i) <= (prb(i) or not ddrb(i)) and pb_in(i);
  end generate;

  irq_n <= '0' when (icr_stat and icr_mask) /= "00000" else '1';

  process(clk)
    variable ai : integer range 0 to 15;
    variable ta_uf_now : std_logic;   -- Timer A underflow THIS clock (for TB cascade)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        pra <= (others => '0'); prb <= (others => '0');
        ddra <= (others => '0'); ddrb <= (others => '0');
        ta_latch <= (others => '1'); ta_cnt <= (others => '1');
        tb_latch <= (others => '1'); tb_cnt <= (others => '1');
        cra <= (others => '0'); crb <= (others => '0');
        icr_mask <= (others => '0'); icr_stat <= (others => '0');
        icr_rd_pend <= '0';
        flag_d <= '1';
        tod_t <= (others => '0'); tod_s <= (others => '0');
        tod_m <= (others => '0'); tod_h <= (others => '0');
        tod_div <= 0; tod_latched <= '0';
      else
        ta_uf <= '0';
        tb_uf <= '0';
        ta_uf_now := '0';

        -- Deferred ICR read-clear: once the ICR read cycle ends (cs low again),
        -- clear the latched status. Placed before the timer/FLAG sets below so a
        -- source that fires on this same clock survives the clear.
        if cs = '0' and icr_rd_pend = '1' then
          icr_stat    <= (others => '0');
          icr_rd_pend <= '0';
        end if;

        -- FLAG falling edge -> ICR bit4
        flag_d <= flag_n;
        if flag_d = '1' and flag_n = '0' then
          icr_stat(4) <= '1';
        end if;

        -- Timer A
        if tick = '1' and cra(0) = '1' then
          if ta_cnt = 0 then
            ta_cnt <= ta_latch;
            ta_uf  <= '1';
            ta_uf_now := '1';
            icr_stat(0) <= '1';
            if cra(3) = '1' then            -- one-shot
              cra(0) <= '0';
            end if;
          else
            ta_cnt <= ta_cnt - 1;
          end if;
        end if;

        -- Timer B: count PHI2 (crb(6:5)="00") or Timer A underflows ("01")
        if crb(0) = '1' then
          if (crb(6 downto 5) = "00" and tick = '1') or
             (crb(6 downto 5) = "01" and ta_uf_now = '1') then
            if tb_cnt = 0 then
              tb_cnt <= tb_latch;
              tb_uf  <= '1';
              icr_stat(1) <= '1';
              if crb(3) = '1' then
                crb(0) <= '0';
              end if;
            else
              tb_cnt <= tb_cnt - 1;
            end if;
          end if;
        end if;

        -- TOD: advance 10ths every 6 (60 Hz) ticks; simple BCD ripple.
        if tod_tick = '1' then
          if tod_div = 5 then
            tod_div <= 0;
            if tod_t = x"09" then
              tod_t <= x"00";
              if tod_s(3 downto 0) = x"9" then
                tod_s(3 downto 0) <= x"0";
                if tod_s(7 downto 4) = x"5" then
                  tod_s(7 downto 4) <= x"0";
                  -- minutes ripple
                  if tod_m(3 downto 0) = x"9" then
                    tod_m(3 downto 0) <= x"0";
                    if tod_m(7 downto 4) = x"5" then
                      tod_m(7 downto 4) <= x"0";
                    else
                      tod_m(7 downto 4) <= std_logic_vector(unsigned(tod_m(7 downto 4)) + 1);
                    end if;
                  else
                    tod_m(3 downto 0) <= std_logic_vector(unsigned(tod_m(3 downto 0)) + 1);
                  end if;
                else
                  tod_s(7 downto 4) <= std_logic_vector(unsigned(tod_s(7 downto 4)) + 1);
                end if;
              else
                tod_s(3 downto 0) <= std_logic_vector(unsigned(tod_s(3 downto 0)) + 1);
              end if;
            else
              tod_t <= std_logic_vector(unsigned(tod_t) + 1);
            end if;
          else
            tod_div <= tod_div + 1;
          end if;
        end if;

        -- Bus access
        if cs = '1' then
          ai := to_integer(unsigned(addr));
          if we = '1' then
            case ai is
              when 0  => pra <= din;
              when 1  => prb <= din;
              when 2  => ddra <= din;
              when 3  => ddrb <= din;
              when 4  => ta_latch(7 downto 0)  <= unsigned(din);
              when 5  => ta_latch(15 downto 8) <= unsigned(din);
                         if cra(0) = '0' then ta_cnt <= unsigned(din) & ta_latch(7 downto 0); end if;
              when 6  => tb_latch(7 downto 0)  <= unsigned(din);
              when 7  => tb_latch(15 downto 8) <= unsigned(din);
                         if crb(0) = '0' then tb_cnt <= unsigned(din) & tb_latch(7 downto 0); end if;
              when 13 =>                          -- ICR mask
                if din(7) = '1' then
                  icr_mask <= icr_mask or din(4 downto 0);
                else
                  icr_mask <= icr_mask and not din(4 downto 0);
                end if;
              when 14 =>                           -- CRA (bit4 = force-load STROBE)
                cra <= din(7 downto 5) & '0' & din(3 downto 0);
                if din(4) = '1' then ta_cnt <= ta_latch; end if;
              when 15 =>                           -- CRB (bit4 = force-load STROBE)
                crb <= din(7 downto 5) & '0' & din(3 downto 0);
                if din(4) = '1' then tb_cnt <= tb_latch; end if;
              when others => null;
            end case;
          else
            -- Reads with side effects
            if ai = 13 then
              icr_rd_pend <= '1';                   -- clear ICR when the read ends
            elsif ai = 8 then
              tod_latched <= '0';                   -- reading 10ths unlatches
            elsif ai = 11 then
              tod_latched <= '1';                   -- reading hours latches
              tod_lt <= tod_t; tod_ls <= tod_s;
              tod_lm <= tod_m; tod_lh <= tod_h;
            end if;
          end if;
        end if;
      end if;
    end if;
  end process;

  process(addr, pa_pin, pb_pin, ddra, ddrb, ta_cnt, tb_cnt, icr_stat, icr_mask,
          cra, crb, tod_t, tod_s, tod_m, tod_h, tod_lt, tod_ls, tod_lm, tod_lh,
          tod_latched)
    variable ai : integer range 0 to 15;
  begin
    ai := to_integer(unsigned(addr));
    case ai is
      when 0  => dout <= pa_pin;
      when 1  => dout <= pb_pin;
      when 2  => dout <= ddra;
      when 3  => dout <= ddrb;
      when 4  => dout <= std_logic_vector(ta_cnt(7 downto 0));
      when 5  => dout <= std_logic_vector(ta_cnt(15 downto 8));
      when 6  => dout <= std_logic_vector(tb_cnt(7 downto 0));
      when 7  => dout <= std_logic_vector(tb_cnt(15 downto 8));
      when 8  => if tod_latched = '0' then dout <= tod_t; else dout <= tod_lt; end if;
      when 9  => if tod_latched = '0' then dout <= tod_s; else dout <= tod_ls; end if;
      when 10 => if tod_latched = '0' then dout <= tod_m; else dout <= tod_lm; end if;
      when 11 => if tod_latched = '0' then dout <= tod_h; else dout <= tod_lh; end if;
      when 13 =>
        if (icr_stat and icr_mask) /= "00000" then
          dout <= '1' & "00" & icr_stat;
        else
          dout <= '0' & "00" & icr_stat;
        end if;
      when 14 => dout <= cra;
      when 15 => dout <= crb;
      when others => dout <= (others => '0');
    end case;
  end process;
end architecture;
