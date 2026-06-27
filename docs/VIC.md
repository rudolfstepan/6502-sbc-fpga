# VIC Video Controller

The **VIC** ([`rtl/core/peripherals/vic_vga.vhd`](../rtl/core/peripherals/vic_vga.vhd))
is the video display controller. It produces an 858×525 (CEA-861 480p / VGA
640×480-class) raster and supports a 40×25 text mode plus several bitmap graphics
modes. It is **bus-stealing** (C64-style): during horizontal blanking it borrows
a few CPU cycles to pre-fetch the next scanline into an internal line buffer, so
no dual-port RAM is needed. The CPU is held via `RDY` during the steal.

The pixel output (`vga_r/g/b`, `vga_hs/vs/de`) feeds the board's HDMI/TMDS
encoder ([`tang20k_hdmi_tx.vhd`](../boards/tang_primer_20k/rtl/tang20k_hdmi_tx.vhd))
on the Tang Primer 20K, or analog VGA on the PIX16 board.

## Files

- RTL: [`rtl/core/peripherals/vic_vga.vhd`](../rtl/core/peripherals/vic_vga.vhd) — scan counters, bus-steal line fetch, text + bitmap rendering, palette
- Char ROM: [`rtl/core/mem/char_rom.vhd`](../rtl/core/mem/char_rom.vhd) — 256 glyphs, 8×8 (see [German keyboard / char ROM](./02_MODULES.md))
- Framebuffer RAM: [`rtl/core/mem/fb_ram.vhd`](../rtl/core/mem/fb_ram.vhd) — exact-depth (38400 B) BSRAM for the 320×240 mode
- Integration: [`rtl/core/sbc_t65_boot_monitor_top.vhd`](../rtl/core/sbc_t65_boot_monitor_top.vhd) — register file, bitmap RAM, bank/address mux
- Testbenches: `sim/tb/tb_vic_core.vhd`, `tb_vic_pixel_gen.vhd`, `tb_vic_color256.vhd`, `tb_vic_color64.vhd`, `tb_vic_color16.vhd`, `tb_vic_raster_irq.vhd`, `tb_sbc_vic_display.vhd`

## Display Timing

| Property | Value |
| --- | --- |
| Total | 858 × 525 |
| Active (Tang, `CEA_480P=true`) | 720 × 480, native 640-wide content pillarboxed (40 px border L/R) |
| Active (PIX16, `CEA_480P=false`) | 640 × 480 in the 858×525 hybrid |
| Pixel clock | 27 MHz (Tang, `CLK_DIV=1`) → 31.47 kHz H, 59.94 Hz V; or 25 MHz (`CLK_DIV=2`) |
| Sync | active-low `vga_hs`/`vga_vs`; `vga_de` high during active video |

The exact CEA-861 480p totals make USB HDMI capture devices lock on; the HDMI
data-island / AVI-InfoFrame side lives in
[`hdmi_encoder.vhd`](../rtl/core/hdmi/hdmi_encoder.vhd).

## Register Map (`$9000`–`$900F`, `DEV_VIC_REG`)

Only offsets 0–4 are decoded ([`sbc_t65_boot_monitor_top.vhd`](../rtl/core/sbc_t65_boot_monitor_top.vhd)).

| Address | Offset | Register | Function |
| --- | --- | --- | --- |
| `$9000` | +0 | MODE | Display mode select (see bit table) |
| `$9001` | +1 | CURSOR_X | Text cursor column 0–39 (writes ≥40 ignored) |
| `$9002` | +2 | CURSOR_Y | Text cursor row 0–24 (writes ≥25 ignored) |
| `$9003` | +3 | TEXT_COLOR | Default text colour register |
| `$9004` | +4 | BG_COLOR | Default background colour register |

A long reset clears MODE to `$00` (text mode) so a returning BASIC text screen is
never hidden behind a leftover bitmap — see [Reset architecture](./02_MODULES.md).
Border and background colour live in the separate VIC-II register block at
`$D020`/`$D021` (below), not here; `$9003`/`$9004` are legacy and not wired to the
display.

### MODE bits (`$9000`)

| Bit | Name | Meaning |
| --- | --- | --- |
| 0 | BITMAP | Enable bitmap mode (0 = text) |
| 1 | COLOR256 | 160×100 RGB332 (one byte = one pixel) |
| 2 | BANK | Legacy 1-bit bitmap bank (COLOR256/COLOR64) |
| 3 | COLOR64 | 180×120 packed RGB222 |
| 4 | COLOR16 | **320×240 4 bpp / 16-colour palette** |
| 7:5 | BANK16 | 3-bit framebuffer bank (0–4) for COLOR16 |

Set BITMAP (bit 0) together with exactly one sub-mode bit. COLOR16 has priority in
the renderer if multiple are set.

## VIC-II Colour Registers (`$D020`–`$D02F`)

For C64 compatibility there is a small VIC-II-style colour register file at the
C64 addresses, decoded as `DEV_VICII`. All 16 bytes are read/write (so classic
pokes — including sprite-colour pokes — land in real registers); two of them
drive the display:

| Address | C64 POKE | Register | Effect |
| --- | --- | --- | --- |
| `$D020` | `POKE 53280,c` | BORDER | Colour of the visible area outside the active text/bitmap content |
| `$D021` | `POKE 53281,c` | BACKGROUND | Global text background (behind characters) |
| `$D022`–`$D02F` | — | (stored) | Read/write only; not yet wired to the display |

