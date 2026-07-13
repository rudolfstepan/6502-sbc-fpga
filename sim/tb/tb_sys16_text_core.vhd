-- Testbench for sys16_text_core: drives the pixel clock directly (no PLL),
-- writes a known glyph into a cell, and samples pixel_data at exact beam
-- coordinates to prove the character renders pixel-accurately (font ROM +
-- char RAM + scanout pipeline alignment), plus the register read path.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_sys16_text_core is
end entity;

architecture sim of tb_sys16_text_core is
  signal clk_in    : std_logic := '0';
  signal clk_pix   : std_logic := '0';
  signal done      : boolean := false;

  signal reset_n   : std_logic := '0';
  signal reset_pix : std_logic := '1';
  signal req, we   : std_logic := '0';
  signal addr      : std_logic_vector(23 downto 0) := (others => '0');
  signal be        : std_logic_vector(3 downto 0) := (others => '0');
  signal wdata     : std_logic_vector(31 downto 0) := (others => '0');
  signal rdata     : std_logic_vector(31 downto 0);
  signal ready     : std_logic;
  signal status_word : std_logic_vector(15 downto 0) := (others => '0');
  signal de, hsync, vsync : std_logic;
  signal pixel_data : std_logic_vector(23 downto 0);
  signal dbg_x     : std_logic_vector(10 downto 0);
  signal dbg_y     : std_logic_vector(9 downto 0);

  signal errors    : natural := 0;

  constant WHITE : std_logic_vector(23 downto 0) := x"FFFFFF";
  constant BLACK : std_logic_vector(23 downto 0) := x"000000";
