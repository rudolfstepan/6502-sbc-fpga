# FPGA Architecture Overview

## System Design

The 6502 SBC FPGA is a synthesizable hardware implementation of a 6502-based single-board computer targeting real FPGA boards. The active PIX16 path is `pix16_sbc_sd_boot_top`: T65 CPU, SDRAM-backed RAM, SD-loaded 16 KB shadow ROM, VGA text output, VIA, UART, boot status screen, RAM self-test, and a UART hardware monitor. The active Tang Primer 20K path is `tang20k_sbc_top`: HDMI boot/status output, CH340 UART, KEY1 monitor entry, on-board microSD ROM loading, low-power BSRAM main RAM (with an optional DDR3 backend), split shadow-ROM windows, and native SID-compatible audio. The older `sbc_minimal_top` remains useful as a compact VGA/T65 smoke-test design.

---

## SD Boot SBC — Active Board Bring-Up Paths

`pix16_sbc_sd_boot_top` wraps the current hardware workflow:

```text
PIX16 board
  -> SD card SPI core reads raw boot image
  -> sd_rom_loader validates sector 0 and streams sectors 1..32
  -> boot_shadow_rom stores the 16 KB ROM window for $C000-$FFFF
  -> boot_sdram_test verifies the SDRAM-backed main RAM path
  -> T65 is released and fetches reset vector from loaded shadow ROM
```

The board top also multiplexes the VGA output:

- during SD load and RAM test: `boot_vga_debug` shows status and errors,
- after successful boot: the SBC's `vic_vga` output is shown.

The UART output is priority-multiplexed:

1. hardware monitor while active,
2. boot debug text while boot debug is active,
3. 6502 UART output.

Pressing `KEY0` enters `uart_debug_monitor`, holds the CPU, and grants the
monitor direct read/write access to RAM, VRAM, VIA, UART, and shadow ROM. See
[UART Monitor](./UART_MONITOR.md) for commands and the live ROM upload workflow.

`tang20k_sbc_top` uses the same SD loader, boot/status renderers, UART monitor,
and shadow-ROM concept with Tang-specific board glue:

```text
Tang Primer 20K board
  -> HDMI/DVI output through tang20k_hdmi_tx
  -> CH340 UART at 115200 8N1
  -> on-board microSD/SDIO slot in SPI mode on N10/N11/R14/M8
  -> sd_rom_loader writes the 16 KB ROM window into boot_shadow_rom
  -> sbc_t65_boot_monitor_top uses a selectable BSRAM/DDR3 byte backend
  -> KEY1 enters the UART monitor and holds the CPU
```

Without a card in the on-board microSD slot, the expected Tang behavior is a
visible boot/status screen plus UART boot debug text reporting SD init/read
failure while the CPU remains held.

### Active Memory Map

| Address Range | Size | Device | Notes |
| --- | --- | --- | --- |
| $0000-$3FFF | 16 KB | Internal FPGA RAM | Zero page, stack, and EhBASIC workspace |
| $4000-$5FFF | 8 KB | Main RAM | BSRAM by default; optional external DDR3 backend |
| $6000-$7FFF | 8 KB window | Banked VIC framebuffer | 16 KB; legacy 1-bpp, 160x100 RGB332, or 180x120 RGB222 |
| $8000-$87FF | 2 KB | VIC text/color VRAM | $8000–$83E7 chars, $8400–$87E7 colors; shared by CPU/monitor/VIC |
| $8800-$880F | 16 B | VIA 6522 | Port B bit 0 -> board LED 1 after boot |
| $8810-$8813 | 4 B | UART 6551 | CPU UART registers |
| $883A | 1 B | Millisecond counter | Timing source retained for native SID playback |
| $88B0-$88BF | 16 B | Math coprocessor (FPU) | Signed 32×32 fixed-point multiply (8.24); see [Math Coprocessor](./FPU.md) |
| $A000-$CFFF | 12 KB | Shadow ROM application window | EhBASIC or standalone application |
| $D000-$EFFF | 8 KB | I/O / reserved | SID at $D400-$D418; not shadow ROM |
| $F000-$FFFF | 4 KB | Shadow ROM kernel window | Kernel and hardware vectors |

The two ROM windows share one physical 16 KB `boot_shadow_rom`. Image offsets
`$0000-$2FFF` map to CPU `$A000-$CFFF`; offsets `$3000-$3FFF` map to
`$F000-$FFFF`. See [Split ROM and Native SID Update](./SPLIT_ROM_SID_UPDATE.md).

