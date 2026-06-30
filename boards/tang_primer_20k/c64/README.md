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
   `CHAR.ROM` 4K). For the virtual-1541 KERNAL hook, patch the local KERNAL
   `LOAD` entry to the guarded `$ECB9` stub, then generate the VHDL image:
   ```
   make c64-kernal-load-vector-patch
   make c64-roms
   ```
   (The ROMs themselves are not redistributed; this is run locally.)
2. Build the FPGA image:
   ```
   make c64-tang20k-build
   ```
   This runs `boards/tang_primer_20k/c64/project/build.bat`, which drives
   `gw_sh project/build.tcl` with a fresh source file list.
3. Flash `impl/pnr/tang_c64.fs`.

Reset = KEY[0] (T10). A short press is a normal C64 reset and leaves RAM
contents intact, matching the real machine. Hold KEY[0] for about one second to
request a cold FPGA reset: the core keeps reset asserted, clears all 64K C64 RAM
plus colour RAM, and then lets the original BASIC/KERNAL boot from a clean RAM
state. Keyboard = PS/2 on PMOD0 (T7 clk / T8 data). Video = HDMI.

### UART-uploadable graphics test PRG

The native C64 core has a small PRG that exercises the currently implemented
VIC-II modes on hardware:

```powershell
make c64-graphics-test-prg
python tools/c64_uart_prg_loader.py roms/test.prg --port COM15
```

The focused sprite smoke test is built and uploaded the same way:

```powershell
make c64-sprite-test-prg
python tools/c64_uart_prg_loader.py roms/sprite_test.prg --port COM15
```

The C64 PRG loader sends monitor wake sequence `A5 5A C3 3C` before uploading. The board
top ignores all other received bytes while the monitor is idle; normal C64 mode
uses the same CH340 link for the host-disk UART at `$DE00/$DE01`. The loader
also uses conservative UART pacing by default because the FPGA monitor writes
directly into C64 RAM and does not acknowledge each byte. The default streams
16 bytes per monitor line with no artificial delay, which keeps 16 KB uploads
practical at the fixed 115200 baud. If a board or older bitstream still drops
bytes, fall back to the old pacing with `--safe` or explicitly use
`--wake-sequence "0xA5 0x5A 0xC3 0x3C" --bytes-per-line 1 --line-delay 0.001`.

After upload, type:

```text
RUN
```

The PRG loads at `$0801`, contains a BASIC `SYS 2064` stub, and then cycles
through text mode, hires bitmap, multicolour bitmap, ECM text, and multicolour
text. Press any key to advance to the next page. Bitmap data is written at
`$2000`, while the video matrix remains at `$0400`, so the test does not
overwrite its own BASIC/loader area.

`sprite_test.prg` also loads at `$0801` and starts with `RUN`. It shows a moving
hires sprite plus multicolour, expanded, and X-MSB sprites using data at `$3000`
and sprite pointers at `$07F8-$07FB`.

### UART-uploadable SID PRGs

SID tunes can be built as normal C64 PRGs with a BASIC `SYS` header and uploaded
through the same UART monitor:

```powershell
make c64-sid-prgs
python tools/c64_uart_prg_loader.py roms/c64_uart_sid/Commando.prg --port COM15
```

Generated SID PRGs include `*.prg.segments.json` sidecars. The UART loader uses
them automatically to skip large zero-filled gaps in the PRG image; pass
`--no-segments` only when testing the old contiguous upload path.

After upload, type:

```text
RUN
```

The C64 SID wrapper is sound-only. It calls the tune's native `init`, then
clears `$D011.DEN`, disables VIC raster IRQs, and drives the `play` routine from
CIA Timer A at roughly 50 Hz. The native VIC honours `DEN=0` by stopping its
RAM-fetch window, which removes BA/RDY stalls from the single-port RAM path and
keeps playback stable for heavy SID players. The HDMI output is blank while the
tune plays by design.

### D64 game PRG upload

For ready-made `.d64` game collections, the current practical path is to extract
a PRG on the PC and upload it through the native C64 UART monitor:

```powershell
python tools/c64_d64_prg_loader.py --folder E:\Emulatoren\C64\Games --find 1942 --first-match --port COM15
```

