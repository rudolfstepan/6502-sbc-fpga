-- MOS 6569 VIC-II -- native C64 video, Milestone 1 scope (standard text mode).
--
-- Reuses the proven Tang Primer 20K display pipeline from rtl/core/peripherals/
-- vic_vga: exact CEA-861 720x480p timing (27 MHz pixel, 858x525 total, the
-- 640-wide content pillarboxed into 720) so the existing tang20k_hdmi_tx encoder
-- and HDMI capture devices keep working unchanged. The renderer is a 40x25 text
-- engine with a per-scanline character fetch that steals CPU bus cycles during
-- horizontal blank (the CPU is held via the `ba` output -> core RDY).
--
-- Data sources are C64-accurate:
--   * screen codes  -> main DRAM at (VIC bank << 14) + video-matrix base, fetched
--                      over the steal bus (vic_addr / vic_data).
--   * colour        -> colour RAM, read in parallel over a dedicated 4-bit port.
--   * glyph pattern -> character generator ROM (chargen) over char_addr/char_data.
--
-- Implemented registers ($D000-$D03F, mirrored every $40):
--   $D011 control1 : [7]=raster bit8 [4]=DEN [3]=RSEL [2:0]=YSCROLL (read: live raster b8)
--   $D012 raster   : raster compare value (write) / current raster low 8 (read)
--   $D016 control2 : [3]=CSEL [2:0]=XSCROLL
--   $D018 memptr   : [7:4]=video matrix base (VM13-10) [3:1]=char base (CB13-11)
--   $D019 irq      : [0]=raster IRQ latch (write 1 to ack)
--   $D01A irqen    : [0]=raster IRQ enable
--   $D020 border, $D021 background0   (palette index, 4-bit)
-- Sprites, bitmap/multicolour/ECM, and sub-char-cycle effects are TODO (M2).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vic_ii is
  port (
    clk        : in  std_logic;
    reset_n    : in  std_logic;

    -- CPU register interface ($D000-$D03F).
    cs         : in  std_logic;
    we         : in  std_logic;
    addr       : in  std_logic_vector(5 downto 0);
    din        : in  std_logic_vector(7 downto 0);
    dout       : out std_logic_vector(7 downto 0);
    irq_n      : out std_logic;

    -- VIC DRAM fetch (screen codes). 16-bit absolute into the 64K space.
    vic_addr   : out std_logic_vector(15 downto 0);
    vic_data   : in  std_logic_vector(7 downto 0);
    ba         : out std_logic;     -- '0' = VIC needs the bus (CPU held)

    -- VIC bank select from CIA-2 PRA[1:0] (already inverted to a bank number).
    vic_bank   : in  std_logic_vector(1 downto 0);

    -- Colour RAM read port (parallel).
    color_addr : out std_logic_vector(9 downto 0);
    color_data : in  std_logic_vector(3 downto 0);

    -- Character generator ROM port.
    char_addr  : out std_logic_vector(11 downto 0);
    char_data  : in  std_logic_vector(7 downto 0);

    -- HDMI/VGA output (fed to tang20k_hdmi_tx, RGB565 split).
    vga_hs     : out std_logic;
    vga_vs     : out std_logic;
    vga_de     : out std_logic;
    vga_r      : out std_logic_vector(4 downto 0);
    vga_g      : out std_logic_vector(5 downto 0);
    vga_b      : out std_logic_vector(4 downto 0)
  );
end entity;