---

## Minimal SBC — Active Implementation

### Block Diagram

```
                 pix16_sbc_minimal_top (board top)
┌────────────────────────────────────────────────────────────────┐
│                      sbc_minimal_top                           │
│                                                                │
│  ┌──────────────┐   RDY=0 when VIC steals                     │
│  │  T65 CPU     │◄──────────────────────────────┐             │
│  │  (t65_adapter│                               │             │
│  │   + T65 core)│                               │             │
│  └──────┬───────┘                               │             │
│         │  cpu_addr / cpu_dout / cpu_bus_we      │             │
│         ▼                                        │             │
│  ┌─────────────┐    ┌──────────┐   ┌──────────┐ │             │
│  │ bus_decode  │    │ CPU SRAM │   │   ROM    │ │             │
│  │             │    │  4 KB    │   │  2 KB    │ │             │
│  │ DEV_SRAM    │───►│$0000-0FFF│   │$F800-FFFF│ │             │
│  │ DEV_VIC_TEXT│    └──────────┘   └──────────┘ │             │
│  │ DEV_VIA     │───►VIA 6522 ($8800) IRQ─────────┤             │
│  │ DEV_UART    │───►UART 6551 ($8810)             │             │
│  │ DEV_ROM     │                                 │             │
│  └──────┬──────┘                                 │             │
│         │                                        │             │
│         ▼  (bus mux: CPU addr OR vic_addr)        │             │
│  ┌──────────────┐  ◄── vic_addr (during steal)   │             │
│  │   VRAM       │                                │             │
│  │  2 KB        │──────────────────────────┐     │             │
│  │ $8000-$87FF  │  vram_dout (async)        │     │             │
│  └──────────────┘                           │     │             │
│                                             ▼     │             │
│                               ┌────────────────────────────┐   │
│                               │       vic_vga              │   │
│                               │  - VGA timing (h/v counters│   │
│                               │  - Video buffer (160 B)    │   │
│                               │  - Color line buffer (40 B)│   │
│                               │  - mode-aware fetch FSM    │──►│ vic_stealing
│                               │  - char_rom lookup         │   │
│                               │  - palette + direct colour │   │
│                               │  - VGA RGB + sync output   │   │
│                               └────────────┬───────────────┘   │
│                                            │                    │
└────────────────────────────────────────────┼────────────────────┘
                                             │ vga_r/g/b, vga_hs/vs
                                             ▼
                                        VGA Monitor
```

### Bus Stealing — C64-Style Shared Bus

The VIC and CPU share single-port video memories through bus multiplexers.
During each horizontal blanking interval the VIC prefetches the next display
line and holds the CPU through the T65 `RDY` pin. Text and legacy bitmap modes
use two phases (40 character/bitmap bytes plus 40 colour bytes). RGB332 fetches
160 direct-colour bytes; packed RGB222 fetches 135 bytes and needs no colour
attribute phase.

```
One scan line = 1716 system clock cycles (858 pixel clocks × 2)

├── H-Visible (1280 cycles) ─────────────────────────────────────┤
│   CPU runs freely                                               │
│   VIC displays from line buffer (no bus access)                 │
│                                                                 │
├── H-Blank (436 cycles) ──────────────────────────────────────┤
│   ├── up to 161 stolen cycles ───────────────────────────────┤ │
│   │   Text/legacy: 40 data + 40 colour bytes (+ setup)       │ │
│   │   RGB332: 160 direct-colour bytes (+ setup)              │ │
│   │   RGB222: 135 packed-colour bytes (+ setup)              │ │
│   │   CPU held (RDY=0) while the VIC owns the VRAM bus.      │ │
│   ├── at least 275 remaining cycles ─────────────────────────┤ │
│   │   CPU runs freely                                         │ │
```

**CPU overhead on the Tang Primer 20K:** text/legacy modes steal 82 of 1716
system clocks (about 4.8%); RGB332 is the worst case at 161 clocks (about 9.4%);
RGB222 uses 136 clocks (about 7.9%).

CPU writes to `$8000-$87FF` are never discarded while the VIC owns VRAM. The
active SD boot cores (`sbc_t65_boot_monitor_top` and `sbc_t65_sdram_boot_top`)
latch a single pending CPU VRAM write (`vram_wr_pending`, address, data) if the
write pulse overlaps `vic_stealing`. The CPU remains held through `RDY` until
the pending write is committed on the first non-steal clock. This prevents
random stale characters when BASIC or firmware rapidly `POKE`s text VRAM while
the display is active.

