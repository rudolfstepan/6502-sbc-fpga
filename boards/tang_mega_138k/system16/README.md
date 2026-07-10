# Tang Mega 138K System16

Experimental 16-bit computer project for the Tang Mega 138K / Tang Console
board. This tree is intentionally separate from the existing 6502 SBC port.

Current first milestone:

- fx68k configured as the active Motorola 68000-compatible CPU core.
- 68000-style bus (`AS`, `UDS/LDS`, `R/W`, `DTACK`).
- 1 KiB internal boot ROM and 2 KiB scratch BSRAM.
- External 16-bit SDRAM0 main memory with a dedicated 68000 `DTACK` bridge.
- SDRAM clock follows the 50 MHz controller clock, matching the Tang 138K SBC
  SDRAM0 implementation.
- On-board DDR3 is intentionally reserved for the future graphics framebuffer.
- Internal 68000 boot monitor with reset vectors and UART banner.
- Raw-sector SD boot loader for the on-board TF slot. A valid image is loaded
  into external SDRAM before the CPU starts; missing or invalid media falls
  back to the UART monitor after the boot watchdog expires.
- 115200-baud UART with polled TX and buffered RX registers.
- 1280x720 HDMI/DVI color bars through the proven Tang 138K diagnostic PLL
  and TMDS path, with the firmware status color in the top band.
- Four diagnostic GPIO outputs on the same safe pins used by the SBC port.

Memory map draft:

| Address range | Width | Function |
| --- | --- | --- |
| `$000000-$0003FF` | 16 bit | Boot ROM |
| `$000400-$0007FF` | 16 bit | Reserved/unmapped |
| `$000800-$000FFF` | 16 bit | 2 KiB boot/scratch BSRAM |
| `$001000-$EFFFFF` | 16 bit | External SDRAM0 main memory |
| `$F00000` | 16 bit | LED/status register |
| `$F00002` | 16 bit | video status/color register |
| `$F00010` | 16 bit | UART TX data (low byte on word writes) |
| `$F00012` | 16 bit | UART status: bit 0 TX ready, bit 1 RX pending |
| `$F00014` | 16 bit | UART RX data; reading clears pending |

On reset the monitor sends `SYSTEM16 READY` at 115200 baud, changes the top
video status band to green, sets the four diagnostic outputs and enters its
UART command loop. The reset supervisor stack starts at `$F00000` and grows
downward into external SDRAM. Input is echoed. Commands are case-insensitive:

- `?` prints help.
- `R` prints the current ready status.
- `T` writes and verifies alternating patterns across the complete 2 KiB
  scratch BSRAM.
- `X` writes and verifies 8 KiB at the start of external SDRAM.
- `Maaaaaa` reads one aligned 16-bit word from a six-digit hex address.
- `Waaaaaadddd` writes a 16-bit hex value to scratch BSRAM or external SDRAM.
  Writes are limited to `$000800-$EFFFFE`; odd addresses are aligned down.
- `Gaaaaaa` starts a program at an aligned external SDRAM address. An `RTS`
  returns to the monitor.

The `M` and `W` commands execute after their final hex digit, without requiring
Enter. `make firmware` assembles `sw/boot_monitor.s` and updates
`rtl/sys16_boot_rom_image_pkg.vhd` directly from the binary output.

## SD boot image

Build the standalone SD boot demo and its raw card image:

```sh
make sd-boot-image
```

This creates `sw/system16_sd_boot.img`. Write that image to the complete SD
card, not to a file on an existing filesystem. The raw image replaces the
card's partition table. On reset, a valid image prints `SYSTEM16 SD BOOT OK`
on the 115200-baud UART and runs directly from external SDRAM at `$001000`.

The 512-byte sector-0 header contains the `SYS16SD1` signature, 24-bit load and
entry addresses, a 32-bit payload length and a 32-bit additive checksum.
Payload data begins at sector 1. Create images for other raw 68000 binaries with:

```sh
python tools/make_system16_sd_image.py program.bin system16.img --load 0x001000 --entry 0x001000
```

Build and upload the external-SDRAM demo without rebuilding the FPGA:

```bat
make sdram-demo
sw\upload_hello_sdram.bat COM14
```

The uploader writes big-endian 16-bit words through the monitor, verifies the
image and starts it at `$001000`. Any raw 68000 binary can be loaded similarly:

```sh
python tools/upload_system16.py program.bin --port COM14 --address 0x001000 --verify --run
```

Rebuild the standalone firmware binary without starting Gowin:

```sh
make firmware
```

Build the bitstream on Windows without opening the Gowin IDE:

```bat
build.bat
```

The default keeps existing implementation data so Gowin can reuse it where
possible. `build.bat clean` removes generated synthesis and P&R data first;
`build.bat nofw` keeps the existing generated boot ROM package.

Build from this directory:

```sh
make build
```

Or from the repository root:

```sh
make tang_mega_138k-system16
```

The active 68000 core is fx68k from `third_party/fx68k`. It is GPL-3.0 per its
`LICENSE`. TG68K.C is also present locally for comparison, but it is not part of
the active Gowin project because its P&R runtime was too high for this bring-up.
The current ROM proves reset-vector fetch, instruction fetch, 16-bit MMIO,
UART output and internal/external memory tests. The next boot stages are the
DDR3 graphics backend, SD block access and a CP/M-68K BIOS, each kept as a
separate bus device.
