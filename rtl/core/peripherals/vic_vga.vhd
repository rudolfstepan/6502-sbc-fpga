-- VIC VGA: Video Controller mit Bus-Stealing und VGA-Ausgabe
--
-- Funktionsprinzip (aehnlich C64):
--   Waehrend H-Blank (160 Pixel-Takte = 320 System-Takte) stiehlt der VIC
--   41 System-Takte vom CPU-Bus: einen Vorlauf-Takt fuer synchrones VRAM
--   und danach einen pro Zeichen der Zeile.
--   Die CPU wird dabei via RDY gehalten. Kein Dual-Port-RAM noetig.
--
--   Waehrend der sichtbaren Zeile laeuft die CPU ungehindert; der VIC
--   zeigt Zeichen aus dem 40-Byte Zeilenpuffer mit kombinatorischer
--   Char-ROM-Ausgabe.
--
-- Timing: 858x525 total. Active width and sync positions are generics.
--   CLK_DIV=2 with 50 MHz -> 25 MHz pixel clock (PIX16 board, default 640 active).
--   CLK_DIV=1 with 27 MHz -> 27 MHz pixel clock (Tang Primer 20K).
--   Tang overrides the generics for exact CEA-861 720x480p (VIC 3): the native
--   640-wide content is pillarboxed (40 px black border each side) into the
--   standard 720 active region so HDMI capture devices lock onto a known mode.
-- Textmodus: 40x25 Zeichen, 2x skaliert (16x16 Bildschirmpixel pro Zeichen)
-- Randhoehe oben/unten: 40 Pixel
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity vic_vga is
  generic (
    -- Pixel-clock divisor: 2 for 50 MHz systems (pixel = 25 MHz),
    --                      1 for 27 MHz systems (pixel = 27 MHz, ~64 Hz refresh).
    CLK_DIV : natural := 2;
    -- Number of clk cycles per cursor blink phase. 25_000_000 gives a
    -- C64-like half-second phase on 50 MHz boards.
    CURSOR_BLINK_DIV : positive := 25_000_000;
    -- Video timing select. Total H/V are fixed at 858x525.
    --   false = legacy 640-active-in-858 hybrid (25 MHz boards, analog VGA).
    --   true  = exact CEA-861 720x480p (VIC 3): the native 640-wide content is
    --           pillarboxed into the standard 720 active region so HDMI capture
    --           devices recognise a known mode (Tang Primer 20K).
    CEA_480P : boolean := false
  );
  port (
    clk          : in  std_logic;
    reset_n      : in  std_logic;

    -- Bus-Steal-Interface
    vic_addr     : out addr_t;
    vram_data    : in  data_t;
    vic_stealing : out std_logic;

    -- Char-ROM (kombinatorisch)
    char_addr    : out std_logic_vector(9 downto 0);
    -- High glyph-select bit (char_code bit 7) -> char_rom glyph_hi. Reaches the
    -- upper 128 glyphs (German umlauts) instead of using bit 7 as reverse video.
    char_glyph_hi : out std_logic;
    char_data    : in  data_t;

    -- Text cursor register inputs (0..39, 0..24)
    cursor_x     : in  std_logic_vector(5 downto 0);
    cursor_y     : in  std_logic_vector(4 downto 0);
    cursor_enable : in std_logic := '1';

    -- Bitmap modes ($9000: bit 0 = bitmap, bit 1 = 160x100 RGB332,
    --                         bit 3 = 180x120 packed RGB222,
    --                         bit 4 = 320x240 4bpp / 16-colour palette)
    bitmap_mode   : in  std_logic := '0';
    color256_mode : in  std_logic := '0';
    color64_mode  : in  std_logic := '0';
    color16_mode  : in  std_logic := '0';
    vic_fetch_bitmap : out std_logic;

    -- VIC-II $D020 border colour (palette index). Colours the visible area
    -- outside the active text/bitmap content (default 0 = black, as before).
    border_color  : in  std_logic_vector(3 downto 0) := "0000";
    -- VIC-II $D021 background colour: global text background (behind characters),
    -- C64-style (foreground stays per-cell). Default 0 = black, as before.
    bg_color      : in  std_logic_vector(3 downto 0) := "0000";

    -- VGA-Ausgang 640x480
    vga_hs       : out std_logic;
    vga_vs       : out std_logic;
    vga_de       : out std_logic;  -- data enable: '1' during active video
    vga_r        : out std_logic_vector(4 downto 0);
    vga_g        : out std_logic_vector(5 downto 0);
    vga_b        : out std_logic_vector(4 downto 0)
  );
