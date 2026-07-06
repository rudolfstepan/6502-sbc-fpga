# Software sources

Split by target machine — put new sources in the matching folder:

- **[6502/](6502/)** — the **6502 SBC** (T65 core). ROMs/PRGs uploaded over the
  UART monitor or from an SD boot image: EhBASIC, the SID player, Mandelbrot, the
  DDR3 framebuffer test, disk/RAM/copro diagnostics. Built with `make -C sw/6502`
  or ad‑hoc `ca65`/`ld65`. Outputs land in `../roms/6502/`.
- **[c64/](c64/)** — the **native C64** core. `c64_*` diagnostics, VIC/SID/1541
  tests, SD/D64 hooks, and `c64diag.s` (a reset‑boot ROM). C64 PRGs load at
  `$0801`. Outputs land in `../roms/c64/{prg,sid,diag}/`.

**Convention:** every C64 source is prefixed `c64_` (or `c64diag`); everything
else is 6502. The one shared image asset (`ich_image_bg.inc`) lives under
`6502/` and is included from `c64/` by relative path.
