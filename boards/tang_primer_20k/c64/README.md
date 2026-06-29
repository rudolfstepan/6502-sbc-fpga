# Native C64 on Tang Primer 20K

A from-scratch Commodore 64 core that runs the **original** BASIC/KERNAL/CHARGEN
ROMs, kept entirely separate from the 6502 SBC so the existing system is
untouched. Reuses the SBC's proven board plumbing (T65 CPU, HDMI TX, PT8211 DAC,
PS/2 front-end concepts) and adds the C64-specific chips natively.

> Status: **Milestone 1+ in progress** — boots to `READY.` in simulation, has
> keyboard/IRQ plumbing, SID hooks, UART PRG upload, and first VIC-II graphics
> modes. On-hardware bring-up and the D64 `LOAD` path are still active work.

## Layout

```
rtl/c64/                         # board-independent C64 core
  c64_pkg.vhd                    # memory map + PLA banking decode + I/O sub-decode
  c64_roms.vhd                   # GENERATED: BASIC/KERNAL/CHARGEN (tools/build_c64_roms.py)
  c64_ram.vhd                    # 64K x 8 DRAM (single-port BSRAM, VIC steal)
  colour_ram.vhd                 # 1K x 4 colour RAM (single-port, VIC steal)
  cpu6510.vhd                    # T65 + $00/$01 processor port (ROM banking)
  cia6526_full.vhd              # full 6526: ports A/B, Timer A/B, TOD, ICR/IRQ
  c64_keyboard_matrix.vhd        # PS/2 -> 8x8 C64 keyboard matrix (+ RESTORE/NMI)
  vic_ii.vhd                     # VIC-II text/bitmap modes + raster IRQ (HDMI-ready)
  c64_core.vhd                   # wires it all together (board independent)

boards/tang_primer_20k/c64/
  rtl/tang20k_c64_top.vhd        # board top: clocks (via hdmi_tx), reset, DAC
  constraints/tang20k_c64.cst    # pins (clock/reset/PS-2/HDMI/DAC)
  constraints/tang20k_c64.sdc    # 27 MHz clock + relaxed CPU multicycle
  project/tang_c64.gprj          # Gowin project
  project/build.tcl              # gw_sh batch build
```

## Building

1. Put the original ROMs in `roms/c64/` (`BASIC.ROM` 8K, `KERNAL.ROM` 8K,
   `CHAR.ROM` 4K) and generate the VHDL image:
   ```
   python tools/build_c64_roms.py
   ```
   (The ROMs themselves are not redistributed; this is run locally.)
2. Open `project/tang_c64.gprj` in Gowin IDE, or run `gw_sh project/build.tcl`.
3. Flash `impl/pnr/tang_c64.fs`.

Reset = KEY[0] (T10). Keyboard = PS/2 on PMOD0 (T7 clk / T8 data). Video = HDMI.

### UART-uploadable graphics test PRG

The native C64 core has a small PRG that exercises the currently implemented
VIC-II modes on hardware:

```powershell
make c64-graphics-test-prg
python tools/c64_uart_prg_loader.py roms/test.prg --port COM15
```

The C64 PRG loader sends monitor wake byte `0xA5` before uploading. The board
top ignores all other received bytes while the monitor is idle, so the C64 debug
UART stream cannot accidentally start or spoof the loader session. The loader
also uses conservative UART pacing by default because the FPGA monitor writes
directly into C64 RAM and does not acknowledge each byte. If an older local copy
still fails after a reset, run it explicitly as
`--wake-byte 0xA5 --bytes-per-line 1 --line-delay 0.02`.

After upload, type:

```text
RUN
```

The PRG loads at `$0801`, contains a BASIC `SYS 2064` stub, and then cycles
through text mode, hires bitmap, multicolour bitmap, ECM text, and multicolour
text. Press any key to advance to the next page. Bitmap data is written at
`$2000`, while the video matrix remains at `$0400`, so the test does not
overwrite its own BASIC/loader area.

## Architecture

