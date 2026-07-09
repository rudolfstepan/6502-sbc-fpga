# Tang Primer 20K — 6502 SBC

The 6502 single-board computer core on the Sipeed Tang Primer 20K: a T65 CPU with
EhBASIC (SD-loaded), a VIC-style text/bitmap video path over HDMI, PS/2 keyboard,
UART, a math coprocessor, a hardware blitter, and a DDR3-backed bitmap
framebuffer. The current placement-safe graphics test build intentionally leaves
the SID/PT8211 audio path and the second SD-card controller disabled.

Build the bitstream with `./make_tang20k.ps1` from the repo root (it preserves
`impl/pnr/device.cfg`, which carries the DDR3 voltage settings).

## DDR3 framebuffers (320x200 / 640x400 8bpp, 320x200 RGB565)

The bitmap framebuffer lives in **DDR3**, not BSRAM — moving it there freed the
BSRAM the DDR3 IP's own FIFOs need. The three modes share the single
`rtl/core/peripherals/vic_fb_ddr3.vhd` controller (there is only one DDR3 app
port). It prefetches each scanline into a double line buffer and streams it to the
VIC. CPU pixel writes are collected by a small 16-byte write-combine buffer:
sequential writes to the same DDR3 burst are absorbed in `clk_x1` and flushed as
one complete unmasked burst before a conflicting read/fetch/blit. This avoids the
sustained masked-byte-write pattern that produced vertical drop-outs and
scattered stale pixels on the live board.
Pixels are reached through the banked `$6000-$7FFF` (8 KiB) window; the frames
live in different DDR3 regions so switching modes does not clobber the others.

- **320x200 8bpp** — `$9000` **bit 4** = 1. RGB332 (256 colours). Bank (0..7) in
  `$9000` bits 7:5; 64000-byte frame at DDR3 base `0`; shown 2x2.
- **640x400 8bpp** — `$9000` **bit 5** = 1. RGB332. Bank (0..31) in the dedicated
  `$9006` register bits 4:0; 256000-byte frame at DDR3 base `0x40000`; shown 1:1.
- **320x200 16bpp** — `$9000` **bit 6** = 1. RGB565 (65536 colours), **two bytes
  per pixel** (low = `GGGBBBBB`, high = `RRRRRGGG`). Bank (0..15) in `$9006`;
  128000-byte frame at DDR3 base `0x80000`; shown 2x2.

RGB565 maps 1:1 onto the 5:6:5 HDMI DAC — the most colour the hardware can show.
All three fill the same 640x400 content window. `hires` / `bpp16` pick the
controller's runtime geometry; the line buffer holds one 16-bit entry per pixel (8bpp
modes use only its low byte). RGB565 costs one extra BSRAM block for that 16-bit
buffer — watch the marginal DDR3 calibration. **640x400 RGB565 is not offered** (80
bursts/line would exceed the per-line DDR3 budget with the single-burst fetch).

> **Backed out — 320x240 full height (`$9007` bit 0).** A 240-line full-screen flag
> for the 320-wide modes was prototyped, then removed after it broke DDR3
> calibration during the earlier unconstrained DDR3 bring-up. The
> `mandelbrot_true240` source stays; re-enable only after re-checking the DDR3
> timing report and hardware calibration margin.

Removing the old BSRAM `fb_ram` retired the legacy bitmap modes (`$9000` bit 0
1bpp hires, bit 1 160x100, bit 3 180x120) — the three DDR3 modes are the only
bitmap modes now.

Demos (build with `make -C sw/6502`, upload with the `.bat` files under
`roms/6502/upload/`):

- `mandelbrot_bitmap` — 256-colour 320x200 Mandelbrot, software fixed-point multiply.
- `mandelbrot_copro` — same, but the hardware **math coprocessor** (`$88B0`) does
  the multiply — much faster.
- `mandelbrot_hires` — the coprocessor Mandelbrot at **640x400**, same view sampled
  twice as densely (four times the pixels of `mandelbrot_copro`).
- `mandelbrot_hires_zoom` — renders the 640x400 Mandelbrot once, copies a clean
  centre tile to RAM, and animates zoom frames from that immutable source.
- `mandelbrot_true` — the coprocessor Mandelbrot in **RGB565 true colour** at
  320x200, `MAX_ITER=64` with a smooth 64-entry palette — no visible colour banding.