### Memory Map (Minimal SBC)

| Address Range | Size | Device | Notes |
| --- | --- | --- | --- |
| $0000–$01FF | 512 B | Internal FPGA RAM | Zero page and stack, no external wait states |
| $0200–$0FFF | 3.5 KB | CPU SRAM | General RAM for the minimal build |
| $8000–$87FF | 2 KB | VRAM | Chars at $8000+, colors at $8400+; shared single-port |
| $8800–$880F | 16 B | VIA 6522 | Timer 1 → IRQ; Port B → board LEDs |
| $8810–$8813 | 4 B | UART 6551 | TX byte stream |
| $F800–$FFFF | 2 KB | ROM | Kernel + reset vector at $FFFC |

The ROM is mirrored across the full $C000–$FFFF range via `cpu_addr[10:0]` indexing.

The bus decoder reports `$6000-$7FFF` as `DEV_VIC_BMP` before applying the
broader main-RAM rule. In the current Tang top, `$0000-$3FFF` is routed to
internal BRAM and `$4000-$5FFF` to the selected board memory backend (BSRAM by
default, optionally DDR3). This keeps EhBASIC, zero-page, stack,
IRQ entry, `JSR/RTS`, and read-modify-write traffic off external memory.

IRQ sources are OR-combined: `cpu_irq_n = NOT (via_irq OR uart_irq)`.

### VGA Output

640×480 @ 59.94 Hz, pixel clock 27 MHz (54 MHz ÷ 2 via clock enable).  
Text mode: 40×25 characters, each rendered 2× scaled (16×16 screen pixels).  
Border: 40 px top and bottom. Character patterns from `char_rom.vhd` (8×8 pixels,
bit 7 = reverse video).

`char_rom` layout: `$00–$1F` PETSCII screen codes, `$20–$5F` ASCII uppercase/digits/punctuation,
`$60–$7F` PETSCII block/line graphics. Lowercase ASCII `$61–$7A` falls in the PETSCII
range, so keyboard/UART input is mapped to A–Z in `CHRIN_NB` before BASIC sees it,
and `CHROUT` also maps lowercase output to uppercase text. Programs that need raw
PETSCII graphics write those character codes directly to VRAM.

### Color Support

The VIC supports per-cell foreground and background colors using the C64 16-color
palette. Color attributes are stored in color RAM at `$8400–$87E7`, parallel to the
character codes at `$8000–$83E7`. Each color byte is packed as `bg[7:4] | fg[3:0]`.
Color attributes apply to text and legacy 1-bpp bitmap modes. Direct-colour
RGB332/RGB222 pixels carry their own colour and do not use color RAM.

In text and legacy bitmap modes the VIC fetches both data and color attributes
during H-blank. The 16-color palette is implemented as constant RGB565 lookup
tables (Pepto-style C64 colors) in `vic_vga.vhd`; direct-colour modes expand
RGB332 or RGB222 values to RGB565 instead.

**VIC color registers** (active in all top-level modules):

| Address | Register | Default | Description |
| --- | --- | --- | --- |
| `$9003` | TEXT_COLOR | 1 (white) | Foreground color index 0–15 |
| `$9004` | BG_COLOR | 0 (black) | Background color index 0–15 |

The kernel reads these registers and writes the composed color byte (`bg<<4 | fg`)
to color RAM with every character output. `CLRSCR` fills color RAM with the current
color, and `SCROLL` scrolls color RAM alongside character data.

**BASIC usage:**

```basic
POKE 36867, 5           : REM green text
POKE 36868, 6           : REM blue background
PRINT "HELLO"           : REM green on blue
POKE 33792+offset, color: REM direct color RAM write
```

See [examples/colortest.bas](../../examples/colortest.bas) for a full demo of all
16 colors with PETSCII art, and [docs/VIC.md](../../docs/VIC.md) for the complete
color palette reference.

### Bitmap Mode

The VIC supports a legacy 320×200 bitmap mode (1 bit per pixel, 2× scaled to
640×400 on VGA), a 160×100 chunky-pixel mode with one RGB332 byte per pixel,
and a higher-resolution 180×120 RGB222 mode. RGB332 is scaled 4× to 640×400;
RGB222 is scaled 3× to 540×360 and centred in the 640×480 output. The 16 KB
framebuffer is exposed through the 8 KB CPU window at `$6000–$7FFF`; MODE bit 2
selects one of two banks.