architecture rtl of vic_ii is
  -- CEA-861 720x480p totals (identical to vic_vga CEA_480P path).
  constant H_TOT  : natural := 858;
  constant H_VIS  : natural := 720;
  constant H_PILL : natural := 40;                 -- pillarbox L/R
  constant H_SS   : natural := 736;
  constant H_SE   : natural := 798;
  constant H_CONT : natural := H_VIS - 2 * H_PILL; -- 640 content
  constant H_CEND : natural := H_PILL + H_CONT;

  constant V_VIS  : natural := 480;
  constant V_TOT  : natural := 525;
  constant V_SS   : natural := 489;
  constant V_SE   : natural := 495;

  -- Text band: 40 px top border, 25 rows * 16 px = 400, 40 px bottom border.
  constant V_BORD : natural := 40;
  constant TV_END : natural := V_BORD + 400;       -- 440

  signal hc : natural range 0 to H_TOT - 1 := 0;
  signal vc : natural range 0 to V_TOT - 1 := 0;

  -- Line buffer: 40 screen codes + 40 colour nibbles for the current row.
  type linebuf_t is array (0 to 39) of std_logic_vector(7 downto 0);
  type colbuf_t  is array (0 to 39) of std_logic_vector(3 downto 0);
  signal linebuf : linebuf_t := (others => (others => '0'));
  signal colbuf  : colbuf_t  := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of linebuf : signal is "distributed";
  attribute ram_style of colbuf  : signal is "distributed";

  -- Fetch FSM (runs during the start of H-blank for the next scanline).
  signal fetching   : std_logic := '0';
  signal fetch_col  : natural range 0 to 40 := 0;
  signal fetch_store: natural range 0 to 39 := 0;
  signal fetch_row  : natural range 0 to 24 := 0;
  signal fetch_valid: std_logic := '0';

  -- Register file.
  signal reg_d011 : std_logic_vector(7 downto 0) := x"1B";  -- DEN=1, RSEL=1, YSCROLL=3
  signal reg_d012 : std_logic_vector(7 downto 0) := x"00";
  signal reg_d016 : std_logic_vector(7 downto 0) := x"08";  -- CSEL=1
  signal reg_d018 : std_logic_vector(7 downto 0) := x"15";  -- screen $0400, char $1000
  signal reg_d020 : std_logic_vector(3 downto 0) := x"E";   -- light blue border
  signal reg_d021 : std_logic_vector(3 downto 0) := x"6";   -- blue background
  signal irq_latch: std_logic := '0';
  signal irq_en   : std_logic := '0';
  signal raster_cmp : unsigned(8 downto 0) := (others => '0');

  -- Display geometry (combinational).
  signal hx   : natural range 0 to H_CONT - 1 := 0;
  signal in_text : std_logic;
  signal col  : natural range 0 to 39 := 0;
  signal cline: natural range 0 to 7  := 0;
  signal cpix : natural range 0 to 7  := 0;
  signal v_off: natural range 0 to V_TOT := 0;

  signal scr_code : std_logic_vector(7 downto 0);
  signal fg_index : natural range 0 to 15;
  signal bg_index : natural range 0 to 15;
  signal border_idx : natural range 0 to 15;
  signal in_border : std_logic;
  signal pbit : std_logic;

  -- Pixel-output pipeline stage 1: the cell colour/geometry/sync are registered
  -- so they line up with the 1-clock CHARGEN read latency AND so the long
  -- combinational path (hc -> linebuf/colbuf 40:1 mux -> palette -> vga) is split
  -- into two shorter segments that close timing at the 27 MHz pixel clock.
  signal hs_c, vs_c, de_c : std_logic;          -- combinational sync (stage 0)
  signal hs_d, vs_d, de_d : std_logic := '1';   -- registered sync (stage 1)
  signal cpix_d   : natural range 0 to 7  := 0;
  signal fg_d, bg_d, bord_d : natural range 0 to 15 := 0;
  signal inb_d, intext_d : std_logic := '0';

  -- Stage 2: combinational palette outputs, then registered so the VIC->HDMI
  -- crossing (pixel clock -> system clock inside tang20k_hdmi_tx) is a short
  -- register-to-register hop instead of dragging the palette mux across domains.
  signal vga_r_c, vga_b_c : std_logic_vector(4 downto 0);
  signal vga_g_c          : std_logic_vector(5 downto 0);

  -- Video matrix base within the VIC bank, from $D018[7:4] (VM*1024).
  signal screen_base : unsigned(15 downto 0);
  signal raster_v    : unsigned(8 downto 0);

  -- Pepto palette in RGB565 split (same constants as vic_vga).
  type pal5_t is array (0 to 15) of std_logic_vector(4 downto 0);
  type pal6_t is array (0 to 15) of std_logic_vector(5 downto 0);
  constant PAL_R : pal5_t := (
    "00000","11111","10001","01101","10001","01011","01000","11000",
    "10001","01011","10111","01010","01111","10011","01111","10100");
  constant PAL_G : pal6_t := (
    "000000","111111","001110","101110","010000","101000","001100","110100",
    "011001","010010","011010","010100","011110","111000","011010","101000");
  constant PAL_B : pal5_t := (
    "00000","11111","00110","11000","10011","01001","10010","01110",
    "00110","00000","01100","01010","01111","10001","11001","10100");
