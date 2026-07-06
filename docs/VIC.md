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

Only offsets 0–5 are decoded ([`sbc_t65_boot_monitor_top.vhd`](../rtl/core/sbc_t65_boot_monitor_top.vhd)).

| Address | Offset | Register | Function |
| --- | --- | --- | --- |
| `$9000` | +0 | MODE | Display mode select (see bit table) |
| `$9001` | +1 | CURSOR_X | Text cursor column 0–39 (writes ≥40 ignored) |
| `$9002` | +2 | CURSOR_Y | Text cursor row 0–24 (writes ≥25 ignored) |
| `$9003` | +3 | TEXT_COLOR | Default text colour register (legacy, not wired to display) |
| `$9004` | +4 | BG_COLOR | Default background colour register (legacy, not wired to display) |
| `$9005` | +5 | TEXT_ATTR | bit0 = per-cell text background (colour-RAM high nibble) |

`TEXT_ATTR` bit 0 switches the text background source: `0` (default) keeps the
C64 model — global background from `$D021`, per-cell foreground from colour RAM;
`1` takes the background from each cell's colour-RAM **high** nibble (foreground
stays the low nibble), so an app can paint coloured square tiles (e.g. the chess
board). It is cleared on `cpu_reset_n`, like MODE, so a returning BASIC text
screen keeps the global background.

A long reset clears MODE to `$00` (text mode) so a returning BASIC text screen is
never hidden behind a leftover bitmap — see [Reset architecture](./02_MODULES.md).
Border and background colour live in the separate VIC-II register block at
`$D020`/`$D021` (below), not here; `$9003`/`$9004` are legacy and not wired to the
display.

### MODE bits (`$9000`)

> **Tang Primer 20K SBC:** the framebuffer moved from BSRAM (`fb_ram`) to **DDR3**
> (`vic_fb_ddr3`), which retired the legacy modes below. The live modes there are
> **bit 4** = 320×200 8bpp RGB332 (bank `$9000[7:5]`), **bit 5** = 640×400 8bpp
> (bank `$9006`), **bit 6** = 320×200 16bpp RGB565 (bank `$9006`). See
> [boards/tang_primer_20k/sbc/README.md](../boards/tang_primer_20k/sbc/README.md).
> The table below documents the older BSRAM modes (still used by the non-DDR3 tops).

| Bit | Name | Meaning |
| --- | --- | --- |
| 0 | BITMAP | Enable bitmap mode (0 = text) |
| 1 | COLOR256 | 160×100 RGB332 (one byte = one pixel) |
| 2 | BANK | Legacy 1-bit bitmap bank (COLOR256/COLOR64) |
| 3 | COLOR64 | 180×120 packed RGB222 |
| 4 | COLOR16 | **320×240 4 bpp / 16-colour palette** (legacy BSRAM) |
| 7:5 | BANK16 | 3-bit framebuffer bank (0–4) for COLOR16 |

Set BITMAP (bit 0) together with exactly one sub-mode bit. COLOR16 has priority in
the renderer if multiple are set.

## VIC-II Register Block (`$D000`–`$D03F`)

For C64 compatibility there is a VIC-II-style register block at the C64 addresses,
decoded as `DEV_VICII`. All 64 bytes are read/write (so classic pokes — including
sprite-position and sprite-colour pokes — land in real registers). A few have
live behaviour:

| Address | C64 POKE / read | Register | Effect |
| --- | --- | --- | --- |
| `$D011` | `PEEK 53265` | CONTROL 1 | Bits 0–6 stored; **read bit 7 = raster line bit 8** (live) |
| `$D012` | `PEEK 53266` | RASTER | **Read** returns the current raster line (low 8 bits, live); writes stored |
| `$D020` | `POKE 53280,c` | BORDER | Colour of the visible area outside the active text/bitmap content |
| `$D021` | `POKE 53281,c` | BACKGROUND | Global text background (behind characters) |
| others | — | (stored) | Read/write only; not yet wired to the display |

