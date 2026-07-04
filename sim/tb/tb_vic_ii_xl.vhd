-- Smoke test for the cycle-based vic_ii_xl.
--
-- Checks the behaviours that distinguish it from the line-buffer vic_ii:
--   * raster IRQ fires at the programmed compare line, $D012 reads it back,
--     $D019 write-acks it
--   * badline BA cadence: ~25 badlines x ~43 stalled cycles per frame with
--     DEN=1, zero with DEN=0
--   * DEN=0 shows border colour over the whole visible frame (vertical border
--     flip-flop never clears)
--   * sprite DMA + display: an enabled sprite paints its colour, collides with
--     text foreground ($D01F latches, reads clear)
--   * register read-back masks (unused bits read as 1)
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_vic_ii_xl is
end entity;

architecture sim of tb_vic_ii_xl is
  signal clk     : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal running : boolean := true;

  signal phi2_cnt : natural range 0 to 26 := 0;
  signal phi2_en  : std_logic := '0';

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

  -- monitors
  signal red_seen      : boolean := false;  -- sprite colour 2 spotted
  signal nonborder_seen: boolean := false;  -- anything not colour 14 while DE
  signal mon_red_en    : boolean := false;
  signal mon_border_en : boolean := false;

  -- Pepto palette entries used by the checks (must match vic_ii_xl)
  constant RED_R : std_logic_vector(4 downto 0) := "10001";
  constant RED_G : std_logic_vector(5 downto 0) := "001110";
  constant RED_B : std_logic_vector(4 downto 0) := "00110";
  constant LBL_R : std_logic_vector(4 downto 0) := "01111";
  constant LBL_G : std_logic_vector(5 downto 0) := "011010";
  constant LBL_B : std_logic_vector(4 downto 0) := "11001";
