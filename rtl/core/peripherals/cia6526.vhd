-- Minimal MOS 6526 CIA (CIA-1 subset): Timer A with a PHI2-rate countdown and an
-- underflow interrupt, plus the ICR (interrupt control/status) register. This is
-- enough for C64 SID tunes that drive their player from a CIA Timer A interrupt,
-- or that read $DC04/$DC05 for timing/randomness.
--
-- The timer counts at a ~1 MHz "PHI2" rate (TICK_DIV system clocks per tick) so
-- that the period values tunes write give C64-compatible interrupt rates (e.g.
-- ~19700 for 50 Hz). Timer B, the TOD clock and the I/O ports are stored for
-- read-back compatibility but are NOT functional in this subset.
--
-- Register map ($DC00-$DC0F), offset = addr:
--   $4/$5  TA LO/HI   : read = live counter, write = latch (reload when stopped)
--   $D     ICR        : read = status (bit7=IRQ, bit0=TA), reading clears it;
--                       write = mask (bit7 = set/clear sense, bits0-4 select)
--   $E     CRA        : bit0 start, bit3 one-shot, bit4 force-load
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity cia6526 is
  generic (
    -- System clocks per PHI2 tick. 54 -> ~1 MHz from the 54 MHz system clock,
    -- close to the C64 PAL PHI2 (985 kHz); music timing error is < 2 %.
    TICK_DIV : positive := 54
  );
  port (
    clk     : in  std_logic;
    reset_n : in  std_logic;
    cs      : in  std_logic;                       -- chip select (DEV_CIA1)
    we      : in  std_logic;                       -- 1 = write, 0 = read
    addr    : in  std_logic_vector(3 downto 0);    -- $DC00-$DC0F offset
    din     : in  data_t;
    dout    : out data_t;
    irq_n   : out std_logic                        -- active-low interrupt
  );
end entity;

architecture rtl of cia6526 is
  signal tick_cnt : integer range 0 to TICK_DIV - 1 := 0;
  signal phi2     : std_logic := '0';

  signal ta_latch : unsigned(15 downto 0) := (others => '1');
  signal ta_cnt   : unsigned(15 downto 0) := (others => '1');
  signal ta_run   : std_logic := '0';
  signal ta_1shot : std_logic := '0';
  signal cra      : data_t := (others => '0');

  signal icr_mask : std_logic_vector(4 downto 0) := (others => '0');  -- enables
  signal icr_stat : std_logic_vector(4 downto 0) := (others => '0');  -- latched
  signal rd_armed : std_logic := '1';   -- one ICR clear per bus access

  type rf_t is array (0 to 15) of data_t;
  signal rf : rf_t := (others => (others => '0'));  -- read-back for unimpl regs
begin
  -- IRQ asserted while any enabled source is latched; cleared by reading ICR.
  irq_n <= '0' when (icr_stat and icr_mask) /= "00000" else '1';

  process(clk)
    variable ai : integer range 0 to 15;
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        tick_cnt <= 0; phi2 <= '0';
        ta_latch <= (others => '1'); ta_cnt <= (others => '1');
        ta_run <= '0'; ta_1shot <= '0'; cra <= (others => '0');
        icr_mask <= (others => '0'); icr_stat <= (others => '0');
        rd_armed <= '1'; rf <= (others => (others => '0'));
      else
        -- PHI2 tick
        phi2 <= '0';
        if tick_cnt = TICK_DIV - 1 then tick_cnt <= 0; phi2 <= '1';
        else tick_cnt <= tick_cnt + 1; end if;

        -- Timer A down-counter
        if phi2 = '1' and ta_run = '1' then
          if ta_cnt = 0 then
            ta_cnt      <= ta_latch;        -- reload on underflow
            icr_stat(0) <= '1';             -- latch TA interrupt flag
            if ta_1shot = '1' then
              ta_run <= '0';
              cra(0) <= '0';
            end if;
          else
            ta_cnt <= ta_cnt - 1;
          end if;
        end if;

        -- re-arm the read-clear once the (2-clock) bus access has ended
        if cs = '0' then
          rd_armed <= '1';
        end if;

        if cs = '1' then
          ai := to_integer(unsigned(addr));
          if we = '1' then
            rf(ai) <= din;                  -- read-back store for unimpl regs
            case addr is
              when x"4" =>
                ta_latch(7 downto 0) <= unsigned(din);
              when x"5" =>
                ta_latch(15 downto 8) <= unsigned(din);
                if ta_run = '0' then        -- stopped: writing hi reloads counter
                  ta_cnt <= unsigned(din) & ta_latch(7 downto 0);
                end if;
              when x"D" =>                  -- ICR mask (bit7 = set/clear sense)
                if din(7) = '1' then
                  icr_mask <= icr_mask or din(4 downto 0);
                else
                  icr_mask <= icr_mask and not din(4 downto 0);
                end if;
              when x"E" =>                  -- CRA
                cra     <= din;
                ta_run  <= din(0);
                ta_1shot <= din(3);
                if din(4) = '1' then        -- force load
                  ta_cnt <= ta_latch;
                end if;
              when others =>
                null;
            end case;
          elsif addr = x"D" and rd_armed = '1' then
            icr_stat <= (others => '0');    -- read of ICR clears status + IRQ
            rd_armed <= '0';
          end if;
        end if;
      end if;
    end if;
  end process;

  process(addr, ta_cnt, icr_stat, icr_mask, cra, rf)
  begin
    case addr is
      when x"4" =>
        dout <= std_logic_vector(ta_cnt(7 downto 0));
      when x"5" =>
        dout <= std_logic_vector(ta_cnt(15 downto 8));
      when x"D" =>
        if (icr_stat and icr_mask) /= "00000" then
          dout <= '1' & "00" & icr_stat;   -- bit7 = interrupt occurred
        else
          dout <= '0' & "00" & icr_stat;
        end if;
      when x"E" =>
        dout <= cra;
      when others =>
        dout <= rf(to_integer(unsigned(addr)));
    end case;
  end process;
end architecture;
