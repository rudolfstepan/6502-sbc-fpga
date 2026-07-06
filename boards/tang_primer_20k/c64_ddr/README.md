# Native C64 on Tang Primer 20K

> DDR fork: this directory is a separate working copy of
> `boards/tang_primer_20k/c64`.  Use it for the C64 + on-board DDR3 bring-up so
> the existing C64 project stays untouched.  The c64_ddr project uses a local
> `rtl/c64_core_ddr.vhd` fork and routes the C64 64K main RAM through the
> on-board DDR3 byte bridge instead of `rtl/c64/c64_ram*.vhd`.

A from-scratch Commodore 64 core that runs the **original** BASIC/KERNAL/CHARGEN
ROMs, kept entirely separate from the 6502 SBC so the existing system is
untouched. Reuses the SBC's proven board plumbing (T65 CPU, HDMI TX, PT8211 DAC,
PS/2 front-end concepts) and adds the C64-specific chips natively.

> Status: **DDR bring-up working on hardware** — 64K C64 main RAM is served by
> the on-board DDR3 through `ddr3_byte_bridge`; the VIC uses the XL renderer and
> reads from a local 16K shadow of the active VIC bank. 1942/Commando-style game
> graphics have been verified clean after the shadow reload/write-through fixes.
> The top-level also performs a one-shot automatic warm reset after DDR/boot
> settle, matching the manual reset that recovers the VIC at power-up.

## Current hardware state (2026-07-06)

- `VIC_XL => true` in `rtl/tang20k_c64_ddr_top.vhd`.
- CPU, monitor and cold-scrub accesses use the byte-wide DDR bridge as the C64
  64K main RAM backend.
- `rtl/c64_core_ddr.vhd` keeps a 16K BSRAM `vic_shadow` for the active VIC bank.
  CPU/monitor/cold-reset writes are mirrored into the shadow when they target
  the visible bank; CIA2 bank changes start a background reload from DDR.
- The XL VIC fetches from the shadow instead of contending for DDR on every
  display cycle. This avoids the broken bitmap/charset backgrounds seen when
  the VIC path hit DDR too directly.
- Power-up reset sequence is one-shot: wait for DDR readiness and boot writes,
  hold C64 reset, run briefly, pulse only the C64 core reset once, then stay in
  `CR_DONE`. The SD controller and hook boot loader stay alive during that
  automatic pulse, so the disk menu cannot reach READY with `sd_init_done` low.
  It is re-armed only by a real KEY[0]/base reset, avoiding the reset loop that
  happened when the generated pulse re-triggered itself.
- Current SD test bitstream uses the SD-card D64 backend again
  (`MISTER_1541_BACKEND => 3`, `MISTER_1541_SD_WRITE => true`) with the
  resident menu/fastload hook booted from LBA 8. For IEC-sensitive titles,
  `LOAD"@I",8` mounts through the menu and then disables the hook signature so
  later loads use the stock IEC/1541 path. Ultima I has been verified on
  hardware with this SD `@I` path.
- The Python-backed virtual 1541 sector source (`MISTER_1541_BACKEND => 2`) was
  used as a comparison path. Ultima I has been verified on hardware there,
  confirming that the C64 IEC loader and internal 1541 logic are viable.
- The shared fixed-point math coprocessor is enabled again in the DDR fork at
  `$DEB0-$DEBF` (I/O1). `$DFxx` remains reserved for the SD disk window, and the
  legacy host UART stays at `$DE00-$DE01` when that path is enabled.
- Latest Gowin build checked: `0` setup and `0` hold violations; resource use is
  about 78% logic and 39/46 BSRAM. The generated `.fs` is kept local because it
  embeds the C64 ROM images.

### Math coprocessor

The C64 DDR project maps `rtl/core/peripherals/math_copro.vhd` into I/O1:

| Address | Meaning |
| --- | --- |
| `$DEB0-$DEB3` | operand A, signed 32-bit little endian |
| `$DEB4-$DEB7` | operand B, signed 32-bit little endian |
| `$DEB8-$DEBB` | shifted result, signed 32-bit little endian |
| `$DEBC` | shift amount, default `24` |

The raw signed 64-bit product is readable at `$DEB0-$DEB7`; after writing the
operands, read `$DEB8-$DEBB` for `(A * B) >> shift`.

