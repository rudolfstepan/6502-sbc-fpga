# Test D64 image

`testdisk.d64` is a 35-track D64 disk image for testing the FPGA D64 GoDrive
(see `docs/D64_DRIVE.md`).  It holds **runnable RAM PRGs**: SID-player programs
built from real `.sid` tunes, plus the Mandelbrot coprocessor demo.

## Contents

Every program is built as a RAM PRG whose **entry point is its load address**
(`$2000`), so they all run the same way: `LOAD "NAME"` then `CALL 8192`.

| Name             | Type                         |
|------------------|------------------------------|
| 3545_II          | SID tune (player PRG)        |
| AHEAD_CRACK_INTR | SID tune (player PRG)        |
| CAT              | SID tune (player PRG)        |
| LAST_STARFIGHTER | SID tune (player PRG)        |
| ZOIDS            | SID tune (player PRG)        |
| MANDEL           | Mandelbrot coprocessor demo  |

The SID PRGs copy their payload to the tune's native address at startup and play
it in a loop.  MANDEL renders to the VIC bitmap, waits for a key, then loops.
All run to completion in their own loop — reset / KEY0 to exit.

## Regenerate

```sh
make tunes-d64                 # rebuild testdisk.d64 (SID tunes + MANDEL)
make TUNES="sid_orig/Zoids.sid" tunes-d64    # custom tune set (+ MANDEL)
python tools/d64/list_d64.py roms/test_d64/testdisk.d64
```

`tools/build_sid_prg.py` wraps a PSID as a RAM PRG (entry = load address); the
Mandelbrot demo is linked at `$2000` via `sw/mandelbrot_copro_prg.cfg`.
`tools/d64/pack_d64.py` packs the `.prg` files into the D64.  Programs must load
and run entirely below the VIC bitmap window (`$6000`).

## On hardware

1. Copy `testdisk.d64` to the second SD card (FAT32, the `sd2_*` data disk).
2. In BASIC:
   ```basic
   LOAD "$"        : REM list the directory
   LOAD "ZOIDS"    : REM prints  LOADED CALL 8192
   CALL 8192       : REM run it (tune plays / Mandelbrot renders)
   ```

The first SD card (ROM loader) is unaffected.
