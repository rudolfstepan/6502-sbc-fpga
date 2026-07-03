# Tang Primer 20K MiSTer C64 Probe

Experimental port of the MiSTer C64 core to the Tang Primer 20K board.

This is not a finished board target.  The goal is to test the MiSTer C64 core
as a larger reference block, separate from the native `rtl/c64` implementation.

Current scope:

- MiSTer `fpga64_sid_iec` C64 core
- Gowin-friendly ROM bridge using the generated `rtl/c64/c64_roms.vhd`
- internal 64K RAM
- fixed PAL/default configuration
- PS/2 keyboard bridge plus a Tang-proven C64 matrix feeding CIA1
- MiSTer 1541 IEC drive logic with a read-only D64 sector backend
- SID output through the native PT8211 path
- Tang HDMI/audio output reused from the native C64 project

Build:

```bat
cd boards\tang_primer_20k\mister_c64_probe\project
build.bat
```

Gowin IDE:

```text
boards\tang_primer_20k\mister_c64_probe\project\tang_mister_c64_probe.gprj
```

## SD-card 1541 backend

The simplest SD backend mode is intentionally raw and read-only to keep the full
MiSTer C64 + SID + 1541 design fitting on the Tang 20K.  It does not parse FAT32
yet.  In raw mode, the D64 image must start at SD LBA 0 in the expanded layout
used by `c1541_sd_d64_sector_source.vhd`.

The SD card is connected through the external PMOD1/GPIO microSD breakout, not
the Tang Primer's on-board SDIO slot:

```text
PMOD1 pin 5 / T11 -> SCK
PMOD1 pin 6 / P11 -> CS
PMOD1 pin 7 / T12 -> MOSI
PMOD1 pin 8 / R11 -> MISO
```

Raw image layout:

- one 256-byte D64 sector per 512-byte SD block
- D64 sector index `n` lives at SD LBA `n`
- only the lower 256 bytes of each SD block are used
- the upper 256 bytes are ignored/padded

Create a raw SD image from a 35-track D64:

```bat
python tools\d64\make_raw_sd_d64_image.py path\to\disk.d64 build\mister1541_sd.img
```

Or use the converter GUI:

```bat
tools\d64\start_d64_to_sd_image_gui.bat
```

Write `build\mister1541_sd.img` to a card with your normal image writer, insert
the card, program the bitstream, then use:

```text
LOAD"$",8
LIST
LOAD"*",8
RUN
```

This first stage proves PC-independent 1541 sector reads.  A FAT32 file selector
can be added later, but the direct FAT32 scanner was too large together with the
MiSTer core on GW2A-18.

### FAT16 multi-D64 experiment

The SD backend can also read a normal contiguous `.d64` file from a FAT16 card
image when its first LBA is supplied by the C64 side.  In this mode the file is
not expanded: D64 sector index `n` is read from `file_start_lba + n/2`, using
the lower half for even sectors and the upper half for odd sectors.

Create a deterministic FAT16 image with several `.d64` files:

```bat
python tools\d64\make_fat16_d64_card.py -o build\mister64_fat16.img ^
  roms\test_d64\testdisk.d64 roms\test_d64\multipart.d64 --size 32M ^
  --selector-table sw\c64_sd_d64_select_table.inc
```

Or build the FAT16 image and matching selector PRG in one step:

```bat
make mister64-fat16-d64-card
```

The tool writes one contiguous FAT16 file per `.d64`, prints one `start_lba`
per file, and can generate the selector table consumed by
`sw\c64_sd_d64_select.s`.  The current Tang top builds the MiSTer 1541 backend
in packed-D64 mode and exposes a small C64 I/O2 mount window:

```text
$DF00-$DF03  selected D64 start LBA, little endian
$DF04        write bit 0 = 1 to mount and invalidate the cached sector
$DF05        status: bit 0 SD ready, bit 1 drive active, bit 2 D64 mounted,
             bit 7 packed-D64 mode
$DF0D        write bit 0 = 1 to read the raw 512-byte SD block at the
             $DF00-$DF03 LBA into the fastload sector buffer (no mount
             needed); bit 1 selects the buffered 256-byte half.  Poll and
             read the result through $DF0B/$DF0A/$DF0C.
```

The same I/O2 window also contains an experimental direct-sector fastload port:

```text
$DF08        D64 track, 1-based
$DF09        D64 sector
$DF0A        buffered-sector byte offset
$DF0B        write bit 0 = 1 to read the requested sector, bit 1 = 1 to clear
             a pending error
             read status: bit 0 SD ready, bit 1 busy, bit 2 sector ready,
             bit 3 error, bit 4 D64 mounted, bit 7 packed-D64 mode
$DF0C        data byte at the buffered-sector offset
```

The fastload port refuses to start until a D64 has been mounted through
`$DF00-$DF04`, so run the selector first.  Drive and fastload SD reads go
through an arbiter that grants the SPI controller for one whole 512-byte
transfer at a time; a fastload request issued while the 1541 is reading is
simply queued instead of corrupting the drive's sector stream.  A hung
transfer sets the error bit after roughly half a second instead of freezing
the port.