The C64 Mandelbrot demo has two separate PRG outputs:

| PRG | Meaning |
| --- | --- |
| `roms/c64/prg/mandelbrot.prg` | CPU-only reference renderer, no coprocessor |
| `roms/c64/prg/mandelbrot-copo.prg` | `$DEB0` coprocessor renderer |

Both keep the bitmap display enabled while rendering. The coprocessor build
does a small `$DEB0` self-test at startup; a red border means the mapped
coprocessor did not return the expected 8.24 result, while a changing border
shows row progress and a green border marks completion.

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
  vic_ii.vhd                     # "small" VIC-II: line-buffer renderer + raster IRQ
  vic_ii_xl.vhd                  # "XL" VIC-II: cycle-based 6569 model (see below)
  c64_ram_dp.vhd                 # 64K x 8 dual-port RAM (XL VIC fetch port B)
  colour_ram_dp.vhd              # 1K x 4 dual-port colour RAM (XL VIC port B)
  c64_core.vhd                   # wires it all together (board independent)

boards/tang_primer_20k/c64_ddr/
  rtl/c64_core_ddr.vhd           # local core fork with external DDR byte RAM port
  rtl/tang20k_c64_ddr_top.vhd    # board top with Gowin DDR3 IP + byte bridge
  rtl/ddr3_byte_bridge.vhd       # copied DDR byte bridge from the SBC project
  project/src/                   # copied Gowin DDR3 IP + rPLL source
  constraints/tang20k_c64_ddr.cst # pins, including on-board DDR3
  constraints/tang20k_c64_ddr.sdc # 27 MHz clock + relaxed CPU multicycle
  project/tang_c64_ddr.gprj      # Gowin project
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
   The patch changes `$FFD5` to a small guard at `$ECB9`. That guard now
   accepts the resident SD hook only when `$C000` contains the `$2C`/`BIT`
   signature and then enters the hook at `$C006`; otherwise it falls back to the
   stock KERNAL LOAD routine. This keeps games that place their own loader or
   overlay at `$C000` from being mistaken for the SD hook.
   `LOAD"@I",8` intentionally clears the resident hook signature after mounting
   a disk; after that the same guard falls through to the stock IEC path until
   the hook is restored by reset/boot.
   (The ROMs themselves are not redistributed; this is run locally.)
2. Build the FPGA image:
   ```
   cd boards/tang_primer_20k/c64_ddr/project
   build.bat
   ```
   This drives `gw_sh build.tcl` with a fresh source file list.
3. Flash `impl/pnr/tang_c64_ddr.fs`.

Tested bitstreams live in `bitstream/` with a date+version suffix; see
`bitstream/RELEASE_NOTES.md` for what each one contains.

### Choosing the VIC implementation

`c64_core_ddr` has a `VIC_XL` generic (set in `rtl/tang20k_c64_ddr_top.vhd`,
currently `true`):

* `VIC_XL => false` — `vic_ii.vhd`, the "small" line-buffer VIC of the frozen
  bring-up bitstream. It prefetches each line during H-blank over the RAM steal
  bus; no badlines, no border flip-flops, register changes act per line.
* `VIC_XL => true` — current DDR build. This selects `vic_ii_xl.vhd`, a
  cycle-based 6569 model after Christian Bauer's vic-ii.txt: real badlines
  (VC/RC/VCBASE), live badline condition (FLD/linecrunch), border flip-flops
  with RSEL/CSEL/DEN, YSCROLL, mid-line register effects, sprite DMA with
  Y-crunch and X/Y expansion flip-flops, idle-state $3FFF fetches, invalid modes
  rendering black, and collision IRQ plumbing.

  The original BSRAM core gives the XL VIC a real second RAM port. This DDR fork
  instead keeps a local 16K shadow of the active VIC bank in BSRAM. The CPU-side
  64K RAM remains in DDR, but every relevant write is mirrored into the shadow
  and each CIA2 VIC-bank switch starts a DDR-to-shadow refresh sweep. BA still
  reproduces 6510 stall timing; the VIC does not issue per-cycle DDR reads.

### SD floppy (alternate backend)

The native core carries the SD-backed MiSTer 1541 drive used during probe-board
bring-up, but the native C64 top also wires the SD write channel and enables
write-back (`MISTER_1541_SD_WRITE => true`). The same FAT16 card, resident SD
hook and disk menu are used for loading:

