# C64 UART SID PRGs

This directory contains C64-loadable SID player PRGs for the Tang C64 UART
monitor loader. Each generated file has a BASIC header at `$0801`, so it can be
uploaded to the C64 core and started with `RUN`.

The PRGs are generated from the source SID files in `sid_orig/`. Rebuild all
convertible tunes with:

```text
make c64-sid-prgs
```

The bulk build writes the generated files to this directory and prints a
summary of converted and skipped SID files. It also writes a small
`*.prg.segments.json` sidecar next to each PRG. The sidecar keeps the PRG itself
standard, but lets the UART loader skip zero-filled gaps between the BASIC stub
and the SID player/payload.

A SID can also be converted individually:

```text
python tools/build_sid_prg.py sid_orig/Erebus.sid roms/c64_uart_sid/Erebus.prg --target c64
```

The default player tick is 50 Hz. For tunes that need a different CIA-driven
rate, rebuild that tune with `--play-hz`, for example `--play-hz 100`.

## Upload and Start

Upload one tune through the UART monitor:

```text
python tools/c64_uart_prg_loader.py roms/c64_uart_sid/Erebus.prg --port COM15
```

When the sidecar exists, the loader uses it automatically and prints the reduced
upload byte count. Use `--no-segments` to force the old contiguous PRG upload.

Then start it from the C64 BASIC prompt:

```text
RUN
```

## Notes

The C64 SID target is different from the older SBC/D64 SID PRGs:

- C64 PRGs use a BASIC `10 SYS ...` header at `$0801`.
- The player tick uses CIA Timer A at roughly 50 Hz, so PAL SIDs do not run at
  the core's 60 Hz video frame rate.
- The wrapper disables the VIC display while playing. That keeps the single-port
  RAM away from VIC fetch stalls and reduces audible timing jitter.
- Older SBC/D64 SID PRGs use the SBC timer at `$883A` and will stall on the C64.

Not every SID file can be wrapped safely. The converter skips files whose
payload overlaps one of the protected regions:

- the BASIC header and SID player loader area
- the C64 I/O hole around `$D000-$DFFF`
- the bitmap-safe RAM window reserved by the C64 graphics tests

Skipped files are reported by `make c64-sid-prgs`; they are not written as PRGs.
