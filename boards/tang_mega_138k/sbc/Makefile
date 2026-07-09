## Tang Mega 138K (Gowin GW5AST-LV138PG484AC1/I0) — GowinEDA build
## Run from this directory: make <target>

BITSTREAM   := project/impl/pnr/tang138k_sbc.fs
ROOT        := ../../..
ROM_IMAGE   := $(ROOT)/roms/6502/fpga_ehbasic_16kb.rom
ROM_PKG     := $(ROOT)/rtl/core/mem/boot_rom_init_pkg.vhd

GOWIN       ?= gw_sh
OPENLOAD    ?= openFPGALoader
PYTHON      ?= python

.PHONY: build program flash clean

build: $(ROM_PKG)
	cd project && $(GOWIN) build.tcl

$(ROM_PKG): $(ROM_IMAGE) $(ROOT)/tools/bin_to_vhdl_rom_pkg.py
	$(PYTHON) $(ROOT)/tools/bin_to_vhdl_rom_pkg.py --size 0x4000 -o $(ROM_PKG) $(ROM_IMAGE)

program: build
	$(OPENLOAD) -b tangmega138k $(BITSTREAM)

flash: build
	$(OPENLOAD) -b tangmega138k -f $(BITSTREAM)

clean:
	powershell -NoProfile -Command "$$paths = @('project/impl/gwsynthesis','project/impl/pnr','project/impl/temp','project/tmp','project/.cache'); Remove-Item -LiteralPath $$paths -Recurse -Force -ErrorAction SilentlyContinue; exit 0"
