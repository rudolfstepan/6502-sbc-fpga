## Tang Mega 138K System16 experimental 16-bit computer
## Run from this directory: make <target>

BITSTREAM   := project/impl/pnr/tang138k_system16.fs
RV32_BITSTREAM := project/impl/pnr/tang138k_system16_rv32.fs
RV32_BITSTREAM_ABS := $(abspath $(RV32_BITSTREAM))
GORV32_BITSTREAM := project/impl/pnr/tang138k_system16_gorv32plus.fs
GORV32_BITSTREAM_ABS := $(abspath $(GORV32_BITSTREAM))

OPENLOAD    ?= openFPGALoader
PYTHON      ?= python

ifeq ($(OS),Windows_NT)
GOWIN       ?= C:/Gowin/Gowin_V1.9.12.03_x64/IDE/bin/gw_sh.exe
GOWIN_PROG  ?= C:/Gowin/Gowin_V1.9.12.03_x64/Programmer/bin/programmer_cli.exe
VASM        ?= C:/Tools/vasm/bin/vasmm68k_mot.exe
else
GOWIN       ?= gw_sh
VASM        ?= vasmm68k_mot
endif

.PHONY: firmware sdram-demo sd-boot-image software sim-rv32 rv32-core rv32-build rv32-program gorv32plus-build gorv32plus-program opensbi-wsl rootfs-wsl rootfs-flash-wsl rootfs-sd-wsl kernel-flash-wsl kernel-sd-wsl kernel-rescue-wsl kernel-qemu-sd-wsl linux-import linux-image-wsl qemu-test qemu-sd-test gorv32-zsbl-wsl gorv32-opensbi-wsl gorv32-import gorv32-import-flash gorv32-import-sd gorv32-import-rescue gorv32-rootfs-sd-import gorv32-flash-image gorv32-rescue-image gorv32-sd-boot-image gorv32-sd-image build program flash clean

GHDL ?= ghdl
SBT  ?= $(CURDIR)/../../../.tmp/sbt-local/sbt/bin/sbt.bat

rv32-core:
	cd ../../../third_party/VexRiscv && "$(SBT)" "runMain vexriscv.demo.LinuxGen -r"
	powershell -NoProfile -Command "Copy-Item -LiteralPath '../../../third_party/VexRiscv/VexRiscv.v' -Destination 'rtl/VexRiscvSystem16.v' -Force"

sim-rv32:
	$(GHDL) -a --std=08 rtl/sys16_bus32_pkg.vhd rtl/sys16_bus32_to_sdram16.vhd rtl/sys16_timer32.vhd sim/tb_sys16_bus32.vhd
	$(GHDL) -e --std=08 tb_sys16_bus32
	$(GHDL) -r --std=08 tb_sys16_bus32 --stop-time=2us

firmware:
	$(VASM) -Fbin -m68000 -o sw/boot_monitor.bin -L sw/boot_monitor.lst sw/boot_monitor.s
	"$(PYTHON)" tools/bin_to_boot_rom_vhdl.py sw/boot_monitor.bin rtl/sys16_boot_rom_image_pkg.vhd

sdram-demo:
	$(VASM) -Fbin -m68000 -o sw/hello_sdram.bin -L sw/hello_sdram.lst sw/hello_sdram.s

sd-boot-image:
	$(VASM) -Fbin -m68000 -o sw/sd_boot_demo.bin -L sw/sd_boot_demo.lst sw/sd_boot_demo.s
	"$(PYTHON)" tools/make_system16_sd_image.py sw/sd_boot_demo.bin sw/system16_sd_boot.img --load 0x001000 --entry 0x001000

software: firmware sdram-demo sd-boot-image

build:
	cd project && $(GOWIN) build.tcl

rv32-build:
	cd project && $(GOWIN) build_rv32.tcl

rv32-program: rv32-build
ifeq ($(OS),Windows_NT)
	"$(GOWIN_PROG)" --cable-index 4 --frequency 2MHz \
		--device GW5AST-138C --operation_index 2 --fsFile "$(RV32_BITSTREAM_ABS)"
else
	$(OPENLOAD) -b tangmega138k $(RV32_BITSTREAM)
endif

gorv32plus-build:
	cd project && $(GOWIN) build_gorv32plus.tcl

gorv32plus-program: gorv32plus-build
ifeq ($(OS),Windows_NT)
	"$(GOWIN_PROG)" --cable-index 4 --frequency 2MHz \
		--device GW5AST-138C --operation_index 2 --fsFile "$(GORV32_BITSTREAM_ABS)"
else
	$(OPENLOAD) -b tangmega138k $(GORV32_BITSTREAM)
endif

linux-sd-image:
	"$(PYTHON)" tools/make_system16_linux_image.py \
		../../../build/system16-linux/fw_jump.bin \
		../../../build/system16-linux/system16-rv32.dtb \
		../../../build/system16-linux/arch/riscv/boot/Image \
		../../../build/system16-linux/system16-linux-sd.img

linux-import:
	"$(PYTHON)" tools/import_linux_from_wsl.py ../../../build/system16-linux

