-- C64 debug UART -- snoops the CPU-bus taps from c64_core and streams the screen.
--
-- DIAGNOSTIC ONLY. About once a second it transmits, 115200 8N1, over the dock
-- CH340 (uart_tx = M11):
--
--     PC=xxxx
--     <25 rows x 40 cols of the $0400-$07E7 text screen, as ASCII>
--
-- "PC=xxxx" is the address of the last instruction fetch -- a CPU heartbeat: if
-- it is identical across dumps the CPU is stuck there. The screen is shadowed
-- from CPU writes to $0400-$07E7 seen on the dbg_* snoop taps; it never drives
-- the VIC, so it cannot create the port-A-write/port-B-read BSRAM collision that
-- a VIC-side shadow would.
--
-- The ~1 KB async-read shadow is also a sizeable LUT-RAM footprint, which makes
-- this module double as a placement "spacer" during hardware bring-up.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity c64_dbg_uart is
  generic (
    CLK_HZ : integer := 27_000_000;
    BAUD   : integer := 115200
  );
  port (
    clk      : in  std_logic;
    reset_n  : in  std_logic;
    -- CPU bus snoop (wire to the c64_core dbg_* taps).
    snp_addr : in  std_logic_vector(15 downto 0);
    snp_we   : in  std_logic;
    snp_do   : in  std_logic_vector(7 downto 0);
    snp_sync : in  std_logic;
    snp_phi  : in  std_logic;
    uart_tx  : out std_logic
  );
end entity;