- `test_ddr3_fb` — 8 vertical RGB332 colour bars, the 320x200 bring-up pattern.
- `test_ddr3_hires` — 640x400 XOR texture (`colour = colLow XOR rowLow`); its
  1-pixel detail only resolves cleanly if the hi-res path is truly 1:1.
- `test_ddr3_true` — 320x200 RGB565 smooth two-axis gradient; a clean gradient with
  no banding means the true-colour path is good.
- `mandelbrot_true240` — the 320x240 full-screen variant; **needs the backed-out
  `$9007` full-height flag**, so it will not display right on the current bitstream.

## Gowin timing closure

The Tang SBC graphics test build is timing-clean with GowinEDA V1.9.12.03 as of
the July 9, 2026 DDR3/blitter pass. This build disables SD2 and audio to keep the
GW2A-18 placer comfortably below the device limit while validating the DDR3
framebuffer path:

| Resource | Usage |
| --- | ---: |
| Logic | 10064 / 20736 (49%) |
| LUT/ALU/ROM16 | 8600 (7789 LUT, 811 ALU, 0 ROM16) |
| SSRAM | 244 |
| Register | 4311 / 16173 (27%) |

The latest PnR setup table reports a worst setup slack of **0.015 ns**; placement,
routing, timing analysis, and bitstream generation complete.

The earlier July 2026 timing pass for the fuller build showed:

| Clock | Constraint | Reported Fmax |
| --- | ---: | ---: |
| `clk_27mhz` | 27.000 MHz | 189.627 MHz |
| `clk_sys` | 54.002 MHz | 56.479 MHz |
| `clk_pix` | 27.000 MHz | 99.392 MHz |
| `ddr_clk_x1` | 100.000 MHz | 100.654 MHz |
| `ddr_mem` | 400.000 MHz | 2016.127 MHz |

The final report has `0` setup-violated endpoints and `0` hold-violated
endpoints. The previous large negative paths were mostly CDC/constraint issues:
raw DDR3 calibration status was gating the SBC boot/reset path from the DDR app
domain, and the SDC did not explicitly describe the generated SBC, pixel, DDR
app, and DDR memory clocks. `tang20k_sbc_top.vhd` now synchronises
`ddr_calib_complete` into `clk_sys` before it gates `sbc_boot_done`, and
synchronises `long_reset` into `clk_27mhz` before the DDR reset sequencer uses
it. `constraints/tang20k_sbc.sdc` now constrains the internal clocks, marks the
DDR app/memory clocks asynchronous to the SBC/HDMI clock tree, and carries the
DDR3 PHY calibration false paths that the generated Gowin IP needs.

There was also one real DDR app-clock critical path in `vic_fb_ddr3.vhd`: CPU
framebuffer writes used a stride/range compare to invalidate only one buffered
half-line. That logic sat on the 100 MHz DDR app clock. The controller later
moved to a CPU write-combine buffer, which also fixed the hardware pixel
drop-outs seen in cube and Mandelbrot stress tests.

Gowin still emits `TA1132` for
`hdmi_i/clkdiv_tmds_i/CLKOUT.default_gen_clk`; it is a generated TMDS clock with
no reportable endpoint frequency in this design and does not correspond to a
setup/hold violation in the current timing report.

## UART PRG monitor (magic-byte upload)

The old on-screen SD boot-debug screen and the heavy `uart_debug_monitor` are
gone. A small `c64_prg_upload_monitor` handles uploads, entered over UART by a
four-byte **magic wake sequence `A5 5A C3 3C`** (no button). `L aaaa` loads hex,
`.` ends, `M aaaa bbbb` dumps, and `G aaaa` runs at an address (a plain `G` just
releases). The upload scripts (`tools/upload_monitor_hex.py`, the `.bat` files)
send the wake automatically.

## Known state / TODO

- **SD2 D64 GoDrive and raw SD2 LOAD/SAVE are disabled** in this graphics test
  build. `sd2_i`, `disk_i`, and `sdraw_i` are replaced by idle tie-offs.
- **SID/PT8211 audio is disabled** in this graphics test build. The SID, CIA
  audio timer, and DAC are replaced by constant read values and muted pins.
- The CPU write-combine fix has been hardware-verified with the cube animation:
  no faulty/stale pixels were observed after the change.