The tool scans folders recursively, prints the selected disk directory, extracts
the first PRG by default, and then calls `c64_uart_prg_loader.py`. After upload,
type:

```text
RUN
```

Pass `--program "NAME"` when a disk has several PRGs and the first entry is not
the desired starter. This is for single-load/cracked games; multi-load games,
fastloaders, and copy-protected disks still need the later KERNAL/IEC/1541 load
path. After testing large games, use a long KEY[0] reset if BASIC/KERNAL should
restart with clean RAM instead of preserving the uploaded program bytes.

### Virtual 1541 UART transport

The C64 board top now routes the native C64 host-disk UART to the CH340 while
the monitor is inactive. The C64 sees this transport at:

| Address | Direction | Meaning |
| --- | --- | --- |
| `$DE00` | read/write | UART data byte; reading consumes the received byte |
| `$DE01` | read | bit 0 = RX byte available, bit 1 = TX busy, bit 2 = RX overflow |

The PC-side companion is:

```powershell
python tools/virtual_1541/c64_1541_uart_gui.py --port COM15 --folder E:\Emulatoren\C64\Games
```

That tool already implements the host-heavy side of the virtual drive: D64
mounting, directory parsing, PRG chain reads, raw sector reads, and a small
binary packet protocol (`0xC6` request magic, `0x64` response magic). The FPGA
monitor still uses the same USB-UART: send the monitor wake sequence
`A5 5A C3 3C` to take over the line for uploads, then `G` returns control to the
C64 disk transport. The sequence keeps arbitrary PRG bytes from accidentally
starting the monitor during a virtual-drive transfer.
Large PC-to-C64 responses are paced by the server in small chunks (default
8 bytes every 5 ms for the smoke loader), and the C64
core buffers received bytes in a 256-byte FIFO so PRG loads are not limited by a
single UART latch. The FIFO is held empty while the FPGA monitor owns the link,
so monitor uploads cannot leave stale bytes for the next virtual-drive command.

The server supports full-file `LOAD`, chunked `LOADFIRSTCHUNK`, named
`LOADCHUNK`, directory, status, and raw sector requests. It is not a
cycle-accurate IEC bus yet; custom fastloaders and copy protection still need
deeper 1541/IEC work.

To smoke-test the serial path without a KERNAL patch:

```powershell
make c64-v1541-ping-prg
python tools/c64_uart_prg_loader.py roms/diagnostics/v1541_ping.prg --port COM15
```

Then close the upload tool, start `tools/virtual_1541/c64_1541_uart_gui.py` on the same COM
port, and type `RUN` on the C64 keyboard. The PRG sends a binary `PING` frame
through `$DE00/$DE01` and prints the server reply.

The next-level test loads the first PRG from the mounted D64 through the same
transport. The small BASIC stub lives at `$0801`, but the loader itself runs at
`$C000` so it can safely load a normal BASIC PRG over `$0801`:

```powershell
make c64-v1541-loadfirst-prg
python tools/c64_uart_prg_loader.py roms/diagnostics/v1541_loadfirst.prg --port COM15
```

Close the upload tool, start the virtual 1541 server, mount/select a D64, and
type `RUN`. On success the loader prints the end address, patches BASIC pointers
for `$0801` PRGs, and returns to READY. It does not queue `RUN`, `SYS`, or alter
the loaded bytes; the PRG is placed at the load address stored in the file, like
`LOAD "",8,1`. The loader preserves its temporary zero-page workspace before
returning to BASIC. Start the PRG manually afterwards if applicable. Avoid `LIST`
on crack/game loaders: many use only a tiny BASIC start line followed by binary
data, and the BASIC lister can run into that data.
If it reports `NO DISK MOUNTED`, mount a D64 in the GUI before running the
loader again. If `$DE01` bit 2 ever appears during debugging, the server response
is still too fast for the current C64-side loader loop.
The GUI logs the load in stages: `< LOADFIRST`, `loading "..."`, `> LOADFIRST
status=...`, and `sent ... bytes`. Missing stages point to PC-side D64 parsing,
serial writes, or C64-side receive timing respectively.
Current smoke-loader builds request the PRG in 128-byte `LOADFIRSTCHUNK` blocks
instead of accepting one large response frame; this keeps the PC-to-C64 transfer
paced by the C64's own RAM-copy loop.