Colour registers use only the low nibble (palette index 0–15); border and
background default to 0 (black), so the original look is unchanged until poked.

*Why this exists:* it lets standard C64 BASIC/assembly set border/background the
familiar way **and** lets raster-synchronised SID players (e.g. Commando) busy-
wait on `$D012`/`$D011` for a stable line instead of hanging on a constant
open-bus value. The raster line comes from `vic_vga`'s vertical scan counter
(`raster` output); border/background are held in the top-level register file and
fed back to `vic_vga` as `border_color`/`bg_color`. Because the active timing is
CEA-480p (525 lines), the raster counts 0–524 rather than the C64's 0–262/311 —
each target line still occurs once per frame, so equality waits resolve.

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
`roms/6502/upload/fb16_test.bat`).

## Displaying a Photograph (image → D64)

A full COLOR16 frame is **38400 bytes** — larger than the `$A000` ROM window
(12 KiB) and larger than the usable RAM, so a photo cannot be embedded in a ROM
or a single RAM PRG. Instead it is shipped on a **D64** as a tiny loader plus
five framebuffer-bank parts and streamed straight into `fb_ram`.

### Tools

| Tool | Purpose |
| --- | --- |
| [`tools/img2hires.py`](../tools/img2hires.py) `--color16` | Convert any image to 38400-byte COLOR16 data (`*_c16.bin`) + a preview PNG. Fits the image to 320×240 preserving aspect (letter/pillar-boxed in black), then serpentine Floyd–Steinberg dithers it to the 16-colour palette — every pixel is a free palette index, so the result is near-photo quality. `--brightness/--contrast/--saturation/--gamma` tune the tone before quantising. |
| [`tools/build_image_disk.py`](../tools/build_image_disk.py) | One-shot pipeline: convert → split → assemble loader → pack D64. |
| [`sw/show_image.s`](../sw/show_image.s) | The on-board loader (loads at `$2000`). |

### How it works

`DISK_LOAD` loads a PRG to the load address stored in its first two bytes, but the
`$6000` window is only 8 KiB — one framebuffer bank. So the 38400-byte frame is
split into five parts, each a PRG whose load address is `$6000`:

```text
IMG0..IMG3 = 8192 bytes   (banks 0..3)
IMG4       = 5632 bytes   (bank 4)
```

For each bank the loader writes `VIC_MODE = (bank << 5) | $11` (bit4 COLOR16 + bit0
BITMAP + the bank bits 7:5), which points the `$6000` window at that bank, then
`DISK_LOAD`s the matching part so the bytes land directly in `fb_ram`. After all
five it selects bank 0 (`$11`) to show the picture; a keypress returns to text
mode. The loader keeps its bank index **in memory, not in X** — `DISK_LOAD`
clobbers A/X/Y, so a register loop counter would only load the first part.

### Build and run

```sh
# host: build a disk from any image (jpg/png/…)
python tools/build_image_disk.py ich.png -o roms/ich_image.d64
```

Write the `.d64` to the SD card, then on the board:

```text
LOAD "!"          mount the D64 (cursor-key picker)
LOAD "SHOWIMG"
CALL 8192
```

The image streams in bank-by-bank (you see it fill top-to-bottom), then displays
the full 320×240 picture.

### Demo

A photo loading live on the Tang Primer 20K
([`examples/HighResImageDemo.mp4`](../examples/HighResImageDemo.mp4)):

<video src="https://github.com/rudolfstepan/6502-sbc-fpga/raw/main/examples/HighResImageDemo.mp4" controls width="640">
  Your browser can't play this video inline —
  <a href="../examples/HighResImageDemo.mp4">download / view it here</a>.
</video>

> The same converter without `--color16` targets the **320×200 hires** bitmap
> mode (2 colours per 8×8 cell, `$8400` colour RAM) used by
> [`sw/ich_image.s`](../sw/ich_image.s)/`roms/ich_image.rom`. COLOR16 looks far
> better for photographs; hires is only worth it when you need exactly 320×200.

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
