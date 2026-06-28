# C64 UART SID PRGs

Small SID-player PRGs generated for the Tang C64 UART monitor loader.

These are rebuilt from `sid_orig/*.sid` with:

```text
python tools/build_sid_prg.py sid_orig/Erebus.sid roms/c64_uart_sid/Erebus.prg --target c64
python tools/build_sid_prg.py sid_orig/Cool_Tune.sid roms/c64_uart_sid/Cool_Tune.prg --target c64
python tools/build_sid_prg.py sid_orig/Simple_Music.sid roms/c64_uart_sid/Simple_Music.prg --target c64
```

The C64 target uses the VIC raster register `$D012` as the 50/60 Hz frame wait.
The older SBC/D64 PRGs use `$883A` and will stall on the C64.

Upload one tune:

```text
python tools/c64_uart_prg_loader.py roms/c64_uart_sid/Erebus.prg --port COM15
```

Start it on the C64:

```text
SYS 8192
```