For games that use the normal KERNAL `LOAD` entry point to fetch later program
parts, patch the C64 KERNAL entry at `$FFD5` to the guarded virtual-1541 stub.
Then regenerate the compiled ROM VHDL:

```powershell
make c64-kernal-load-vector-patch
make c64-roms
```

The patch changes `$FFD5` from `JMP $F49E` to `JMP $ECB9`. The `$ECB9` guard
stub checks whether the RAM hook is installed at `$C700` and only then jumps to
the hook load trampoline at `$C703`; otherwise it falls back to `$F49E`. This avoids the
earlier READY hang caused by KERNAL/BASIC restoring `$0330/$0331` to `$F4A5`
after a directory load. After rebuilding and flashing the FPGA bitstream,
install the RAM hook on the real C64 core. Start with the diagnostic variant:

```powershell
make c64-v1541-hook-diag-prg c64-v1541-hook-prg
python tools/c64_uart_prg_loader.py roms/diagnostics/v1541_hook_diag.prg --port COM15
```

Run the PRG once on the C64. After that, start the virtual 1541 server, mount a
D64, and use normal C64 commands such as:

```basic
LOAD"$",8
LIST
LOAD"*",8,1
RUN
```

The hook reads the real KERNAL filename/device variables, asks the PC server for
the requested PRG in 128-byte `LOADCHUNK` blocks, honours the file's embedded
load address for `,8,1`, and returns the end address in X/Y like KERNAL `LOAD`.
This is enough for programs that later call KERNAL `LOAD` for additional parts.
It will not catch games that replace the KERNAL path with a custom fastloader,
and the current hook lives at `$C700`, so software that overwrites that area can
still destroy it.

See `docs/C64_V1541_UART_TECHNOTE.md` for the READY hang analysis and monitor
probe workflow.

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

### Keyboard and joystick

The PS/2 keyboard drives the C64 CIA1 keyboard matrix. The numeric keypad cursor
legends also emulate C64 joystick port 2 (`$DC00`, active low), which is the
default port for many games. Full implementation notes live in
[`docs/input-devices.md`](../../../docs/input-devices.md).

| PS/2 numeric keypad | C64 joystick port 2 |
| --- | --- |
| KP8 | Up |
| KP2 | Down |
| KP4 | Left |
| KP6 | Right |
| KP0 or KP5 | Fire |

### Native VIC-II graphics

The native C64 `vic_ii` renders into the same CEA-861 720x480p HDMI timing as
the SBC video path: a 640-pixel-wide C64 content area is pillarboxed inside the
720 active pixels, and the 200-line C64 display is scaled 2x vertically to 400
visible lines.

Implemented display modes:

| Mode | VIC bits | Data source | Colour source |
| --- | --- | --- | --- |
| Standard text | `$D011.BMM=0`, `$D016.MCM=0` | `$D018` video matrix + CHARGEN/RAM charset | `$D800` foreground, `$D021` background |
| ECM text | `$D011.ECM=1` | character code low 6 bits + CHARGEN/RAM charset | `$D800` foreground, `$D021-$D024` backgrounds |
| Multicolour text | `$D016.MCM=1`, colour bit 3 set | CHARGEN/RAM charset bit pairs | `$D021-$D023` + colour RAM low 3 bits |
| Hires bitmap | `$D011.BMM=1`, `$D016.MCM=0` | bitmap base from `$D018[3]` | video-matrix high/low nibbles |
| Multicolour bitmap | `$D011.BMM=1`, `$D016.MCM=1` | bitmap bit pairs | `$D021`, video-matrix nibbles, colour RAM |

Relevant registers:

| Register | Implemented bits / use |
| --- | --- |
| `$D011` | raster bit 8 on read, `ECM`, `BMM`, `DEN`, `RSEL`, `YSCROLL` |
| `$D012` | live raster low byte on read, raster IRQ compare on write |
| `$D016` | `MCM`, `CSEL`, `XSCROLL` |
| `$D018` | video matrix base in bits 7:4, bitmap base in bit 3, charset base in bits 3:1 |
| `$D019/$D01A` | raster IRQ latch/enable; sprite collision IRQ status is masked for now |
| `$D020` | border colour |
| `$D021-$D024` | background colours 0-3 |
| `$D000-$D00F`, `$D010`, `$D015`, `$D017`, `$D01B-$D01D`, `$D025-$D02E` | first-pass sprite positions, enable, expansion, priority, multicolour, and colours |
| `$D01E/$D01F` | first-pass sprite-sprite and sprite-background collision latches; read clears |