For loaders that talk to the 1541 directly, use `LOAD"@I",8` instead of
`LOAD"@",8`. It still uses the FAT16 menu to mount the D64, but then disables
the resident hook signature so the KERNAL guard falls back to the stock IEC
entry point.

* `mister_c1541_iec` runs with `D64_BACKEND => 3` (contiguous .d64 file on the
  card, mounted at runtime) and `SD_PACKED_D64_FILE => true`.
* The board top implements the identical register window in C64 I/O2
  (`$DF00-$DF1F`): mount LBA + strobe, status, hook-boot status, fastload sector
  window, raw-block read/write helpers, and write-diagnostic counters.
* `c64_sd_hook_boot_loader` pulls the resident hook ("C64HOOK1" header at
  LBA 8, written by `tools/d64/make_fat16_d64_card.py`) into C64 RAM at
  power-up. In this core the CPU is parked through the monitor RDY path while
  the loader streams bytes through the monitor memory port (a small FIFO shim
  bridges the per-byte writes onto the req/ready handshake).
* SD card in SPI mode on the PMOD1 breakout: SCK=T11, CS=P11, MOSI=T12,
  MISO=R11 (same pins as the probe board).

The SD arbiter grants whole 512-byte transfers to one owner at a time
(boot loader, then 1541 drive, then fastload window), exactly like the probe.

Normal C64 disk commands work through the SD-backed 1541 after a disk is mounted
with the resident hook:

```basic
LOAD"@",8       : REM FAT16 disk menu / mount .d64
LOAD"$",8
LIST
LOAD"*",8,1
SAVE"NAME",8
```

For IEC-loader games such as Ultima I, mount with:

```basic
LOAD"@I",8
LOAD"$",8
LIST
LOAD"*",8,1
RUN
```

After `@I`, the hook stays disabled until a reset restores it from the SD hook
block at LBA 8. Re-run `tools/write_sd_hook_block.ps1` after rebuilding the hook
PRG, otherwise the card still contains the old resident hook.

The `LOAD"@",8` selector shows 16 `.d64` files per page. Use cursor
right/down for the next page and cursor left/up for the previous page, then
choose an entry with `1-9` or `A-G`.

`SAVE` modifies the mounted `.d64` in place. Keep a backup or use a disposable
image while testing; the FPGA does not create FAT files and does not protect the
card from saving over a disk image you care about. The write path decodes the
1541 GCR write burst, stalls the virtual drive while the SD card is flushed, and
updates the containing 512-byte card block with a read-modify-write so the other
256-byte D64 sector half is preserved.

Supported and verified path: normal BASIC/KERNAL `SAVE` into a standard
35-track D64 stored as one contiguous FAT16 file. Not a supported target yet:
1541 formatting commands such as `OPEN 15,8,15,"N:..."`, scratch/rename
workflows, copy-protected disks, custom fastloaders and non-standard D64
variants.

Board LEDs are active-low and held long enough to see short events:

| LED | Meaning |
| --- | --- |
| LED0 | 1541 head/read mode active |
| LED1 | 1541 head/write mode active |
| LED2 | drive-owned SD read transfer |
| LED3 | drive-owned SD write flush |

Write diagnostics are exposed in the same I/O2 page for hardware bring-up:

| Address | Meaning |
| --- | --- |
| `$DF07` | high nibble = accepted drive SD writes, low nibble = granted drive SD writes |
| `$DF0D` | high nibble = GCR checksum failures, low nibble = decoded GCR block completions |
| `$DF0E` | high nibble = SD write errors, low nibble = SD write-end pulses |
| `$DF0F` | high nibble = GCR checksum commits, low nibble = decoded GCR data bytes seen |
| `$DF10-$DF14` | captured write trace: count plus four bytes selected by writing the trace index to `$DF10` |

The UART-loadable SAVE diagnostic is:

```powershell
python tools/build_c64_save_diagnose_prg.py
python tools/c64_uart_prg_loader.py roms/c64/diag/diagnose.prg --port COM15
```

After resident-hook changes, an already formatted FAT16 SD card can be updated
without rebuilding the image or deleting `.d64` files:

```powershell
make mister64-sd-hook-block
tools/write_sd_hook_block.ps1 -DriveLetter G    # elevated PowerShell
```

