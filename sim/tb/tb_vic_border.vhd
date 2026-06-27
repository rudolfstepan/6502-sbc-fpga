-- Verifies the VIC-II $D020 border colour path: in text mode the area outside
-- the 40x25 character matrix (here: the top border line, vc=0) must render the
-- selected palette colour. border_color = 2 -> C64 red (PAL index 2).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.sbc_pkg.all;

entity tb_vic_border is
end entity;

architecture sim of tb_vic_border is
  constant CLK_PERIOD : time := 10 ns;
  signal clk     : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal vic_addr : addr_t;
  signal vic_stealing, fetch_bitmap : std_logic;
  signal char_addr : std_logic_vector(9 downto 0);
  signal hs, vs, de : std_logic;
  signal r, b : std_logic_vector(4 downto 0);
  signal g    : std_logic_vector(5 downto 0);
begin
  clk <= not clk after CLK_PERIOD / 2;

  -- Use the real Tang config (CEA_480P=true): there the color64 geometry spans
  -- the whole screen, which previously suppressed the border everywhere.
  dut : entity work.vic_vga
    generic map (CLK_DIV => 1, CEA_480P => true, CURSOR_BLINK_DIV => 1000)
    port map (
      clk => clk, reset_n => reset_n,
      vic_addr => vic_addr, vram_data => x"00",
      vic_stealing => vic_stealing,
      char_addr => char_addr, char_data => x"00",
      cursor_x => (others => '0'), cursor_y => (others => '0'),
      cursor_enable => '0',
      bitmap_mode => '0',                 -- text mode
      border_color => "0010",             -- C64 red
      vic_fetch_bitmap => fetch_bitmap,
      vga_hs => hs, vga_vs => vs, vga_de => de,
      vga_r => r, vga_g => g, vga_b => b
    );

  test : process
  begin
    wait for 5 * CLK_PERIOD;
    reset_n <= '1';

    -- The very first active line (vc=0) is entirely above the text region
    -- (V_BORD=40), so it is pure border. Sample at data-enable.
    wait until rising_edge(de);
    wait for CLK_PERIOD;
    assert r = "10001" and g = "001110" and b = "00110"
      report "border colour wrong: got r=" & integer'image(to_integer(unsigned(r)))
           & " g=" & integer'image(to_integer(unsigned(g)))
           & " b=" & integer'image(to_integer(unsigned(b))) severity failure;

    report "tb_vic_border passed" severity note;
    finish;
  end process;
end architecture;
