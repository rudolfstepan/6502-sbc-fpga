-- PS/2 numeric keypad -> C64 joystick port 2 smoke test.
library ieee;
use ieee.std_logic_1164.all;

entity tb_c64_keyboard_matrix_joystick is
end entity;

architecture sim of tb_c64_keyboard_matrix_joystick is
  signal clk      : std_logic := '0';
  signal reset_n  : std_logic := '0';
  signal running  : boolean := true;

  signal ps2_clk  : std_logic := '1';
  signal ps2_data : std_logic := '1';
  signal col_drive: std_logic_vector(7 downto 0) := x"FF";
  signal row_drive: std_logic_vector(7 downto 0) := x"FF";
  signal col_read : std_logic_vector(7 downto 0);
  signal row_read : std_logic_vector(7 downto 0);
  signal restore_n: std_logic;
begin
  dut : entity work.c64_keyboard_matrix
    port map (
      clk => clk, reset_n => reset_n,
      ps2_clk => ps2_clk, ps2_data => ps2_data,
      col_drive => col_drive, row_drive => row_drive,
      col_read => col_read, row_read => row_read,
      restore_n => restore_n
    );

  clk_p : process
  begin
    while running loop
      clk <= '0'; wait for 5 ns;
      clk <= '1'; wait for 5 ns;
    end loop;
    wait;
  end process;

  stim : process
    procedure ps2_bit(bitv : std_logic) is
    begin
      ps2_data <= bitv;
      wait for 20 us;
      ps2_clk <= '0';
      wait for 20 us;
      ps2_clk <= '1';
      wait for 20 us;
    end procedure;

    procedure ps2_byte(code : std_logic_vector(7 downto 0)) is
      variable parity : std_logic := '1';
    begin
      ps2_bit('0');
      for i in 0 to 7 loop
        ps2_bit(code(i));
        parity := parity xor code(i);
      end loop;
      ps2_bit(parity);
      ps2_bit('1');
      ps2_data <= '1';
      wait for 80 us;
    end procedure;

    procedure ps2_make(code : std_logic_vector(7 downto 0)) is
    begin
      ps2_byte(code);
    end procedure;

    procedure ps2_break(code : std_logic_vector(7 downto 0)) is
    begin
      ps2_byte(x"F0");
      ps2_byte(code);
    end procedure;
  begin
    reset_n <= '0';
    wait for 1 us;
    reset_n <= '1';
    wait for 100 us;

    assert col_read(4 downto 0) = "11111"
      report "joystick port 2 should idle high" severity failure;

    ps2_make(x"75");             -- keypad 8 -> up
    wait for 100 us;
    assert col_read(0) = '0'
      report "keypad 8 did not pull joystick up low" severity failure;

    ps2_make(x"74");             -- keypad 6 -> right
    wait for 100 us;
    assert col_read(3) = '0'
      report "keypad 6 did not pull joystick right low" severity failure;

    ps2_break(x"75");
    wait for 100 us;
    assert col_read(0) = '1' and col_read(3) = '0'
      report "releasing keypad 8 affected the wrong joystick bits" severity failure;

    ps2_make(x"70");             -- keypad 0 -> fire
    ps2_make(x"73");             -- keypad 5 -> fire too
    wait for 100 us;
    assert col_read(4) = '0'
      report "keypad fire did not pull joystick fire low" severity failure;

    ps2_break(x"70");
    wait for 100 us;
    assert col_read(4) = '0'
      report "fire released while the second fire key was still held" severity failure;

    ps2_break(x"73");
    ps2_break(x"74");
    wait for 100 us;
    assert col_read(4 downto 0) = "11111"
      report "joystick port 2 did not return idle high" severity failure;

    report "tb_c64_keyboard_matrix_joystick passed" severity note;
    running <= false;
    wait;
  end process;
end architecture;
