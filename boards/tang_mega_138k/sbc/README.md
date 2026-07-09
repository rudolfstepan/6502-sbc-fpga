# Tang Mega 138K SBC

This is a first Tang Mega 138K port of the SDRAM/DDR framebuffer SBC build.
It follows the Tang Primer 20K SBC closely, but uses the GW5AST-138 device,
the Sipeed 32-bit DDR3 controller example, and the Sipeed DVI transmitter.

Current bring-up choices:

- 50 MHz board oscillator as `clk_sys`.
- 25 MHz DVI pixel clock / 125 MHz bit clock, so the core uses the existing
  VGA-compatible `CEA_480P=false` video path.
- 32-bit DDR3 IP adapted to the existing 128-bit `vic_fb_ddr3` app interface
  by using the low 128-bit lane and masking the upper half.
- UART pins, HDMI0, DDR3, audio, clock and SD CMD/CLK/DAT0 pins are copied from
  Sipeed's TangMega-138K examples.

Build from the repository root with:

```sh
make tang_mega_138k-sbc GOWIN=C:/Gowin/Gowin_V1.9.12.03_x64/IDE/bin/gw_sh.exe
```

This target has been verified through placement, routing, and bitstream
generation with Gowin V1.9.12.03.

For the Gowin GUI, open `project/tang138k_sbc.gprj`. The matching IDE process
configuration is kept in `project/impl/tang138k_sbc_process_config.json`, so
the GUI build uses the same top module, output name, VHDL standard, timing
driven routing, and dual-purpose CPU/SSPI-as-GPIO settings as `build.tcl`.

TODO before hardware use:

- Confirm the desired PS/2 and SD2 breakout header pins for your console wiring.

Resolved:

- SD-card DAT3/SPI-CS is W15 (confirmed against nand2mario's 486tang/NESTang
  `console.cst` for the Tang Console 138K, which also matches our CLK/CMD/DAT0
  pins). The earlier placeholder on W21 made SPI-mode init impossible: without
  CS the card never leaves SD-bus mode, `sd_init_done` never asserts, the boot
  loader waits forever and the CPU stays parked (black screen).
- `sdram0_cs_n` is F21 on the Tang Console 138K; F19 is the Mega-60K location.