The smoke-test loader uses that port to bypass IEC transfer for the first PRG
on the mounted disk:

```bat
make c64-sd-fastload-first-prg
python tools\c64_uart_prg_loader.py roms\diagnostics\sd_fastload_first.prg --port COM15
```

After upload, type `RUN`.  The loader parses the D64 directory, follows the PRG
sector chain directly through `$DF08-$DF0C`, patches BASIC pointers for `$0801`
programs, and returns to READY.

The resident KERNAL `LOAD` hook combines the fastloader and the FAT16 disk
menu in one program, so only a single UART upload per power-on is needed:

```bat
make c64-sd-fastload-hook-prg
python tools\c64_uart_prg_loader.py roms\diagnostics\sd_fastload_hook.prg --port COM15
```

After upload, type `RUN` once.  The hook lives at `$C000` and installs itself
at the KERNAL `LOAD` vector `$0330`.  Independently of that vector, the
patched KERNAL from `tools\patch_c64_kernal_load_vector.py` detects the
resident hook by its `JMP` opcode at `$C000` and enters it directly at
`$C003`, so the hook stays active even after RUN/STOP+RESTORE resets the RAM
vectors.  The guard stub saves and restores A around its signature check; an
earlier stub version clobbered A there, which turned every hooked LOAD into a
VERIFY and silently fell back to the IEC path.  Device-8 loads then work like
this:

```text
LOAD"@",8        FAT16 disk menu: scan the SD root dir, pick a .D64, mount it
LOAD"*",8,1      fastload the first PRG from the mounted D64
LOAD"PART1",8,1  fastload by name
LOAD"$",8        falls back to the original KERNAL/IEC path, like VERIFY
```

The menu path is the same FAT16 scanner as the standalone selector, including
the FAT-chain contiguity check, and returns to READY without touching the
BASIC program in memory.  RAM keeps the hook across resets; only a power
cycle requires a new upload.

The whole chain can be regression-tested without hardware:

```bat
make c64-sd-hook-test
```

builds the hook PRG, generates a FAT16 card image from the test D64s and runs
`tools\test_c64_sd_hook.py`: a small 6502 emulator executes the real PRG
against the image with the `$DF00-$DF0D` window emulated, and every fastload
is compared byte-for-byte against an independent Python D64 parse.

The disk selector runs entirely on the C64: `sw\c64_sd_fat16_select.s` parses
the FAT16 filesystem itself through the `$DF0D` raw-block window.  It handles
both an MBR card with one FAT16 partition and the `--superfloppy` layout,
scans the root directory for `*.D64` entries (up to 16, keys `1-9`/`A-G`),
walks the FAT chain of the selected file to make sure it is stored
contiguously — fragmented files are refused because the packed-D64 backend
computes sector LBAs arithmetically — and then mounts the file's start LBA
through `$DF00-$DF04`:

```bat
make c64-sd-fat16-selector-prg
python tools\c64_uart_prg_loader.py roms\diagnostics\sd_fat16_select.prg --port COM15
```

Because the card is read live, `.d64` files copied onto the card later (for
example under Windows) show up without regenerating anything; they only need
to be unfragmented, which freshly written files on a defragmented card are.

The older table-based selector still works as a fallback and does not depend
on the `$DF0D` window:

```bat
make c64-sd-d64-selector-prg
python tools\c64_uart_prg_loader.py roms\diagnostics\sd_d64_select.prg --port COM15
```

The monitor is entered by the same wake sequence as the native Tang C64 target,
pauses the MiSTer C64 core, writes the PRG into C64 RAM, fixes BASIC pointers
for `$0801` PRGs, and releases back to READY.  Type `RUN`, choose one of the
listed entries, and use:

```text
LOAD"$",8
LIST
```

The table-based selector is PC-assisted: the FAT16 image builder generates its
table of names and LBAs at card-creation time, so it cannot see files added to
the card afterwards.  The FAT16 selector above supersedes it for normal use.

The helper scripts `tools\d64\write_raw_sd_image.ps1` and
`tools\d64\verify_raw_sd_image.ps1` can write/verify the image against a Windows
PhysicalDrive when run with the necessary permissions.  Be careful to select the
SD card, not a system disk.

Build status:

- Hardware test 2026-07-01: reaches the BASIC V2 screen and stays stable
  without the freeze seen in the native IEC experiments.
- Hardware test 2026-07-01: PS/2 input works with the local simple keyboard
  matrix; the original MiSTer `fpga64_keyboard` did not drive CIA1 correctly in
  this Gowin probe.
- Hardware test 2026-07-01: BASIC `RUN` loops are stable after gating the
  external 64K RAM write enable with `ramCE`; ungated `ramWE` corrupted RAM
  during I/O cycles.
- Build test 2026-07-01 with Gowin V1.9.12.03: minimal MiSTer 1541 IEC
  responder fits and produces a bitstream.
- Hardware test 2026-07-01: with the minimal MiSTer 1541 IEC responder,
  `LOAD"$",8` no longer hangs at `SEARCHING`; it returns `FILE NOT FOUND`
  because no disk/track backend is connected yet.