The script writes only the `C64HOOK1` boot block at LBA 8, below the FAT16
partition, and verifies it afterwards. Re-run this after changing
`sw/c64_sd_fastload_hook.s`; a bitstream with the current `$2C` guard will not
enter an older hook block that still starts with the old `$4C`/`JMP` header.

There is also a standalone board project for testing only the floppy write path
without the C64 core: `boards/tang_primer_20k/c1541_selftest`.

For a direct `$DF0E` sector-write test from C64 BASIC, mount
`roms/test_d64/writetest.d64` and run `LOAD"WRITETEST",8` / `RUN`. That disk is
deliberately disposable and overwrites track 35 sector 16.

Reset = KEY[0] (T10). A short press is a normal C64 reset and leaves RAM
contents intact, matching the real machine. Hold KEY[0] for about one second to
request a cold FPGA reset: the core keeps reset asserted, clears all 64K C64 RAM
plus colour RAM, and then lets the original BASIC/KERNAL boot from a clean RAM
state.

The DDR fork also performs one automatic warm-reset pulse after power-up. This
is intentionally a one-shot state machine: it waits until DDR is ready and the
SD hook boot writes have drained, lets the machine run briefly, asserts the same
board reset path as KEY[0] for a short pulse, then disables itself until the next
real reset. Keyboard = PS/2 on PMOD0 (T7 clk / T8 data). Video = HDMI.

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
top ignores all other received bytes while the monitor is idle; with the SD
floppy build the CH340 link is otherwise free. The loader
also uses conservative UART pacing by default because the FPGA monitor writes
directly into C64 RAM and does not acknowledge each byte. The default streams
16 bytes per monitor line with no artificial delay, which keeps 16 KB uploads
practical at the fixed 115200 baud. If a board or older bitstream still drops
bytes, fall back to the old pacing with `--safe` or explicitly use
`--wake-sequence "0xA5 0x5A 0xC3 0x3C" --bytes-per-line 1 --line-delay 0.001`.

### UART monitor

The board carries the small `c64_prg_upload_monitor` (the full FLAT_64K
`uart_debug_monitor` no longer fits next to the SD floppy). Waking it with the
magic sequence `A5 5A C3 3C` pauses the C64 (RDY) and prints `FPGA MONITOR`;
it understands:

```text
L aaaa       enter hex load mode at aaaa, then send hex bytes; '.' ends it
M aaaa bbbb  hex dump aaaa..bbbb: 8 bytes per line plus an ASCII column
             (non-printable as '.'), reads RAM under ROM/I/O
G            release the C64 and leave the monitor
```

Interactive use from the PC:

```powershell
python tools/c64_uart_monitor_wake.py --port COM15
```

The monitor lives in `boards/tang_primer_20k/mister_c64_probe/rtl/` and is
shared with the probe board; the `M` dump sits behind the `ENABLE_DUMP`
generic, which only this board top enables.

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
python tools/c64_uart_prg_loader.py roms/c64/sid/Commando.prg --port COM15
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

### D64 game PRG upload fallback

For quick one-file tests, a ready-made `.d64` can still be handled entirely on
the PC by extracting one PRG and uploading it through the native C64 UART
monitor:

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
the desired starter. This bypasses the SD-backed 1541 completely and is useful
when debugging the UART monitor or trying a single-load/cracked game without
touching the SD card. Multi-load games that use normal KERNAL `LOAD` should use
the SD floppy path above; custom fastloaders and copy protection still need
deeper 1541/IEC compatibility work. After testing large uploads, use a long
KEY[0] reset if BASIC/KERNAL should restart with clean RAM instead of preserving
the uploaded program bytes.

### Virtual 1541 UART sector backend

The Python sector backend is the confirmed comparison path for IEC-loader
debugging. With `MISTER_1541_BACKEND => 2`, the 1541 CPU/VIA/IEC/GCR path
remains inside the FPGA, while `c1541_v1541_uart_sector_source` asks the Python
GUI for each D64 sector on demand.

Do not press `SEND HOOK` for this mode and do not use `LOAD"@",8`; there is no
SD hook installed. Start the Python drive, mount the D64, then use normal C64
disk commands:

```basic
LOAD"$",8
LIST
LOAD"*",8,1
RUN
```

The PC-side companion is:

