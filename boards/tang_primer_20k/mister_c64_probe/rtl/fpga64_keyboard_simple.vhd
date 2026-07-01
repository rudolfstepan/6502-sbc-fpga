library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fpga64_keyboard is
  port (
    clk     : in std_logic;
    reset   : in std_logic;

    ps2_key : in std_logic_vector(10 downto 0);
    joyA    : in unsigned(6 downto 0);
    joyB    : in unsigned(6 downto 0);

    shift_mod : in std_logic_vector(1 downto 0);

    pai     : in unsigned(7 downto 0);
    pbi     : in unsigned(7 downto 0);
    pao     : out unsigned(7 downto 0);
    pbo     : out unsigned(7 downto 0);

    restore_key : out std_logic;
    mod_key     : out std_logic;
    tape_play   : out std_logic;

    backwardsReadingEnabled : in std_logic
  );
end entity;

architecture rtl of fpga64_keyboard is
  type row_t is array (0 to 7) of std_logic_vector(7 downto 0);
  signal down : row_t := (others => (others => '0'));
  signal ps2_stb : std_logic := '0';
  signal restore_down : std_logic := '0';

  function map_norm(code : std_logic_vector(7 downto 0)) return std_logic_vector is
    variable r : std_logic_vector(6 downto 0) := (others => '0');
    procedure m(pa_col, pb_row : integer) is
    begin
      r := '1' & std_logic_vector(to_unsigned(pb_row, 3)) & std_logic_vector(to_unsigned(pa_col, 3));
    end procedure;
  begin
    case code is
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
      when x"2A" => m(3,7);  -- V
      when x"1D" => m(1,1);  -- W
      when x"22" => m(2,7);  -- X
      when x"35" => m(3,1);  -- Y
      when x"1A" => m(1,4);  -- Z

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

      when x"29" => m(7,4);  -- SPACE
      when x"5A" => m(0,1);  -- RETURN
      when x"66" => m(0,0);  -- BACKSPACE -> DEL
      when x"12" => m(1,7);  -- LSHIFT
      when x"59" => m(6,4);  -- RSHIFT
      when x"14" => m(7,2);  -- CTRL
      when x"11" => m(7,5);  -- ALT -> C=
      when x"76" => m(7,7);  -- ESC -> RUN/STOP
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

      when x"83" => m(0,3);  -- F7
      when x"05" => m(0,4);  -- F1
      when x"04" => m(0,5);  -- F3
      when x"03" => m(0,6);  -- F5
      when others => null;
    end case;
    return r;
  end function;

  function map_ext(code : std_logic_vector(7 downto 0)) return std_logic_vector is
    variable r : std_logic_vector(6 downto 0) := (others => '0');
    procedure m(pa_col, pb_row : integer) is
    begin
      r := '1' & std_logic_vector(to_unsigned(pb_row, 3)) & std_logic_vector(to_unsigned(pa_col, 3));
    end procedure;
  begin
    case code is
      when x"74" => m(0,2);  -- cursor right
      when x"72" => m(0,7);  -- cursor down
      when others => null;
    end case;
    return r;
  end function;
begin
  mod_key <= '0';
  tape_play <= '0';
  restore_key <= restore_down;

  process(clk)
    variable rc : std_logic_vector(6 downto 0);
    variable rr : integer range 0 to 7;
    variable cc : integer range 0 to 7;
  begin
    if rising_edge(clk) then
      if reset = '1' then
        down <= (others => (others => '0'));
        ps2_stb <= ps2_key(10);
        restore_down <= '0';
      elsif ps2_key(10) /= ps2_stb then
        ps2_stb <= ps2_key(10);
        if ps2_key(8) = '1' then
          rc := map_ext(ps2_key(7 downto 0));
          if ps2_key(7 downto 0) = x"7D" then
            restore_down <= ps2_key(9);
          end if;
        else
          rc := map_norm(ps2_key(7 downto 0));
        end if;
        if rc(6) = '1' then
          rr := to_integer(unsigned(rc(5 downto 3)));
          cc := to_integer(unsigned(rc(2 downto 0)));
          down(rr)(cc) <= ps2_key(9);
        end if;
      end if;
    end if;
  end process;

  process(down, pai, pbi, joyA, joyB)
    variable cv : std_logic_vector(7 downto 0);
    variable rv : std_logic_vector(7 downto 0);
  begin
    cv := std_logic_vector(pai);
    rv := std_logic_vector(pbi);
    for rr in 0 to 7 loop
      for cc in 0 to 7 loop
        if down(rr)(cc) = '1' then
          if pai(cc) = '0' then
            rv(rr) := '0';
          end if;
          if pbi(rr) = '0' then
            cv(cc) := '0';
          end if;
        end if;
      end loop;
    end loop;
    pao <= unsigned(cv);
    pbo <= unsigned(rv);
  end process;
end architecture;
