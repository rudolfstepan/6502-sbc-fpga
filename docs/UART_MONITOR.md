# FPGA UART Monitor and Live ROM Upload

The SD boot bitstream includes a small hardware monitor that can take over the
6502 bus through the board UART. It is meant for bring-up and firmware
development: inspect memory, patch bytes, disassemble small ranges, and upload a
new ROM data into the shadow-ROM RAM without rewriting the SD card. The current
Tang build exposes that RAM through two CPU windows rather than one contiguous
window.

## Hardware Entry

The monitor is instantiated in both active board tops:

- PIX16: `boards/pix16/rtl/pix16_sbc_sd_boot_top.vhd`
- Tang Primer 20K: `boards/tang_primer_20k/rtl/tang20k_sbc_top.vhd`

PIX16:

1. Program the PIX16 with the `pix16_sbc_sd_boot_top` bitstream.
2. Open the board UART at `230400 8N1`.
3. Press hardware button `KEY0`.

Tang Primer 20K:

1. Program the Tang with the `tang20k_sbc_top` bitstream.
2. Open the CH340 UART, for example Windows `COM15`, at `115200 8N1`.
3. Press hardware button `KEY1`.

In both cases:

4. The monitor holds the T65 through `monitor_hold`, prints:

```text
FPGA MONITOR
H for help
.
```

While the monitor is active, the CPU is stopped and CPU-side UART RX is gated
off. The monitor uses the same UART TX serializer as the boot/debug output and
the 6502 UART, but the board top gives the monitor priority while it is active.

## Commands

Commands are case-insensitive. Hex values may be entered with or without `$`.

| Command | Description |
| --- | --- |
| `H` or `?` | Print help. |
| `M addr [end]` | Hex dump memory. Dumps 16 bytes per line and appends an ASCII column. Non-printable bytes are shown as `.`. |
| `D addr [end]` | Disassemble memory starting at `addr`. If `end` is omitted, a short default range is used. |
| `U addr [end]` | Alias for `D`, following common monitor naming. |
| `E addr byte` | Write one byte to memory. |
| `W addr byte` | Alias for `E`. |
| `: addr byte` | Compact byte-write form, useful for quick patches. |
| `L addr` | Enter hex-loader mode and write sequential bytes starting at `addr`. End the upload with a single `.` line. |
| `G [addr]` | Leave the monitor and resume the 6502. With an address, the reset vector is overridden briefly and the CPU is restarted there. |

Examples:

```text
M 8000 80FF
D A000 A040
E 8050 41
L A000
```

## Accessible Address Ranges

The monitor uses a small memory-master inside `sbc_t65_sdram_boot_top.vhd`
on PIX16 and `sbc_t65_boot_monitor_top.vhd` on Tang.
Currently supported ranges are:

| Range | Target |
| --- | --- |
| `$0000-$3FFF` | Internal BRAM main memory, including zero page, stack, and EhBASIC workspace. |
| `$4000-$5FFF` | External DDR3 main RAM. |
| `$6000-$7FFF` | 8 KB window into the banked 16 KB VIC framebuffer; MODE bit 2 selects the bank. |
| `$8000-$87FF` | VIC text VRAM. Writes are visible immediately on VGA. |
| `$8800-$880F` | VIA 6522 registers. Port B bit 0 is connected to board LED 1 after boot. |
| `$8810-$8813` | UART 6551 registers. |
| `$A000-$CFFF` | 12 KB shadow ROM: application/EhBASIC window. |
| `$F000-$FFFF` | 4 KB shadow ROM: kernel/vector window. |

`$D000-$EFFF` is not ROM in the current Tang map. It is reserved for I/O;
notably, the SID-compatible registers occupy `$D400-$D418`. A loader operation
must not cross from `$CFFF` into this hole.

Sprite and blitter ranges remain unavailable where no physical implementation
exists. Bitmap RAM is implemented separately at `$6000-$7FFF`.

When using monitor reads/writes on the framebuffer, set `$9000` first: `$03/$07`
select RGB332 bank 0/1 and `$09/$0D` select packed RGB222 bank 0/1. The legacy
1-bpp mode uses `$01` and normally keeps bank 0 selected.