end entity;

architecture rtl of vic_vga is
  -- Compile-time conditional select (VHDL-93 safe; resolved at elaboration).
  function ite(c : boolean; a, b : natural) return natural is
  begin
    if c then return a; else return b; end if;
  end function;

  -- 858x525 total @ pixel clock. At 27 MHz -> 59.94 Hz (CEA-861 480p totals).
  -- H_freq = 27 MHz / 858 = 31.47 kHz,  V_freq = 31468 / 525 = 59.94 Hz
  constant H_TOT  : natural := 858;
  constant H_VIS  : natural := ite(CEA_480P, 720, 640);  -- active / DE width
  constant H_PILL : natural := ite(CEA_480P,  40,   0);  -- pillarbox border L/R
  constant H_SS   : natural := ite(CEA_480P, 736, 671);  -- H-Sync-Start
  constant H_SE   : natural := ite(CEA_480P, 798, 767);  -- H-Sync-Ende
  -- Native content width (40 chars * 16 px = 640) carved out of the active
  -- region: [H_PILL, H_CEND).  H_CONT stays 640 for the renderer geometry.
  constant H_CONT : natural := H_VIS - 2 * H_PILL;
  constant H_CEND : natural := H_PILL + H_CONT;

  constant V_VIS  : natural := 480;
  constant V_TOT  : natural := 525;
  constant V_SS   : natural := ite(CEA_480P, 489, 490);  -- V-Sync-Start
  constant V_SE   : natural := ite(CEA_480P, 495, 492);  -- V-Sync-Ende

  -- 320x240 16-colour bitmap: displayed 1:1 (no scaling/zoom), centred in the
  -- active area; the (colourable) border fills the rest. Avoids the stretched
  -- look of upscaling.
  constant BMP16_W  : natural := 320;
  constant BMP16_H  : natural := 240;
  constant BMP16_X0 : natural := (H_VIS - BMP16_W) / 2;
  constant BMP16_Y0 : natural := (V_VIS - BMP16_H) / 2;
  constant BMP16_X1 : natural := BMP16_X0 + BMP16_W;
  constant BMP16_Y1 : natural := BMP16_Y0 + BMP16_H;

  -- Textbereich: 40px Rand oben, 25 Zeilen * 16 Pixel = 400px, 40px Rand unten
  constant V_BORD : natural := 40;
  constant TV_END : natural := V_BORD + 400;   -- 440
  -- RGB222 (180x120) scaling. On the Tang CEA 720x480p path it is scaled 4x to
  -- fill the whole active region (180*4=720, 120*4=480, no border). On the
  -- 640-wide boards it stays 3x = 540x360, centred (50/60 px border).
  constant C64_SC     : natural := ite(CEA_480P, 4, 3);
  constant C64_H_BORD : natural := ite(CEA_480P, 0, 50);
  constant C64_V_BORD : natural := ite(CEA_480P, 0, 60);
  constant C64_H_END  : natural := C64_H_BORD + 180 * C64_SC;
  constant C64_V_END  : natural := C64_V_BORD + 120 * C64_SC;

  -- Pixel-Takt-Enable (div2)
  signal pce      : std_logic := '0';

  -- Scan-Zaehler (Pixel-Takt-Einheiten)
  signal hc       : natural range 0 to H_TOT - 1 := 0;
  signal vc       : natural range 0 to V_TOT - 1 := 0;

  -- 160-byte pixel/character line buffer. Text and legacy bitmap modes use
  -- entries 0..39; RGB332 mode uses one entry per logical 160x100 pixel.
  type linebuf_t is array (0 to 159) of data_t;
  type colorbuf_t is array (0 to 39) of data_t;
  signal linebuf  : linebuf_t := (others => (others => '0'));
  signal colorbuf : colorbuf_t := (others => x"01");  -- default: white on black
  attribute ram_style : string;
  attribute ram_style of linebuf  : signal is "distributed";
  attribute ram_style of colorbuf : signal is "distributed";

  -- Fetch-Zustandsautomat (2-Phasen: Phase 0 = Zeichencodes, Phase 1 = Farben)
  signal fetching       : std_logic := '0';
  signal fetch_phase    : std_logic := '0';  -- 0=char, 1=color
  signal fetch_col      : natural range 0 to 159 := 0;
  signal fetch_store_col : natural range 0 to 159 := 0;
  signal fetch_row      : natural range 0 to 24 := 0;
  signal fetch_bmp_line : natural range 0 to 239 := 0;
  signal fetch_valid    : std_logic := '0';

  -- Anzeige-Geometrie (kombinatorisch aus Scanzaehlern)
  -- Breiter Wertebereich um Out-of-Bounds bei Blanking zu vermeiden
  signal in_text  : std_logic;
  -- Content-relative horizontal coordinate (0..H_CONT-1) inside the pillarbox.
  signal hx       : natural range 0 to H_CONT - 1 := 0;
  -- v_off/crow get headroom up to the full V_TOT: in the 320x240 mode vc spans
  -- the whole frame (incl. blanking up to V_TOT-1), not just the text band, so
  -- vc-V_BORD can exceed V_VIS. (Only used by text-mode cursor logic.)
  signal v_off    : natural range 0 to V_TOT := 0;
  signal col      : natural range 0 to 39 := 0;
  signal crow     : natural range 0 to 32 := 0;
  signal cline    : natural range 0 to 7  := 0;
  signal cpix     : natural range 0 to 7  := 0;
  signal pixel_col : natural range 0 to 159 := 0;
  signal pixel_col64 : natural range 0 to 179 := 0;
  signal pack_base   : natural range 0 to 132 := 0;
  signal pack_sub    : natural range 0 to 3 := 0;

  signal char_code : data_t;
  signal cell_color : data_t;
  signal pbit      : std_logic;
  signal cursor_pixel   : std_logic;
  signal cursor_visible : std_logic := '1';
  signal cursor_cnt     : natural range 0 to CURSOR_BLINK_DIV - 1 := 0;

  -- C64-Farbpalette (16 Farben, Pepto-Palette, RGB565)
  type pal5_t is array (0 to 15) of std_logic_vector(4 downto 0);
  type pal6_t is array (0 to 15) of std_logic_vector(5 downto 0);

  constant PAL_R : pal5_t := (
    "00000", "11111", "10001", "01101",   -- black, white, red, cyan
    "10001", "01011", "01000", "11000",   -- purple, green, blue, yellow
    "10001", "01011", "10111", "01010",   -- orange, brown, light red, dark gray
    "01111", "10011", "01111", "10100"    -- gray, light green, light blue, light gray
  );
  constant PAL_G : pal6_t := (
    "000000", "111111", "001110", "101110",
    "010000", "101000", "001100", "110100",
    "011001", "010010", "011010", "010100",
    "011110", "111000", "011010", "101000"
  );
  constant PAL_B : pal5_t := (
    "00000", "11111", "00110", "11000",
    "10011", "01001", "10010", "01110",
    "00110", "00000", "01100", "01010",
    "01111", "10001", "11001", "10100"
  );

  signal fg_index : natural range 0 to 15;
  signal bg_index : natural range 0 to 15;
  signal chunky_color : data_t;
  signal color64      : std_logic_vector(5 downto 0);
  signal in_color64   : std_logic;

  -- 320x240 4bpp (16-colour palette) mode: one byte holds two pixels.
  signal in_bmp16   : std_logic;
  signal pix16_idx  : natural range 0 to 15;
  signal bmp16_x    : natural range 0 to BMP16_W;   -- pixel X within the image
  signal bmp16_col  : natural range 0 to 159;       -- byte index within the line

  -- VIC-II border: visible pixels outside the active text/bitmap content.
  signal in_border  : std_logic;
  signal border_idx : natural range 0 to 15;