begin
  dut : entity work.vic_ii_xl
    port map (
      clk => clk, reset_n => reset_n, phi2_en => phi2_en,
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

  -- PHI2 tick, generated exactly like c64_core (same reset, div 27).
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        phi2_cnt <= 0; phi2_en <= '0';
      elsif phi2_cnt = 26 then
        phi2_cnt <= 0; phi2_en <= '1';
      else
        phi2_cnt <= phi2_cnt + 1; phi2_en <= '0';
      end if;
    end if;
  end process;

  -- Main RAM model (registered read, like c64_ram_dp port B).
  --   $0400..$07E7 : screen codes $01
  --   $07F8        : sprite 0 pointer $80 -> data at $2000
  --   $2000..$203F : sprite data $FF (solid block)
  ram_p : process(clk)
    variable a : integer;
  begin
    if rising_edge(clk) then
      a := to_integer(unsigned(vic_addr));
      if a = 16#07F8# then
        vic_data <= x"80";
      elsif a >= 16#2000# and a < 16#2040# then
        vic_data <= x"FF";
      elsif a >= 16#0400# and a < 16#07E8# then
        vic_data <= x"01";
      else
        vic_data <= x"00";
      end if;
    end if;
  end process;

  color_p : process(clk)
  begin
    if rising_edge(clk) then
      col_data <= x"5";
    end if;
  end process;

  -- Character ROM model: every glyph row = $AA (alternating fg pixels).
  char_p : process(clk)
  begin
    if rising_edge(clk) then
      char_data <= x"AA";
    end if;
  end process;

  -- Pixel monitors.
  mon_p : process(clk)
  begin
    if rising_edge(clk) then
      if vga_de = '1' then
        if mon_red_en and vga_r = RED_R and vga_g = RED_G and vga_b = RED_B then
          red_seen <= true;
        end if;
        if mon_border_en and
           not (vga_r = LBL_R and vga_g = LBL_G and vga_b = LBL_B) then
          nonborder_seen <= true;
        end if;
      end if;
    end if;
  end process;

  stim_p : process
    variable rdval : std_logic_vector(7 downto 0);
    variable ba_cnt : natural;
    variable vs_prev : std_logic;

    procedure wr(a : in std_logic_vector(5 downto 0);
                 d : in std_logic_vector(7 downto 0)) is
    begin
      wait until rising_edge(clk);
      cs <= '1'; we <= '1'; addr <= a; din <= d;
      wait until rising_edge(clk);
      cs <= '0'; we <= '0';
    end procedure;

    procedure rd(a : in std_logic_vector(5 downto 0);
                 d : out std_logic_vector(7 downto 0)) is
    begin
      wait until rising_edge(clk);
      cs <= '1'; we <= '0'; addr <= a;
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      d := dout;
      cs <= '0';
      wait until rising_edge(clk);
    end procedure;
  begin
    -- reset
    reset_n <= '0';
    for i in 0 to 9 loop wait until rising_edge(clk); end loop;
    reset_n <= '1';

    -- let DEN latch + a full frame settle
    wait until falling_edge(vga_vs);
    wait until falling_edge(vga_vs);

    -- ---------- register read-back masks ----------
    wr("010110", x"00");                    -- $D016 = 0
    rd("010110", rdval);
    assert rdval = x"C0"
      report "D016 readback mask wrong" severity error;
    wr("010110", x"08");                    -- restore CSEL
    rd("011000", rdval);                    -- $D018 default $15 -> bit0 reads 1
    assert rdval = x"15"
      report "D018 readback wrong" severity error;
    -- After reset raster_cmp=0 matched raster 0 -> the raster latch is set
    -- (real chip behaves the same); ack it before checking the idle value.
    wr("011001", x"0F");
    rd("011001", rdval);                    -- $D019 idle = $70
    assert rdval = x"70"
      report "D019 idle readback wrong" severity error;

    -- ---------- raster IRQ ----------
    wr("010010", std_logic_vector(to_unsigned(150, 8)));  -- $D012 = 150
    wr("010001", x"1B");                                  -- $D011 bit7 = 0
    wr("011001", x"0F");                                  -- ack stale latch
    wr("011010", x"01");                                  -- enable raster IRQ
    wait until irq_n = '0' for 30 ms;
    assert irq_n = '0' report "raster IRQ did not fire" severity failure;
    rd("010010", rdval);
    assert to_integer(unsigned(rdval)) = 150
      report "raster IRQ fired on wrong line: " &
             integer'image(to_integer(unsigned(rdval))) severity error;
    rd("011001", rdval);                                  -- $D019: raster + IRQ
    assert rdval(7) = '1' and rdval(0) = '1'
      report "D019 should show pending raster IRQ" severity error;
    wr("011001", x"0F");                                  -- ack
    for i in 0 to 4 loop wait until rising_edge(clk); end loop;
    assert irq_n = '1' report "raster IRQ ack failed" severity error;
    wr("011010", x"00");                                  -- disable IRQs

    -- ---------- badline BA cadence (DEN=1, no sprites) ----------
    wait until falling_edge(vga_vs);
    ba_cnt := 0;
    vs_prev := '0';
    loop
      wait until rising_edge(clk);
      if phi2_en = '1' and ba = '0' then
        ba_cnt := ba_cnt + 1;
      end if;
      exit when vs_prev = '1' and vga_vs = '0';   -- next frame's vsync start
      vs_prev := vga_vs;
    end loop;
    report "badline BA cycles per frame: " & integer'image(ba_cnt);
    assert ba_cnt >= 25 * 40 and ba_cnt <= 25 * 46
      report "unexpected badline BA count: " & integer'image(ba_cnt)
      severity error;

    -- ---------- sprite display + sprite/background collision ----------
    wr("000000", std_logic_vector(to_unsigned(100, 8)));  -- sprite 0 X
    wr("000001", std_logic_vector(to_unsigned(100, 8)));  -- sprite 0 Y
    wr("100111", x"02");                                  -- sprite 0 colour red
    wr("010101", x"01");                                  -- sprite 0 enable
    rd("011111", rdval);                                  -- clear stale $D01F
    mon_red_en <= true;
    wait until falling_edge(vga_vs);
    wait until falling_edge(vga_vs);
    wait until falling_edge(vga_vs);
    mon_red_en <= false;
    assert red_seen report "sprite pixels never displayed" severity error;
    rd("011111", rdval);                                  -- $D01F
    assert rdval(0) = '1'
      report "sprite/background collision not latched" severity error;
    rd("011111", rdval);                                  -- read cleared it
    assert rdval = x"00"
      report "D01F read-clear failed" severity error;

    -- ---------- DEN=0: full border, no badlines ----------
    wr("010101", x"00");                                  -- sprites off
    wr("010001", x"0B");                                  -- DEN=0
    wait until falling_edge(vga_vs);
    wait until falling_edge(vga_vs);
    mon_border_en <= true;
    ba_cnt := 0;
    vs_prev := '0';
    loop
      wait until rising_edge(clk);
      if phi2_en = '1' and ba = '0' then
        ba_cnt := ba_cnt + 1;
      end if;
      exit when vs_prev = '1' and vga_vs = '0';   -- next frame's vsync start
      vs_prev := vga_vs;
    end loop;
    mon_border_en <= false;
    assert ba_cnt = 0
      report "DEN=0 must produce no badlines, got " & integer'image(ba_cnt)
      severity error;
    for i in 0 to 9 loop wait until rising_edge(clk); end loop;
    assert not nonborder_seen
      report "DEN=0 frame contained non-border pixels" severity error;

    report "tb_vic_ii_xl PASSED" severity note;
    running <= false;
    wait;
  end process;
end architecture;