architecture rtl of c64_dbg_uart is
  constant DIV : integer := CLK_HZ / BAUD;          -- 234 @ 27 MHz / 115200

  -- ---- UART transmit (8N1) ----
  signal baud_cnt : integer range 0 to DIV-1 := 0;
  signal tx_sr    : std_logic_vector(9 downto 0) := (others => '1');
  signal tx_bits  : integer range 0 to 10 := 0;
  signal tx_busy  : std_logic := '0';
  signal tx_load  : std_logic := '0';
  signal tx_data  : std_logic_vector(7 downto 0) := (others => '0');

  -- ---- screen shadow (async-read LUT RAM, $0400-$07E7 -> index 0..999) ----
  type scr_t is array (0 to 1023) of std_logic_vector(7 downto 0);
  signal scr : scr_t := (others => (others => '0'));

  signal last_pc : std_logic_vector(15 downto 0) := (others => '0');

  -- ---- dump sequencer ----
  type st_t is (S_IDLE, S_REQ, S_WAIT);
  signal ds    : st_t := S_IDLE;
  signal phase : std_logic := '0';                  -- '0' = header, '1' = body
  signal hi    : integer range 0 to 8 := 0;         -- header char index
  signal col   : integer range 0 to 41 := 0;        -- 0..39 cell, 40 = CR, 41 = LF
  signal cell  : integer range 0 to 1023 := 0;
  signal go    : std_logic := '0';
  signal sec   : integer range 0 to CLK_HZ-1 := 0;

  signal cur_byte : std_logic_vector(7 downto 0);
  signal scr_rd   : std_logic_vector(7 downto 0);

  function hexd(n : std_logic_vector(3 downto 0)) return std_logic_vector is
    variable v : integer := to_integer(unsigned(n));
  begin
    if v < 10 then
      return std_logic_vector(to_unsigned(v + 16#30#, 8));    -- '0'..'9'
    else
      return std_logic_vector(to_unsigned(v + 16#37#, 8));    -- 'A'..'F'
    end if;
  end function;

  -- C64 screen code -> a printable ASCII approximation.
  function scr2asc(c : std_logic_vector(7 downto 0)) return std_logic_vector is
    variable v : integer := to_integer(unsigned(c));
  begin
    if v <= 31 then
      return std_logic_vector(to_unsigned(v + 64, 8));        -- @ A..Z [ \ ] ^ _
    elsif v <= 63 then
      return std_logic_vector(to_unsigned(v, 8));             -- space ! .. ?
    else
      return x"2E";                                           -- '.' reverse/graphics
    end if;
  end function;
begin
  -- ---- UART TX engine ----
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        tx_busy <= '0'; tx_bits <= 0; tx_sr <= (others => '1'); baud_cnt <= 0;
      elsif tx_busy = '0' then
        if tx_load = '1' then
          tx_sr    <= '1' & tx_data & '0';          -- stop, d7..d0, start (LSB out first)
          tx_bits  <= 10;
          baud_cnt <= DIV - 1;
          tx_busy  <= '1';
        end if;
      else
        if baud_cnt = 0 then
          baud_cnt <= DIV - 1;
          tx_sr    <= '1' & tx_sr(9 downto 1);
          tx_bits  <= tx_bits - 1;
          if tx_bits = 1 then
            tx_busy <= '0';
          end if;
        else
          baud_cnt <= baud_cnt - 1;
        end if;
      end if;
    end if;
  end process;
  uart_tx <= tx_sr(0);

  -- ---- screen shadow write + PC latch (CPU bus snoop) ----
  process(clk)
  begin
    if rising_edge(clk) then
      if snp_phi = '1' then
        if snp_sync = '1' then
          last_pc <= snp_addr;
        end if;
        if snp_we = '1' and
           unsigned(snp_addr) >= 16#0400# and unsigned(snp_addr) <= 16#07E7# then
          scr(to_integer(unsigned(snp_addr)) - 16#0400#) <= snp_do;
        end if;
      end if;
    end if;
  end process;

  scr_rd <= scr(cell);

  -- ---- next byte to send (combinational) ----
  process(phase, hi, col, last_pc, scr_rd)
  begin
    if phase = '0' then
      case hi is
        when 0      => cur_byte <= x"50";                     -- P
        when 1      => cur_byte <= x"43";                     -- C
        when 2      => cur_byte <= x"3D";                     -- =
        when 3      => cur_byte <= hexd(last_pc(15 downto 12));
        when 4      => cur_byte <= hexd(last_pc(11 downto 8));
        when 5      => cur_byte <= hexd(last_pc(7 downto 4));
        when 6      => cur_byte <= hexd(last_pc(3 downto 0));
        when 7      => cur_byte <= x"0D";                     -- CR
        when others => cur_byte <= x"0A";                     -- LF
      end case;
    else
      if col < 40 then
        cur_byte <= scr2asc(scr_rd);
      elsif col = 40 then
        cur_byte <= x"0D";
      else
        cur_byte <= x"0A";
      end if;
    end if;
  end process;

  -- ---- 1 Hz trigger + dump sequencer ----
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        ds <= S_IDLE; phase <= '0'; hi <= 0; col <= 0; cell <= 0;
        go <= '0'; sec <= 0; tx_load <= '0';
      else
        tx_load <= '0';                               -- default: one-cycle pulse

        if sec = CLK_HZ - 1 then
          sec <= 0; go <= '1';
        else
          sec <= sec + 1;
        end if;

        case ds is
          when S_IDLE =>
            if go = '1' then
              go <= '0'; phase <= '0'; hi <= 0; col <= 0; cell <= 0;
              ds <= S_REQ;
            end if;

          when S_REQ =>
            if tx_busy = '0' then
              tx_data <= cur_byte;
              tx_load <= '1';
              ds <= S_WAIT;
            end if;

          when S_WAIT =>
            if tx_busy = '1' then                     -- TX engine accepted the byte
              if phase = '0' then
                if hi = 8 then
                  phase <= '1'; col <= 0; cell <= 0;
                else
                  hi <= hi + 1;
                end if;
                ds <= S_REQ;
              else
                if col < 40 then
                  cell <= cell + 1;
                  if col = 39 then col <= 40; else col <= col + 1; end if;
                  ds <= S_REQ;
                elsif col = 40 then
                  col <= 41;
                  ds <= S_REQ;
                else                                  -- col = 41: LF just sent
                  if cell >= 1000 then
                    ds <= S_IDLE;                     -- whole screen done
                  else
                    col <= 0;
                    ds <= S_REQ;
                  end if;
                end if;
              end if;
            end if;
        end case;
      end if;
    end if;
  end process;
end architecture;