begin
  -- Pixel-clock enable: divide by CLK_DIV (2 for 50 MHz, 1 for 27 MHz)
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        pce <= '0';
      elsif CLK_DIV = 1 then
        pce <= '1';
      else
        pce <= not pce;
      end if;
    end if;
  end process;

  -- C64-style blinking text cursor: invert the whole character cell while
  -- visible. The kernel updates cursor_x/y through VIC registers $9001/$9002.
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        cursor_cnt <= 0;
        cursor_visible <= '1';
      elsif cursor_cnt = CURSOR_BLINK_DIV - 1 then
        cursor_cnt <= 0;
        cursor_visible <= not cursor_visible;
      else
        cursor_cnt <= cursor_cnt + 1;
      end if;
    end if;
  end process;

  -- Horizontal/Vertikal-Zaehler
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        hc <= 0;
        vc <= 0;
      elsif pce = '1' then
        if hc = H_TOT - 1 then
          hc <= 0;
          if vc = V_TOT - 1 then
            vc <= 0;
          else
            vc <= vc + 1;
          end if;
        else
          hc <= hc + 1;
        end if;
      end if;
    end if;
  end process;

  -- Zeilenpuffer-Lade-Automat
  -- Laeuft 41 System-Takte am Anfang jedes H-Blank
  -- pre-fetcht fuer die NAECHSTE Scan-Zeile
  -- Das VRAM ist synchron: vic_addr wird einen Takt vor dem Speichern
  -- ausgegeben. Ohne diesen Vorlauf landet besonders Spalte 0 mit altem
  -- RAM-Datenwert im Zeilenpuffer.
  process(clk)
    variable nv : natural range 0 to V_TOT - 1;
    variable nr : natural range 0 to 24;
    variable nb : natural range 0 to 239;
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        fetching        <= '0';
        fetch_phase     <= '0';
        fetch_col       <= 0;
        fetch_store_col <= 0;
        fetch_row       <= 0;
        fetch_bmp_line  <= 0;
        fetch_valid     <= '0';
      else
        if fetching = '0' then
          -- Trigger beim letzten sichtbaren Pixel
          if pce = '1' and hc = H_VIS - 1 then
            -- Naechste Scanzeile
            if vc = V_TOT - 1 then nv := 0;
            else nv := vc + 1;
            end if;
            -- Zeichenzeile fuer naechste Scanzeile berechnen
            if bitmap_mode = '1' and color16_mode = '1' then
              -- 320x240 4bpp shown 1:1 and centred: one framebuffer line per
              -- scanline inside [BMP16_Y0, BMP16_Y1). 160 bytes per line.
              nr := 0;
              if nv >= BMP16_Y0 and nv < BMP16_Y1 then nb := nv - BMP16_Y0;
              else nb := 0; end if;
            elsif bitmap_mode = '1' and color64_mode = '1' then
              -- RGB222: C64_SC scanlines per bitmap row (4x full-screen on Tang,
              -- 3x centred on 640 boards).
              nr := 0;
              if nv >= C64_V_BORD and nv < C64_V_END then
                nb := (nv - C64_V_BORD) / C64_SC;
              else
                nb := 0;
              end if;
            elsif nv >= V_BORD and nv < TV_END then
              nr := (nv - V_BORD) / 16;
              if bitmap_mode = '1' and color256_mode = '1' then
                nb := (nv - V_BORD) / 4;
              else
                nb := (nv - V_BORD) / 2;
              end if;
            else
              nr := 0;
              nb := 0;
            end if;
            fetch_row       <= nr;
            fetch_bmp_line  <= nb;
            fetch_col       <= 0;
            fetch_store_col <= 0;
            fetch_valid     <= '0';
            fetch_phase     <= '0';
            fetching        <= '1';
          end if;
        else
          -- fetch_col Vorlauf: Adresse einen Takt vor Datenuebernahme ausgeben.
          -- Steht VOR dem Phasencheck, damit fetch_col<=0 beim Phasenwechsel
          -- als spaetere Zuweisung gewinnt (VHDL last-assignment rule).
          if bitmap_mode = '1' and color64_mode = '1' then
            if fetch_col < 134 then
              fetch_col <= fetch_col + 1;
            end if;
          elsif fetch_col < 159 then
            fetch_col <= fetch_col + 1;
          end if;

          -- Einen Takt nach Ausgabe der Adresse liegt das synchrone VRAM-Datum an.
          if fetch_valid = '1' then
            if fetch_phase = '0' then
              linebuf(fetch_store_col) <= vram_data;
            else
              colorbuf(fetch_store_col) <= vram_data;
            end if;
            if (bitmap_mode = '1' and color64_mode = '1' and fetch_phase = '0' and fetch_store_col = 134) or
               (bitmap_mode = '1' and color64_mode = '0' and
                (color256_mode = '1' or color16_mode = '1') and
                fetch_phase = '0' and fetch_store_col = 159) or
               ((bitmap_mode = '0' or
                 (color64_mode = '0' and color256_mode = '0' and color16_mode = '0')) and
                fetch_store_col = 39) then
              if fetch_phase = '0' then
                if bitmap_mode = '1' and
                   (color64_mode = '1' or color256_mode = '1' or color16_mode = '1') then
                  -- Chunky pixels carry their colour/index directly; no colour phase.
                  fetching    <= '0';
                  fetch_valid <= '0';
                else
                  -- Zeichencodes fertig, jetzt Farbattribute holen
                  fetch_phase     <= '1';
                  fetch_col       <= 0;
                  fetch_store_col <= 0;
                  fetch_valid     <= '0';
                end if;
              else
                -- Beide Phasen fertig
                fetching    <= '0';
                fetch_valid <= '0';
              end if;
            else
              fetch_store_col <= fetch_store_col + 1;
            end if;
          else
            fetch_valid <= '1';
          end if;
        end if;
      end if;
    end if;
  end process;

  -- Bus-Steal-Ausgaenge (kombinatorisch)
  -- Phase 0 Text:   Zeichencodes aus $8000+
  -- Phase 0 Bitmap: Pixeldaten aus ADDR_VIC_BMP_BASE ($6000)
  -- Phase 1:        Farben aus $8400+ (beide Modi identisch)
  vic_stealing <= fetching;
  vic_fetch_bitmap <= fetching and (not fetch_phase) and bitmap_mode;

  -- Bitmap addresses are framebuffer-relative. This permits all 16 KiB to be
  -- addressed even though the CPU sees it through the banked $6000-$7FFF window.
  vic_addr <= std_logic_vector(to_unsigned(fetch_bmp_line * 135 + fetch_col, 16))
    when fetching = '1' and fetch_phase = '0' and bitmap_mode = '1' and color64_mode = '1' else
             std_logic_vector(to_unsigned(fetch_bmp_line * 160 + fetch_col, 16))
    when fetching = '1' and fetch_phase = '0' and bitmap_mode = '1' and
         (color256_mode = '1' or color16_mode = '1') else
             std_logic_vector(to_unsigned(fetch_bmp_line * 40 + fetch_col, 16))
    when fetching = '1' and fetch_phase = '0' and bitmap_mode = '1' else
             std_logic_vector(
      to_unsigned(16#8000# + fetch_row * 40 + fetch_col, 16))
    when fetching = '1' and fetch_phase = '0' else
             std_logic_vector(
      to_unsigned(16#8400# + fetch_row * 40 + fetch_col, 16))
    when fetching = '1' else (others => '0');

  -- Anzeige-Geometrie: col/row auf gueltigen Bereich klemmen
  -- damit kein Out-of-Bounds bei Blanking entsteht
  -- Pillarbox: hx is the content X (0..H_CONT-1) inside the active region.
  -- Outside the content window (left/right border, blanking) hx = 0; those
  -- pixels render as black because in_text/in_color64 are deasserted there.
  hx <= hc - H_PILL when hc >= H_PILL and hc < H_CEND else 0;

  in_text <= '1' when hc >= H_PILL and hc < H_CEND and
                       vc >= V_BORD and vc < TV_END else '0';

  v_off <= (vc - V_BORD)   when vc >= V_BORD else 0;
  col   <= hx / 16;
  crow  <= v_off / 16;
  cline <= (v_off / 2) mod 8;
  cpix  <= (hx  / 2) mod 8;
  pixel_col <= hx / 4;
  -- RGB222 maps to the full active region (uses hc, not the pillarboxed hx),
  -- scaled by C64_SC: on Tang that is 4x -> 720x480 edge to edge (no pillarbox
  -- for this mode); on 640 boards 3x -> 540x360 centred.
  in_color64 <= '1' when hc >= C64_H_BORD and hc < C64_H_END and
                            vc >= C64_V_BORD and vc < C64_V_END else '0';
  pixel_col64 <= (hc - C64_H_BORD) / C64_SC
                 when hc >= C64_H_BORD and hc < C64_H_END else 0;
  pack_base <= (pixel_col64 / 4) * 3;
  pack_sub  <= pixel_col64 mod 4;

  -- 320x240 4bpp shown 1:1 and centred (no scaling). One byte = two pixels:
  -- even image-X in the low nibble, odd in the high nibble. Image X = hc-BMP16_X0,
  -- byte index = that / 2, nibble selected by bit 0 of the image X.
  in_bmp16  <= '1' when bitmap_mode = '1' and color16_mode = '1' and
                        hc >= BMP16_X0 and hc < BMP16_X1 and
                        vc >= BMP16_Y0 and vc < BMP16_Y1 else '0';
  bmp16_x   <= hc - BMP16_X0 when hc >= BMP16_X0 and hc < BMP16_X1 else 0;
  bmp16_col <= bmp16_x / 2;
  pix16_idx <= to_integer(unsigned(linebuf(bmp16_col)(7 downto 4)))
                 when (bmp16_x mod 2) = 1
               else to_integer(unsigned(linebuf(bmp16_col)(3 downto 0)));

  -- Border: any visible pixel not inside the ACTIVE mode's content region.
  -- in_color64 is a pure-geometry signal that on the CEA path spans the whole
  -- screen, so it must only suppress the border when color64_mode is actually
  -- selected (otherwise the border never appears in text/256/16 modes). in_bmp16
  -- is already gated by color16_mode; in_text is the text/color256 content area.
  border_idx <= to_integer(unsigned(border_color));
  in_border  <= '1' when hc < H_VIS and vc < V_VIS and
                         in_text = '0' and in_bmp16 = '0' and
                         (in_color64 = '0' or color64_mode = '0')
                else '0';

  -- Zeichencode und Farbattribut aus Zeilenpuffer
  char_code  <= linebuf(col)  when in_text = '1' else x"00";
  cell_color <= colorbuf(col) when in_text = '1' else x"00";
  fg_index   <= to_integer(unsigned(cell_color(3 downto 0)));
  -- Background is now the global VIC-II $D021 colour (C64 text-mode model),
  -- not the per-cell high nibble. Foreground stays per-cell (color RAM).
  bg_index   <= to_integer(unsigned(bg_color));
  chunky_color <= linebuf(pixel_col) when in_text = '1' else x"00";
  color64 <= linebuf(pack_base)(7 downto 2) when pack_sub = 0 else
             linebuf(pack_base)(1 downto 0) & linebuf(pack_base + 1)(7 downto 4)
               when pack_sub = 1 else
             linebuf(pack_base + 1)(3 downto 0) & linebuf(pack_base + 2)(7 downto 6)
               when pack_sub = 2 else
             linebuf(pack_base + 2)(5 downto 0);

  -- Char-ROM-Adresse: char_code[6:0] & cline[2:0]; bit 7 selects the upper
  -- glyph half (umlauts) via glyph_hi.
  char_addr <= char_code(6 downto 0) &
               std_logic_vector(to_unsigned(cline, 3));
  char_glyph_hi <= char_code(7);

  -- Pixel-Bit aus ROM-Muster; bit 7 im Zeichencode ist Reverse-Video.
  -- The cursor is an OR overlay on the lower scan lines. It never clears
  -- character pixels, so it cannot hide the last typed character.
  cursor_pixel <= '1' when in_text = '1' and cursor_enable = '1' and
                           cursor_visible = '1' and
                           to_integer(unsigned(cursor_x)) = col and
                           to_integer(unsigned(cursor_y)) = crow and
                           cline >= 6
                  else '0';
  pbit <= char_code(7 - cpix)
          when in_text = '1' and bitmap_mode = '1' else
          (char_data(7 - cpix) or cursor_pixel)
          when in_text = '1' else '0';

  -- VGA-Sync (aktiv-low)
  vga_hs <= '0' when hc >= H_SS and hc < H_SE else '1';
  vga_vs <= '0' when vc >= V_SS and vc < V_SE else '1';
  vga_de <= '1' when hc < H_VIS and vc < V_VIS else '0';

  -- RGB332 expands directly to RGB565 in 256-colour mode. Replicated high bits
  -- fill the DAC width without needing a 256-entry palette RAM.
  vga_r <= PAL_R(border_idx) when in_border = '1' else
           PAL_R(pix16_idx) when in_bmp16 = '1' else
           "00000" when bitmap_mode = '1' and color16_mode = '1' else
           color64(5 downto 4) & color64(5 downto 4) & color64(5)
           when bitmap_mode = '1' and color64_mode = '1' and in_color64 = '1' else
           "00000" when bitmap_mode = '1' and color64_mode = '1' else
           chunky_color(7 downto 5) & chunky_color(7 downto 6)
           when bitmap_mode = '1' and color256_mode = '1' and in_text = '1' else
           PAL_R(fg_index) when pbit = '1' else PAL_R(bg_index);
  vga_g <= PAL_G(border_idx) when in_border = '1' else
           PAL_G(pix16_idx) when in_bmp16 = '1' else
           "000000" when bitmap_mode = '1' and color16_mode = '1' else
           color64(3 downto 2) & color64(3 downto 2) & color64(3 downto 2)
           when bitmap_mode = '1' and color64_mode = '1' and in_color64 = '1' else
           "000000" when bitmap_mode = '1' and color64_mode = '1' else
           chunky_color(4 downto 2) & chunky_color(4 downto 2)
           when bitmap_mode = '1' and color256_mode = '1' and in_text = '1' else
           PAL_G(fg_index) when pbit = '1' else PAL_G(bg_index);
  vga_b <= PAL_B(border_idx) when in_border = '1' else
           PAL_B(pix16_idx) when in_bmp16 = '1' else
           "00000" when bitmap_mode = '1' and color16_mode = '1' else
           color64(1 downto 0) & color64(1 downto 0) & color64(1)
           when bitmap_mode = '1' and color64_mode = '1' and in_color64 = '1' else
           "00000" when bitmap_mode = '1' and color64_mode = '1' else
           chunky_color(1 downto 0) & chunky_color(1 downto 0) & chunky_color(1)
           when bitmap_mode = '1' and color256_mode = '1' and in_text = '1' else
           PAL_B(fg_index) when pbit = '1' else PAL_B(bg_index);

end architecture;
