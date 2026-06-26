-- Testbench for the 320x240 4bpp / 16-colour palette VIC mode (color16_mode).
-- Drives a constant framebuffer byte $21 via vram_data: low nibble = 1 (white),
-- high nibble = 2 (red). Verifies (a) a line fetch covers all 160 bytes, and
-- (b) a visible line shows BOTH palette colours (low nibble -> white on even
-- logical pixels, high nibble -> red on odd ones), proving the nibble unpack and
-- palette lookup.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.sbc_pkg.all;

entity tb_vic_color16 is
end entity;

architecture sim of tb_vic_color16 is
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
      vic_addr => vic_addr, vram_data => x"21",
      vic_stealing => vic_stealing,
      char_addr => char_addr, char_data => x"00",
      cursor_x => (others => '0'), cursor_y => (others => '0'),
      cursor_enable => '0', bitmap_mode => '1', color16_mode => '1',
      vic_fetch_bitmap => fetch_bitmap,
      vga_hs => hs, vga_vs => vs, vga_de => de,
      vga_r => r, vga_g => g, vga_b => b
    );

  test : process
    variable max_addr   : natural := 0;
    variable white_seen : boolean := false;
    variable red_seen   : boolean := false;
  begin
    wait for 5 * CLK_PERIOD;
    reset_n <= '1';

    -- (a) the first line fetch must read all 160 framebuffer bytes (0..159).
    wait until rising_edge(vic_stealing);
    while vic_stealing = '1' loop
      wait until rising_edge(clk);
      if fetch_bitmap = '1' then
        max_addr := natural(to_integer(unsigned(vic_addr)));
      end if;
    end loop;
    assert max_addr = 159
      report "color16 fetch did not cover all 160 bytes/line" severity failure;

    -- (b) prime one full frame, then sample a mid-screen visible line. Its
    -- linebuf was filled with $21 during the previous H-blank.
    wait until falling_edge(vs);
    wait until rising_edge(vs);
    for i in 1 to 60 loop
      wait until falling_edge(hs);
    end loop;
    wait until rising_edge(de);
    while de = '1' loop
      wait until rising_edge(clk);
      if r = "11111" and g = "111111" and b = "11111" then
        white_seen := true;                       -- palette index 1 (low nibble)
      end if;
      if r = "10001" and g = "001110" and b = "00110" then
        red_seen := true;                         -- palette index 2 (high nibble)
      end if;
    end loop;
    assert white_seen
      report "color16: low-nibble pixel (white, index 1) not displayed" severity failure;
    assert red_seen
      report "color16: high-nibble pixel (red, index 2) not displayed" severity failure;

    report "tb_vic_color16 passed" severity note;
    finish;
  end process;
end architecture;