Only the low nibble (palette index 0–15) is used. Both default to 0 (black), so
the original look is unchanged until poked. *Why this exists:* it lets standard
C64 BASIC/assembly set border and background the familiar way. The border itself
is rendered by `vic_vga`; the value is held in the top-level register file and
fed in as `border_color`/`bg_color`.

## Text Mode (default)

40×25 characters, each cell scaled 2× to 16×16 screen pixels (400 px tall, 40 px
top/bottom border). For each scanline the VIC fetches:

- **character codes** from `$8000`+ (`row*40 + col`)
- **colour attributes** from `$8400`+ — low nibble = per-cell **foreground** index

The background is **global**, from the VIC-II `$D021` register (C64 text-mode
model): every character cell shares the same background colour, while the
foreground stays per-cell. (Previously the colour attribute's high nibble was a
per-cell background; that was changed to the global `$D021` for C64
compatibility, so `POKE 53281,c` sets the screen background.) Default `$D021`=0
keeps the original black background.

Glyphs come combinationally from the char ROM. `char_code(7)` selects the upper
128 glyphs (German umlauts) via `glyph_hi` rather than reverse-video. A blinking
cursor is OR-overlaid on the lower scanlines of the cell at (CURSOR_X, CURSOR_Y).
Colours use the 16-entry palette below.

## Bitmap Modes

All bitmap pixel data lives in a banked framebuffer RAM addressed through the CPU
window **`$6000`–`$7FFF`** (8 KiB/bank, `ADDR_VIC_BMP_BASE`). The VIC fetches it
framebuffer-relative during the steal, independent of the CPU bank bits.

| Mode (MODE bits) | Resolution | Format | Bytes | Bank bits |
| --- | --- | --- | --- | --- |
| COLOR256 (`0x03`) | 160×100 | RGB332, 1 px/byte | 16000 | bit 2 |
| COLOR64 (`0x09`) | 180×120 | RGB222, 4 px / 3 bytes | 16200 | bit 2 |
| COLOR16 (`0x11`) | 320×240 | 4 bpp palette, 2 px/byte | 38400 | bits 7:5 |

COLOR256/COLOR64 expand their packed colour directly to the DAC (no palette).
COLOR16 looks up the 16-colour palette.

### COLOR16 — 320×240, 16 colours

The flagship bitmap mode. The framebuffer is **38400 bytes** held in BSRAM
(`fb_ram`, sized to exactly 38400 so Gowin packs ~19 of the 46 block-RAMs instead
of rounding a 16-bit address up to a 64 KiB / 32-block array). Each line is
160 bytes.

**Displayed 1:1 (no scaling), centred** in the active area, framed by the
border. One framebuffer pixel = one screen pixel; the image occupies a
320×240 window in the middle and the `$D020` border colour fills the rest.
(Earlier revisions upscaled it 2× to 640×480 — that was dropped because the
upscale looked stretched on the CEA-480p output. Use a 2× variant only if a
larger image is wanted at the cost of sharpness.)

**Pixel layout** — one byte holds two horizontally adjacent pixels:

```
byte = y * 160 + (x / 2)          ; y = 0..239, x = 0..319
even x -> low nibble  [3:0]
odd  x -> high nibble [7:4]
colour = palette index 0..15
```

**CPU access** through the banked window:

```
bank   = byte / 8192              ; 0..4 (VIC_MODE bits 7:5)
offset = byte mod 8192            ; CPU address = $6000 + offset
```

Because two pixels share a byte, plotting a single pixel is a read-modify-write.
Writing whole bytes (two same-colour pixels, or a precomputed line) avoids the RMW.

Example — enable the mode and select bank 0:

```asm
lda #$11        ; bit0 BITMAP + bit4 COLOR16, bank 0 (bits 7:5 = 0)
sta $9000
```

A worked example that fills the screen with 16 vertical colour bars is in
[`sw/fb16_test.s`](../sw/fb16_test.s) → `roms/fb16_test.rom` (upload via
`roms/upload/fb16_test.bat`).

## 16-Colour Palette

The renderer uses the C64 (Pepto) palette, expanded to RGB565. Text mode and
COLOR16 both index it.

| # | Colour | # | Colour |
| --- | --- | --- | --- |
| 0 | black | 8 | orange |
| 1 | white | 9 | brown |
| 2 | red | 10 | light red |
| 3 | cyan | 11 | dark grey |
| 4 | purple | 12 | grey |
| 5 | green | 13 | light green |
| 6 | blue | 14 | light blue |
| 7 | yellow | 15 | light grey |

## Bus-Stealing Architecture

During each line's H-blank the fetch FSM borrows CPU cycles and reads the next
line into a 160-byte line buffer (`linebuf`, distributed RAM) — character codes
then colours in text mode, or one packed pixel line in bitmap modes. `vic_addr`
is presented one cycle ahead of the synchronous RAM data. During the visible line
the CPU runs unhindered and the renderer streams pixels from the line buffer, so a
single-port BSRAM suffices. CPU bitmap writes that collide with a steal are
deferred (`bitmap_wr_pending`) and committed on the next non-steal cycle, with the
CPU stalled so no write is lost.

## See Also

- [Modules Reference](./02_MODULES.md) — char ROM, reset behaviour, device map
- [Architecture](./01_ARCHITECTURE.md) — system design and memory map
- [Tang Primer 20K Guide](../boards/tang_primer_20k/README.md) — HDMI output and board specifics