| MODE (`$9000`) | Function |
|---|---|
| bit 0 | Bitmap enable (`0` text, `1` bitmap) |
| bit 1 | 256-colour RGB332 enable (valid with bit 0) |
| bit 2 | CPU framebuffer bank, 0–1 |
| bit 3 | 64-colour packed RGB222 enable (valid with bit 0; takes priority over bit 1) |
| bits 7–4 | Reserved, write zero |

Values `$00` and `$01` therefore retain their original text and legacy-bitmap
meaning. Extended 256-colour mode is selected with `$03` plus the desired bank;
64-colour mode uses `$09` plus the bank bit.

During bitmap mode, the bus-stealing FSM fetches 40 bitmap bytes per scanline
(from `$6000 + bmp_line*40`) in phase 0, and 40 color bytes (from `$8400 +
color_row*40`) in phase 1. The bitmap byte is used directly as the pixel pattern
— no char ROM lookup or reverse-video processing. Each 8×8 pixel cell shares one
color attribute from color RAM, providing 16-color foreground/background per cell.

In 256-colour mode the VIC fetches 160 bytes per logical scanline and skips the
colour-attribute phase. Pixel `(X,Y)` is stored at framebuffer offset `Y*160+X`.
To access it from the CPU, write `(offset DIV 8192)*4+3` to `$9000`, then access
`$6000+(offset AND 8191)`. RGB332 is packed as `RRRGGGBB` and expanded directly
to the RGB565 video output.

In 64-colour mode each pixel is `RRGGBB`. Four pixels occupy three consecutive
bytes, so a 180×120 frame consumes 16,200 bytes. The packing is:

```text
byte 0 = P0[5:0] in bits 7–2 | P1[5:4] in bits 1–0
byte 1 = P1[3:0] in bits 7–4 | P2[5:2] in bits 3–0
byte 2 = P2[1:0] in bits 7–6 | P3[5:0] in bits 5–0
```

Use MODE `$09` for bank 0 and `$0D` for bank 1.

**Pixel formula:** `address = $6000 + Y*40 + INT(X/8)`, bit = `7 - (X AND 7)`
(MSB-first, C64 convention).

**BASIC usage:**

```basic
POKE 36864, 1                          : REM bitmap mode on
A=24576+Y*40+INT(X/8)                  : REM pixel address ($6000)
POKE A, PEEK(A) OR 2^(7-(X AND 7))    : REM set pixel
POKE 36864, 0                          : REM back to text
```

**256-colour BASIC addressing:**

```basic
O=Y*160+X:B=INT(O/8192)
POKE 36864,3+B*4                       : REM chunky mode + CPU bank
POKE 24576+(O-B*8192),C               : REM C is RRRGGGBB
```

See [examples/bitmaptest.bas](../examples/bitmaptest.bas) for a full demo. With
EhBASIC waiting at its prompt, upload and run it with:

```powershell
python tools\upload_basic_uart.py examples\bitmaptest.bas --port COM15 `
       --baud 115200 --new --run --verbose
