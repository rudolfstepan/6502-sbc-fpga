# MiSTer C64 Sources

This directory contains selected C64 and IEC/1541 sources copied from the local
`C64_MiSTer` reference tree used during bring-up.

Imported source files are kept unmodified unless explicitly noted in future
commits:

- `rtl/t65/T65_Pack.vhd`
- `rtl/t65/T65_ALU.vhd`
- `rtl/t65/T65_MCode.vhd`
- `rtl/t65/T65.vhd`
- `rtl/dprom.vhd`
- `rtl/spram.vhd`
- `rtl/mos6526.v`
- `rtl/video_sync.vhd`
- `rtl/fpga64_rgbcolor.vhd`
- `rtl/video_vicII_656x.vhd`
- `rtl/iec_drive/c1541_logic.sv`
- `rtl/iec_drive/iecdrv_misc.sv`
- `rtl/iec_drive/iecdrv_via6522.vhd`
- `rtl/iec_drive/c1541_rom.mif`

The wrapper and Gowin-facing ROM conversion live in this repository under
`rtl/c64/`.

Upstream attribution from the imported files includes Sorgelig/MiSTer, Dar
FPGA, Mark McDougall, and Gideon Zweijtzer. Preserve the original file headers
when updating this copy.
