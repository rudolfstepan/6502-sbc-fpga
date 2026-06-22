library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.sbc_pkg.all;

entity tb_vic_color256 is
end entity;

architecture sim of tb_vic_color256 is
  constant CLK_PERIOD : time := 10 ns;
  signal clk          : std_logic := '0';
  signal reset_n      : std_logic := '0';
  signal vic_addr     : addr_t;
  signal vic_stealing : std_logic;
  signal fetch_bitmap : std_logic;
  signal char_addr    : std_logic_vector(9 downto 0);
  signal hs, vs, de   : std_logic;
  signal r, b         : std_logic_vector(4 downto 0);
  signal g            : std_logic_vector(5 downto 0);
begin
  clk <= not clk after CLK_PERIOD / 2;

  dut : entity work.vic_vga
    generic map (CLK_DIV => 2, CURSOR_BLINK_DIV => 1000)
    port map (
      clk => clk, reset_n => reset_n,
      vic_addr => vic_addr, vram_data => x"E3",
      vic_stealing => vic_stealing,
      char_addr => char_addr, char_data => x"00",
      cursor_x => (others => '0'), cursor_y => (others => '0'),
      cursor_enable => '0', bitmap_mode => '1', color256_mode => '1',
      vic_fetch_bitmap => fetch_bitmap,
      vga_hs => hs, vga_vs => vs, vga_de => de,
      vga_r => r, vga_g => g, vga_b => b
    );

  test : process
    variable max_addr : natural := 0;
    variable cycles   : natural := 0;
  begin
    wait for 5 * CLK_PERIOD;
    reset_n <= '1';

    wait until rising_edge(vic_stealing);
    while vic_stealing = '1' loop
      wait until rising_edge(clk);
      if fetch_bitmap = '1' then
        max_addr := natural(to_integer(unsigned(vic_addr)));
      end if;
      cycles := cycles + 1;
    end loop;
    assert max_addr = 159
      report "RGB332 fetch did not cover all 160 pixels" severity failure;
    assert cycles >= 160
      report "RGB332 fetch ended too early" severity failure;

    -- The first visible graphics line is VGA line 40. Constant framebuffer
    -- value $E3 (RGB332 111/000/11) must expand to RGB565 magenta.
    for line in 1 to 39 loop
      wait until falling_edge(hs);
    end loop;
    wait until rising_edge(de);
    wait for CLK_PERIOD;
    assert r = "11111" and g = "000000" and b = "11111"
      report "RGB332-to-RGB565 expansion mismatch" severity failure;

    report "tb_vic_color256 passed" severity note;
    finish;
  end process;
end architecture;
