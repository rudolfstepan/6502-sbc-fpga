library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.sbc_pkg.all;

entity tb_vic_color64 is
end entity;

architecture sim of tb_vic_color64 is
  constant CLK_PERIOD : time := 10 ns;
  signal clk, reset_n : std_logic := '0';
  signal vic_addr     : addr_t;
  signal vram_data    : data_t := (others => '0');
  signal stealing, fetch_bitmap : std_logic;
  signal char_addr    : std_logic_vector(9 downto 0);
  signal hs, vs, de   : std_logic;
  signal r, b         : std_logic_vector(4 downto 0);
  signal g            : std_logic_vector(5 downto 0);
begin
  clk <= not clk after CLK_PERIOD / 2;

  -- Four packed RGB222 pixels: red, green, blue, white -> C0 C0 FF.
  process(clk)
  begin
    if rising_edge(clk) then
      case to_integer(unsigned(vic_addr)) mod 3 is
        when 0 | 1 => vram_data <= x"C0";
        when others => vram_data <= x"FF";
      end case;
    end if;
  end process;

  -- Test the Tang CEA path where RGB222 is scaled 4x to fill 720x480.
  dut : entity work.vic_vga
    generic map (CLK_DIV => 2, CURSOR_BLINK_DIV => 1000, CEA_480P => true)
    port map (
      clk => clk, reset_n => reset_n,
      vic_addr => vic_addr, vram_data => vram_data,
      vic_stealing => stealing, char_addr => char_addr, char_data => x"00",
      cursor_x => (others => '0'), cursor_y => (others => '0'),
      cursor_enable => '0', bitmap_mode => '1', color256_mode => '0',
      color64_mode => '1', vic_fetch_bitmap => fetch_bitmap,
      vga_hs => hs, vga_vs => vs, vga_de => de,
      vga_r => r, vga_g => g, vga_b => b
    );

  test : process
    variable max_addr : natural := 0;
  begin
    wait for 5 * CLK_PERIOD;
    reset_n <= '1';

    wait until rising_edge(stealing);
    while stealing = '1' loop
      wait until rising_edge(clk);
      if fetch_bitmap = '1' then
        max_addr := to_integer(unsigned(vic_addr));
      end if;
    end loop;
    assert max_addr = 134
      report "RGB222 fetch max address was " & integer'image(max_addr) severity failure;

    for line in 1 to 59 loop
      wait until falling_edge(hs);
    end loop;
    wait until rising_edge(de);       -- line 60, hc=0
    wait for 5 * CLK_PERIOD;          -- full-screen RGB222 starts at hc=0 (pixel 0)
    assert r = "11111" and g = "000000" and b = "00000"
      report "packed RGB222 pixel 0 (red) mismatch" severity failure;
    wait for 8 * CLK_PERIOD;          -- 4x scale: each RGB222 pixel is 4 hc wide
    assert r = "00000" and g = "111111" and b = "00000"
      report "packed RGB222 pixel 1 (green) mismatch" severity failure;
    wait for 8 * CLK_PERIOD;
    assert r = "00000" and g = "000000" and b = "11111"
      report "packed RGB222 pixel 2 (blue) mismatch" severity failure;
    wait for 8 * CLK_PERIOD;
    assert r = "11111" and g = "111111" and b = "11111"
      report "packed RGB222 pixel 3 (white) mismatch" severity failure;

    report "tb_vic_color64 passed" severity note;
    finish;
  end process;
end architecture;
