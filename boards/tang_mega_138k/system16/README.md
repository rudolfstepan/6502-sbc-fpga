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

## RV32 Linux path

The m68k build remains the default.  The parallel RV32 path uses a
little-endian 32-bit request/ready bus and is intended for an RV32IMA core with
Sv32 MMU support.  `sys16_bus32_to_sdram16.vhd` lets that bus use SDRAM0 now;
it preserves four byte enables while issuing two 16-bit memory cycles.
`sys16_timer32.vhd` supplies a 1 MHz, CLINT-style `mtime`/`mtimecmp` machine
timer plus `msip` at `$F0001000`.

The remaining CPU integration must expose separate timer/software/external
interrupt inputs and boot at `$00001000`.  A core without Sv32 is deliberately
not accepted for this profile: it would only move the project back to a
no-MMU Linux port.  Run the bus regression with `make sim-rv32`.

The generated `VexRiscvSystem16.v` now implements RV32IMA, supervisor mode and
Sv32 with 4 KiB instruction/data caches. `sys16_rv32_soc.vhd` arbitrates its
cache-fill ports, maps the CLINT timer and exposes one external interrupt. The
core resets at `$00001000`, with the initial machine trap vector at `$00001020`.

Linux 6.12.95 LTS is used by this profile. The image is loaded at the required
RV32 4 MiB boundary (`$00400000`); the board DTS exposes the remaining 11 MiB
through `$00EFFFFF` to Linux and reserves low memory for OpenSBI/boot data.
The DTS, size-oriented config fragment and reproducible build script are in
`linux/`. OpenSBI 1.8.1 is the selected M-mode firmware.

With current GNU binutils, build OpenSBI using
`PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei`; CSR and instruction-fence
extensions are no longer implied by the base `rv32ima` spelling.

The SD image starts with a four-instruction shim at `$001000`. It passes hart
zero and the DTB address `$3F0000` to generic OpenSBI at `$002000`; OpenSBI then
jumps to Linux at `$400000`. Accordingly OpenSBI must use
`FW_TEXT_START=0x00002000`.

On Windows, `make linux-image-wsl` imports OpenSBI, the DTB and the kernel
directly from the default WSL distribution, validates the OpenSBI ELF entry
point and creates the SD image. It refuses firmware not linked at `$00002000`.
Use `make qemu-test` for a 25-second software sanity boot on QEMU's RV32
`virt` machine. This verifies the kernel and early console independently of
the System16 SDRAM and bus logic; install `qemu-system-riscv` in WSL once
(`qemu-system-misc` is the package name on some older distributions).

## GoRV32 Plus vendor Linux path

This is the hardware-verified Linux profile: the complete chain reaches Linux
6.12.95 and a BusyBox shell from the embedded initramfs. Hart 1 remains parked
and Linux runs on hart 0. See `linux/README.md` for the consolidated
architecture, build order, artifact list and known constraints, and
`linux/gorv32-brennen.md` for the exact programming procedure.

`tang138k_system16_gorv32plus.gprj` is the second Linux route. It uses
Gowin's encrypted GoRV32 Plus MPU (dual-hart RV32IMAFDC, Sv32 MMU, CLINT at
`$E6000000`, PLIC at `$E4000000`, 16550-style UART at `$F0200020`) instead
of the local VexRiscv. The IP reference is MUG1532, direct download from
`cdn.gowinsemi.com.cn/MUG1532E.pdf`; Gowin's Linux SDK is deliberately not
used - everything below builds from the same WSL environment as the
VexRiscv profile.

Boot chain, all self-built: the CPU reset-fetches at `0x80000000`, an XIP
window into the on-board NOR flash at offset `FLASH_BURN_ADDR`. The Tang
Console 138K flash is an 8 MB XT25F64B (JEDEC 0x0B4017), the uncompressed
GW5AST-138 bitstream takes ~4.9 MB, so the burn address is `0x500000` -
addresses at or above `0x800000` are beyond the chip and wrap onto the
bitstream. The ZSBL in `linux/zsbl` runs there in place, initializes UART1
(registers at `+0x20`, 4-byte stride, 32-bit APB access, divisor 27 for
115200 at the 50 MHz APB clock) and copies a GRV1 image into SDRAM: OpenSBI
to `$0`, `gorv32plus.dtb`
to `$3F0000`, the kernel to `$400000` - the same DDR layout as the
VexRiscv SD profile. Hart 1 parks in a wfi loop. The DDR window at CPU
address `0` is served by SDRAM0 through `sys16_axi32_to_bus32` and
`sys16_bus32_to_sdram16`; the memory node exposes `$400000`-`$FFFFFF`.

