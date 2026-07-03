# Pipistrello Project Notes

This directory documents the Saanlima Pipistrello Spartan-6 LX45 board port.
The port is kept as a Xilinx ISE 14.7 target and currently covers three bring-up
tracks: a minimal video smoke test, the 6502 SBC path, and the native C64 core.

## Board Target

- Board: Saanlima Pipistrello
- FPGA: Xilinx Spartan-6 `XC6SLX45-CSG324-3`
- Input clock: on-board 50 MHz oscillator
- Video: DVI-style TMDS on the Pipistrello HDMI connector
- Serial: FT2232 UART channel
- Storage: on-board SD slot for raw 6502 SBC boot images

## Repository Layout

```text
boards/pipistrello/
  Makefile                board-local build target dispatcher
  README.md               short board build guide
  docs/README.md          this project note
  docs/vendor/            archived Saanlima board documentation
  constraints/            UCF pin constraints per top-level
  project/                checked-in ISE .xise project files
  rtl/                    Pipistrello-specific top-levels and OSERDES glue
  scripts/                helper scripts for generated ISE projects
```

ISE output files are intentionally ignored. The `.xise` files are source files
and must stay version controlled.

## Build Targets

From the repository root:

```sh
make pipistrello-hdmi-test
make pipistrello-6502-hdmi
make pipistrello-6502-sd-hdmi
make pipistrello-c64
```

Each target points at a checked-in ISE project under `boards/pipistrello/project/`.
Open the matching `.xise` in ISE and run synthesis/implementation there.

## Current Project Files

```text
project/pipistrello_hdmi_test.xise       640x480 colour-bar HDMI/DVI test
project/pipistrello_6502_hdmi.xise       minimal 6502 SBC over HDMI/DVI
project/pipistrello_6502_sd_hdmi.xise    6502 SBC with raw SD ROM boot
project/pipistrello_c64.xise             native C64 core over HDMI/DVI
project/pipistrello_sbc_minimal.xise     small baseline SBC smoke project
```

## Vendor Board Files

The original Pipistrello wiki is offline, so the board files are mirrored from
the archived Saanlima download area:

```text
docs/vendor/saanlima-pipistrello-v2.0/pipistrello_v2_schematic.pdf
docs/vendor/saanlima-pipistrello-v2.0/pipistrello_v2_top.pdf
docs/vendor/saanlima-pipistrello-v2.0/pipistrello_v2_bottom.pdf
docs/vendor/saanlima-pipistrello-v2.0/pipistrello_v2.sch
docs/vendor/saanlima-pipistrello-v2.0/pipistrello_v2.brd
docs/vendor/saanlima-pipistrello-v2.0/pipistrello_v2.03.ucf
```

Source page:
`https://web.archive.org/web/20170124123137/http://pipistrello.saanlima.com/index.php?title=Welcome_to_Pipistrello`

## Native C64 Bring-Up

The native C64 target uses `rtl/c64/c64_core.vhd` with board-local clocking and
Spartan-6 TMDS output. The working bring-up path uses a simple DVI-style TMDS
encoder (`rtl/core/hdmi/tmds_encoder.vhd`) and the board-local
`rtl/serdes_n_to_1.vhd` OSERDES wrapper. The older reference DVI encoder/FIFO
path is not used by the C64 project.

The C64 project currently ties PS/2 idle-high and leaves audio unconnected. It
performs an automatic cold RAM/color-RAM scrub after PLL lock before releasing
the C64 core. Hardware bring-up has reached the BASIC V2 ready screen.

## 6502 SBC SD Boot

The 6502 SD boot project expects a raw image at sector 0 of the SD card, not a
FAT filesystem copy. Build the image from the repository root:

```sh
make sd-boot-image
```

Then write `sim/generated/sbc_ehbasic_sd.img` raw to the SD card.

## Notes

- Keep generated ISE products out of git (`.ngc`, `.ngd`, `.ncd`, `.bit`, logs,
  reports, `xst/`, `_ngo/`, `_xmsgs/`, `iseconfig/`, and similar files).
- Keep `.xise`, RTL, UCF constraints, scripts, and this documentation tracked.
- If ISE keeps stale source lists, close and reopen the project after changing
  `.xise` file references.