begin
  clk_in  <= not clk_in  after 10 ns   when not done else '0';
  -- Accelerated pixel clock: scanout is cycle based, so this keeps the
  -- full 1680x831-frame test quick without changing any video coordinates.
  clk_pix <= not clk_pix after 1 ns when not done else '0';

  dut : entity work.sys16_text_core
    port map (
      clk_in => clk_in, reset_n => reset_n,
      req => req, we => we, addr => addr, be => be, wdata => wdata,
      rdata => rdata, ready => ready, status_word => status_word,
      clk_pix => clk_pix, reset_pix => reset_pix,
      de => de, hsync => hsync, vsync => vsync, pixel_data => pixel_data,
      dbg_x => dbg_x, dbg_y => dbg_y);

  stim : process
    procedure bus_write(a : std_logic_vector(23 downto 0);
                        d : std_logic_vector(31 downto 0);
                        ben : std_logic_vector(3 downto 0)) is
    begin
      wait until rising_edge(clk_in);
      addr <= a; wdata <= d; be <= ben; we <= '1'; req <= '1';
      loop wait until rising_edge(clk_in); exit when ready = '1'; end loop;
      req <= '0'; we <= '0';
      wait until rising_edge(clk_in);
    end procedure;

    procedure bus_read(a : std_logic_vector(23 downto 0);
                       got : out std_logic_vector(31 downto 0)) is
    begin
      wait until rising_edge(clk_in);
      addr <= a; we <= '0'; req <= '1';
      loop wait until rising_edge(clk_in); exit when ready = '1'; end loop;
      got := rdata;
      req <= '0';
      wait until rising_edge(clk_in);
    end procedure;

    procedure sample(px, py : integer; expect : std_logic_vector(23 downto 0);
                     name : string) is
    begin
      loop
        wait until rising_edge(clk_pix);
        if to_integer(unsigned(dbg_x)) = px and
           to_integer(unsigned(dbg_y)) = py then
          wait for 1 ns;
          if pixel_data /= expect then
            report name & " @(" & integer'image(px) & "," & integer'image(py) &
              "): got " & integer'image(to_integer(unsigned(pixel_data))) &
              " expected " & integer'image(to_integer(unsigned(expect)))
              severity error;
            errors <= errors + 1; wait for 0 ns;
          end if;
          exit;
        end if;
      end loop;
    end procedure;

    variable r : std_logic_vector(31 downto 0);
  begin
    wait for 60 ns;
    reset_n <= '1';
    wait for 40 ns;
    reset_pix <= '0';

    -- ID / geometry register readback
    bus_read(x"800000", r);
    assert r = x"53313654" report "ID mismatch" severity error;
    bus_read(x"800010", r);   -- GEOM: cell_h,cell_w,rows,cols
    assert r(7 downto 0) = x"50" report "GEOM cols/=80" severity error;    -- 80
    assert r(15 downto 8) = x"19" report "GEOM rows/=25" severity error;   -- 25
    assert r(23 downto 16) = x"10" report "GEOM cell width/=16" severity error;
    assert r(31 downto 24) = x"1C" report "GEOM cell height/=28" severity error;

    -- cursor register write + readback
    bus_write(x"80000C", x"0001040A", "1111");   -- en=1,row=4,col=10
    bus_read(x"80000C", r);
    assert r(6 downto 0) = "0001010" report "cursor col" severity error;   -- 10
    assert r(12 downto 8) = "00100" report "cursor row" severity error;    -- 4
    assert r(16) = '1' report "cursor en" severity error;

    -- write 'A' (0x41) white-on-black into cell (0,0): low half of word 0.
    -- 16-bit store to byte offset 0 -> be=0011, wdata[15:0] = attr&char.
    bus_write(x"000000", x"00000F41", "0011");
    -- 'A' into cell (3,5) = cell index 245 (odd -> high half), byte offset
    -- 490 = 0x1EA, word 122, be=1100. Exercises the row/col address multiply.
    bus_write(x"0001EA", x"0F410000", "1100");
    -- 'A' into the first cell of the 25th row. This is word 960 of the
    -- 1000-word character RAM and verifies the enlarged geometry.
    bus_write(x"000F00", x"00000F41", "0011");
    -- CTRL: enable on, test pattern OFF, stripe OFF
    bus_write(x"800004", x"00000001", "0001");

    -- let a couple of pixel-clock cycles cross the CDC
    for i in 0 to 20 loop wait until rising_edge(clk_pix); end loop;

    -- Sample the glyph. 'A' 8x16 (bit7=leftmost):
    --   row0=00 row2=10 row7=FE; cell(0,0) is x=0..15,y=10..37.
    --   Vertical glyph rows are stretched from 16 to 28 scanlines.
    sample(0,  0, BLACK, "top border");                  -- y<10 border
    sample(0, 10, BLACK, "A r0c0");                      -- row0 blank
    sample(0, 14, BLACK, "A r2c0");                      -- row2 bit7=0
    sample(6, 14, WHITE, "A r2c3");                      -- row2 0x10 bit4=1
    sample(0, 23, WHITE, "A r7c0");                      -- row7 0xFE bit7=1
    sample(14,23, BLACK, "A r7c7");                      -- row7 0xFE bit0=0
    sample(16,23, BLACK, "cell(0,1) blank");             -- neighbour cell empty
    -- 'A' at cell (3,5): content window x=80..95, y=94..121.
    sample(80,  94, BLACK, "cell(3,5) A r0c0");          -- row0 blank
    sample(86,  98, WHITE, "cell(3,5) A r2c3");          -- row2 0x10 bit4=1
    sample(80, 107, WHITE, "cell(3,5) A r7c0");          -- row7 0xFE bit7=1
    sample(64, 107, BLACK, "cell(3,4) blank");           -- neighbour col empty
    -- First cell of row 24 occupies y=682..709, proving all 25 rows scan.
    sample(6, 686, WHITE, "cell(24,0) A r2c3");

    if errors = 0 then report "TB PASSED" severity note;
    else report "TB FAILED, " & integer'image(errors) & " errors" severity error;
    end if;
    done <= true;
    wait;
  end process;
end architecture;