The kernel Image is the identical artifact as the VexRiscv build - it is
device-tree driven, only `linux/gorv32plus.dts` differs (ns16550a at
`$F0200020` with `reg-shift 2`/`reg-io-width 4`, sifive,plic-1.0.0,
sifive,clint0, timebase 50 MHz). OpenSBI needs a second build with
`FW_TEXT_START=0x0` out of the same patched tree; the GoRV32 Plus is also a
pre-MDT privilege-1.10 VexRiscv, so the existing fw_base.S patch applies.

ZSBL v12 boots the GRV1 payload at SD LBA 0 first. If the card is absent,
unreadable or does not contain a valid image, it falls back to the GRV1
payload in flash at `0x510000`. Its SD reader uses the vendor host (MUG1532
chapter 16): identification
at 200 kHz, conservative 1 MHz data transfers, 4-bit mode with a 1-bit
fallback and single-block CMD17 reads. Records are 512-byte aligned and
the RX FIFO word order is autodetected from the magic.

Build and program:

1. `make gorv32-zsbl-wsl` - compiles `linux/zsbl` with the kernel
   toolchain, output `linux/zsbl/zsbl.bin`.
2. `make gorv32-opensbi-wsl` - fw_jump linked at `$0`
   (`~/opensbi-system16/build-gorv32`).
3. `make rootfs-flash-wsl` - creates the BusyBox cpio embedded by the kernel.
4. `make kernel-flash-wsl` - builds the verified initramfs kernel profile.
5. `make gorv32-flash-image` - imports fw_jump/Image, compiles the DTB and
   packs `build/gorv32-linux-flash/gorv32-linux-flash.bin`.
6. Flash (Gowin Programmer): bitstream at `0x000000`, `zsbl.bin` at
   `0x500000`, and optionally a fallback GRV1 payload at `0x510000`.
   Details in `linux/gorv32-brennen.md`.

For the SD-root profile, create and write the full card only once with
`make gorv32-sd-image`. During driver and kernel development use
`make kernel-sd-wsl` followed by `make gorv32-sd-boot-image`, then write only
`build/gorv32-linux-sd/gorv32-linux-sd-boot.bin` raw at SD LBA 0. The 512 MB
ext2 area beginning at LBA 32768 is not rewritten.

The preferred hardware debug loop is `kernel-rescue-wsl` followed by
`gorv32-rescue-image`: its embedded BusyBox shell starts independently of the
card while the built-in driver calibrates read-only access. On the verified
2026-07-12 run it selected 1-bit mode at 2.5 MHz and measured 190 KiB/s with
zero retries and zero FIFO-full events. All 50 combinations from 25 to 1 MHz
are tested at each boot; later errors automatically reduce the clock.

The whole console chain - probe, ZSBL, OpenSBI, kernel - runs 115200 8N1.
The "System16 GoRV32 ZSBL" banner is the first milestone and only needs the
bitstream plus `zsbl.bin`; it reports each copied record and verifies a
checksum before jumping, so a corrupted burn or a broken SDRAM path is
diagnosed on the UART instead of hanging silently. Note the IP owns the
IOBUFs of the FLASH_QSPI and SD pads, so fabric logic must not touch those
nets (synthesis error EX0339).

The FPGA project needs `use_mspi_as_gpio`; the flash sits on the MSPI pins
T19/L12/P22/R22/P21/R21 and the TF slot is wired in native 4-bit SD mode on
V15/Y16/AA15/AB15/W14/W15. Regenerate the IP after ipc changes with
`gw_sh create_gorv32plus_ip.tcl` or the IDE IP Core Generator.

`linux/system16-flash.config` embeds the BusyBox cpio created by
`make rootfs-flash-wsl`. A second profile uses the built-in Gowin SD block
driver and a 512 MiB ext2 filesystem with native development tools; see
`linux/linux-build-image.md` and the targets `rootfs-sd-wsl`,
`kernel-sd-wsl`, and `gorv32-sd-image`.
For the initramfs profiles, kernel plus embedded rootfs must stay inside the
12 MB between `$400000` and `$FFFFFF`; the primary flash payload has the
stricter 2.9 MB GRV1 limit.
The current board DTS exposes the SD device read-only: CMD17 and ext2 reads
are verified, while CMD24, writable ext2, swap and native compilation on the
FPGA remain future work. QEMU can already validate the rootfs and toolchain.