opensbi-wsl:
	"$(PYTHON)" tools/build_opensbi_wsl.py

## Busybox initramfs via Buildroot (~/buildroot-2025.02 in WSL); the
## kernel embeds output/images/rootfs.cpio via CONFIG_INITRAMFS_SOURCE.
rootfs-wsl: rootfs-flash-wsl

rootfs-flash-wsl:
	"$(PYTHON)" tools/build_rootfs_wsl.py

rootfs-sd-wsl:
	"$(PYTHON)" tools/build_rootfs_sd_wsl.py

kernel-flash-wsl:
	"$(PYTHON)" tools/build_kernel_wsl.py flash

kernel-sd-wsl:
	"$(PYTHON)" tools/build_kernel_wsl.py sd

kernel-rescue-wsl:
	"$(PYTHON)" tools/build_kernel_wsl.py rescue

kernel-qemu-sd-wsl:
	"$(PYTHON)" tools/build_kernel_wsl.py qemu-sd

linux-image-wsl: linux-import linux-sd-image

qemu-test:
	"$(PYTHON)" tools/qemu_linux_test.py

qemu-sd-test: kernel-qemu-sd-wsl
	"$(PYTHON)" tools/qemu_sd_rootfs_test.py

## GoRV32 Plus vendor-CPU Linux, built entirely from the WSL environment.
## Burn zsbl.bin at flash 0x500000. ZSBL v12 boots a raw GRV1 image at SD
## LBA 0 first and falls back to the flash payload at 0x510000.
gorv32-zsbl-wsl:
	"$(PYTHON)" tools/build_gorv32_zsbl_wsl.py

gorv32-opensbi-wsl:
	"$(PYTHON)" tools/build_opensbi_gorv32_wsl.py

gorv32-import: gorv32-import-flash

gorv32-import-flash:
	"$(PYTHON)" tools/import_gorv32_from_wsl.py \
		../../../build/gorv32-linux-flash --linux ~/system16-out

gorv32-import-sd:
	"$(PYTHON)" tools/import_gorv32_from_wsl.py \
		../../../build/gorv32-linux-sd --linux ~/system16-out-sd \
		--dts gorv32plus-sd.dts --dtb-name gorv32plus-sd.dtb

gorv32-import-rescue:
	"$(PYTHON)" tools/import_gorv32_from_wsl.py \
		../../../build/gorv32-linux-rescue --linux ~/system16-out-rescue \
		--dts gorv32plus-rescue.dts --dtb-name gorv32plus-rescue.dtb

gorv32-rootfs-sd-import:
	"$(PYTHON)" tools/import_rootfs_sd_from_wsl.py \
		../../../build/gorv32-linux-sd/rootfs.ext2

## .bin extension: the Gowin Programmer's FW/MCU input silently rejects
## other extensions (parses them as HEX) and programs zero bytes.
gorv32-flash-image: gorv32-import
	"$(PYTHON)" tools/make_gorv32_flash_image.py \
		../../../build/gorv32-linux-flash/fw_jump.bin \
		../../../build/gorv32-linux-flash/gorv32plus.dtb \
		../../../build/gorv32-linux-flash/Image \
		../../../build/gorv32-linux-flash/gorv32-linux-flash.bin \
		--require-flash-fit

gorv32-rescue-image: gorv32-import-rescue
	"$(PYTHON)" tools/make_gorv32_flash_image.py \
		../../../build/gorv32-linux-rescue/fw_jump.bin \
		../../../build/gorv32-linux-rescue/gorv32plus-rescue.dtb \
		../../../build/gorv32-linux-rescue/Image \
		../../../build/gorv32-linux-rescue/gorv32-linux-rescue.bin \
		--require-flash-fit

gorv32-sd-boot-image: gorv32-import-sd
	"$(PYTHON)" tools/make_gorv32_flash_image.py \
		../../../build/gorv32-linux-sd/fw_jump.bin \
		../../../build/gorv32-linux-sd/gorv32plus-sd.dtb \
		../../../build/gorv32-linux-sd/Image \
		../../../build/gorv32-linux-sd/gorv32-linux-sd-boot.bin \
		--require-flash-fit

gorv32-sd-image: gorv32-sd-boot-image gorv32-rootfs-sd-import
	"$(PYTHON)" tools/make_gorv32_sd_card_image.py \
		../../../build/gorv32-linux-sd/gorv32-linux-sd-boot.bin \
		../../../build/gorv32-linux-sd/rootfs.ext2 \
		../../../build/gorv32-linux-sd/gorv32-linux-sd.img

program: build
	$(OPENLOAD) -b tangmega138k $(BITSTREAM)

flash: build
	$(OPENLOAD) -b tangmega138k -f $(BITSTREAM)

clean:
	powershell -NoProfile -Command "$$paths = @('project/impl/gwsynthesis','project/impl/pnr','project/impl/temp','project/tmp','project/.cache'); Remove-Item -LiteralPath $$paths -Recurse -Force -ErrorAction SilentlyContinue; exit 0"