- Hardware test 2026-07-01: static read-only GCR track backend works for
  `LOAD"$",8` and `LIST`; the 1541 DOS reads the synthetic empty directory
  from track 18.
- Hardware test 2026-07-01: the static backend loads and runs a two-sector
  `HELLO` PRG through the 1541 DOS sector chain. The image bytes are separated
  into `c1541_static_d64_image.sv` as a `track/sector/offset -> byte` layer for
  later UART/SDRAM/D64 replacement.
- Build test 2026-07-02 with Gowin V1.9.12.03: raw SD-card D64 backend
  (`D64_BACKEND=3`) fits and produces a bitstream.  FAT32 auto-mount was tested
  first but exceeded GW2A-18 logic resources, so this stage uses a D64 at SD
  LBA 0.
- Hardware test 2026-07-02: external PMOD1/GPIO SD breakout works with the raw
  expanded D64 layout.  `LOAD"$",8` and `LIST` show the directory through the
  MiSTer 1541 DOS/IEC path.  Earlier tests accidentally constrained the SD
  signals to the Tang on-board SDIO slot; the working pinout is the PMOD1
  breakout listed above.
- Hardware test 2026-07-02: packed FAT16 multi-D64 mode works with the C64-side
  selector.  Selecting `MULTIPAR.D64` mounts the second D64, and `LOAD"$",8`
  lists `PART1` and `PART2` through the MiSTer 1541 DOS/IEC path.
- Build test 2026-07-03 with Gowin V1.9.12.03: experimental `$DF08-$DF0C`
  direct-sector fastload port fits and produces a bitstream.  Resource use is
  tight: 19923/20736 logic (97%), 10146/10368 CLS (98%), 46/46 BSRAM (100%).
- Debug 2026-07-03: `LOAD"*",8,1` with the resident hook fell back to the IEC
  path and ended in `?FILE NOT FOUND ERROR`.  Root cause was the KERNAL guard
  stub at `$ECB9`: its `LDA $C700` signature check clobbered the LOAD/VERIFY
  flag in A, so the hook always saw a VERIFY request.  The stub now saves A on
  the stack.  Fixed in the same pass: the hook polled the `$DF0B` sector-ready
  bit with inverted logic (never waited for the SD transfer) and compared
  filenames two bytes past the directory entry name field.  The fastload port
  gained an SD arbiter (drive and fastload requests are queued per 512-byte
  transfer), a D64-mounted status bit, a mount guard, and a ~0.5 s watchdog
  that flags a hung transfer as an error.  Requires rebuilding the bitstream
  (`make c64-roms` regenerated `rtl/c64/c64_roms.vhd` with the fixed stub) and
  re-uploading `sd_fastload_hook.prg`.
- Added 2026-07-03: `$DF0D` raw SD block window and the C64-side FAT16
  selector `sw\c64_sd_fat16_select.s`.  Verified in a 6502 emulator against
  images from `make_fat16_d64_card.py`: MBR and superfloppy layouts mount the
  exact `start_lba` values the builder prints, and a file with a broken FAT
  chain is refused as fragmented.  Not yet tested on hardware.
- Added 2026-07-03: fastloader and FAT16 menu merged into one resident hook
  (`LOAD"@",8` opens the menu).  The hook moved from `$C700` to `$C000` for
  the extra room; the KERNAL guard stub now checks `$C000`/`$C003`, so the
  KERNAL ROM and bitstream must be rebuilt again.  The emulator test drives
  the full chain against a generated FAT16 card: install, unmounted-load
  error, menu mount of both disks, `LOAD"*"` and named fastloads verified
  byte-for-byte against an independent D64 parse, missing-file error, and
  `$`/VERIFY fallback.  The test also caught a V2 bug where `restore_zp`
  clobbered the returned end address, which would have corrupted VARTAB
  after every BASIC fastload.  The harness is checked in as
  `tools\test_c64_sd_hook.py` (`make c64-sd-hook-test`).
- Hardware test 2026-07-03: the combined hook works on the Tang board with
  the rebuilt bitstream: `LOAD"@",8` scans the card and mounts, `LOAD"*",8,1`
  and named loads run through the `$DF08-$DF0C` fastload port.
- Tooling 2026-07-02: `tools\d64\d64_to_sd_image_gui.py` and
  `tools\d64\make_raw_sd_d64_image.py` generate the expanded raw image format
  used by the FPGA backend.
- Next static-image test: directory now contains `HELLO` and `SECOND`, allowing
  one hardware build to verify `LOAD"*",8`, `LOAD"HELLO",8` and
  `LOAD"SECOND",8` through the same 1541 DOS path.
- Fits without SID/1541: about 45/46 BSRAM and 23% logic.
- Fits with minimal 1541 responder and SID stub: 12523/20736 logic (61%),
  7560/10368 CLS (73%), 46/46 BSRAM (100%).
- Fits with static directory GCR backend and SID stub: 12829/20736 logic (62%),
  7740/10368 CLS (75%), 46/46 BSRAM (100%).
- The full MiSTer platform shell (`emu`) is not used; it depends on MiSTer HPS,
  DDRAM, OSD, SD upload and Altera PLL/scaler blocks.
