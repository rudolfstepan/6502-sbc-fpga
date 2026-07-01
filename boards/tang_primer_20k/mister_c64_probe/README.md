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
- IEC lines looped back/released, no 1541 drive yet
- SID is stubbed out for the first fit/stability probe
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

If this core fits and reaches the BASIC screen, the next step is adding the
MiSTer `iec_drive`/`c1541_multi` path or a reduced GCR/track backend.

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
- Fits without SID/1541: about 45/46 BSRAM and 23% logic.
- Fits with minimal 1541 responder and SID stub: 12523/20736 logic (61%),
  7560/10368 CLS (73%), 46/46 BSRAM (100%).
- Fits with static directory GCR backend and SID stub: 12829/20736 logic (62%),
  7740/10368 CLS (75%), 46/46 BSRAM (100%).
- The full MiSTer platform shell (`emu`) is not used; it depends on MiSTer HPS,
  DDRAM, OSD, SD upload and Altera PLL/scaler blocks.
