# 6502 SBC software

Sources for the **6502 SBC** (T65 core). Outputs go to `../../roms/6502/`.

Maintained targets build with `make` here (see the `Makefile`):

    make mandelbrot-bitmap      # 256-colour DDR3 Mandelbrot
    make fpga-ehbasic           # EhBASIC + kernel split ROM
    make soundsid               # converted SID tune ROM
    make disk-test              # D64 GoDrive API test

Others build ad‑hoc, e.g. the DDR3 framebuffer test:

    ca65 --cpu 65c02 -o test_ddr3_fb.o test_ddr3_fb.s
    ld65 -C test_ddr3_fb.cfg -o ../../roms/6502/test_ddr3_fb.rom test_ddr3_fb.o

Upload over the UART monitor (the 4‑byte magic wake `A5 5A C3 3C` is sent
automatically — no button):

    python ../../tools/upload_monitor_hex.py ../../roms/6502/<name>.rom --split-rom --run

Every source here is 6502. C64 sources live in `../c64/`.
