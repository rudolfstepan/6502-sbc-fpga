-- Text-console core for the sys16 HDMI "graphics card": the testable
-- half of sys16_hdmi_text (no PLL / no DVI serialiser, so GHDL can drive
-- clk_pix directly and observe the rendered pixels).
--
-- 80x25 character cells, 8x16 glyphs, scaled 2x horizontally and 1.75x
-- vertically (16x28 screen pixels per cell) ->
-- 1280x700 content, centred in CEA 1280x720. One 16-bit cell per character:
-- low byte = code, high byte =
-- VGA-style attribute (fg = attr[3:0], bg = attr[7:4], both 16 colours).
--
-- Why this is fast where the pixel framebuffer was slow: the CPU writes
-- TWO bytes per character (code + attribute) instead of 16x16x2 = 512
-- bytes of pixels, and a scroll moves the tiny 3.5 KB cell array (or, with
-- the start-row register, nothing at all) instead of a 259 KB pixel
-- memmove. Rendering is done here in hardware from the font ROM.
--
-- The character array is four sys16_fb_ram8 byte banks (dual-clock, the
-- same block used by the pixel framebuffer): port A is the CPU (bus
-- clock), port B the scanout (pixel clock) -- the CDC boundary, no
-- handshake. Two cells per 32-bit word; 80 is even so each row is exactly
-- 40 words and no cell straddles a word.
--
-- Register window (addr(23) = 1), addr(5:2) selects:
--   0x00 ID       "S16T" = 0x53313654 (RO)
--   0x04 CTRL     bit0 enable, bit1 test pattern, bit2 diag stripe
--   0x08 STATUS   bit0 vblank, [31:16] frame counter (RO)
--   0x0C CURSOR   [6:0] col, [12:8] row, [16] enable
--   0x10 GEOM     [7:0] cols, [15:8] rows, [23:16] cell_w, [31:24] cell_h (RO)
--   0x14 START    [4:0] hardware scroll: first cell row shown at screen top
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sys16_font_pkg.all;

entity sys16_text_core is
  generic (
    COLS      : natural := 80;
    ROWS      : natural := 25;
    H_ACTIVE  : natural := 1280;
    H_FP      : natural := 110;
    H_SYNC    : natural := 40;
    H_BP      : natural := 220;
    V_ACTIVE  : natural := 720;
    V_FP      : natural := 5;
    V_SYNC    : natural := 5;
    V_BP      : natural := 20
  );
  port (
    -- bus clock domain (50 MHz), bus32 device port
    clk_in    : in  std_logic;
    reset_n   : in  std_logic;
    req       : in  std_logic;
    we        : in  std_logic;
    addr      : in  std_logic_vector(23 downto 0);
    be        : in  std_logic_vector(3 downto 0);
    wdata     : in  std_logic_vector(31 downto 0);
    rdata     : out std_logic_vector(31 downto 0);
    ready     : out std_logic;
    boot_data : in std_logic_vector(7 downto 0) := (others => '0');
    boot_valid: in std_logic := '0';
    status_word : in std_logic_vector(15 downto 0);
    -- pixel clock domain (75 MHz), video output
    clk_pix   : in  std_logic;
    reset_pix : in  std_logic;          -- active-high, synchronous to clk_pix
    de        : out std_logic;
    hsync     : out std_logic;
    vsync     : out std_logic;
    pixel_data: out std_logic_vector(23 downto 0);
    -- debug (for the testbench; leave open in synthesis)
    dbg_x     : out std_logic_vector(10 downto 0);
    dbg_y     : out std_logic_vector(9 downto 0)
  );
end entity;

