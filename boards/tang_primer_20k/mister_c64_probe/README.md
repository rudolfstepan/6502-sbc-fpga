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

The current SD backend is intentionally raw and read-only to keep the full
MiSTer C64 + SID + 1541 design fitting on the Tang 20K.  It does not parse FAT32
yet.  The D64 image must start at SD LBA 0 in the expanded raw layout used by
`c1541_sd_d64_sector_source.vhd`.

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
