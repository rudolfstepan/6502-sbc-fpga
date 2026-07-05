# Test D64 image

`testdisk.d64` is a 35-track D64 disk image for testing the FPGA D64 GoDrive
(see `docs/D64_DRIVE.md`).  It holds **runnable RAM PRGs**: SID-player programs
built from real `.sid` tunes, plus the Mandelbrot coprocessor demo.

For the native Tang Primer 20K C64 SD-floppy write path, use
`writetest.d64` as a disposable image. It is a real C64-style test disk, not an
SBC GoDrive application disk.

## Contents

Every program is built as a RAM PRG whose **entry point is its load address**
(`$2000`), so they all run the same way: `LOAD "NAME"` then `CALL 8192`.

| Name             | Type                         |
|------------------|------------------------------|
| 3545_II          | SID tune (player PRG)        |
| AHEAD_CRACK_INTR | SID tune (player PRG)        |
| CAT              | SID tune (player PRG)        |
| CHESS            | Chess game (text + PS/2 kbd) |
| LAST_STARFIGHTER | SID tune (player PRG)        |
| ZOIDS            | SID tune (player PRG)        |
| MANDEL           | Mandelbrot coprocessor demo  |

The SID PRGs copy their payload to the tune's native address at startup and play
it in a loop.  MANDEL renders to the VIC bitmap, waits for a key, then loops.
CHESS is the `sw/chess.s` game relinked from its standalone `$C000` ROM down to a
RAM PRG at `$2000`; it draws on the VIC text screen and reads moves from the PS/2
keyboard, looping in its own game loop.  All run to completion in their own loop
— reset / KEY0 to exit.

## Regenerate

```sh
make tunes-d64                 # rebuild testdisk.d64 (SID tunes + MANDEL + CHESS)
make TUNES="sid_orig/Zoids.sid" tunes-d64    # custom tune set (+ MANDEL)
python tools/d64/list_d64.py roms/test_d64/testdisk.d64
```

`tools/build_sid_prg.py` wraps a PSID as a RAM PRG (entry = load address); the
Mandelbrot demo is linked at `$2000` via `sw/mandelbrot_copro_prg.cfg`, and the
chess game via `sw/chess_prg.cfg` (both from `sw/*.s`).  `tools/d64/pack_d64.py`
packs the `.prg` files into the D64.  Programs must load and run entirely below
the VIC bitmap window (`$6000`).

## Full SID collection (`sid/`)

`make sid-disks` converts **every** convertible PSID under `sid_orig/` to a RAM
PRG and packs them into numbered images `sid/tunesNN.d64`, **at most 20 tunes per
image** so each directory fits one screen without scrolling (`--max-files`).
Tunes that can't run in this machine's RAM are skipped: those that load into the
shadow-ROM windows (`$A000+`/`$F000`, read-only here — no `$01` banking), IRQ/CIA
tunes with no play address, or payloads too large for RAM.  `Commando` is also
excluded — it only plays as the bespoke `roms/sound_commando.rom`, not via the
generic wrapper.  ~115 of ~199 tunes convert.

`build_sid_prg.py` wraps each tune one of two ways, chosen automatically:

- **copy-up** (default): the PRG loads at `$2000`, carries an embedded payload
  copy, and copies it down/up to the tune's native address at startup — so
  `CALL 8192` runs every one of these.
- **in-place** (fallback for tunes that load too high for two payload copies to
  fit under the `$6000` bitmap window): the payload loads straight at its native
  address with a ~`$80`-byte player just below it, so the entry point is that
  player, not `$2000`.

Either way the entry point is the PRG's load address, so it runs with
`CALL <load address>` — and `LOAD "NAME"` prints that address.  Copy a
`tunesNN.d64` to the data SD card as `TESTDISK.D64` (or mount it), then
`LOAD "$"` to see the list.

The intermediate per-tune `.prg` files (`prg/`, `sid/prg/`) are build products
and are not committed; the `.d64` images are.

## Native C64 writeback test disk

`writetest.d64` contains one C64 BASIC V2 program named `WRITETEST`. It fills
the `$DF0x` direct sector buffer, writes track 35 sector 16 through `$DF0E`,
reads the sector back from SD, and checks that the partner sector in the same
512-byte SD block was preserved by the read-modify-write flush.

Regenerate it with:

```powershell
python tools/d64/make_write_testdisk.py
```

Use it on the native C64 SD-floppy build:

```basic
LOAD"@",8
LOAD"WRITETEST",8
RUN
```

The program intentionally overwrites track 35 sector 16 of the mounted image.
Keep it on a disposable card/image; do not run it against a disk image you want
to preserve.

## On hardware

1. Copy `testdisk.d64` to the second SD card (FAT32, the `sd2_*` data disk).
2. In BASIC:
   ```basic
   LOAD "$"        : REM list the directory
   LOAD "ZOIDS"    : REM prints  LOADED CALL 8192
   CALL 8192       : REM run it (tune plays / Mandelbrot renders)
   ```

The first SD card (ROM loader) is unaffected.