### Reused vs. new
- **Reused unchanged:** T65 (as the 6510's core), `sid6581`, the HDMI TX +
  encoder (`tang20k_hdmi_tx`, exact CEA-861 720x480p), `pt8211_dac`.
- **New, C64-accurate:** PLA banking, 6510 processor port, VIC-II, both CIAs,
  colour RAM, 64K RAM map, PS/2 keyboard matrix.
- **Deliberately omitted:** the SBC boot screen / SD ROM loader. The original
  KERNAL paints its own banner, and dropping the loader frees BSRAM + LUTs.

### Memory map (PLA, unexpanded machine GAME=EXROM=1)
| Range          | LORAM/HIRAM/CHAREN          | Maps to            |
|----------------|-----------------------------|--------------------|
| `$0000-$9FFF`  | always                      | RAM                |
| `$A000-$BFFF`  | LORAM & HIRAM               | BASIC ROM / RAM    |
| `$C000-$CFFF`  | always                      | RAM                |
| `$D000-$DFFF`  | (LORAM\|HIRAM) & CHAREN     | I/O                |
|                | (LORAM\|HIRAM) & !CHAREN    | CHARGEN ROM        |
|                | else                        | RAM                |
| `$E000-$FFFF`  | HIRAM                       | KERNAL ROM / RAM   |

I/O sub-decode: VIC `$D000`, SID `$D400`, colour `$D800`, CIA1 `$DC00`,
CIA2 `$DD00`. **Writes always reach the RAM beneath ROM** ("RAM under ROM"),
exactly as on hardware. `$00/$01` are the 6510 port (handled in `cpu6510`).

### Clocking and memory sharing
`tang20k_hdmi_tx` turns the 27 MHz oscillator into 135 MHz TMDS + 27 MHz pixel.
The whole core runs at 27 MHz; the CPU/CIAs advance on a ~1 MHz PHI2 clock-enable
(`PHI2_DIV` generic, `27 MHz / 27`).

Main RAM and colour RAM are single-port BSRAMs time-shared between the CPU and
the VIC. During the horizontal-blank fetch window the VIC asserts `BA` low, the
core parks the 6510 through `RDY`, and small deferred-write FIFOs preserve CPU
writes that complete while the bus is being taken. This keeps the C64 memory map
compact enough for the GW2A-18 while avoiding dropped 6502 writes. CHARGEN still
has an independent read port for the VIC pixel pipeline.

> Sim note: a faithful boot needs `PHI2_DIV >= 2` so the 1-cycle synchronous
> RAM/ROM has settled before the CPU samples it. `PHI2_DIV=1` reads data one
> cycle early -- a simulation-only skew (hardware runs `PHI2_DIV=27`).

### IRQ/NMI
CIA1 IRQ + VIC raster IRQ -> CPU IRQ. CIA2 IRQ + RESTORE key -> CPU NMI.

### Native VIC-II graphics

The native C64 `vic_ii` renders into the same CEA-861 720x480p HDMI timing as
the SBC video path: a 640-pixel-wide C64 content area is pillarboxed inside the
720 active pixels, and the 200-line C64 display is scaled 2x vertically to 400
visible lines.

Implemented display modes:

| Mode | VIC bits | Data source | Colour source |
| --- | --- | --- | --- |
| Standard text | `$D011.BMM=0`, `$D016.MCM=0` | `$D018` video matrix + CHARGEN | `$D800` foreground, `$D021` background |
| ECM text | `$D011.ECM=1` | character code low 6 bits + CHARGEN | `$D800` foreground, `$D021-$D024` backgrounds |
| Multicolour text | `$D016.MCM=1`, colour bit 3 set | CHARGEN bit pairs | `$D021-$D023` + colour RAM low 3 bits |
| Hires bitmap | `$D011.BMM=1`, `$D016.MCM=0` | bitmap base from `$D018[3]` | video-matrix high/low nibbles |
| Multicolour bitmap | `$D011.BMM=1`, `$D016.MCM=1` | bitmap bit pairs | `$D021`, video-matrix nibbles, colour RAM |

Relevant registers:

| Register | Implemented bits / use |
| --- | --- |
| `$D011` | raster bit 8 on read, `ECM`, `BMM`, `DEN`, `RSEL`, `YSCROLL` |
| `$D012` | live raster low byte on read, raster IRQ compare on write |
| `$D016` | `MCM`, `CSEL`, `XSCROLL` |
| `$D018` | video matrix base in bits 7:4, bitmap base in bit 3 |
| `$D019/$D01A` | raster IRQ latch/enable |
| `$D020` | border colour |
| `$D021-$D024` | background colours 0-3 |

Bitmap modes fetch 40 bitmap bytes per visible scanline from `(VIC bank +
bitmap base + y*40 + column)`, then fetch the 40 video-matrix attribute bytes for
the current 8-line character row. Colour RAM is read in parallel during the first
phase. This preserves a single steal window per output scanline and keeps the
CPU-visible C64 addresses standard.

Focused simulation:

```powershell
make test-c64-vic
```

That target runs the existing text-render smoke test plus
`tb_c64_vic_graphics_modes`, which checks actual RGB output for hires bitmap and
multicolour bitmap.

## Milestones

- **M1a — boot to `READY.`** ✅ boots in simulation, ⏳ on-hardware verify
  6510 + processor port, 64K RAM, PLA banking, VIC-II text/bitmap basics, CIA1
  keyboard + Timer-A jiffy IRQ. `sim/tb/tb_c64_core.vhd` boots the real ROMs and
  prints the full banner + `38911 BASIC BYTES FREE` + `READY.`. On hardware
  expect the blue screen, border, banner, blinking cursor, PS/2 typing, and the
  UART-upload graphics PRG above.
- **M1b — `LOAD` from D64** ⏳ next
  Integrate the existing `d64_subsystem` + SD path behind a KERNAL LOAD/IEC
  hook (stubbed in `c64_core` for now). Target `LOAD"*",8,1` + `RUN`.
- **M2 — full VIC-II**
  Hires/multicolour bitmap, ECM, and multicolour text are in place. Remaining:
  8 sprites + collisions, sprite/gfx priority, per-cycle accuracy, badlines,
  CHARGEN upper/lower set via `$D018` CB bits.

## Known limitations (M1)
- VIC-II has text, ECM, multicolour text, hires bitmap, and multicolour bitmap.
  Sprites, collisions, badlines, and cycle-exact display effects are still M2.
- CHARGEN: always the upper-case set; `$D018` charset-base bit not yet decoded.
- CHARGEN read has 1-cycle latency (sync BSRAM) -> at most a 1-pixel horizontal
  shift; cosmetic for M1.
- CIA TOD is a simple BCD counter (no alarm); enough for the KERNAL fallback.
- 64K RAM + 20K ROM in BSRAM is tight on GW2A-18. If P&R runs out of block RAM,
  move `c64_ram` to the DDR3 backend (`ddr3_byte_bridge`) behind the same port.
- Keyboard layout is a first-pass positional map (US-style); umlaut/extra keys
  and shifted cursor up/left are TODO.
