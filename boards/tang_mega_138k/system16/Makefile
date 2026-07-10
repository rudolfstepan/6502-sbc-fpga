## Tang Mega 138K System16 experimental 16-bit computer
## Run from this directory: make <target>

BITSTREAM   := project/impl/pnr/tang138k_system16.fs

GOWIN       ?= gw_sh
OPENLOAD    ?= openFPGALoader
PYTHON      ?= python

ifeq ($(OS),Windows_NT)
VASM        ?= C:/Tools/vasm/bin/vasmm68k_mot.exe
else
VASM        ?= vasmm68k_mot
endif

.PHONY: firmware sdram-demo sd-boot-image software build program flash clean

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

program: build
	$(OPENLOAD) -b tangmega138k $(BITSTREAM)

flash: build
	$(OPENLOAD) -b tangmega138k -f $(BITSTREAM)

clean:
	powershell -NoProfile -Command "$$paths = @('project/impl/gwsynthesis','project/impl/pnr','project/impl/temp','project/tmp','project/.cache'); Remove-Item -LiteralPath $$paths -Recurse -Force -ErrorAction SilentlyContinue; exit 0"