architecture rtl of sys16_text_core is
  constant H_TOTAL : natural := H_ACTIVE + H_FP + H_SYNC + H_BP;
  constant V_TOTAL : natural := V_ACTIVE + V_FP + V_SYNC + V_BP;

  constant CELL_W  : natural := 16;   -- 8 glyph px x 2
  constant CELL_H  : natural := 28;   -- 16 glyph px stretched to 28
  constant CONT_W  : natural := COLS * CELL_W;                 -- 1280
  constant CONT_H  : natural := ROWS * CELL_H;                 -- 700
  constant XBORDER : natural := (H_ACTIVE - CONT_W) / 2;       -- 0
  constant YBORDER : natural := (V_ACTIVE - CONT_H) / 2;       -- 10
  constant WORDS_PL: natural := COLS / 2;                      -- 40 words/row
  constant CRAM_W  : natural := WORDS_PL * ROWS;               -- 1000 words
  constant CRAM_AW : natural := 10;                            -- 2**10 = 1024
  constant LOOKAHEAD : natural := 6;   -- prefetch pipeline depth (see below)

  subtype glyph_row_t is unsigned(3 downto 0);
  function glyph_row_28(p : natural) return glyph_row_t is
  begin
    case p is
      when 0 | 1   => return to_unsigned(0, 4);
      when 2 | 3   => return to_unsigned(1, 4);
      when 4 | 5   => return to_unsigned(2, 4);
      when 6       => return to_unsigned(3, 4);
      when 7 | 8   => return to_unsigned(4, 4);
      when 9 | 10  => return to_unsigned(5, 4);
      when 11 | 12 => return to_unsigned(6, 4);
      when 13      => return to_unsigned(7, 4);
      when 14 | 15 => return to_unsigned(8, 4);
      when 16 | 17 => return to_unsigned(9, 4);
      when 18 | 19 => return to_unsigned(10, 4);
      when 20      => return to_unsigned(11, 4);
      when 21 | 22 => return to_unsigned(12, 4);
      when 23 | 24 => return to_unsigned(13, 4);
      when 25 | 26 => return to_unsigned(14, 4);
      when others  => return to_unsigned(15, 4);
    end case;
  end function;

  -- 16-colour palette -> RGB888 (standard VGA/CGA).
  type pal_t is array (0 to 15) of std_logic_vector(23 downto 0);
  constant PAL : pal_t := (
    0  => x"000000", 1  => x"0000AA", 2  => x"00AA00", 3  => x"00AAAA",
    4  => x"AA0000", 5  => x"AA00AA", 6  => x"AA5500", 7  => x"AAAAAA",
    8  => x"555555", 9  => x"5555FF", 10 => x"55FF55", 11 => x"55FFFF",
    12 => x"FF5555", 13 => x"FF55FF", 14 => x"FFFF55", 15 => x"FFFFFF");

  -- font ROM (registered read, one BSRAM)
  signal font_byte : std_logic_vector(7 downto 0) := (others => '0');

  -- char RAM banks
  signal cram_qa   : std_logic_vector(31 downto 0);
  signal cram_qb   : std_logic_vector(31 downto 0);
  signal cram_wea  : std_logic_vector(3 downto 0);
  signal cpu_widx  : std_logic_vector(CRAM_AW-1 downto 0);
  signal ram_widx  : std_logic_vector(CRAM_AW-1 downto 0);
  signal ram_wdata : std_logic_vector(31 downto 0);
  signal boot_wea  : std_logic_vector(3 downto 0) := (others => '0');
  signal boot_widx : std_logic_vector(CRAM_AW-1 downto 0) := (others => '0');
  signal boot_wdata: std_logic_vector(31 downto 0) := (others => '0');
  signal boot_wen  : std_logic := '0';
  signal saddr_r   : std_logic_vector(CRAM_AW-1 downto 0) := (others => '0');

  -- bus domain
  type bus_state_t is (B_IDLE, B_RDWAIT, B_RDWAIT2, B_RESP);
  signal bus_state : bus_state_t := B_IDLE;
  signal rdata_r   : std_logic_vector(31 downto 0) := (others => '0');
  signal ctrl_reg  : std_logic_vector(2 downto 0) := "001";  -- enabled, blank RAM
  signal boot_enable : std_logic := '1';
  signal boot_col : natural range 0 to COLS-1 := 0;
  signal boot_row : natural range 0 to ROWS-1 := 0;
  signal cur_col   : unsigned(6 downto 0) := (others => '0');
  signal cur_row   : unsigned(4 downto 0) := (others => '0');
  signal cur_en    : std_logic := '0';
  signal start_row : unsigned(4 downto 0) := (others => '0');
  signal frame_cnt : unsigned(15 downto 0) := (others => '0');
  signal vblank_m, vblank_s, vblank_p : std_logic := '0';
  signal sel_regs  : std_logic;
  signal reg_idx   : std_logic_vector(3 downto 0);

  -- pixel domain
  signal x        : unsigned(10 downto 0) := (others => '0');
  signal y        : unsigned(9 downto 0) := (others => '0');
  signal scan_row : natural range 0 to ROWS-1 := 0;
  signal scan_y_cell : natural range 0 to CELL_H-1 := 0;
  signal active   : std_logic;
  signal vblank_pix : std_logic;
  signal cur_blink : unsigned(24 downto 0) := (others => '0');
  -- CTRL synchronised into the pixel domain
  signal ctrl_meta, ctrl_sync : std_logic_vector(2 downto 0) := (others => '0');
  signal status_meta, status_sync : std_logic_vector(15 downto 0) := (others => '0');
  signal curcol_meta, curcol_sync : unsigned(6 downto 0) := (others => '0');
  signal currow_meta, currow_sync : unsigned(4 downto 0) := (others => '0');
  signal curen_meta, curen_sync   : std_logic := '0';
  signal strt_meta, strt_sync     : unsigned(4 downto 0) := (others => '0');

  -- scanout pipeline (control aligned to the char-RAM/font-ROM latency)
  signal fetch_row_0 : unsigned(4 downto 0) := (others => '0');
  signal fetch_col_0 : unsigned(6 downto 0) := (others => '0');
  signal frow_0      : unsigned(3 downto 0) := (others => '0');
  signal testp_0     : std_logic := '0';
  signal frow_1, frow_2, frow_3 : unsigned(3 downto 0) := (others => '0');
  signal half_1, half_2, half_3 : std_logic := '0';
  signal testp_1, testp_2, testp_3 : std_logic := '0';
  signal tchar_1, tchar_2, tchar_3 : std_logic_vector(7 downto 0) := (others => '0');
  signal attr_4, attr_5 : std_logic_vector(7 downto 0) := (others => '0');
  signal fa_r     : std_logic_vector(11 downto 0) := (others => '0');
