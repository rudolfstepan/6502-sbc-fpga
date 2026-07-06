# Tang Primer 20K — 6502 SBC

The 6502 single-board computer core on the Sipeed Tang Primer 20K: a T65 CPU with
EhBASIC (SD-loaded), a VIC-style text/bitmap video path over HDMI, PS/2 keyboard,
UART, SID + PT8211 audio, a math coprocessor, and a DDR3-backed bitmap framebuffer.

Build the bitstream with `./make_tang20k.ps1` from the repo root (it preserves
`impl/pnr/device.cfg`, which carries the DDR3 voltage settings).

## DDR3 320x200 8bpp framebuffer

`$9000` **bit 4** selects a 320x200, 256-colour (RGB332, one byte per pixel)
bitmap that lives in **DDR3**, not BSRAM — moving it there freed the BSRAM the
DDR3 IP's own FIFOs need. Pixels are reached through the banked `$6000-$7FFF`
window: `$9000` bits 7:5 pick the 8 KiB bank, so the 64000-byte frame spans 8
banks. The controller is `rtl/core/peripherals/vic_fb_ddr3.vhd`: it prefetches
each scanline into a double line buffer and streams it to the VIC, and takes CPU
pixel writes as **masked single-byte writes** (no read-modify-write, so a marginal
DDR3 read can't smear neighbouring pixels).

Removing the old BSRAM `fb_ram` retired the legacy bitmap modes (`$9000` bit 0
1bpp hires, bit 1 160x100, bit 3 180x120) — bit 4 DDR3 is the only bitmap mode now.

Demos (build with `make -C sw/6502`, upload with the `.bat` files under
`roms/6502/upload/`):

- `mandelbrot_bitmap` — 256-colour Mandelbrot, software fixed-point multiply.
- `mandelbrot_copro` — same, but the hardware **math coprocessor** (`$88B0`) does
  the multiply — much faster.
- `test_ddr3_fb` — 8 vertical RGB332 colour bars, a framebuffer bring-up pattern.

## UART PRG monitor (magic-byte upload)

The old on-screen SD boot-debug screen and the heavy `uart_debug_monitor` are
gone. A small `c64_prg_upload_monitor` handles uploads, entered over UART by a
four-byte **magic wake sequence `A5 5A C3 3C`** (no button). `L aaaa` loads hex,
`.` ends, `M aaaa bbbb` dumps, and `G aaaa` runs at an address (a plain `G` just
releases). The upload scripts (`tools/upload_monitor_hex.py`, the `.bat` files)
send the wake automatically.

## Known state / TODO

- **SD2 D64 GoDrive is currently disabled** (commented out in
  `rtl/core/sbc_t65_boot_monitor_top.vhd` and `.../sbc/rtl/tang20k_sbc_top.vhd`).
  Its `fat32_reader` had a ~-215 ns combinational setup path (oversized 40x32 /
  32x32 multiplies + a 32-bit divide) that, on top of the unconstrained DDR3,
  pushed the marginal DDR3 calibration over the edge. Uncomment `disk_i` + `sd2_i`
  (and drop the tie-offs) to restore it; the right fix is to right-size that
  arithmetic and constrain the DDR3 clocks. SD1 (the EhBASIC boot loader) is
  untouched.
- **DDR3 leaves a few scattered pixel errors** in the framebuffer read path. That
  is the VREF/Gowin-version issue — VREF=INTERNAL wants Gowin 1.9.8.08. The DDR3
  clocks are intentionally left unconstrained in `constraints/tang20k_sbc.sdc`;
  see the comments there before adding constraints (separate app/mem clock groups
  break the PHY).
