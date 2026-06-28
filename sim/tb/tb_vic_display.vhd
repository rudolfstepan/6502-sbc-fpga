-- VIC-II display testbench: checks the ACTUAL rendered pixels (not just screen
-- RAM). Feeds the VIC a known screen ("HELLO" on row 0) via models of the screen
-- RAM / colour RAM / CHARGEN, sets border+background to black and foreground to
-- white, then dumps one text scanline as '#'/'.' so a glyph misrender or pipeline
-- misalignment is visible directly.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_vic_display is
end entity;

architecture sim of tb_vic_display is
  signal clk     : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal running : boolean := true;

  signal cs, we  : std_logic := '0';
  signal addr    : std_logic_vector(5 downto 0) := (others => '0');
  signal din     : std_logic_vector(7 downto 0) := (others => '0');
  signal dout    : std_logic_vector(7 downto 0);
  signal irq_n   : std_logic;

  signal vic_addr : std_logic_vector(15 downto 0);
  signal vic_data : std_logic_vector(7 downto 0);
  signal ba       : std_logic;
  signal col_addr : std_logic_vector(9 downto 0);
  signal col_data : std_logic_vector(3 downto 0);
  signal char_addr: std_logic_vector(11 downto 0);
  signal char_data: std_logic_vector(7 downto 0);

  signal vga_hs, vga_vs, vga_de : std_logic;
  signal vga_r, vga_b : std_logic_vector(4 downto 0);
  signal vga_g        : std_logic_vector(5 downto 0);

  -- "HELLO" screen codes: H=8 E=5 L=12 L=12 O=15
  type srow_t is array (0 to 39) of integer;
  constant ROW0 : srow_t := (8,5,12,12,15, others => 32);

  constant TARGET_VC : integer := 44;   -- inside row 0's glyph band (40..55)
  type line_t is array (0 to 759) of character;
  signal vline : line_t := (others => ' ');
  signal captured : boolean := false;
begin
  dut : entity work.vic_ii
    port map (
      clk => clk, reset_n => reset_n,
      cs => cs, we => we, addr => addr, din => din, dout => dout, irq_n => irq_n,
      vic_addr => vic_addr, vic_data => vic_data, ba => ba,
      vic_bank => "00",
      color_addr => col_addr, color_data => col_data,
      char_addr => char_addr, char_data => char_data,
      vga_hs => vga_hs, vga_vs => vga_vs, vga_de => vga_de,
      vga_r => vga_r, vga_g => vga_g, vga_b => vga_b
    );

  -- real CHARGEN for char_data
  chargen : entity work.chargen_rom
    port map (clk => clk, a_addr => (others=>'0'), a_dout => open,
              b_addr => char_addr, b_dout => char_data);

  -- screen RAM model: $0400 + row*40 + col -> ROW0 for row 0, else space.
  scr_p : process(clk)
    variable a : integer;
    variable off : integer;
  begin
    if rising_edge(clk) then
      a := to_integer(unsigned(vic_addr));
      off := a - 16#0400#;
      if off >= 0 and off < 40 then
        vic_data <= std_logic_vector(to_unsigned(ROW0(off), 8));
      else
        vic_data <= std_logic_vector(to_unsigned(32, 8));  -- space
      end if;
    end if;
  end process;

  -- colour RAM model: white (1) everywhere.
  col_p : process(clk)
  begin
    if rising_edge(clk) then
      col_data <= "0001";
    end if;
  end process;

  clk_p : process
  begin
    while running loop clk <= '0'; wait for 5 ns; clk <= '1'; wait for 5 ns; end loop;
    wait;
  end process;

  -- reset, then set border ($D020) and background ($D021) to black for contrast.
  stim : process
  begin
    reset_n <= '0';
    for i in 1 to 10 loop wait until rising_edge(clk); end loop;
    reset_n <= '1';
    wait until rising_edge(clk);
    cs <= '1'; we <= '1'; addr <= "100000"; din <= x"00";  -- $D020 border=black
    wait until rising_edge(clk);
    addr <= "100001"; din <= x"00";                        -- $D021 bg=black
    wait until rising_edge(clk);
    cs <= '0'; we <= '0';
    wait;
  end process;

  -- Reconstruct the visible line index from de/vs edges and capture one scanline.
  -- vs-falling resets the line counter; each de-rising edge is the next visible
  -- line (vc=0,1,2,...). Within a line, pixel index = clocks since de-rising.
  mon : process(clk)
    variable line_cnt : integer := -1;
    variable pix      : integer := 0;
    variable prev_de  : std_logic := '0';
    variable prev_vs  : std_logic := '1';
    variable l        : line;
  begin
    if rising_edge(clk) and reset_n = '1' then
      if vga_vs = '0' and prev_vs = '1' then line_cnt := -1; end if;
      if vga_de = '1' and prev_de = '0' then line_cnt := line_cnt + 1; pix := 0; end if;

      if vga_de = '1' then
        if line_cnt = TARGET_VC and pix < 760 then
          if vga_r(4) = '1' or vga_g(5) = '1' or vga_b(4) = '1' then
            vline(pix) <= '#';
          else
            vline(pix) <= '.';
          end if;
        end if;
        pix := pix + 1;
      end if;

      if line_cnt = TARGET_VC + 1 and not captured then
        captured <= true;
        write(l, string'("visible line ")); write(l, TARGET_VC);
        write(l, string'(" (expect HELLO glyphs at the left of the content area):"));
        writeline(output, l);
        for i in 0 to 759 loop write(l, vline(i)); end loop;
        writeline(output, l);
        running <= false;
      end if;

      prev_de := vga_de;
      prev_vs := vga_vs;
    end if;
  end process;
end architecture;
