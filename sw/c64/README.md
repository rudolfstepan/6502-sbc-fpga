# Native C64 software

Sources for the **native C64** core. C64 PRGs load at `$0801` and upload over
`tools/c64_uart_prg_loader.py`; outputs go to `../../roms/c64/{prg,sid,diag}/`.

- `c64diag.s` — reset‑boot diagnostic ROM, baked into `rtl/c64/c64_roms.vhd` by
  `tools/build_c64_diag.py` (no KERNAL/BASIC needed).
- `c64_*` — VIC/SID/CIA/1541 tests, SD/D64 fastload + hook experiments, RTI/hang
  diagnostics.

Every source here is C64 (prefix `c64_` / `c64diag`). The one shared image asset
`ich_image_bg.inc` is included from `../6502/` by relative path.
