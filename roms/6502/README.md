# 6502 SBC ROM images

Prebuilt images for the **6502 SBC** (T65) core — mostly 16 KB **split shadow‑ROM**
maps (`$A000–$CFFF` + `$F000–$FFFF`, the `$D000–$EFFF` I/O hole left free).
Sources: `../../sw/6502/`.

Upload one:

    upload\<name>.bat                                        # one-click (sends the magic wake)
    python ..\..\tools\upload_monitor_hex.py <name>.rom --split-rom --run

Contents:

- `fpga_ehbasic_*` — EhBASIC + kernel (`.rom` split image, `.img` SD boot image,
  `_A000`/`_F000` split‑upload segments).
- `sound_*.rom`, `soundsid.rom`, `soundtest.rom` — native SID‑player tune ROMs.
- `mandelbrot_bitmap.rom` (256‑colour DDR3), `mandelbrot_copro.bin`.
- `test_ddr3_fb.rom` — DDR3 framebuffer bring‑up (colour bars).
- `adventure`, `cia_test`, `fb16_test`, `raster_test`, `sram_*`, `copro_selftest`,
  `upload_demo`, `kernel` — demos and diagnostics.
- `imgdisk/` — `show_image` slideshow parts; `ich_image.*` image data.
- `upload/` — one‑click `.bat` uploaders.
