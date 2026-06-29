-- C64 keyboard matrix from a PS/2 keyboard.
--
-- CIA-1 scans the keyboard as an 8x8 matrix: it drives column-select bits on
-- PRA ($DC00, active low) and reads row bits on PRB ($DC01). A pressed key
-- shorts its column to its row, so a driven-low column pulls its row bit low.
--
-- The event-based ps2_keyboard controller can't drive this -- the matrix needs
-- the *current down state* of every key. So this module has its own small PS/2
-- frame receiver, tracks make/break (F0) and the E0 extension prefix, and keeps
-- a down bit per matrix position. Mapping is positional by primary legend: PC
-- Shift -> C64 Shift, PC '2' -> C64 '2', etc., so the C64 KERNAL does its own
-- shift handling (Shift+2 = ", and so on), exactly as on real hardware.
--
-- Matrix layout (PA = column drive, PB = row read), matching the KERNAL scan.
-- Each cell is the key at (PA column, PB row):
--         PB0   PB1   PB2    PB3   PB4    PB5   PB6   PB7
--   PA0   DEL   RET   CRSR-> F7    F1     F3    F5    CRSR-v
--   PA1   3     W     A      4     Z      S     E     LSHIFT
--   PA2   5     R     D      6     C      F     T     X
--   PA3   7     Y     G      8     B      H     U     V
--   PA4   9     I     J      0     M      K     O     N
--   PA5   +     P     L      -     .      :     @     ,
--   PA6   pound *     ;      HOME  RSHIFT =     ^     /
--   PA7   1     <-    CTRL   2     SPACE  C=    Q     RUN/STOP
--
-- Joystick emulation: the otherwise unused numeric keypad cursor keys drive
-- C64 joystick port 2 on CIA-1 PRA ($DC00), active low:
--   KP8=up, KP2=down, KP4=left, KP6=right, KP0/KP5=fire.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity c64_keyboard_matrix is
  generic (
    CLK_HZ : positive := 27_000_000
  );
  port (
    clk      : in  std_logic;
    reset_n  : in  std_logic;

    ps2_clk  : in  std_logic;
    ps2_data : in  std_logic;

    -- CIA-1 interface: the keyboard is a passive bidirectional matrix between
    -- port A columns and port B rows. Inputs are the CIA pin levels driven by
    -- the output latches/DDR; outputs are the resulting pin levels after pressed
    -- keys short a driven-low line to the opposite side.
    col_drive : in  std_logic_vector(7 downto 0);
    row_drive : in  std_logic_vector(7 downto 0) := x"FF";
    col_read  : out std_logic_vector(7 downto 0);
    row_read  : out std_logic_vector(7 downto 0);

    -- RESTORE key -> CPU NMI (active-low pulse handled in the core).
    restore_n : out std_logic
  );
end entity;

architecture rtl of c64_keyboard_matrix is
  -- ---- PS/2 frame receiver (11-bit: start, 8 data LSB-first, parity, stop) ----
  signal clk_sr   : std_logic_vector(2 downto 0) := "111";
  signal clk_fall : std_logic;
  signal sr       : std_logic_vector(10 downto 0) := (others => '1');
  signal bit_cnt  : unsigned(3 downto 0) := (others => '0');
  signal byte_rdy : std_logic := '0';
  signal rx_byte  : std_logic_vector(7 downto 0) := (others => '0');

  signal is_break : std_logic := '0';
  signal is_ext   : std_logic := '0';

  -- 8 rows x 8 cols down-state. down(row)(col).
  type row_t is array (0 to 7) of std_logic_vector(7 downto 0);
  signal down : row_t := (others => (others => '0'));

  signal restore_down : std_logic := '0';
  signal joy2_up_down    : std_logic := '0';
  signal joy2_down_down  : std_logic := '0';
  signal joy2_left_down  : std_logic := '0';
  signal joy2_right_down : std_logic := '0';
  signal joy2_fire0_down : std_logic := '0';
  signal joy2_fire5_down : std_logic := '0';
  signal joy2_n          : std_logic_vector(4 downto 0);

  -- Decode a (non-extended) Set-2 make code to a matrix position.
  -- Returns row(2:0) & col(2:0) in bits 5:0, and valid in bit 6.
  function map_norm(code : std_logic_vector(7 downto 0)) return std_logic_vector is
    variable r : std_logic_vector(6 downto 0) := (others => '0');
    -- Call sites pass (PA column, PB row). Store as down[pb_row][pa_col] so the
    -- matrix matches the KERNAL scan: PA drives columns, PB reads rows.
    procedure m(pa_col, pb_row : integer) is
    begin
      r := '1' & std_logic_vector(to_unsigned(pb_row, 3)) & std_logic_vector(to_unsigned(pa_col, 3));
    end procedure;
  begin
    case code is
      -- letters
      when x"1C" => m(1,2);  -- A
      when x"32" => m(3,4);  -- B
      when x"21" => m(2,4);  -- C
      when x"23" => m(2,2);  -- D
      when x"24" => m(1,6);  -- E
      when x"2B" => m(2,5);  -- F
      when x"34" => m(3,2);  -- G
      when x"33" => m(3,5);  -- H
      when x"43" => m(4,1);  -- I
      when x"3B" => m(4,2);  -- J
      when x"42" => m(4,5);  -- K
      when x"4B" => m(5,2);  -- L
      when x"3A" => m(4,4);  -- M
      when x"31" => m(4,7);  -- N
      when x"44" => m(4,6);  -- O
      when x"4D" => m(5,1);  -- P
      when x"15" => m(7,6);  -- Q
      when x"2D" => m(2,1);  -- R
      when x"1B" => m(1,5);  -- S
      when x"2C" => m(2,6);  -- T
      when x"3C" => m(3,6);  -- U
      when x"1D" => m(1,1);  -- W
      when x"22" => m(2,7);  -- X
      when x"35" => m(3,1);  -- Y
      when x"1A" => m(1,4);  -- Z
      -- digits (top row)
      when x"16" => m(7,0);  -- 1
      when x"1E" => m(7,3);  -- 2
      when x"26" => m(1,0);  -- 3
      when x"25" => m(1,3);  -- 4
      when x"2E" => m(2,0);  -- 5
      when x"36" => m(2,3);  -- 6
      when x"3D" => m(3,0);  -- 7
      when x"3E" => m(3,3);  -- 8
      when x"46" => m(4,0);  -- 9
      when x"45" => m(4,3);  -- 0
      -- controls / punctuation
      when x"29" => m(7,4);  -- SPACE
      when x"5A" => m(0,1);  -- RETURN
      when x"66" => m(0,0);  -- BACKSPACE -> DEL
      when x"12" => m(1,7);  -- LSHIFT
      when x"59" => m(6,4);  -- RSHIFT
      when x"14" => m(7,2);  -- LCTRL -> CTRL
      when x"11" => m(7,5);  -- LALT  -> C= (Commodore)
      when x"76" => m(7,7);  -- ESC   -> RUN/STOP
      when x"41" => m(5,7);  -- ,
      when x"49" => m(5,4);  -- .
      when x"4A" => m(6,7);  -- /
      when x"4C" => m(6,2);  -- ;
      when x"4E" => m(5,3);  -- -
      when x"55" => m(6,5);  -- =
      when x"52" => m(5,5);  -- ' -> :
      when x"54" => m(5,6);  -- [ -> @
      when x"5B" => m(6,1);  -- ] -> *
      when x"0E" => m(6,0);  -- ` -> pound
      when x"5D" => m(5,0);  -- \ -> +
      -- function keys
      when x"83" => m(0,3);  -- F7
      when x"05" => m(0,4);  -- F1
      when x"04" => m(0,5);  -- F3
      when x"03" => m(0,6);  -- F5
      when others => null;
    end case;
    return r;
  end function;

  -- Extended (E0-prefixed) keys: cursor + home.
  function map_ext(code : std_logic_vector(7 downto 0)) return std_logic_vector is
    variable r : std_logic_vector(6 downto 0) := (others => '0');
    -- Call sites pass (PA column, PB row). Store as down[pb_row][pa_col] so the
    -- matrix matches the KERNAL scan: PA drives columns, PB reads rows.
    procedure m(pa_col, pb_row : integer) is
    begin
      r := '1' & std_logic_vector(to_unsigned(pb_row, 3)) & std_logic_vector(to_unsigned(pa_col, 3));
    end procedure;
  begin
    case code is
      when x"74" => m(0,2);  -- cursor right -> CRSR L/R
      when x"72" => m(0,7);  -- cursor down  -> CRSR U/D
      when others => null;   -- up/left need shift; added later
    end case;
    return r;
  end function;

  -- Non-extended PS/2 Set-2 numeric keypad codes. With Num Lock off, most PS/2
  -- keyboards send these for the keypad cursor legends; the separate cursor
  -- cluster sends E0-prefixed codes and remains mapped to C64 cursor keys.
  procedure update_joy2(
    signal up_down    : out std_logic;
    signal down_down  : out std_logic;
    signal left_down  : out std_logic;
    signal right_down : out std_logic;
    signal fire0_down : out std_logic;
    signal fire5_down : out std_logic;
    constant code     : in  std_logic_vector(7 downto 0);
    constant pressed  : in  std_logic
  ) is
  begin
    case code is
      when x"75" => up_down    <= pressed; -- keypad 8
      when x"72" => down_down  <= pressed; -- keypad 2
      when x"6B" => left_down  <= pressed; -- keypad 4
      when x"74" => right_down <= pressed; -- keypad 6
      when x"70" => fire0_down <= pressed; -- keypad 0
      when x"73" => fire5_down <= pressed; -- keypad 5
      when others => null;
    end case;
  end procedure;

begin
  -- PS/2 clock synchroniser (ps2_clk is an asynchronous open-collector input).
  -- ps2_data is sampled raw at the (synchronised) clock falling edge -- the known-
  -- good receiver that typed correctly on hardware.
  process(clk)
  begin
    if rising_edge(clk) then
      clk_sr <= clk_sr(1 downto 0) & ps2_clk;
    end if;
  end process;
  clk_fall <= '1' when clk_sr(2 downto 1) = "10" else '0';

  -- Shift in PS/2 frames (LSB first: start, d0..d7, parity, stop).
  -- After 11 falling edges the data byte is bits 8..1 of the shift register.
  process(clk)
    variable next_sr : std_logic_vector(10 downto 0);
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        sr <= (others => '1'); bit_cnt <= (others => '0'); byte_rdy <= '0';
      else
        byte_rdy <= '0';
        if clk_fall = '1' then
          next_sr := ps2_data & sr(10 downto 1);
          sr <= next_sr;
          if bit_cnt = 10 then
            bit_cnt  <= (others => '0');
            rx_byte  <= next_sr(8 downto 1);
            byte_rdy <= '1';
          else
            bit_cnt <= bit_cnt + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- Decode make/break and update the matrix.
  process(clk)
    variable rc : std_logic_vector(6 downto 0);
    variable rr : integer range 0 to 7;
    variable cc : integer range 0 to 7;
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        down <= (others => (others => '0'));
        is_break <= '0'; is_ext <= '0'; restore_down <= '0';
        joy2_up_down <= '0'; joy2_down_down <= '0';
        joy2_left_down <= '0'; joy2_right_down <= '0';
        joy2_fire0_down <= '0'; joy2_fire5_down <= '0';
      elsif byte_rdy = '1' then
        if rx_byte = x"F0" then
          is_break <= '1';
        elsif rx_byte = x"E0" then
          is_ext <= '1';
        else
          -- RESTORE = PageUp (E0 7D) on PC, mapped to NMI line.
          if is_ext = '1' and rx_byte = x"7D" then
            restore_down <= not is_break;
          else
            if is_ext = '0' then
              update_joy2(joy2_up_down, joy2_down_down, joy2_left_down,
                          joy2_right_down, joy2_fire0_down, joy2_fire5_down,
                          rx_byte, not is_break);
            end if;
            if is_ext = '1' then
              rc := map_ext(rx_byte);
            else
              rc := map_norm(rx_byte);
            end if;
            if rc(6) = '1' then
              rr := to_integer(unsigned(rc(5 downto 3)));
              cc := to_integer(unsigned(rc(2 downto 0)));
              down(rr)(cc) <= not is_break;
            end if;
          end if;
          is_break <= '0';
          is_ext   <= '0';
        end if;
      end if;
    end if;
  end process;

  restore_n <= '0' when restore_down = '1' else '1';
  joy2_n <= (not joy2_fire0_down and not joy2_fire5_down) &
            not joy2_right_down &
            not joy2_left_down &
            not joy2_down_down &
            not joy2_up_down;

  -- Matrix read: a pin bit is pulled low when a pressed key connects it to a low
  -- pin on the opposite port. With no pressed key, the CIA reads back its own pin
  -- level (outputs included), matching the MiST/MiSTer CIA top-level feedback.
  process(down, col_drive, row_drive, joy2_n)
    variable cv : std_logic_vector(7 downto 0);
    variable rv : std_logic_vector(7 downto 0);
  begin
    cv := col_drive;
    rv := row_drive;
    for rr in 0 to 7 loop
      for cc in 0 to 7 loop
        if down(rr)(cc) = '1' then
          if col_drive(cc) = '0' then
            rv(rr) := '0';
          end if;
          if row_drive(rr) = '0' then
            cv(cc) := '0';
          end if;
        end if;
      end loop;
    end loop;
    cv(4 downto 0) := cv(4 downto 0) and joy2_n;
    col_read <= cv;
    row_read <= rv;
  end process;
end architecture;
