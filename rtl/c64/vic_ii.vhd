-- MOS 6569 VIC-II -- native C64 video, Milestone 1 scope.
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
--   * glyph pattern -> character generator ROM in VIC banks 0/2 at $1000-$1FFF,
--                      otherwise RAM charset bytes fetched over the steal bus.
--
-- Implemented registers ($D000-$D03F, mirrored every $40):
--   $D011 control1 : [7]=raster bit8 [6]=ECM [5]=BMM [4]=DEN
--                    [3]=RSEL [2:0]=YSCROLL (read: live raster b8)
--   $D012 raster   : raster compare value (write) / current raster low 8 (read)
--   $D016 control2 : [4]=MCM [3]=CSEL [2:0]=XSCROLL
--   $D018 memptr   : [7:4]=video matrix base (VM13-10)
--                    [3]=bitmap base / [3:1]=char base (CB13-11)
--   $D000-$D00F sprite X/Y, $D010 sprite X MSBs, $D015 sprite enable
--   $D017/$D01D expansion, $D01B priority, $D01C multicolour
--   $D019 irq      : [0]=raster latch (write 1 to ack). Collision IRQ status
--                    is masked from $D019/irq_n until the collision model is
--                    cycle-closer; poll $D01E/$D01F for first-pass collisions.
--   $D01A irqen    : [2:0]=IRQ enables (collision enables are read back)
--   $D01E/$D01F    : sprite-sprite / sprite-background collision latches
--                    (read clears)
--   $D020 border, $D021-$D024 background0-3, $D025-$D026 sprite multicolours,
--   $D027-$D02E sprite colours (palette index, 4-bit)
-- Text, ECM text, multicolour text, hires bitmap, and multicolour bitmap are
-- implemented. Sprite rendering and collision latches are a first-pass scanline
-- overlay; sub-char-cycle effects are TODO (M2).
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
  -- Software-visible VIC raster. The HDMI output uses 480p and doubles C64
  -- scanlines vertically, so expose a logical C64 raster rather than the raw
  -- HDMI line counter through $D011/$D012 and raster IRQ compare.
  constant C64_RASTER_LINES  : natural := 263;
  constant C64_RASTER_OFFSET : natural := 30;

  -- Text band: 40 px top border, 25 rows * 16 px = 400, 40 px bottom border.
  constant V_BORD : natural := 40;
  constant TV_END : natural := V_BORD + 400;       -- 440

  signal hc : natural range 0 to H_TOT - 1 := 0;
  signal vc : natural range 0 to V_TOT - 1 := 0;

  -- Line buffer: 40 screen codes/attrs + 40 bitmap/glyph bytes + 40 colour nibbles.
  type linebuf_t is array (0 to 39) of std_logic_vector(7 downto 0);
  type colbuf_t  is array (0 to 39) of std_logic_vector(3 downto 0);
  type sprite_byte_t is array (0 to 7) of std_logic_vector(7 downto 0);
  type sprite_line_t is array (0 to 7) of std_logic_vector(23 downto 0);
  type sprite_row_t is array (0 to 7) of natural range 0 to 20;
  type sprite_col_t is array (0 to 7) of std_logic_vector(3 downto 0);
  signal linebuf : linebuf_t := (others => (others => '0'));
  signal bmpbuf  : linebuf_t := (others => (others => '0'));
  signal glyphbuf: linebuf_t := (others => (others => '0'));
  signal colbuf  : colbuf_t  := (others => (others => '0'));
  signal spr_ptrbuf : sprite_byte_t := (others => (others => '0'));
  signal spr_linebuf: sprite_line_t := (others => (others => '0'));
  signal spr_rowbuf : sprite_row_t := (others => 0);
  signal spr_activebuf : std_logic_vector(7 downto 0) := (others => '0');
  attribute ram_style : string;
  attribute ram_style of linebuf : signal is "distributed";
  attribute ram_style of bmpbuf : signal is "distributed";
  attribute ram_style of glyphbuf : signal is "distributed";
  attribute ram_style of colbuf  : signal is "distributed";
  attribute ram_style of spr_linebuf : signal is "distributed";

  -- Fetch FSM (runs during the start of H-blank for the next scanline).
  signal fetching   : std_logic := '0';
  signal fetch_col  : natural range 0 to 40 := 0;
  signal fetch_store: natural range 0 to 39 := 0;
  signal fetch_row  : natural range 0 to 24 := 0;
  signal fetch_y    : natural range 0 to 199 := 0;
  signal fetch_phase: natural range 0 to 3 := 0;
  signal fetch_bmm  : std_logic := '0';
  signal fetch_chargen : std_logic := '0';
  signal fetch_latch_matrix : std_logic := '0';
  signal fetch_valid: std_logic := '0';
  signal fetch_addr_col : natural range 0 to 39 := 0;
  signal fetch_spr_idx : natural range 0 to 7 := 0;
  signal fetch_spr_byte: natural range 0 to 2 := 0;
  signal any_sprite_line : std_logic := '0';

  -- Register file.
  signal reg_d011 : std_logic_vector(7 downto 0) := x"1B";  -- DEN=1, RSEL=1, YSCROLL=3
  signal reg_spr_x_lo : sprite_byte_t := (others => (others => '0'));
  signal reg_spr_y    : sprite_byte_t := (others => (others => '0'));
  signal reg_d010 : std_logic_vector(7 downto 0) := x"00";
  signal reg_d015 : std_logic_vector(7 downto 0) := x"00";
  signal reg_d012 : std_logic_vector(7 downto 0) := x"00";
  signal reg_d016 : std_logic_vector(7 downto 0) := x"08";  -- CSEL=1
  signal reg_d016_disp : std_logic_vector(7 downto 0) := x"08";
  signal reg_d017 : std_logic_vector(7 downto 0) := x"00";
  signal reg_d018 : std_logic_vector(7 downto 0) := x"15";  -- screen $0400, char $1000
  signal reg_d01b : std_logic_vector(7 downto 0) := x"00";
  signal reg_d01c : std_logic_vector(7 downto 0) := x"00";
  signal reg_d01d : std_logic_vector(7 downto 0) := x"00";
  signal reg_d020 : std_logic_vector(3 downto 0) := x"E";   -- light blue border
  signal reg_d021 : std_logic_vector(3 downto 0) := x"6";   -- blue background
  signal reg_d022 : std_logic_vector(3 downto 0) := x"0";   -- extra bg colours
  signal reg_d023 : std_logic_vector(3 downto 0) := x"0";
  signal reg_d024 : std_logic_vector(3 downto 0) := x"0";
  signal reg_d025 : std_logic_vector(3 downto 0) := x"0";
  signal reg_d026 : std_logic_vector(3 downto 0) := x"0";
  signal reg_spr_col : sprite_col_t := (others => x"0");
  signal reg_d01e : std_logic_vector(7 downto 0) := x"00";
  signal reg_d01f : std_logic_vector(7 downto 0) := x"00";
  signal irq_latch: std_logic_vector(2 downto 0) := (others => '0');
  signal irq_en   : std_logic_vector(2 downto 0) := (others => '0');
  signal irq_master : std_logic;
  signal d01e_read_armed : std_logic := '1';
  signal d01f_read_armed : std_logic := '1';
  signal raster_cmp : unsigned(8 downto 0) := (others => '0');

  -- Display geometry (combinational).
  signal hx   : natural range 0 to H_CONT - 1 := 0;
  signal in_text : std_logic;
  signal col  : natural range 0 to 39 := 0;
  signal cline: natural range 0 to 7  := 0;
  signal cpix : natural range 0 to 7  := 0;
  signal v_off: natural range 0 to V_TOT := 0;
  signal src_y: natural range 0 to 199 := 0;
  signal src_x: natural range 0 to 319 := 0;
  signal xscroll: natural range 0 to 7 := 0;
  signal h_text_left : natural range 0 to H_CONT := 0;
  signal h_text_right: natural range 0 to H_CONT := H_CONT;

  signal scr_code : std_logic_vector(7 downto 0);
  signal glyph_code : std_logic_vector(7 downto 0);
  signal fg_index : natural range 0 to 15;
  signal bg_index : natural range 0 to 15;
  signal bg1_index : natural range 0 to 15;
  signal bg2_index : natural range 0 to 15;
  signal bg3_index : natural range 0 to 15;
  signal border_idx : natural range 0 to 15;
  signal in_border : std_logic;
  signal in_sprite_area : std_logic;
  signal char_pbit : std_logic;
  signal bmp_pbit : std_logic;
  signal mc_pair : std_logic_vector(1 downto 0);
  signal pix_idx : natural range 0 to 15;
  signal c64_x : natural range 0 to 319 := 0;
  signal spr_opaque_c : std_logic;
  signal spr_prio_c : std_logic;
  signal spr_color_c : natural range 0 to 15;
  signal spr_mask_c : std_logic_vector(7 downto 0);

  -- Pixel-output pipeline stage 1: the cell colour/geometry/sync are registered
  -- so they line up with the 1-clock CHARGEN read latency AND so the long
  -- combinational path (hc -> linebuf/colbuf 40:1 mux -> palette -> vga) is split
  -- into two shorter segments that close timing at the 27 MHz pixel clock.
  signal hs_c, vs_c, de_c : std_logic;          -- combinational sync (stage 0)
  signal hs_d, vs_d, de_d : std_logic := '1';   -- registered sync (stage 1)
  signal cpix_d   : natural range 0 to 7  := 0;
  signal fg_d, bg_d, bg1_d, bg2_d, bg3_d, bord_d : natural range 0 to 15 := 0;
  signal scr_d, bmp_d, glyph_d : std_logic_vector(7 downto 0) := (others => '0');
  signal col_d : std_logic_vector(3 downto 0) := (others => '0');
  signal bmm_d, mcm_d, ecm_d, chargen_d : std_logic := '0';
  signal inb_d, intext_d : std_logic := '0';
  signal spr_opaque_d : std_logic := '0';
  signal spr_prio_d : std_logic := '0';
  signal spr_color_d : natural range 0 to 15 := 0;
  signal spr_mask_d : std_logic_vector(7 downto 0) := (others => '0');
  signal coll_spr_mask_c : std_logic_vector(7 downto 0) := (others => '0');
  signal coll_bg_mask_c : std_logic_vector(7 downto 0) := (others => '0');

  -- Stage 2: combinational palette outputs, then registered so the VIC->HDMI
  -- crossing (pixel clock -> system clock inside tang20k_hdmi_tx) is a short
  -- register-to-register hop instead of dragging the palette mux across domains.
  signal vga_r_c, vga_b_c : std_logic_vector(4 downto 0);
  signal vga_g_c          : std_logic_vector(5 downto 0);

  -- Video matrix base within the VIC bank, from $D018[7:4] (VM*1024).
  signal screen_base : unsigned(15 downto 0);
  signal char_base   : unsigned(15 downto 0);
  signal bitmap_base : unsigned(15 downto 0);
  signal fetch_offset : unsigned(15 downto 0);
  signal char_fetch_code : std_logic_vector(7 downto 0);
  signal char_fetch_offset : unsigned(15 downto 0);
  signal sprite_fetch_offset : unsigned(15 downto 0);
  signal char_rom_visible : std_logic;
  signal raster_v    : unsigned(8 downto 0);
  signal display_en  : std_logic;
  signal glyph_byte  : std_logic_vector(7 downto 0);

  constant SPR_X_BIAS : natural := 24;  -- C64 left text edge is around sprite X=24.
  constant SPR_Y_BIAS : natural := 50;  -- C64 first text row is around sprite Y=50.

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
  char_base   <= "00" & unsigned(reg_d018(3 downto 1)) & "00000000000";
  bitmap_base <= "00" & unsigned(reg_d018(3 downto 3)) & "0000000000000";
  -- On a real C64 the VIC sees character ROM at $1000-$1FFF in VIC banks 0 and
  -- 2 only. Other char bases/banks are RAM charsets.
  char_rom_visible <= '1' when (vic_bank = "00" or vic_bank = "10") and
                               reg_d018(3 downto 2) = "01" else '0';
  raster_v    <= to_unsigned(((vc / 2) + C64_RASTER_OFFSET) mod C64_RASTER_LINES, 9);
  display_en  <= reg_d011(4);
  fetch_addr_col <= fetch_col when fetch_col < 40 else 39;
  fetch_spr_idx <= fetch_col / 3 when fetch_col < 24 else 7;
  fetch_spr_byte <= fetch_col mod 3 when fetch_col < 24 else 2;
  any_sprite_line <= '1' when spr_activebuf /= x"00" else '0';

  -- ----- per-line character/colour fetch -----
  process(clk)
    variable nv : natural range 0 to V_TOT - 1;
    variable sy : natural range 0 to 199;
    variable nr : natural range 0 to 24;
    variable spr_line_y : natural range 0 to 255;
    variable spr_y : natural range 0 to 255;
    variable spr_h : natural range 0 to 42;
    variable spr_rel_y : natural range 0 to 41;
    variable store_spr : natural range 0 to 7;
    variable store_byte : natural range 0 to 2;
    variable sprite_any : std_logic;
    variable spr_active_next : std_logic_vector(7 downto 0);
    variable fetch_needed : std_logic;
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        fetching <= '0'; fetch_col <= 0; fetch_store <= 0;
        fetch_row <= 0; fetch_y <= 0; fetch_phase <= 0; fetch_bmm <= '0';
        fetch_chargen <= '0';
        fetch_latch_matrix <= '0';
        fetch_valid <= '0';
        spr_activebuf <= (others => '0');
      else
        if fetching = '0' then
          if hc = H_VIS - 1 then                    -- last visible pixel: prefetch next line
            if vc = V_TOT - 1 then nv := 0; else nv := vc + 1; end if;
            fetch_needed := '0';
            if nv >= V_BORD and nv < TV_END then
              sy := (nv - V_BORD) / 2;
              nr := sy / 8;
              if ((nv - V_BORD) mod 2) = 0 then
                fetch_needed := '1';
              end if;
            else
              sy := 0;
              nr := 0;
            end if;
            fetch_y     <= sy;
            fetch_row   <= nr;
            fetch_bmm   <= reg_d011(5);
            fetch_chargen <= char_rom_visible;
            if (sy mod 8) = 0 then
              fetch_latch_matrix <= '1';
            else
              fetch_latch_matrix <= '0';
            end if;
            fetch_valid <= '0';
            spr_line_y := sy + SPR_Y_BIAS;
            sprite_any := '0';
            spr_active_next := (others => '0');
            for i in 0 to 7 loop
              spr_y := to_integer(unsigned(reg_spr_y(i)));
              if reg_d017(i) = '1' then spr_h := 42; else spr_h := 21; end if;
              if reg_d015(i) = '1' and spr_line_y >= spr_y and
                 spr_line_y < spr_y + spr_h then
                spr_rel_y := spr_line_y - spr_y;
                spr_active_next(i) := '1';
                sprite_any := '1';
                if reg_d017(i) = '1' then
                  spr_rowbuf(i) <= spr_rel_y / 2;
                else
                  spr_rowbuf(i) <= spr_rel_y;
                end if;
              else
                spr_rowbuf(i) <= 0;
              end if;
            end loop;
            spr_activebuf <= spr_active_next;
            if fetch_needed = '1' and
               (display_en = '1' or sprite_any = '1') then
              fetch_col   <= 0;
              fetch_store <= 0;
              if display_en = '1' then
                fetch_phase <= 0;
              else
                fetch_phase <= 2;
              end if;
              fetching <= '1';
            else
              fetch_col   <= 0;
              fetch_store <= 0;
              fetch_phase <= 0;
            end if;
          end if;
        else
          if fetch_col < 40 then fetch_col <= fetch_col + 1; end if;
          if fetch_valid = '1' then
            if fetch_bmm = '1' and fetch_phase = 0 then
              bmpbuf(fetch_store) <= vic_data;
              if fetch_latch_matrix = '1' then
                colbuf(fetch_store) <= color_data;
              end if;
            elsif fetch_bmm = '1' then
              if fetch_latch_matrix = '1' then
                linebuf(fetch_store) <= vic_data;
              end if;
            elsif fetch_phase = 0 then
              if fetch_latch_matrix = '1' then
                linebuf(fetch_store) <= vic_data;
                colbuf(fetch_store)  <= color_data;
              end if;
            elsif fetch_phase = 1 then
              glyphbuf(fetch_store) <= vic_data;
            elsif fetch_phase = 2 then
              spr_ptrbuf(fetch_store) <= vic_data;
            else
              store_spr := fetch_store / 3;
              store_byte := fetch_store mod 3;
              if spr_activebuf(store_spr) = '1' then
                case store_byte is
                  when 0 => spr_linebuf(store_spr)(23 downto 16) <= vic_data;
                  when 1 => spr_linebuf(store_spr)(15 downto 8)  <= vic_data;
                  when others => spr_linebuf(store_spr)(7 downto 0) <= vic_data;
                end case;
              else
                spr_linebuf(store_spr) <= (others => '0');
              end if;
            end if;

            if (fetch_phase <= 1 and fetch_store = 39) or
               (fetch_phase = 2 and fetch_store = 7) or
               (fetch_phase = 3 and fetch_store = 23) then
              if fetch_phase = 0 and (fetch_bmm = '1' or fetch_chargen = '0') then
                fetch_phase <= 1;
                fetch_col <= 0;
                fetch_store <= 0;
                fetch_valid <= '0';
              elsif fetch_phase < 2 and any_sprite_line = '1' then
                fetch_phase <= 2;
                fetch_col <= 0;
                fetch_store <= 0;
                fetch_valid <= '0';
              elsif fetch_phase = 2 then
                fetch_phase <= 3;
                fetch_col <= 0;
                fetch_store <= 0;
                fetch_valid <= '0';
              else
                fetching <= '0'; fetch_valid <= '0';
              end if;
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

  -- Steal-bus address: screen/bitmap bytes from DRAM (bank + within-bank offset).
  char_fetch_code <= ("00" & linebuf(fetch_addr_col)(5 downto 0))
                     when reg_d011(6) = '1' and fetch_bmm = '0'
                     else linebuf(fetch_addr_col);
  char_fetch_offset <= char_base + resize(unsigned(char_fetch_code) & to_unsigned(fetch_y mod 8, 3), 16);
  sprite_fetch_offset <= resize(unsigned(spr_ptrbuf(fetch_spr_idx)) & "000000", 16) +
                         to_unsigned(spr_rowbuf(fetch_spr_idx) * 3 + fetch_spr_byte, 16);
  fetch_offset <= screen_base + to_unsigned(1016 + fetch_col, 16)
                  when fetch_phase = 2 else
                  sprite_fetch_offset
                  when fetch_phase = 3 else
                  bitmap_base + to_unsigned(fetch_y * 40 + fetch_col, 16)
                  when fetch_bmm = '1' and fetch_phase = 0 else
                  char_fetch_offset
                  when fetch_bmm = '0' and fetch_phase = 1 else
                  screen_base + to_unsigned(fetch_row * 40 + fetch_col, 16);
  vic_addr <= std_logic_vector(
                (unsigned(vic_bank) & "00000000000000") + fetch_offset);
  -- Colour RAM is bank-independent: row*40+col within the 1K nibble RAM.
  color_addr <= std_logic_vector(to_unsigned(fetch_row * 40 + fetch_col, 10));

  -- ----- display geometry -----
  xscroll <= to_integer(unsigned(reg_d016_disp(2 downto 0)));
  hx     <= hc - H_PILL when hc >= H_PILL and hc < H_CEND else 0;
  in_text <= '1' when display_en = '1' and
                      hc >= H_PILL + h_text_left and
                      hc < H_PILL + h_text_right and
                      vc >= V_BORD and vc < TV_END else '0';
  v_off  <= (vc - V_BORD) when vc >= V_BORD else 0;
  src_y  <= (v_off / 2) when v_off < 400 else 0;

  h_text_left  <= 0 when reg_d016_disp(3) = '1' else 16; -- CSEL: 40/38 columns, in 720p pixels.
  h_text_right <= H_CONT when reg_d016_disp(3) = '1' else H_CONT - 16;

  process(hx, xscroll)
    variable sx_base : natural range 0 to 319;
  begin
    sx_base := hx / 2;
    -- $D016 fine X scroll shifts the display right. Convert back to source
    -- coordinates so left-scrollers that count 7..0 move smoothly.
    if sx_base < xscroll then
      src_x <= sx_base + 320 - xscroll;
    else
      src_x <= sx_base - xscroll;
    end if;
  end process;

  col    <= src_x / 8;
  cline  <= src_y mod 8;
  cpix   <= src_x mod 8;
  c64_x  <= hx / 2;

  scr_code <= linebuf(col) when in_text = '1' else x"00";
  glyph_code <= "00" & scr_code(5 downto 0)
                when reg_d011(6) = '1' and reg_d011(5) = '0' else scr_code;
  fg_index <= to_integer(unsigned(colbuf(col))) when in_text = '1' else 0;
  bg_index <= to_integer(unsigned(reg_d021));
  bg1_index <= to_integer(unsigned(reg_d022));
  bg2_index <= to_integer(unsigned(reg_d023));
  bg3_index <= to_integer(unsigned(reg_d024));
  border_idx <= to_integer(unsigned(reg_d020));

  -- Glyph pattern from CHARGEN when the VIC's character-ROM window is active.
  -- reg_d018(1) selects the upper/lower 2K half inside the 4K character ROM.
  char_addr <= reg_d018(1) & glyph_code & std_logic_vector(to_unsigned(cline, 3));

  in_border <= '1' when hc < H_VIS and vc < V_VIS and in_text = '0' else '0';
  in_sprite_area <= '1' when hc >= H_PILL and hc < H_CEND and
                             vc >= V_BORD and vc < TV_END else '0';

  process(in_sprite_area, c64_x, spr_activebuf, spr_linebuf, reg_spr_x_lo, reg_d010,
          reg_d01b, reg_d01c, reg_d01d, reg_d025, reg_d026, reg_spr_col)
    variable sx_abs : natural range 0 to 343;
    variable spr_x  : natural range 0 to 511;
    variable spr_w  : natural range 0 to 48;
    variable rel_x  : natural range 0 to 47;
    variable bit_x  : natural range 0 to 23;
    variable bit_pos: natural range 0 to 23;
    variable pair   : std_logic_vector(1 downto 0);
    variable mask   : std_logic_vector(7 downto 0);
  begin
    spr_opaque_c <= '0';
    spr_prio_c <= '0';
    spr_color_c <= 0;
    mask := (others => '0');
    sx_abs := c64_x + SPR_X_BIAS;

    if in_sprite_area = '1' then
      for i in 7 downto 0 loop
        spr_x := to_integer(unsigned(reg_spr_x_lo(i)));
        if reg_d010(i) = '1' then spr_x := spr_x + 256; end if;
        if reg_d01d(i) = '1' then spr_w := 48; else spr_w := 24; end if;

        if spr_activebuf(i) = '1' and sx_abs >= spr_x and sx_abs < spr_x + spr_w then
          rel_x := sx_abs - spr_x;
          if reg_d01d(i) = '1' then bit_x := rel_x / 2; else bit_x := rel_x; end if;

          if reg_d01c(i) = '1' then
            bit_pos := 23 - 2 * (bit_x / 2);
            pair := spr_linebuf(i)(bit_pos downto bit_pos - 1);
            if pair /= "00" then
              mask(i) := '1';
              spr_opaque_c <= '1';
              spr_prio_c <= reg_d01b(i);
              case pair is
                when "01" => spr_color_c <= to_integer(unsigned(reg_d025));
                when "10" => spr_color_c <= to_integer(unsigned(reg_spr_col(i)));
                when others => spr_color_c <= to_integer(unsigned(reg_d026));
              end case;
            end if;
          else
            bit_pos := 23 - bit_x;
            if spr_linebuf(i)(bit_pos) = '1' then
              mask(i) := '1';
              spr_opaque_c <= '1';
              spr_prio_c <= reg_d01b(i);
              spr_color_c <= to_integer(unsigned(reg_spr_col(i)));
            end if;
          end if;
        end if;
      end loop;
    end if;
    spr_mask_c <= mask;
  end process;

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
      bg1_d    <= bg1_index;
      bg2_d    <= bg2_index;
      bg3_d    <= bg3_index;
      bord_d   <= border_idx;
      scr_d    <= linebuf(col);
      bmp_d    <= bmpbuf(col);
      glyph_d  <= glyphbuf(col);
      col_d    <= colbuf(col);
      bmm_d    <= reg_d011(5);
      ecm_d    <= reg_d011(6);
      mcm_d    <= reg_d016_disp(4);
      chargen_d <= char_rom_visible;
      inb_d    <= in_border;
      intext_d <= in_text;
      spr_opaque_d <= spr_opaque_c;
      spr_prio_d <= spr_prio_c;
      spr_color_d <= spr_color_c;
      spr_mask_d <= spr_mask_c;
      hs_d <= hs_c; vs_d <= vs_c; de_d <= de_c;
    end if;
  end process;

  -- ----- register file + raster IRQ -----
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        reg_d011 <= x"1B"; reg_d012 <= x"00"; reg_d016 <= x"08";
        reg_d016_disp <= x"08";
        reg_d018 <= x"15"; reg_d020 <= x"E"; reg_d021 <= x"6";
        reg_d022 <= x"0"; reg_d023 <= x"0"; reg_d024 <= x"0";
        reg_spr_x_lo <= (others => (others => '0'));
        reg_spr_y <= (others => (others => '0'));
        reg_d010 <= x"00"; reg_d015 <= x"00"; reg_d017 <= x"00";
        reg_d01b <= x"00"; reg_d01c <= x"00"; reg_d01d <= x"00";
        reg_d025 <= x"0"; reg_d026 <= x"0"; reg_spr_col <= (others => x"0");
        reg_d01e <= x"00"; reg_d01f <= x"00";
        irq_latch <= (others => '0'); irq_en <= (others => '0');
        d01e_read_armed <= '1'; d01f_read_armed <= '1';
        raster_cmp <= (others => '0');
      else
        if hc = H_PILL - 1 then
          reg_d016_disp <= reg_d016;
        end if;

        -- Raster compare: latch IRQ when the logical C64 raster crosses the
        -- compare. Each C64 raster line spans two HDMI lines in this renderer.
        if hc = 0 and (vc mod 2) = 0 then
          if raster_v = raster_cmp then
            irq_latch(0) <= '1';
          end if;
        end if;

        if coll_bg_mask_c /= x"00" then
          if (coll_bg_mask_c and not reg_d01f) /= x"00" then
            irq_latch(1) <= '1';
          end if;
          reg_d01f <= reg_d01f or coll_bg_mask_c;
        end if;
        if coll_spr_mask_c /= x"00" then
          if (coll_spr_mask_c and not reg_d01e) /= x"00" then
            irq_latch(2) <= '1';
          end if;
          reg_d01e <= reg_d01e or coll_spr_mask_c;
        end if;

        if cs = '1' and we = '0' and addr = "011110" then
          if d01e_read_armed = '1' then
            reg_d01e <= x"00";
            d01e_read_armed <= '0';
          end if;
        else
          d01e_read_armed <= '1';
        end if;

        if cs = '1' and we = '0' and addr = "011111" then
          if d01f_read_armed = '1' then
            reg_d01f <= x"00";
            d01f_read_armed <= '0';
          end if;
        else
          d01f_read_armed <= '1';
        end if;

        if cs = '1' and we = '1' then
          if addr(5 downto 4) = "00" then                    -- $D000-$D00F
            if addr(0) = '0' then
              reg_spr_x_lo(to_integer(unsigned(addr(3 downto 1)))) <= din;
            else
              reg_spr_y(to_integer(unsigned(addr(3 downto 1)))) <= din;
            end if;
          else
            case addr is
              when "010000" => reg_d010 <= din;               -- $D010
              when "010001" => reg_d011 <= din;               -- $D011
                               raster_cmp(8) <= din(7);
              when "010010" => raster_cmp(7 downto 0) <= unsigned(din); -- $D012
              when "010101" => reg_d015 <= din;               -- $D015
              when "010110" => reg_d016 <= din;               -- $D016
              when "010111" => reg_d017 <= din;               -- $D017
              when "011000" => reg_d018 <= din;               -- $D018
              when "011001" => irq_latch <= irq_latch and not din(2 downto 0); -- $D019 ack
              when "011010" => irq_en <= din(2 downto 0);     -- $D01A
              when "011011" => reg_d01b <= din;               -- $D01B
              when "011100" => reg_d01c <= din;               -- $D01C
              when "011101" => reg_d01d <= din;               -- $D01D
              when "100000" => reg_d020 <= din(3 downto 0);   -- $D020
              when "100001" => reg_d021 <= din(3 downto 0);   -- $D021
              when "100010" => reg_d022 <= din(3 downto 0);   -- $D022
              when "100011" => reg_d023 <= din(3 downto 0);   -- $D023
              when "100100" => reg_d024 <= din(3 downto 0);   -- $D024
              when "100101" => reg_d025 <= din(3 downto 0);   -- $D025
              when "100110" => reg_d026 <= din(3 downto 0);   -- $D026
              when "100111" => reg_spr_col(0) <= din(3 downto 0); -- $D027
              when "101000" => reg_spr_col(1) <= din(3 downto 0);
              when "101001" => reg_spr_col(2) <= din(3 downto 0);
              when "101010" => reg_spr_col(3) <= din(3 downto 0);
              when "101011" => reg_spr_col(4) <= din(3 downto 0);
              when "101100" => reg_spr_col(5) <= din(3 downto 0);
              when "101101" => reg_spr_col(6) <= din(3 downto 0);
              when "101110" => reg_spr_col(7) <= din(3 downto 0);
              when others => null;
            end case;
          end if;
        end if;
      end if;
    end if;
  end process;

  irq_master <= '1' when irq_latch(0) = '1' and irq_en(0) = '1' else '0';
  irq_n <= '0' when irq_master = '1' else '1';

  -- Register read-back.
  process(addr, reg_spr_x_lo, reg_spr_y, reg_d010, reg_d011, reg_d015,
          reg_d016, reg_d017, reg_d018, reg_d01b, reg_d01c, reg_d01d,
          reg_d01e, reg_d01f,
          reg_d020, reg_d021, reg_d022, reg_d023, reg_d024, reg_d025,
          reg_d026, reg_spr_col,
          irq_latch, irq_en, irq_master, raster_v)
  begin
    if addr(5 downto 4) = "00" then
      if addr(0) = '0' then
        dout <= reg_spr_x_lo(to_integer(unsigned(addr(3 downto 1))));
      else
        dout <= reg_spr_y(to_integer(unsigned(addr(3 downto 1))));
      end if;
    else
      case addr is
        when "010000" => dout <= reg_d010;
        when "010001" => dout <= raster_v(8) & reg_d011(6 downto 0);
        when "010010" => dout <= std_logic_vector(raster_v(7 downto 0));
        when "010101" => dout <= reg_d015;
        when "010110" => dout <= reg_d016;
        when "010111" => dout <= reg_d017;
        when "011000" => dout <= reg_d018;
        when "011001" => dout <= irq_master & "000000" & irq_latch(0);
        when "011010" => dout <= "00000" & irq_en;
        when "011011" => dout <= reg_d01b;
        when "011100" => dout <= reg_d01c;
        when "011101" => dout <= reg_d01d;
        when "011110" => dout <= reg_d01e;
        when "011111" => dout <= reg_d01f;
        when "100000" => dout <= x"F" & reg_d020;
        when "100001" => dout <= x"F" & reg_d021;
        when "100010" => dout <= x"F" & reg_d022;
        when "100011" => dout <= x"F" & reg_d023;
        when "100100" => dout <= x"F" & reg_d024;
        when "100101" => dout <= x"F" & reg_d025;
        when "100110" => dout <= x"F" & reg_d026;
        when "100111" => dout <= x"F" & reg_spr_col(0);
        when "101000" => dout <= x"F" & reg_spr_col(1);
        when "101001" => dout <= x"F" & reg_spr_col(2);
        when "101010" => dout <= x"F" & reg_spr_col(3);
        when "101011" => dout <= x"F" & reg_spr_col(4);
        when "101100" => dout <= x"F" & reg_spr_col(5);
        when "101101" => dout <= x"F" & reg_spr_col(6);
        when "101110" => dout <= x"F" & reg_spr_col(7);
        when others   => dout <= x"FF";
      end case;
    end if;
  end process;

  -- ----- stage 1->2: combinational palette from stage-1 registers -----
  -- Pixel decisions are combinational but only from stage-1 registers
  -- (plus char_data, which is aligned with them by the CHARGEN read latency).
  glyph_byte <= char_data when chargen_d = '1' else glyph_d;
  char_pbit <= glyph_byte(7 - cpix_d) when intext_d = '1' else '0';
  bmp_pbit  <= bmp_d(7 - cpix_d) when intext_d = '1' else '0';
  mc_pair   <= bmp_d(7 - 2 * (cpix_d / 2) downto 6 - 2 * (cpix_d / 2))
               when bmm_d = '1' else
               glyph_byte(7 - 2 * (cpix_d / 2) downto 6 - 2 * (cpix_d / 2));

  process(inb_d, intext_d, bmm_d, mcm_d, ecm_d, char_pbit, bmp_pbit, mc_pair,
          fg_d, bg_d, bg1_d, bg2_d, bg3_d, bord_d, scr_d, col_d,
          spr_opaque_d, spr_prio_d, spr_color_d, spr_mask_d)
    variable base_idx : natural range 0 to 15;
    variable base_bg  : std_logic;
    variable spr_count : natural range 0 to 8;
  begin
    base_bg := '0';
    spr_count := 0;
    if inb_d = '1' then
      base_idx := bord_d;
      base_bg := '1';
    elsif intext_d = '0' then
      base_idx := bg_d;
      base_bg := '1';
    elsif bmm_d = '1' then
      if mcm_d = '1' then
        case mc_pair is
          when "00" => base_idx := bg_d; base_bg := '1';
          when "01" => base_idx := to_integer(unsigned(scr_d(7 downto 4)));
          when "10" => base_idx := to_integer(unsigned(scr_d(3 downto 0)));
          when others => base_idx := to_integer(unsigned(col_d));
        end case;
      elsif bmp_pbit = '1' then
        base_idx := to_integer(unsigned(scr_d(7 downto 4)));
      else
        base_idx := to_integer(unsigned(scr_d(3 downto 0)));
        base_bg := '1';
      end if;
    elsif ecm_d = '1' then
      if char_pbit = '1' then
        base_idx := fg_d;
      else
        case scr_d(7 downto 6) is
          when "00" => base_idx := bg_d;
          when "01" => base_idx := bg1_d;
          when "10" => base_idx := bg2_d;
          when others => base_idx := bg3_d;
        end case;
        base_bg := '1';
      end if;
    elsif mcm_d = '1' and col_d(3) = '1' then
      case mc_pair is
        when "00" => base_idx := bg_d; base_bg := '1';
        when "01" => base_idx := bg1_d;
        when "10" => base_idx := bg2_d;
        when others => base_idx := to_integer(unsigned('0' & col_d(2 downto 0)));
      end case;
    elsif char_pbit = '1' then
      base_idx := fg_d;
    else
      base_idx := bg_d;
      base_bg := '1';
    end if;

    for i in 0 to 7 loop
      if spr_mask_d(i) = '1' then
        spr_count := spr_count + 1;
      end if;
    end loop;

    if spr_count >= 2 then
      coll_spr_mask_c <= spr_mask_d;
    else
      coll_spr_mask_c <= x"00";
    end if;

    if base_bg = '0' then
      coll_bg_mask_c <= spr_mask_d;
    else
      coll_bg_mask_c <= x"00";
    end if;

    if spr_opaque_d = '1' and (spr_prio_d = '0' or base_bg = '1') then
      pix_idx <= spr_color_d;
    else
      pix_idx <= base_idx;
    end if;
  end process;

  vga_r_c <= PAL_R(pix_idx);
  vga_g_c <= PAL_G(pix_idx);
  vga_b_c <= PAL_B(pix_idx);

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