## Hex Loader Mode

`L addr` switches the monitor into a raw hex-byte input mode:

```text
. L A000
LOAD HEX . END
> A9 20 8D 00 80
> 4C 00 A0
> .
OK
.
```

Rules:

- Each byte is two hex digits.
- Spaces, newlines, commas, and `$` are ignored.
- A single `.` ends the upload.
- If an odd number of hex nibbles was entered, the monitor returns `ERR`.
- Uploads may not cross holes in the monitor-accessible memory map.

For a full 16 KB ROM image, use the Python uploader instead of typing hex by
hand.

## Python Upload Tool

The helper script `fpga/tools/upload_monitor_hex.py` automates `L`, streams the image
as hex lines, sends `.`, and optionally starts the CPU with `G`.

Default settings:

| Setting | Value |
| --- | --- |
| Port | `COM15` on PIX16 examples; Tang has been tested as `COM12` |
| Baud | `115200` in the current Tang bitstream |
| Load address | `$C000` for a legacy single segment; explicit modes are preferred for split images |
| Image | `fpga/roms/upload_demo.rom` |

EhBASIC uploads the kernel first and the BASIC window second, then starts at
`$A000`:

```sh
python tools/upload_monitor_hex.py --ehbasic --port COM15 --baud 115200 --run --verbose
```

The same operation, including rebuilding EhBASIC, is available through:

```sh
python tools/build_fpga_ehbasic.py --upload --port COM15 --baud 115200 --run --verbose
```

Standalone 16 KB images built in physical split-ROM order use `--split-rom`.
The uploader sends bytes `$3000-$3FFF` to `$F000`, then bytes `$0000-$2FFF`
to `$A000`, and `--run` starts at `$A000`:

```sh
python tools/upload_monitor_hex.py roms/soundsid.rom --split-rom \
       --port COM15 --baud 115200 --run --verbose
```

The old command `--address 0xC000` is invalid for a contiguous 16 KB image in
the split map because it would overwrite the I/O hole. The uploader detects
this case before opening the serial port. It also reports monitor-side
`MEM/IO ONLY` and `?` responses instead of claiming that the upload completed.

If the upload fails with an access error, another serial terminal still has the
COM port open. Close the terminal and run the command again.

## Legacy Demo ROM Generator

`fpga/tools/make_upload_demo_rom.py` creates a simple 16 KB ROM at
`fpga/roms/upload_demo.rom`. It is hand-assembled by a tiny Python builder so it
has no cc65 dependency.

The bundled demo still uses the legacy contiguous `$C000-$FFFF` layout. It is
useful on the corresponding PIX16/legacy configuration, but must be relinked
before use with the current Tang split map. It does the following:

1. Initialize stack and VIA Port B.
2. Clear the 2 KB text VRAM.
3. Write a few status lines to VGA.
4. Print one UART banner.
5. Toggle VIA Port B bit 0 slowly so board LED 1 blinks.

Generate it explicitly:

```sh
python fpga/tools/make_upload_demo_rom.py
```

The reset, NMI, and IRQ vectors at `$FFFA-$FFFF` all point to `$C000`, so
`G C000` is enough to start it after upload.

## SD Image vs. Monitor Upload

There are two firmware update paths:

- SD boot image: persistent across FPGA resets. Build with `make sd-boot-image`
  and write the raw image to the SD card.
- UART monitor upload: fast development loop. It modifies the shadow-ROM RAM
  after boot, so it is lost when the FPGA is reset or reprogrammed.

Use the SD image for stable firmware snapshots and the UART monitor for quick
ROM experiments.

## Legacy Demo Checks

After upload and `G C000`, the UART should print the demo banner once:

```text
[UPLOAD DEMO] ROM ACTIVE AT $C000
```

On VGA, row 2 and following rows should show the demo text. Board LED 0 is a
boot-status LED and may stay lit. Board LED 1 is driven by VIA Port B bit 0 and
should blink slowly.
