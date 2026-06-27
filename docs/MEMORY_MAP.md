# Memory Map

The 6502 sees a flat 64 KiB address space (`$0000`–`$FFFF`). Address decoding is
purely combinational in [`rtl/core/bus_decode.vhd`](../rtl/core/bus_decode.vhd);
all region constants live in [`rtl/core/sbc_pkg.vhd`](../rtl/core/sbc_pkg.vhd).
This page describes the **Tang Primer 20K split-ROM map** used by
[`sbc_t65_boot_monitor_top.vhd`](../rtl/core/sbc_t65_boot_monitor_top.vhd).

## Overview

| Range | Size | Region | Backing |
| --- | --- | --- | --- |
| `$0000`–`$00FF` | 256 B | Zero page | on-chip BSRAM |
| `$0100`–`$01FF` | 256 B | CPU stack | on-chip BSRAM |
| `$0200`–`$3FFF` | ~15.5 KiB | Program / BASIC working RAM | on-chip BSRAM |
| `$4000`–`$5FFF` | 8 KiB | RAM (decoded as SRAM; aliases — physical RAM is 16 KiB) | on-chip BSRAM |
| `$6000`–`$7FFF` | 8 KiB | **VIC bitmap window** (banked into the framebuffer) | `fb_ram` |
| `$8000`–`$87FF` | 2 KiB | VIC text RAM (char `$8000`+, colour `$8400`+) | BSRAM |
| `$8800`–`$880F` | 16 B | VIA 6522 (parallel I/O, timers) | — |
| `$8810`–`$8813` | 4 B | UART 6551 (serial) | — |
| `$8820`–`$8823` | 4 B | USB HID keyboard host | — |
| `$8824`–`$882F` | 12 B | Disk controller (D64 GoDrive) | — |
| `$8830`–`$883D` | 14 B | Sound channel 0 + ms timer + SID PW ext | — |
| `$8840`–`$884F` | 16 B | VIC blitter (reserved) | — |
| `$8850`–`$888F` | 64 B | VIC sprite controller (reserved) | — |
| `$8890`–`$8899` | 10 B | Sound channel 1 | — |
| `$889A`–`$88A3` | 10 B | Sound channel 2 | — |
| `$88A4`–`$88AD` | 10 B | Sound channel 3 | — |
| `$88B0`–`$88BF` | 16 B | Math coprocessor (FPU) | — |
| `$8900`–`$89FF` | 256 B | VIC sprite pattern data (reserved) | — |
| `$9000`–`$900F` | 16 B | VIC control registers | — |
| `$A000`–`$CFFF` | 12 KiB | **EhBASIC ROM** | shadow ROM (SD-loaded) |
| `$D000`–`$D01F` | 32 B | free I/O | — |
| `$D020`–`$D02F` | 16 B | VIC-II colour registers (border `$D020`, background `$D021`) — C64-compatible | — |
| `$D030`–`$D3FF` | ~976 B | free I/O | — |
| `$D400`–`$D41C` | 29 B | SID (MOS 6581-compatible, incl. OSC3/ENV3 read regs) | — |
| `$D41D`–`$EFFF` | ~11 KiB | free I/O (unmapped → `DEV_NONE`) | — |
| `$F000`–`$FFFF` | 4 KiB | **Kernel ROM** (incl. vectors) | shadow ROM (SD-loaded) |

CPU/IRQ/NMI vectors are at `$FFFA`–`$FFFF` inside the Kernel ROM.

## Decode order (important)

`bus_decode` checks ranges in priority order. The one non-obvious case: the
bitmap window is matched **before** main RAM —

```
if addr(15 downto 13) = "011" then  sel <= DEV_VIC_BMP;   -- $6000-$7FFF wins
elsif addr in $0000..$7FFF then     sel <= DEV_SRAM;       -- the rest of low RAM
```

So `$6000`–`$7FFF` is the framebuffer, not RAM; usable contiguous RAM is
`$0000`–`$5FFF`. Anything not matched (e.g. most of `$D000`–`$EFFF`) decodes to
`DEV_NONE`.

## RAM

The system RAM is **16 KiB of on-chip BSRAM** (`sync_ram ADDR_WIDTH=14`), mapped
at `$0000`–`$3FFF`. EhBASIC is configured for working RAM `$0200`–`$3FFF`.
Addresses `$4000`–`$5FFF` still decode as `DEV_SRAM` but alias the 16 KiB array.

## ROM (split-ROM layout)

A single **16 KiB shadow ROM** image (loaded from SD at boot, see
[SD Bootloader](./SD_BOOTLOADER_PLAN.md)) is mapped into two CPU windows so the
`$D000`–`$EFFF` I/O hole stays free:

| CPU window | ROM image offset | Contents |
| --- | --- | --- |
| `$A000`–`$CFFF` | `$0000`–`$2FFF` | EhBASIC (12 KiB) |
| `$F000`–`$FFFF` | `$3000`–`$3FFF` | Kernel (4 KiB) + vectors |

`rom_offset()` in `sbc_pkg.vhd` performs this CPU-address → image-offset mapping.
(The legacy single-window constants `ADDR_ROM_BASE`/`$C000`-`$FFFF` remain for
older boot tops.)

## VIC bitmap window banking (`$6000`–`$7FFF`)

The 8 KiB window is a movable view into the larger framebuffer RAM (`fb_ram`,
38400 bytes for 320×240 4 bpp). The active bank is chosen via the VIC MODE
register `$9000`:

- **320×240 16-colour** (MODE bit 4): 3 bank bits `$9000[7:5]` select bank 0–4.
- **legacy 160×100 / 180×120** modes: single bank bit `$9000[2]`.

Pixel/byte addressing for each mode is documented in [VIC](./VIC.md).

## See Also

- [VIC Video Controller](./VIC.md) — text/bitmap modes, `$9000` registers, framebuffer addressing
- [Sound Chip](./SOUND.md) — `$8830`+ and SID `$D400`
- [Math Coprocessor (FPU)](./FPU.md) — `$88B0`
- [Architecture](./01_ARCHITECTURE.md) and [Modules Reference](./02_MODULES.md)
