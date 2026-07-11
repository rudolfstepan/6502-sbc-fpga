# System16 GoRV32 Plus Linux

This directory contains the software side of the hardware-verified minimal
Linux port for the Tang Console 138K System16 project. The working profile
boots Linux 6.12.95 on hart 0 of the Gowin GoRV32 Plus core and reaches a
BusyBox shell from an embedded initramfs. Hart 1 remains parked in the ZSBL.

The VexRiscv profile in the parent README remains useful for QEMU and bus
bring-up, but the GoRV32 Plus project is the profile confirmed on the board.

## Boot chain

1. The FPGA loads its bitstream from the board's 8 MB XT25F64B flash.
2. GoRV32 Plus resets at CPU address `0x80000000`. Its XIP window maps this
   address to flash offset `0x500000`, where the ZSBL executes in place.
3. The ZSBL initializes UART1 and first looks for a GRV1 image at SD LBA 0.
   If SD initialization or validation fails, it looks at flash offset
   `0x510000` instead.
4. The ZSBL copies OpenSBI, the DTB and Linux into SDRAM0, verifies the
   additive payload checksum and jumps to OpenSBI at address zero.
5. OpenSBI starts Linux at `0x00400000`; the kernel unpacks its embedded
   BusyBox initramfs and starts the shell.

The GRV1 container is little-endian. It starts with a header containing the
magic, record count and checksum, followed by `(source offset, destination,
length)` records. Each payload begins on a 512-byte boundary so the SD path can
copy complete sectors directly into SDRAM. `tools/make_gorv32_flash_image.py`
is the authoritative format implementation.

## Address layout

| Space | Address | Contents |
| --- | ---: | --- |
| Flash | `0x000000` | FPGA bitstream, approximately 4.9 MB |
| Flash | `0x500000` | ZSBL; also the IP Core Generator `Flash_Burn_Address` |
| Flash | `0x510000` | Optional GRV1 fallback image |
| SD | LBA 0 | Primary raw GRV1 image; no partition table or filesystem |
| CPU XIP | `0x80000000` | ZSBL mapping of flash offset `0x500000` |
| SDRAM | `0x00000000` | OpenSBI (`FW_TEXT_START=0`) |
| SDRAM | `0x003f0000` | `gorv32plus.dtb` |
| SDRAM | `0x00400000` | Linux `Image`, including initramfs |
| MMIO | `0xe4000000` | PLIC |
| MMIO | `0xe6000000` | CLINT |
| MMIO | `0xf0200020` | UART1 16550 register window |
| MMIO | `0xf0600000` | Vendor SD host |

Linux sees 12 MB from `0x00400000` through `0x00ffffff`. The lower 4 MB are
reserved for OpenSBI and the DTB. The complete kernel plus initramfs must fit
in the remaining region. The optional flash fallback has a stricter 2.9 MB
GRV1 size limit; the packer reports when an image is SD-only.

The UART uses 115200 baud, 8 data bits, no parity and one stop bit. Its APB
registers use 32-bit accesses and a four-byte stride. During SD identification
the ZSBL uses 200 kHz; data transfer currently uses a conservative 5 MHz and
four-bit mode when the card accepts ACMD6, otherwise one-bit mode.

## Source and generated files

- `gorv32plus.dts` describes the vendor CLINT, PLIC, UART and SDRAM layout.
- `system16.config` is the small RV32 kernel configuration fragment.
- `build-kernel.sh` creates the kernel image and the VexRiscv DTB.
- `zsbl/` contains the freestanding XIP bootloader sources and linker script.
- `../tools/build_rootfs_wsl.py` creates a static uClibc/BusyBox cpio with
  Buildroot 2025.02.
- `../tools/build_opensbi_gorv32_wsl.py` builds OpenSBI at address zero.
- `../tools/import_gorv32_from_wsl.py` validates and imports the WSL artifacts
  and compiles `gorv32plus.dts`.
- `../tools/make_gorv32_flash_image.py` creates the GRV1 SD/flash image.

Generated artifacts are intentionally not repository sources: Gowin `impl/`
output, `zsbl.bin`, `zsbl.elf`, the Linux build tree and `build/gorv32-linux/`
can all be recreated. The Gowin IP's editable `.ipc` and synthesizable
encrypted `.v` are retained with the project, matching the policy used by the
other Gowin board ports.

## Build order

The Windows make targets call the default WSL distribution. They expect the
Linux output at `~/system16-out` and the patched OpenSBI checkout at
`~/opensbi-system16`. The current kernel fragment contains the path
`/home/rudolf/buildroot-2025.02/output/images/rootfs.cpio`; change that path
when building under another WSL user.

From the System16 directory on Windows:

```text
make rootfs-wsl
```

Then build Linux from WSL. When using the repository script with the paths
expected by the import tools, supply the source, output and cross-compiler:

```sh
cd /mnt/d/Development/6502-sbc-fpga/boards/tang_mega_138k/system16/linux
KERNEL_SRC=~/linux-6.12.95 \
KERNEL_OUT=~/system16-out \
CROSS_COMPILE=riscv64-linux-gnu- \
./build-kernel.sh
```

Back on Windows:

```text
make gorv32-zsbl-wsl
make gorv32-opensbi-wsl
make gorv32-flash-image
make gorv32plus-build
```

The relevant outputs are:

- `linux/zsbl/zsbl.bin`
- `build/gorv32-linux/gorv32-flash.bin`
- `project/impl/pnr/tang138k_system16_gorv32plus.fs`

Program them according to [gorv32-brennen.md](gorv32-brennen.md). For normal
kernel, DTB or OpenSBI iterations, only rewrite the SD card; the FPGA and ZSBL
do not need to be rebuilt or programmed.

## Expected console and diagnostics

The successful sequence starts with:

```text
FPGA BOOT OK
System16 GoRV32 ZSBL v9
boot from SD
copy $00000000 len $...
copy $003F0000 len $...
copy $00400000 len $...
checksum ok, jump to OpenSBI
OpenSBI ...
[    0.000000] Linux version ...
```

After initramfs startup, BusyBox supplies the minimal user space and shell.
The HDMI top stripe is a coarse hardware diagnostic: red means no CPU UART or
DDR traffic, blue means DDR reads without UART, magenta means DDR writes
without UART, yellow means UART without DDR, cyan means UART plus reads, and
green means UART plus a DDR write. Green proves the chain through the ZSBL copy
loop, but the UART log remains the authoritative boot result.

## Known constraints

- Do not use flash offsets at or above `0x800000`: they exceed the physical
  8 MB device and can wrap over the bitstream.
- The GoRV32 Plus project must not include `VexRiscvSystem16.v`; the encrypted
  vendor core contains its own `VexRiscv` module.
- The vendor IP owns the QSPI and SD I/O buffers. Fabric logic must not also
  drive or probe those pads, or synthesis reports EX0339.
- OpenSBI 1.8.1 requires the local pre-MDT `fw_base.S` adjustment implemented
  by the build helper for this privilege-architecture implementation.
- QEMU validates the generic RV32 kernel and early console, not the board's
  XIP, AXI-to-SDRAM bridge, SD host or UART wiring.