begin
  -- ----- raster counters (27 MHz pixel clock = system clock here) -----
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        hc <= 0; vc <= 0;
      elsif hc = H_TOT - 1 then
        hc <= 0;
        if vc = V_TOT - 1 then vc <= 0; else vc <= vc + 1; end if;
      else
        hc <= hc + 1;
      end if;
    end if;
  end process;

  -- Video-matrix base = VM13-10 ($D018[7:4]) -> address bits 13:10, zero-extended
  -- to a full 16-bit within-bank offset (bits 15:14 = 0; the bank is added later).
  screen_base <= "00" & unsigned(reg_d018(7 downto 4)) & "0000000000";
  raster_v    <= to_unsigned(vc, 9);

  -- ----- per-line character/colour fetch -----
  process(clk)
    variable nv : natural range 0 to V_TOT - 1;
    variable nr : natural range 0 to 24;
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        fetching <= '0'; fetch_col <= 0; fetch_store <= 0;
        fetch_row <= 0; fetch_valid <= '0';
      else
        if fetching = '0' then
          if hc = H_VIS - 1 then                    -- last visible pixel: prefetch next line
            if vc = V_TOT - 1 then nv := 0; else nv := vc + 1; end if;
            if nv >= V_BORD and nv < TV_END then
              nr := (nv - V_BORD) / 16;
            else
              nr := 0;
            end if;
            fetch_row   <= nr;
            fetch_col   <= 0;
            fetch_store <= 0;
            fetch_valid <= '0';
            if nv >= V_BORD and nv < TV_END then
              fetching <= '1';
            end if;
          end if;
        else
          if fetch_col < 40 then fetch_col <= fetch_col + 1; end if;
          if fetch_valid = '1' then
            linebuf(fetch_store) <= vic_data;
            colbuf(fetch_store)  <= color_data;
            if fetch_store = 39 then
              fetching <= '0'; fetch_valid <= '0';
            else
              fetch_store <= fetch_store + 1;
            end if;
          else
            fetch_valid <= '1';
          end if;
        end if;
      end if;
    end if;
  end process;

  -- VIC needs the bus during the fetch window.
  ba <= '0' when fetching = '1' else '1';

  -- Steal-bus address: screen codes from DRAM (bank + matrix base + row*40+col).
  vic_addr <= std_logic_vector(
                (unsigned(vic_bank) & "00000000000000") +
                screen_base + to_unsigned(fetch_row * 40 + fetch_col, 16));
  -- Colour RAM is bank-independent: row*40+col within the 1K nibble RAM.
  color_addr <= std_logic_vector(to_unsigned(fetch_row * 40 + fetch_col, 10));

  -- ----- display geometry -----
  hx     <= hc - H_PILL when hc >= H_PILL and hc < H_CEND else 0;
  in_text <= '1' when hc >= H_PILL and hc < H_CEND and
                      vc >= V_BORD and vc < TV_END else '0';
  v_off  <= (vc - V_BORD) when vc >= V_BORD else 0;
  col    <= hx / 16;
  cline  <= (v_off / 2) mod 8;
  cpix   <= (hx / 2) mod 8;

  scr_code <= linebuf(col) when in_text = '1' else x"00";
  fg_index <= to_integer(unsigned(colbuf(col))) when in_text = '1' else 0;
  bg_index <= to_integer(unsigned(reg_d021));
  border_idx <= to_integer(unsigned(reg_d020));

  -- Glyph pattern from chargen ROM: code*8 + line (lower/upper set TODO via CB).
  char_addr <= "0" & scr_code & std_logic_vector(to_unsigned(cline, 3));

  in_border <= '1' when hc < H_VIS and vc < V_VIS and in_text = '0' else '0';

  -- Combinational sync (stage 0).
  hs_c <= '0' when hc >= H_SS and hc < H_SE else '1';
  vs_c <= '0' when vc >= V_SS and vc < V_SE else '1';
  de_c <= '1' when hc < H_VIS and vc < V_VIS else '0';

  -- Pixel pipeline stage 1: register the cell colour/geometry and sync so they
  -- line up with the CHARGEN's 1-clock read latency, and so the output palette
  -- stage starts from registers (short path) instead of the full hc->mux chain.
  process(clk)
  begin
    if rising_edge(clk) then
      cpix_d   <= cpix;
      fg_d     <= fg_index;
      bg_d     <= bg_index;
      bord_d   <= border_idx;
      inb_d    <= in_border;
      intext_d <= in_text;
      hs_d <= hs_c; vs_d <= vs_c; de_d <= de_c;
    end if;
  end process;

  -- ----- register file + raster IRQ -----
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        reg_d011 <= x"1B"; reg_d012 <= x"00"; reg_d016 <= x"08";
        reg_d018 <= x"15"; reg_d020 <= x"E"; reg_d021 <= x"6";
        irq_latch <= '0'; irq_en <= '0'; raster_cmp <= (others => '0');
      else
        -- Raster compare: latch IRQ when the current line crosses the compare.
        if hc = 0 then
          if to_unsigned(vc, 9) = raster_cmp then
            irq_latch <= '1';
          end if;
        end if;

        if cs = '1' and we = '1' then
          case addr is
            when "010001" => reg_d011 <= din;                 -- $D011
                             raster_cmp(8) <= din(7);
            when "010010" => raster_cmp(7 downto 0) <= unsigned(din); -- $D012
            when "010110" => reg_d016 <= din;                 -- $D016
            when "011000" => reg_d018 <= din;                 -- $D018
            when "011001" => if din(0) = '1' then irq_latch <= '0'; end if; -- $D019 ack
            when "011010" => irq_en <= din(0);                -- $D01A
            when "100000" => reg_d020 <= din(3 downto 0);     -- $D020
            when "100001" => reg_d021 <= din(3 downto 0);     -- $D021
            when others => null;
          end case;
        end if;
      end if;
    end if;
  end process;

  irq_n <= '0' when (irq_latch = '1' and irq_en = '1') else '1';

  -- Register read-back.
  process(addr, reg_d011, reg_d016, reg_d018, reg_d020, reg_d021,
          irq_latch, irq_en, raster_v)
  begin
    case addr is
      when "010001" => dout <= raster_v(8) & reg_d011(6 downto 0);
      when "010010" => dout <= std_logic_vector(raster_v(7 downto 0));
      when "010110" => dout <= reg_d016;
      when "011000" => dout <= reg_d018;
      when "011001" => dout <= '0' & "000" & "000" & irq_latch;
      when "011010" => dout <= '0' & "000" & "000" & irq_en;
      when "100000" => dout <= x"F" & reg_d020;
      when "100001" => dout <= x"F" & reg_d021;
      when others   => dout <= x"FF";
    end case;
  end process;

  -- ----- stage 1->2: combinational palette from stage-1 registers -----
  -- pbit is combinational but only from registers (char_data, cpix_d).
  pbit <= char_data(7 - cpix_d) when intext_d = '1' else '0';

  vga_r_c <= PAL_R(bord_d) when inb_d = '1' else
             PAL_R(fg_d) when pbit = '1' else PAL_R(bg_d);
  vga_g_c <= PAL_G(bord_d) when inb_d = '1' else
             PAL_G(fg_d) when pbit = '1' else PAL_G(bg_d);
  vga_b_c <= PAL_B(bord_d) when inb_d = '1' else
             PAL_B(fg_d) when pbit = '1' else PAL_B(bg_d);

  -- ----- stage 2: register the VIC outputs. Colour has 2 register stages
  -- (stage 1 + this one) with the palette mux between; the sync is registered
  -- once here too so both leave the VIC with the same 2-clock latency, aligned.
  process(clk)
  begin
    if rising_edge(clk) then
      vga_r  <= vga_r_c;
      vga_g  <= vga_g_c;
      vga_b  <= vga_b_c;
      vga_hs <= hs_d;
      vga_vs <= vs_d;
      vga_de <= de_d;
    end if;
  end process;
end architecture;
