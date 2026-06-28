-- C64 debug UART -- snoops the CPU-bus taps from c64_core and streams the screen.
--
-- DIAGNOSTIC ONLY. About once a second it transmits, 115200 8N1, over the dock
-- CH340 (uart_tx = M11):
--
--     PC=xxxx ST=xxxx A=xxxx DI=xx DO=xx C1=xxxxxxxx R=xxxxxxxxxxxxxxxx IC=xxxx IK=xxxx SW=aa:dd SR=aa:dd
--     <25 rows x 40 cols of the $0400-$07E7 text screen, as ASCII>
--
-- "PC=xxxx" is the address of the last instruction fetch -- a CPU heartbeat: if
-- it is identical across dumps the CPU is stuck there. "ST" is the packed core
-- status word from c64_core (RDY/BA/IRQ/FIFO/sync/write taps). "C1" is CIA1
-- internals: irq_n,int_reset,rd,wr,IMR[4:0],ICR[4:0],CRA[1:0],TimerA[15:0].
-- "R" is the T65 register pack: PC,S,P,Y,X,A (MSB -> LSB).
-- "IC" counts opcode fetches, "IK" counts entries into the KERNAL IRQ prologue
-- at $FF48 (the ROM's IRQ/BRK vector target); if PC looks unchanged but IC/IK
-- advance, the CPU is still alive.
-- "SW"/"SR" are the last stack-page write/read address low byte and data.
-- The screen is shadowed from CPU writes to $0400-$07E7 seen on the dbg_* snoop
-- taps; it never drives the VIC, so it cannot create the port-A-write/port-B-read
-- BSRAM collision that a VIC-side shadow would.
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
    snp_di   : in  std_logic_vector(7 downto 0);
    snp_sync : in  std_logic;
    snp_phi  : in  std_logic;
    snp_status : in std_logic_vector(15 downto 0);
    snp_cia1 : in std_logic_vector(31 downto 0);
    snp_regs : in std_logic_vector(63 downto 0);
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
  signal hi    : integer range 0 to 102 := 0;       -- header char index
  signal col   : integer range 0 to 41 := 0;        -- 0..39 cell, 40 = CR, 41 = LF
  signal cell  : integer range 0 to 1023 := 0;
  signal go    : std_logic := '0';
  signal sec   : integer range 0 to CLK_HZ-1 := 0;

  signal cur_byte : std_logic_vector(7 downto 0);
  signal scr_rd   : std_logic_vector(7 downto 0);
  signal snap_pc     : std_logic_vector(15 downto 0) := (others => '0');
  signal snap_addr   : std_logic_vector(15 downto 0) := (others => '0');
  signal snap_do     : std_logic_vector(7 downto 0) := (others => '0');
  signal snap_di     : std_logic_vector(7 downto 0) := (others => '0');
  signal snap_status : std_logic_vector(15 downto 0) := (others => '0');
  signal snap_cia1   : std_logic_vector(31 downto 0) := (others => '0');
  signal snap_regs   : std_logic_vector(63 downto 0) := (others => '0');
  signal inst_count  : unsigned(15 downto 0) := (others => '0');
  signal irqk_count  : unsigned(15 downto 0) := (others => '0');
  signal snap_inst   : std_logic_vector(15 downto 0) := (others => '0');
  signal snap_irqk   : std_logic_vector(15 downto 0) := (others => '0');
  signal last_sw_addr : std_logic_vector(7 downto 0) := (others => '0');
  signal last_sw_data : std_logic_vector(7 downto 0) := (others => '0');
  signal last_sr_addr : std_logic_vector(7 downto 0) := (others => '0');
  signal last_sr_data : std_logic_vector(7 downto 0) := (others => '0');
  signal snap_sw_addr : std_logic_vector(7 downto 0) := (others => '0');
  signal snap_sw_data : std_logic_vector(7 downto 0) := (others => '0');
  signal snap_sr_addr : std_logic_vector(7 downto 0) := (others => '0');
  signal snap_sr_data : std_logic_vector(7 downto 0) := (others => '0');

  function hexd(n : std_logic_vector(3 downto 0)) return std_logic_vector is
    variable v : integer := to_integer(unsigned(n));
  begin
    if v < 10 then
      return std_logic_vector(to_unsigned(v + 16#30#, 8));    -- '0'..'9'
    else
      return std_logic_vector(to_unsigned(v + 16#37#, 8));    -- 'A'..'F'
    end if;
  end function;

  function hex64(v : std_logic_vector(63 downto 0); idx : integer) return std_logic_vector is
    variable n : std_logic_vector(3 downto 0);
  begin
    case idx is
      when 0  => n := v(63 downto 60);
      when 1  => n := v(59 downto 56);
      when 2  => n := v(55 downto 52);
      when 3  => n := v(51 downto 48);
      when 4  => n := v(47 downto 44);
      when 5  => n := v(43 downto 40);
      when 6  => n := v(39 downto 36);
      when 7  => n := v(35 downto 32);
      when 8  => n := v(31 downto 28);
      when 9  => n := v(27 downto 24);
      when 10 => n := v(23 downto 20);
      when 11 => n := v(19 downto 16);
      when 12 => n := v(15 downto 12);
      when 13 => n := v(11 downto 8);
      when 14 => n := v(7 downto 4);
      when others => n := v(3 downto 0);
    end case;
    return hexd(n);
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
          inst_count <= inst_count + 1;
          if snp_addr = x"FF48" then
            irqk_count <= irqk_count + 1;
          end if;
        end if;
        if snp_we = '1' and
           unsigned(snp_addr) >= 16#0400# and unsigned(snp_addr) <= 16#07E7# then
          scr(to_integer(unsigned(snp_addr)) - 16#0400#) <= snp_do;
        end if;
        if snp_addr(15 downto 8) = x"01" then
          if snp_we = '1' then
            last_sw_addr <= snp_addr(7 downto 0);
            last_sw_data <= snp_do;
          else
            last_sr_addr <= snp_addr(7 downto 0);
            last_sr_data <= snp_di;
          end if;
        end if;
      end if;
    end if;
  end process;

  scr_rd <= scr(cell);

  -- ---- next byte to send (combinational) ----
  process(phase, hi, col, snap_pc, snap_addr, snap_do, snap_di, snap_status,
          snap_cia1, snap_regs, snap_inst, snap_irqk, snap_sw_addr,
          snap_sw_data, snap_sr_addr, snap_sr_data, scr_rd)
  begin
    if phase = '0' then
      case hi is
        when 0      => cur_byte <= x"50";                     -- P
        when 1      => cur_byte <= x"43";                     -- C
        when 2      => cur_byte <= x"3D";                     -- =
        when 3      => cur_byte <= hexd(snap_pc(15 downto 12));
        when 4      => cur_byte <= hexd(snap_pc(11 downto 8));
        when 5      => cur_byte <= hexd(snap_pc(7 downto 4));
        when 6      => cur_byte <= hexd(snap_pc(3 downto 0));
        when 7      => cur_byte <= x"20";                     -- space
        when 8      => cur_byte <= x"53";                     -- S
        when 9      => cur_byte <= x"54";                     -- T
        when 10     => cur_byte <= x"3D";                     -- =
        when 11     => cur_byte <= hexd(snap_status(15 downto 12));
        when 12     => cur_byte <= hexd(snap_status(11 downto 8));
        when 13     => cur_byte <= hexd(snap_status(7 downto 4));
        when 14     => cur_byte <= hexd(snap_status(3 downto 0));
        when 15     => cur_byte <= x"20";                     -- space
        when 16     => cur_byte <= x"41";                     -- A
        when 17     => cur_byte <= x"3D";                     -- =
        when 18     => cur_byte <= hexd(snap_addr(15 downto 12));
        when 19     => cur_byte <= hexd(snap_addr(11 downto 8));
        when 20     => cur_byte <= hexd(snap_addr(7 downto 4));
        when 21     => cur_byte <= hexd(snap_addr(3 downto 0));
        when 22     => cur_byte <= x"20";                     -- space
        when 23     => cur_byte <= x"44";                     -- D
        when 24     => cur_byte <= x"49";                     -- I
        when 25     => cur_byte <= x"3D";                     -- =
        when 26     => cur_byte <= hexd(snap_di(7 downto 4));
        when 27     => cur_byte <= hexd(snap_di(3 downto 0));
        when 28     => cur_byte <= x"20";                     -- space
        when 29     => cur_byte <= x"44";                     -- D
        when 30     => cur_byte <= x"4F";                     -- O
        when 31     => cur_byte <= x"3D";                     -- =
        when 32     => cur_byte <= hexd(snap_do(7 downto 4));
        when 33     => cur_byte <= hexd(snap_do(3 downto 0));
        when 34     => cur_byte <= x"20";                     -- space
        when 35     => cur_byte <= x"43";                     -- C
        when 36     => cur_byte <= x"31";                     -- 1
        when 37     => cur_byte <= x"3D";                     -- =
        when 38     => cur_byte <= hexd(snap_cia1(31 downto 28));
        when 39     => cur_byte <= hexd(snap_cia1(27 downto 24));
        when 40     => cur_byte <= hexd(snap_cia1(23 downto 20));
        when 41     => cur_byte <= hexd(snap_cia1(19 downto 16));
        when 42     => cur_byte <= hexd(snap_cia1(15 downto 12));
        when 43     => cur_byte <= hexd(snap_cia1(11 downto 8));
        when 44     => cur_byte <= hexd(snap_cia1(7 downto 4));
        when 45     => cur_byte <= hexd(snap_cia1(3 downto 0));
        when 46     => cur_byte <= x"20";                     -- space
        when 47     => cur_byte <= x"52";                     -- R
        when 48     => cur_byte <= x"3D";                     -- =
        when 49     => cur_byte <= hex64(snap_regs, 0);
        when 50     => cur_byte <= hex64(snap_regs, 1);
        when 51     => cur_byte <= hex64(snap_regs, 2);
        when 52     => cur_byte <= hex64(snap_regs, 3);
        when 53     => cur_byte <= hex64(snap_regs, 4);
        when 54     => cur_byte <= hex64(snap_regs, 5);
        when 55     => cur_byte <= hex64(snap_regs, 6);
        when 56     => cur_byte <= hex64(snap_regs, 7);
        when 57     => cur_byte <= hex64(snap_regs, 8);
        when 58     => cur_byte <= hex64(snap_regs, 9);
        when 59     => cur_byte <= hex64(snap_regs, 10);
        when 60     => cur_byte <= hex64(snap_regs, 11);
        when 61     => cur_byte <= hex64(snap_regs, 12);
        when 62     => cur_byte <= hex64(snap_regs, 13);
        when 63     => cur_byte <= hex64(snap_regs, 14);
        when 64     => cur_byte <= hex64(snap_regs, 15);
        when 65     => cur_byte <= x"20";                     -- space
        when 66     => cur_byte <= x"49";                     -- I
        when 67     => cur_byte <= x"43";                     -- C
        when 68     => cur_byte <= x"3D";                     -- =
        when 69     => cur_byte <= hexd(snap_inst(15 downto 12));
        when 70     => cur_byte <= hexd(snap_inst(11 downto 8));
        when 71     => cur_byte <= hexd(snap_inst(7 downto 4));
        when 72     => cur_byte <= hexd(snap_inst(3 downto 0));
        when 73     => cur_byte <= x"20";                     -- space
        when 74     => cur_byte <= x"49";                     -- I
        when 75     => cur_byte <= x"4B";                     -- K
        when 76     => cur_byte <= x"3D";                     -- =
        when 77     => cur_byte <= hexd(snap_irqk(15 downto 12));
        when 78     => cur_byte <= hexd(snap_irqk(11 downto 8));
        when 79     => cur_byte <= hexd(snap_irqk(7 downto 4));
        when 80     => cur_byte <= hexd(snap_irqk(3 downto 0));
        when 81     => cur_byte <= x"20";                     -- space
        when 82     => cur_byte <= x"53";                     -- S
        when 83     => cur_byte <= x"57";                     -- W
        when 84     => cur_byte <= x"3D";                     -- =
        when 85     => cur_byte <= hexd(snap_sw_addr(7 downto 4));
        when 86     => cur_byte <= hexd(snap_sw_addr(3 downto 0));
        when 87     => cur_byte <= x"3A";                     -- :
        when 88     => cur_byte <= hexd(snap_sw_data(7 downto 4));
        when 89     => cur_byte <= hexd(snap_sw_data(3 downto 0));
        when 90     => cur_byte <= x"20";                     -- space
        when 91     => cur_byte <= x"53";                     -- S
        when 92     => cur_byte <= x"52";                     -- R
        when 93     => cur_byte <= x"3D";                     -- =
        when 94     => cur_byte <= hexd(snap_sr_addr(7 downto 4));
        when 95     => cur_byte <= hexd(snap_sr_addr(3 downto 0));
        when 96     => cur_byte <= x"3A";                     -- :
        when 97     => cur_byte <= hexd(snap_sr_data(7 downto 4));
        when 98     => cur_byte <= hexd(snap_sr_data(3 downto 0));
        when 99     => cur_byte <= x"0D";                     -- CR
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
              snap_pc <= last_pc;
              snap_addr <= snp_addr;
              snap_do <= snp_do;
              snap_di <= snp_di;
              snap_status <= snp_status;
              snap_cia1 <= snp_cia1;
              snap_regs <= snp_regs;
              snap_inst <= std_logic_vector(inst_count);
              snap_irqk <= std_logic_vector(irqk_count);
              snap_sw_addr <= last_sw_addr;
              snap_sw_data <= last_sw_data;
              snap_sr_addr <= last_sr_addr;
              snap_sr_data <= last_sr_data;
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
                if hi = 100 then
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