```powershell
python tools/c64_1541_uart_gui.py --port COM15 --baud 230400 --folder E:\Emulatoren\C64\Games
```

The GUI answers the FPGA sector protocol (`CMD_SECTOR`) and the GCR engine
stretches the virtual disk rotation while a 256-byte sector is fetched.

#### Legacy KERNAL-hook UART transport

The older `$DE00/$DE01` KERNAL-hook transport is still useful for smoke tests
and RAM-hook experiments, but it is not enabled in the current Ultima sector
build (`HOST_UART_ENABLE => false`). Enable it only when intentionally testing
the hook path.

With that configuration the board top routes the native C64 host-disk UART to
the CH340 while the monitor is inactive. The C64 sees this transport at:

| Address | Direction | Meaning |
| --- | --- | --- |
| `$DE00` | read/write | UART data byte; reading consumes the received byte |
| `$DE01` | read | bit 0 = RX byte available, bit 1 = TX busy, bit 2 = RX overflow |

The PC-side companion for the legacy hook transport is:

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
python tools/c64_uart_prg_loader.py roms/c64/diag/v1541_ping.prg --port COM15
```

Then close the upload tool, start `tools/virtual_1541/c64_1541_uart_gui.py` on the same COM
port, and type `RUN` on the C64 keyboard. The PRG sends a binary `PING` frame
through `$DE00/$DE01` and prints the server reply.

The next-level test loads the first PRG from the mounted D64 through the same
transport. The small BASIC stub lives at `$0801`, but the loader itself runs at
`$C000` so it can safely load a normal BASIC PRG over `$0801`:

```powershell
make c64-v1541-loadfirst-prg
python tools/c64_uart_prg_loader.py roms/c64/diag/v1541_loadfirst.prg --port COM15
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
python tools/c64_uart_prg_loader.py roms/c64/diag/v1541_hook_diag.prg --port COM15
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

In this DDR fork, main RAM is externalized through `ddr3_byte_bridge`; colour
RAM, ROMs, FIFOs, SD buffers and the active 16K VIC shadow stay on-chip. The CPU
and monitor see normal C64 RAM semantics including RAM under ROM. The XL VIC is
fed from the shadow bank so its cycle fetch pattern does not become a DDR
bandwidth/timing problem. CIA2 bank switches update the visible shadow bank and
start a background reload; writes into the visible bank are mirrored immediately.

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

- **M1a — boot to `READY.`** done on hardware
  6510 + processor port, 64K RAM, PLA banking, VIC-II text/bitmap basics, CIA1
  keyboard + Timer-A jiffy IRQ. `sim/tb/tb_c64_core.vhd` boots the real ROMs and
  prints the full banner + `38911 BASIC BYTES FREE` + `READY.`. On hardware
  expect the blue screen, border, banner, blinking cursor, PS/2 typing, and the
  UART-upload graphics PRG above.
- **M1b — SD D64 loading and SAVE** ✅ normal KERNAL/IEC `LOAD`/`SAVE`
  through the SD-backed MiSTer 1541 path works with a contiguous FAT16 D64.
  Remaining: formatting/scratch workflows, copy protection, custom fastloaders
  and more exact 1541/VIC timing compatibility.
- **M2 — fuller VIC-II**
  The DDR build currently uses the XL VIC plus a 16K shadow bank; real game
  graphics have been verified clean after the shadow reload/write-through fixes.
  Remaining: more edge-case coverage, copy-protected titles and exact 1541/VIC
  compatibility.

## Known limitations (M1)
- VIC-II XL is enabled in this fork and uses a local 16K shadow of the active
  VIC bank. Games that depend on bitmap/charset background data now render
  cleanly, but cycle-exact edge cases remain active work.
- CHARGEN/RAM charset selection follows `$D018` for the common text-mode cases;
  the character-ROM window is modelled for VIC banks 0 and 2.
- CIA TOD is a simple BCD counter (no alarm); enough for the KERNAL fallback.
- In this DDR fork the 64K main RAM is already behind `ddr3_byte_bridge`; the
  remaining BSRAM users are ROMs, colour RAM, video line buffers, SD buffers and
  small FIFOs, plus the active 16K VIC shadow.
- Keyboard layout is a first-pass positional map (US-style); umlaut/extra keys
  and shifted cursor up/left are TODO.