```

The FPGA BASIC example [examples/petscii_gfx.bas](../../examples/petscii_gfx.bas)
is intentionally a pure VRAM `POKE` demo. It avoids `PRINT CHR$(96)` for graphics
because `CHROUT` is kept text-safe, and it avoids dense multi-statement BASIC
lines so it can be uploaded reliably over the UART input path.

### Kernel ROM

Source: `fpga/sw/rom_demo.s` (ca65 assembly) — built with the cc65 toolchain.

```bash
cd fpga/sw && make        # assembles, links, installs fpga/sim/hex/rom_welcome.hex
```

The kernel initialises VIA Timer 1 in free-running mode (period $FFFF ≈ 1.3 ms),
prints reset diagnostics over UART, runs a quick power-on system check, enables
the T1 interrupt, and idles. The system check probes zero page, stack RAM, main
RAM, VRAM, VIA configuration, and UART status, printing `OK` or `FAIL` for each
line before `CLI`.

The ISR fires ~750 Hz; every 256th call (~330 ms) it:

- increments a tick counter and writes two hex digits to VIC row 8,
- toggles VIA Port B bit 0 (LED blink, visible on board).

```text
Row 1:  ←↑→↓ (PETSCII block/line graphics $60–$7F, cols 4–35)
Row 2:  **** 6502 SINGLE BOARD COMPUTER ****
Row 4:  4096 BYTES RAM     2048 BYTES ROM
Row 6:  BEREIT.
Row 8:  VIA-T1:  XX    (live counter, ~3 Hz)
```

Build and upload:

```bash
cd fpga/sw
make all                                    # assemble + install sim hex
python upload_rom_demo.py --run --verbose   # upload via UART monitor
# or: make upload-demo
```

ROM hex format: `XXXX YY` (4-digit ROM offset, 2-digit byte, no comments —
the hex loader uses raw `hread`; comments cause read errors).

---

## Full SBC — Reference Implementation

`sbc_t65_top.vhd` is the full-featured integration including VIA 6522 and UART 6551.  
It is present in the project but not synthesized for the PIX16 board (Implementation seqID = 0).

### High-Level Block Diagram (Full SBC)

```
┌────────────────────────────────────────────────────────────┐
│                    sbc_t65_top                             │
│                                                            │
│  T65 CPU ──► bus_decode ──► SRAM (4 KB)                   │
│                         ──► ROM  (2 KB)                   │
│                         ──► VIA 6522  ($8800)             │
│                         ──► UART 6551 ($8810)             │
│                         ──► VIC core  ($8000, $9000)      │
│                                                            │
│  IRQ: VIA ─┐                                              │
│  IRQ: UART ├──► OR ──► CPU IRQ_N                          │
│  IRQ: VIC ─┘                                              │
└────────────────────────────────────────────────────────────┘
```

### Current Tang Primer 20K Memory Map

| Address Range | Size | Device |
| --- | --- | --- |
| $0000–$3FFF | 16 KB | BRAM main RAM |
| $4000–$5FFF | 8 KB | BSRAM main RAM; optional DDR3 backend |
| $6000–$7FFF | 8 KB window | Banked 16 KB VIC framebuffer |
| $8000–$87FF | 2 KB | VIC Text RAM |
| $8800–$880F | 16 B | VIA 6522 |
| $8810–$8813 | 4 B | UART 6551 |
| $883A | 1 B | Free-running millisecond counter |
| $88B0–$88BF | 16 B | Math coprocessor |
| $9000–$900F | 16 B | VIC Control Regs |
| $A000–$CFFF | 12 KB | Shadow ROM application window |
| $D400–$D418 | 25 B | SID-compatible audio registers |
| $F000–$FFFF | 4 KB | Shadow ROM kernel/vector window |

---

## Clocking

The Tang Primer 20K uses its 27 MHz oscillator as the reference for one 270 MHz
PLL root. Dedicated dividers derive three phase-related clocks:

- 135 MHz TMDS serializer clock (`270 / 2`)
- 54 MHz SBC system clock (`270 / 5`)
- 27 MHz HDMI pixel clock (`135 / 5`)

The direct 135-to-27 MHz divide is required by OSER10's 5:1 fast/parallel clock
relationship. The renderer output is registered at 54 MHz and transferred on
the falling system edge before the next 27 MHz TMDS encoder edge.

The T65 CPU runs at effective half system-clock speed through a toggling
`cpu_enable` signal:

- `cpu_enable` toggles every 54 MHz system clock → T65 advances at up to 27 MHz.
- Writes committed on the `cpu_enable = '0'` half-cycle (`cpu_bus_we = cpu_we AND NOT cpu_enable`).
- In the minimal SBC, `vic_stealing` additionally holds the CPU via `RDY`.

The VGA timing advances at 27 MHz through `CLK_DIV=2` inside `vic_vga`.

## Reset Sequence

1. `reset_n` asserted low — all state cleared.
2. `reset_n` released — CPU starts reset sequence (7 internal cycles).
3. CPU reads reset vector from $FFFC–$FFFD (ROM).
4. CPU jumps to reset address ($F800 in kernel ROM).
5. Kernel initialises stack and writes welcome text to VRAM.
6. Kernel prints reset diagnostics and the system check result over UART.
7. Kernel enables interrupts and enters the UART keyboard polling loop.

---

**See Also:**

- [Modules Reference](./02_MODULES.md)
- [UART Monitor](./UART_MONITOR.md)
- [Build Instructions](../boards/pix16/README.md)
- [Simulation Guide](./06_SIMULATION.md)
