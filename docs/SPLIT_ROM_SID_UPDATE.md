# Split ROM and Native SID Update

This note summarizes the firmware and upload changes introduced for the current
Tang Primer 20K build.

## What changed

The previous firmware layout treated `$C000-$FFFF` as one contiguous 16 KB ROM.
That overlapped the address space needed by the SID-compatible peripheral. The
shadow RAM remains 16 KB physically, but is now mapped into two CPU windows:

| CPU address | Image offset | Purpose |
| --- | --- | --- |
| `$A000-$CFFF` | `$0000-$2FFF` | EhBASIC or standalone application |
| `$D000-$EFFF` | none | I/O space; SID is at `$D400-$D418` |
| `$F000-$FFFF` | `$3000-$3FFF` | Kernel and hardware vectors |

Bitmap RAM was subsequently moved from the conflicting `$9010-$AF4F` window to
the dedicated `$6000-$7FFF` window. EhBASIC is configured with `Ram_top=$4000`,
so its working memory does not overlap the framebuffer.

`rom_offset()` in `sbc_pkg.vhd` performs this translation. `bus_decode.vhd`,
the Tang boot-monitor core, and the UART monitor use the same two windows.

## EhBASIC

EhBASIC was relocated to `$A000-$CFFF`; the kernel moved to `$F000-$FFFF`.
The fixed entry table is:

| Address | Entry |
| --- | --- |
| `$A000` | Reset |
| `$A003` | IRQ |
| `$A006` | NMI |

The kernel vectors at `$FFFA-$FFFF` point to this table. The builder produces:

- `roms/fpga_ehbasic_A000.bin` — 12 KB application segment;
- `roms/fpga_kernel_F000.bin` — 4 KB kernel segment;
- `roms/fpga_ehbasic_16kb.rom` — both segments in physical shadow-RAM order.

Upload and start it with:

```powershell
python tools\upload_monitor_hex.py --ehbasic --port COM15 --baud 115200 --run --verbose
```

`roms\upload\ehbasic.bat` provides the same command. A newly synthesized bitstream is
required because older monitor RTL rejects writes below `$C000`.

## Standalone ROMs and Soundsid

Standalone ROMs can no longer be linked across `$C000-$FFFF`. They must keep
code and read-only data inside `$A000-$CFFF`, leave the I/O hole unused, and put
vectors in the final six bytes of the `$F000` window.

`soundsid.rom` now follows this layout. Its wrapper runs at `$A000`, embeds the
original PSID payload at `$A04B`, copies that payload to its native `$1000`
address, and writes the emulated SID at `$D400-$D418`. The reset, IRQ, and NMI
vectors all point to `$A000`.

Build and upload:

```powershell
make -C sw soundsid
python tools\upload_monitor_hex.py roms\soundsid.rom --split-rom `
       --port COM15 --baud 115200 --run --verbose
```

Or use `make -C sw upload-soundsid`.
The Windows shortcut for an already-built image is
`roms\upload\soundsid.bat`.

## New uploader behavior

`tools/upload_monitor_hex.py` adds two modes:

- `--ehbasic` selects the two generated EhBASIC segment files;
- `--split-rom` splits one 16 KB physical image between `$F000` and `$A000`.

Both modes upload the `$F000` window first and the `$A000` window second. This
ensures `--run` can safely start the newly uploaded entry point. The uploader
also stops on monitor rejection and rejects the obsolete contiguous 16 KB
`--address 0xC000` workflow locally.

## Compatibility note

Old standalone images linked at `$C000` must be relinked. Merely splitting such
an image is unsafe when code or data occupies `$D000-$EFFF`. Reprogramming or a
full reset restores the persistent SD-loaded image; `roms\upload\ehbasic.bat` restores the
volatile EhBASIC image after running a standalone ROM.

The standalone Mandelbrot images have been migrated accordingly:

- `roms/mandelbrot_bitmap.rom` uses software fixed-point multiplication;
- `roms/mandelbrot_copro.bin` uses the `$88B0-$88BF` math coprocessor and the
  packed 180×120 RGB222 framebuffer mode.

Both start at `$A000`, access the framebuffer through `$6000-$7FFF`, and upload
with `--split-rom`. The coprocessor image changes VIC MODE from `$09` to `$0D`
when it crosses into framebuffer bank 1.