Text modes fetch 40 screen bytes and colour nibbles per visible scanline. When
`$D018` points at the VIC character-ROM window (`$1000-$1FFF` in banks 0 and 2),
the renderer uses CHARGEN; otherwise it performs a second fetch phase for the 40
RAM charset bytes of the current glyph row. This is needed for game tile graphics
such as Boulder Dash-style custom character sets. `$D011.YSCROLL` and
`$D016.XSCROLL` are applied as first-pass fine-scroll offsets for text and
bitmap pixels.

Bitmap modes fetch 40 bitmap bytes per visible scanline from `(VIC bank +
bitmap base + y*40 + column)`, then fetch the 40 video-matrix attribute bytes for
the current 8-line character row. Colour RAM is read in parallel during the first
phase. This preserves a single steal window per output scanline and keeps the
CPU-visible C64 addresses standard.

Sprites are implemented as a first-pass scanline overlay. The VIC fetches sprite
pointers from the active video matrix at `$03F8-$03FF`, reads the visible sprite
row bytes from the selected VIC bank, and renders hires/multicolour sprites with
X/Y expansion and foreground/background priority. Sprite rendering and fetches
continue while `$D011.DEN=0`, which is needed by games that blank character or
bitmap fetches during raster sections. `$D01E/$D01F` latch sprite-sprite and
sprite-background pixel collisions and clear on read. Sprite collision IRQ status
is currently masked from `$D019` and `irq_n` because the collision model is
pixel-based and not yet cycle-exact.

Focused simulation:

```powershell
make test-c64-vic
```

That target runs the existing text-render smoke test plus
`tb_c64_vic_graphics_modes`, which checks actual RGB output for hires bitmap,
multicolour bitmap, RAM charsets, hires/multicolour sprites, DEN-independent
sprite rendering, and sprite collision latches.

## Milestones

- **M1a — boot to `READY.`** ✅ boots in simulation, ⏳ on-hardware verify
  6510 + processor port, 64K RAM, PLA banking, VIC-II text/bitmap basics, CIA1
  keyboard + Timer-A jiffy IRQ. `sim/tb/tb_c64_core.vhd` boots the real ROMs and
  prints the full banner + `38911 BASIC BYTES FREE` + `READY.`. On hardware
  expect the blue screen, border, banner, blinking cursor, PS/2 typing, and the
  UART-upload graphics PRG above.
- **M1b — D64 game loading** ⏳ in progress
  Current practical path: PC extracts a PRG from a D64 and uploads it through
  the C64 UART monitor. Next: a KERNAL/IEC/1541 path for `LOAD"*",8,1`, `RUN`,
  multi-load games, and fastloader-aware compatibility work.
- **M2 — full VIC-II**
  Hires/multicolour bitmap, ECM, multicolour text, RAM charsets, and first-pass
  sprites including collision latches are in place. Remaining: per-cycle
  accuracy, badlines, and more exact badline/fetch timing.

## Known limitations (M1)
- VIC-II has text, ECM, multicolour text, hires bitmap, multicolour bitmap, RAM
  charsets, and first-pass sprites with pixel collision latches. Badlines and
  cycle-exact display effects are still M2.
- CHARGEN/RAM charset selection follows `$D018` for the common text-mode cases;
  the character-ROM window is modelled for VIC banks 0 and 2.
- CHARGEN read has 1-cycle latency (sync BSRAM) -> at most a 1-pixel horizontal
  shift; cosmetic for M1.
- CIA TOD is a simple BCD counter (no alarm); enough for the KERNAL fallback.
- 64K RAM + 20K ROM in BSRAM is tight on GW2A-18. If P&R runs out of block RAM,
  move `c64_ram` to the DDR3 backend (`ddr3_byte_bridge`) behind the same port.
- Keyboard layout is a first-pass positional map (US-style); umlaut/extra keys
  and shifted cursor up/left are TODO.