begin
  ------------------------------------------------------------------ bus side
  sel_regs <= addr(23);
  reg_idx  <= addr(5 downto 2);
  cpu_widx <= addr(CRAM_AW+1 downto 2);   -- 32-bit word index into the cells
  ram_widx <= boot_widx when boot_wen = '1' else cpu_widx;
  ram_wdata <= boot_wdata when boot_wen = '1' else wdata;
  rdata    <= rdata_r;
  ready    <= '1' when bus_state = B_RESP else '0';

  -- CPU cell writes: byte-enable strobes while leaving B_IDLE (a cell is
  -- 16 bit, so a 16-bit store hits two byte lanes of one 32-bit word).
  wea_g : for i in 0 to 3 generate
    cram_wea(i) <= boot_wea(i) when boot_wen = '1' else
                   '1' when bus_state = B_IDLE and req = '1' and we = '1'
                            and sel_regs = '0' and be(i) = '1' else '0';
  end generate;

  banks : for i in 0 to 3 generate
    bank_i : entity work.sys16_fb_ram8
      generic map (DEPTH => CRAM_W, AW => CRAM_AW)
      port map (
        clka  => clk_in,  wea => cram_wea(i), addra => ram_widx,
        dina  => ram_wdata(8*i+7 downto 8*i), qa => cram_qa(8*i+7 downto 8*i),
        clkb  => clk_pix, addrb => saddr_r, qb => cram_qb(8*i+7 downto 8*i));
  end generate;

  bus_p : process(clk_in)
    variable cell_idx : natural range 0 to COLS*ROWS-1;
  begin
    if rising_edge(clk_in) then
      if reset_n = '0' then
        bus_state <= B_IDLE; ctrl_reg <= "001";
        boot_enable <= '1'; boot_col <= 0; boot_row <= 0;
        boot_wen <= '0'; boot_wea <= (others => '0');
        cur_col <= (others => '0'); cur_row <= (others => '0'); cur_en <= '0';
        start_row <= (others => '0');
        frame_cnt <= (others => '0');
        vblank_m <= '0'; vblank_s <= '0'; vblank_p <= '0';
      else
        boot_wen <= '0';
        boot_wea <= (others => '0');
        -- Mirror the physical UART TX during ZSBL/OpenSBI/early Linux boot.
        -- The first Linux CTRL write atomically hands the RAM back to the VT
        -- driver, which then repaints the complete screen.
        if boot_enable = '1' and boot_valid = '1' then
          if boot_data = x"0D" then
            boot_col <= 0;
          elsif boot_data = x"0A" then
            boot_col <= 0;
            if boot_row = ROWS-1 then boot_row <= 0; else boot_row <= boot_row+1; end if;
          elsif unsigned(boot_data) >= 32 then
            cell_idx := boot_row * COLS + boot_col;
            boot_widx <= std_logic_vector(to_unsigned(cell_idx / 2, CRAM_AW));
            boot_wdata <= x"0F" & boot_data & x"0F" & boot_data;
            if (cell_idx mod 2) = 0 then boot_wea <= "0011";
            else                         boot_wea <= "1100"; end if;
            boot_wen <= '1';
            if boot_col = COLS-1 then
              boot_col <= 0;
              if boot_row = ROWS-1 then boot_row <= 0; else boot_row <= boot_row+1; end if;
            else boot_col <= boot_col+1; end if;
          end if;
        end if;
        vblank_m <= vblank_pix; vblank_s <= vblank_m; vblank_p <= vblank_s;
        if vblank_s = '1' and vblank_p = '0' then
          frame_cnt <= frame_cnt + 1;
        end if;

        case bus_state is
          when B_IDLE =>
            if req = '1' then
              if sel_regs = '1' and we = '1' then
                case reg_idx is
                  when "0001" => if be(0) = '1' then
                    ctrl_reg <= wdata(2 downto 0); boot_enable <= '0';
                  end if;
                  when "0011" =>
                    cur_col <= unsigned(wdata(6 downto 0));
                    cur_row <= unsigned(wdata(12 downto 8));
                    cur_en  <= wdata(16);
                  when "0101" => start_row <= unsigned(wdata(4 downto 0));
                  when others => null;
                end case;
                bus_state <= B_RESP;
              elsif we = '1' then
                bus_state <= B_RESP;       -- cell write strobed by wea_g
              else
                bus_state <= B_RDWAIT;
              end if;
            end if;
          when B_RDWAIT  => bus_state <= B_RDWAIT2;
          when B_RDWAIT2 =>
            if sel_regs = '1' then
              case reg_idx is
                when "0000" => rdata_r <= x"53313654";                       -- "S16T"
                when "0001" => rdata_r <= x"0000000" & '0' & ctrl_reg;
                when "0010" => rdata_r <= std_logic_vector(frame_cnt) &
                                          "000000000000000" & vblank_s;
                when "0011" => rdata_r <=
                     "000000000000000" & cur_en & "000" &
                     std_logic_vector(cur_row) & '0' & std_logic_vector(cur_col);
                when "0100" => rdata_r <=
                     std_logic_vector(to_unsigned(CELL_H,8)) &
                     std_logic_vector(to_unsigned(CELL_W,8)) &
                     std_logic_vector(to_unsigned(ROWS,8)) &
                     std_logic_vector(to_unsigned(COLS,8));
                when others => rdata_r <= (others => '0');
              end case;
            else
              rdata_r <= cram_qa;
            end if;
            bus_state <= B_RESP;
          when B_RESP =>
            if req = '0' then bus_state <= B_IDLE; end if;
        end case;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------- pixel side
  -- CEA 1280x720p video timing
  timing_p : process(clk_pix)
  begin
    if rising_edge(clk_pix) then
      if reset_pix = '1' then
        x <= (others => '0'); y <= (others => '0');
        scan_row <= 0; scan_y_cell <= 0;
        ctrl_meta <= (others => '0'); ctrl_sync <= (others => '0');
        status_meta <= (others => '0'); status_sync <= (others => '0');
        curcol_meta <= (others => '0'); curcol_sync <= (others => '0');
        currow_meta <= (others => '0'); currow_sync <= (others => '0');
        curen_meta <= '0'; curen_sync <= '0';
        strt_meta <= (others => '0'); strt_sync <= (others => '0');
        cur_blink <= (others => '0');
      else
        ctrl_meta <= ctrl_reg;   ctrl_sync <= ctrl_meta;
        status_meta <= status_word; status_sync <= status_meta;
        curcol_meta <= cur_col;  curcol_sync <= curcol_meta;
        currow_meta <= cur_row;  currow_sync <= currow_meta;
        curen_meta <= cur_en;    curen_sync <= curen_meta;
        strt_meta <= start_row;  strt_sync <= strt_meta;
        cur_blink <= cur_blink + 1;
        if x = to_unsigned(H_TOTAL-1, x'length) then
          x <= (others => '0');
          if y = to_unsigned(V_TOTAL-1, y'length) then
            y <= (others => '0');
            scan_row <= 0; scan_y_cell <= 0;
          else
            y <= y + 1;
            -- Track the text row once per scanline. This replaces division
            -- by 28 in the pixel path and keeps the 75 MHz timing shallow.
            if y = to_unsigned(YBORDER-1, y'length) then
              scan_row <= 0; scan_y_cell <= 0;
            elsif y >= to_unsigned(YBORDER, y'length) and
                  y < to_unsigned(YBORDER + CONT_H - 1, y'length) then
              if scan_y_cell = CELL_H-1 then
                scan_y_cell <= 0;
                if scan_row = ROWS-1 then scan_row <= 0;
                else scan_row <= scan_row + 1; end if;
              else
                scan_y_cell <= scan_y_cell + 1;
              end if;
            else
              scan_row <= 0; scan_y_cell <= 0;
            end if;
          end if;
        else
          x <= x + 1;
        end if;
      end if;
    end if;
  end process;

  active <= '1' when x < H_ACTIVE and y < V_ACTIVE else '0';
  hsync  <= '1' when x >= H_ACTIVE + H_FP and x < H_ACTIVE + H_FP + H_SYNC else '0';
  vsync  <= '1' when y >= V_ACTIVE + V_FP and y < V_ACTIVE + V_FP + V_SYNC else '0';
  vblank_pix <= '1' when y >= V_ACTIVE else '0';
  de     <= active;
  dbg_x  <= std_logic_vector(x);
  dbg_y  <= std_logic_vector(y);

  -- Prefetch pipeline. The character byte and the glyph row emerge from
  -- the char RAM (2 cycles) and font ROM (2 cycles); we present the cell
  -- address LOOKAHEAD pixels ahead of the beam and delay the control bits
  -- to match, so font_byte at the output stage is exactly the cell the
  -- beam is in. Everything positional (in-window, glyph column, cursor,
  -- border, diag stripe) is recomputed from x,y at the output, so only
  -- the character/attribute/glyph-row data flows through the pipeline.
  fetch_p : process(clk_pix)
    variable nx    : unsigned(10 downto 0);
    variable ny    : unsigned(9 downto 0);
    variable rowp  : unsigned(4 downto 0);
    variable lrow  : unsigned(4 downto 0);
    variable colp  : unsigned(6 downto 0);
    variable cell_y: natural range 0 to CELL_H-1;
    variable in_c  : boolean;
    variable char3 : std_logic_vector(7 downto 0);
    variable tcode : unsigned(12 downto 0);
  begin
    if rising_edge(clk_pix) then
      -- beam + lookahead, wrapping across the line/frame like sys16_hdmi_fb
      if x < to_unsigned(H_TOTAL - LOOKAHEAD, x'length) then
        nx := x + LOOKAHEAD; ny := y;
      else
        nx := x + LOOKAHEAD - to_unsigned(H_TOTAL, x'length);
        if y = to_unsigned(V_TOTAL-1, y'length) then ny := (others => '0');
        else ny := y + 1; end if;
      end if;

      in_c := (ny >= YBORDER) and (ny < YBORDER + CONT_H) and (nx < CONT_W);
      if in_c then
        -- Usually lookahead remains on the current scanline. For the final
        -- five pixels it wraps to the next line, so advance a local copy of
        -- the line counters without putting a divider in the pixel path.
        lrow := to_unsigned(scan_row, lrow'length);
        cell_y := scan_y_cell;
        if ny /= y then
          if y = to_unsigned(YBORDER-1, y'length) then
            lrow := (others => '0'); cell_y := 0;
          elsif scan_y_cell = CELL_H-1 then
            cell_y := 0;
            if scan_row = ROWS-1 then lrow := (others => '0');
            else lrow := to_unsigned(scan_row + 1, lrow'length); end if;
          else
            cell_y := scan_y_cell + 1;
          end if;
        end if;
        -- logical cell row, offset by the hardware scroll start row (mod ROWS)
        rowp := lrow + strt_sync;
        if rowp >= ROWS then rowp := rowp - ROWS; end if;
        colp := nx(10 downto 4);
        -- Integer arithmetic: "unsigned * natural" would coerce WORDS_PL/COLS
        -- into the operand's narrow width and silently wrap (40 -> 8, 80 -> 16).
        -- Register row/column before the address multipliers. Besides making
        -- the 28-line scaler cheap, this cuts the x-to-BSRAM path at 75 MHz.
        fetch_row_0 <= rowp;
        fetch_col_0 <= colp;
        frow_0 <= glyph_row_28(cell_y);
        testp_0 <= ctrl_sync(1);
      else
        fetch_row_0 <= (others => '0');
        fetch_col_0 <= (others => '0');
        frow_0 <= (others => '0');
        testp_0 <= ctrl_sync(1);
      end if;

      saddr_r <= std_logic_vector(to_unsigned(
                   to_integer(fetch_row_0) * WORDS_PL +
                   to_integer(fetch_col_0(6 downto 1)), CRAM_AW));
      frow_1  <= frow_0;
      half_1  <= fetch_col_0(0);
      testp_1 <= testp_0;
      tcode   := to_unsigned(to_integer(fetch_row_0) * COLS +
                             to_integer(fetch_col_0), tcode'length);
      tchar_1 <= std_logic_vector(tcode(7 downto 0));          -- mod 256

      -- align control with the 2-cycle char-RAM read
      frow_2 <= frow_1; frow_3 <= frow_2;
      half_2 <= half_1; half_3 <= half_2;
      testp_2 <= testp_1; testp_3 <= testp_2;
      tchar_2 <= tchar_1; tchar_3 <= tchar_2;

      -- char RAM output valid now (aligned with frow_3/half_3): pick the cell
      if half_3 = '1' then char3 := cram_qb(23 downto 16);
      else                 char3 := cram_qb(7 downto 0); end if;
      if testp_3 = '1' then char3 := tchar_3; end if;
      if half_3 = '1' then attr_4 <= cram_qb(31 downto 24);
      else                 attr_4 <= cram_qb(15 downto 8); end if;
      if testp_3 = '1' then attr_4 <= x"0F"; end if;   -- white on black

      fa_r <= char3 & std_logic_vector(frow_3);
      attr_5 <= attr_4;
      font_byte <= FONT_8X16(to_integer(unsigned(fa_r)));
    end if;
  end process;

  -- Output mux, recomputed from the current beam position.
  paint_p : process(x, y, active, font_byte, attr_5, ctrl_sync, status_sync,
                    curcol_sync, currow_sync, curen_sync, strt_sync, cur_blink,
                    scan_row)
    variable gx     : integer range 0 to 7;
    variable colc   : unsigned(6 downto 0);
    variable rowc   : unsigned(4 downto 0);   -- logical cell row
    variable inwin  : boolean;
    variable fgpix  : boolean;
    variable fg, bg : integer range 0 to 15;
    variable rgb    : std_logic_vector(23 downto 0);
    variable status_rgb : std_logic_vector(23 downto 0);
    variable cur_hit: boolean;
  begin
    inwin := (y >= YBORDER) and (y < YBORDER + CONT_H) and (x < CONT_W);
    gx    := to_integer(x(3 downto 1));           -- 2x horizontal
    colc  := x(10 downto 4);
    -- logical row of the displayed cell (screen cell row + scroll start)
    rowc := to_unsigned(scan_row, rowc'length) + strt_sync;
    if rowc >= ROWS then rowc := rowc - ROWS; end if;

    fgpix := font_byte(7 - gx) = '1';
    fg := to_integer(unsigned(attr_5(3 downto 0)));
    bg := to_integer(unsigned(attr_5(7 downto 4)));

    -- block cursor: blink ~1 Hz, invert the whole cell. Cursor position is
    -- in logical console coordinates, compared against the logical row.
    cur_hit := (curen_sync = '1') and inwin and
               (colc = curcol_sync) and (rowc = currow_sync) and
               (cur_blink(24) = '1');
    if cur_hit then fgpix := not fgpix; end if;

    if fgpix then rgb := PAL(fg); else rgb := PAL(bg); end if;

    status_rgb := status_sync(15 downto 11) & status_sync(15 downto 13) &
                  status_sync(10 downto 5)  & status_sync(10 downto 9) &
                  status_sync(4 downto 0)   & status_sync(4 downto 2);

    if active = '0' then
      pixel_data <= x"000000";
    elsif ctrl_sync(2) = '1' and y < to_unsigned(16, y'length) then
      pixel_data <= status_rgb;             -- diagnostic stripe (top 16 lines)
    elsif inwin = false then
      pixel_data <= x"000000";              -- border
    elsif ctrl_sync(0) = '0' then
      pixel_data <= x"000000";              -- disabled
    else
      pixel_data <= rgb;
    end if;
  end process;
end architecture;
