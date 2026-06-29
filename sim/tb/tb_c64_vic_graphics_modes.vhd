-- Native C64 VIC-II graphics-mode smoke test.
--
-- Exercises the new bitmap renderer through the real VIC register interface:
--   * BMM=1, MCM=0: hires bitmap uses screen-RAM nibbles as fg/bg.
--   * BMM=1, MCM=1: multicolour bitmap maps bit-pairs to bg/screen/colour RAM.
--   * BMM=0, custom RAM charset selected through $D018.
--   * Sprite pointer fetch + hires/multicolour sprite overlay.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_c64_vic_graphics_modes is
end entity;

architecture sim of tb_c64_vic_graphics_modes is
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

  signal test_mode : natural range 0 to 4 := 0;
  signal hi_red, hi_white, mc_green, mc_black, ram_white, ram_black : boolean := false;
  signal spr_red, spr_mc_green : boolean := false;

  constant TARGET_VC : integer := 44;  -- visible row 0, glyph/bitmap line 2
  constant H_PILL    : integer := 40;
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

  clk_p : process
  begin
    while running loop
      clk <= '0'; wait for 5 ns;
      clk <= '1'; wait for 5 ns;
    end loop;
    wait;
  end process;

  -- Synchronous RAM model. Bitmap base is $0000, screen matrix is $0400.
  ram_p : process(clk)
    variable a : integer;
  begin
    if rising_edge(clk) then
      a := to_integer(unsigned(vic_addr));
      if (test_mode = 3 or test_mode = 4) and a = 16#07F8# then
        vic_data <= x"20";  -- sprite 0 pointer -> $0800
      elsif (test_mode = 3 or test_mode = 4) and
            a >= 16#0800# and a < 16#0840# and ((a - 16#0800#) mod 3) = 0 then
        if test_mode = 3 then
          vic_data <= x"80";  -- hires sprite first pixel set
        else
          vic_data <= x"40";  -- multicolour sprite first pair = 01
        end if;
      elsif a >= 16#0000# and a < 16#0140# and (a mod 40) = 0 then
        if test_mode = 0 then
          vic_data <= x"80";  -- first hires bitmap pixel set, rest clear
        else
          vic_data <= x"C0";  -- first multicolour pair = 11, then 00
        end if;
      elsif test_mode = 2 and a = 16#0400# then
        vic_data <= x"01";  -- screen code 1, glyph comes from RAM charset $2000
      elsif test_mode = 2 and a >= 16#2008# and a < 16#2010# then
        vic_data <= x"80";  -- RAM charset: first hires text pixel set
      elsif a = 16#0400# then
        if test_mode = 0 then
          vic_data <= x"21";  -- hires fg=red, bg=white
        else
          vic_data <= x"12";  -- multicolour screen colours white/red
        end if;
      else
        vic_data <= x"00";
      end if;
    end if;
  end process;

  -- Colour RAM is only used by multicolour bitmap pair 11.
  color_p : process(clk)
  begin
    if rising_edge(clk) then
      if test_mode = 1 then
        col_data <= x"5";    -- green
      else
        col_data <= x"1";
      end if;
    end if;
  end process;

  -- Bitmap tests do not consume CHARGEN, but keep the port synchronous.
  char_p : process(clk)
  begin
    if rising_edge(clk) then
      char_data <= x"00";
    end if;
  end process;

  stim : process
    procedure write_reg(
      constant a : in std_logic_vector(5 downto 0);
      constant d : in std_logic_vector(7 downto 0)
    ) is
    begin
      wait until rising_edge(clk);
      cs <= '1'; we <= '1'; addr <= a; din <= d;
      wait until rising_edge(clk);
      cs <= '0'; we <= '0';
    end procedure;
  begin
    reset_n <= '0';
    for i in 1 to 10 loop wait until rising_edge(clk); end loop;
    reset_n <= '1';

    -- Hires bitmap: BMM=1, MCM=0, screen $0400, bitmap $0000.
    test_mode <= 0;
    write_reg("100000", x"00");  -- $D020 border black
    write_reg("100001", x"00");  -- $D021 background black
    write_reg("011000", x"15");  -- $D018 screen=$0400, bitmap=$0000
    write_reg("010110", x"08");  -- $D016 MCM=0
    write_reg("010001", x"3B");  -- $D011 DEN/RSEL + BMM
    wait for 25 ms;
    assert hi_red report "hires bitmap did not render screen high-nibble colour" severity failure;
    assert hi_white report "hires bitmap did not render screen low-nibble colour" severity failure;

    -- Multicolour bitmap: pair 11 must use colour RAM, pair 00 background.
    test_mode <= 1;
    write_reg("010110", x"18");  -- $D016 MCM=1, CSEL=1
    wait for 25 ms;
    assert mc_green report "multicolour bitmap did not render colour RAM colour" severity failure;
    assert mc_black report "multicolour bitmap did not render background colour" severity failure;

    -- Text mode with custom charset in RAM at $2000. This is the path used by
    -- many games for tile graphics (for example Boulder Dash-style screens).
    test_mode <= 2;
    write_reg("100000", x"00");  -- $D020 border black
    write_reg("100001", x"00");  -- $D021 background black
    write_reg("011000", x"18");  -- $D018 screen=$0400, char=$2000
    write_reg("010110", x"08");  -- $D016 MCM=0
    write_reg("010001", x"1B");  -- $D011 text mode, DEN=1
    wait for 25 ms;
    assert ram_white report "RAM charset text did not render foreground pixel" severity failure;
    assert ram_black report "RAM charset text did not render background pixel" severity failure;

    -- Hires sprite 0: screen=$0400, pointer at $07F8 -> $0800, X/Y biased to
    -- the first visible text pixel of the test scanline.
    test_mode <= 3;
    write_reg("000000", x"18");  -- $D000 sprite 0 X = 24
    write_reg("000001", x"34");  -- $D001 sprite 0 Y = 52
    write_reg("010000", x"00");  -- $D010 X MSB clear
    write_reg("010101", x"01");  -- $D015 enable sprite 0
    write_reg("011100", x"00");  -- $D01C hires sprite
    write_reg("100111", x"02");  -- $D027 sprite 0 colour red
    wait for 25 ms;
    assert spr_red report "hires sprite did not render over text/background" severity failure;

    -- Multicolour sprite 0: pair 01 must use $D025.
    test_mode <= 4;
    write_reg("011100", x"01");  -- $D01C sprite 0 multicolour
    write_reg("100101", x"05");  -- $D025 sprite multicolour 0 = green
    wait for 25 ms;
    assert spr_mc_green report "multicolour sprite did not render shared colour 0" severity failure;

    report "tb_c64_vic_graphics_modes passed" severity note;
    running <= false;
    wait;
  end process;

  mon : process(clk)
    variable line_cnt : integer := -1;
    variable pix      : integer := 0;
    variable prev_de  : std_logic := '0';
    variable prev_vs  : std_logic := '1';
  begin
    if rising_edge(clk) and reset_n = '1' then
      if vga_vs = '0' and prev_vs = '1' then
        line_cnt := -1;
      end if;
      if vga_de = '1' and prev_de = '0' then
        line_cnt := line_cnt + 1;
        pix := 0;
      end if;

      if vga_de = '1' then
        if line_cnt = TARGET_VC and pix >= H_PILL and pix < H_PILL + 20 then
          case test_mode is
          when 0 =>
            if vga_r = "10001" and vga_g = "001110" and vga_b = "00110" then
              hi_red <= true;
            end if;
            if vga_r = "11111" and vga_g = "111111" and vga_b = "11111" then
              hi_white <= true;
            end if;
          when 1 =>
            if vga_r = "01011" and vga_g = "101000" and vga_b = "01001" then
              mc_green <= true;
            end if;
            if vga_r = "00000" and vga_g = "000000" and vga_b = "00000" then
              mc_black <= true;
            end if;
          when 2 =>
            if vga_r = "11111" and vga_g = "111111" and vga_b = "11111" then
              ram_white <= true;
            end if;
            if vga_r = "00000" and vga_g = "000000" and vga_b = "00000" then
              ram_black <= true;
            end if;
          when 3 =>
            if vga_r = "10001" and vga_g = "001110" and vga_b = "00110" then
              spr_red <= true;
            end if;
          when others =>
            if vga_r = "01011" and vga_g = "101000" and vga_b = "01001" then
              spr_mc_green <= true;
            end if;
          end case;
        end if;
        pix := pix + 1;
      end if;

      prev_de := vga_de;
      prev_vs := vga_vs;
    end if;
  end process;
end architecture;
