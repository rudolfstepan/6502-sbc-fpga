## Tang Primer 20K (Gowin GW2A-LV18PG256C8/I7) — GowinEDA build
## Run from this directory: make <target>

BITSTREAM   := project/impl/pnr/tang_sbc.fs

GOWIN       ?= C:/Gowin/Gowin_V1.9.11.03_Education_x64/IDE/bin/gw_sh.exe
OPENLOAD    ?= openFPGALoader

.PHONY: build program clean

build:
	cd project && $(GOWIN) build.tcl

program:
	$(OPENLOAD) -b tang_primer_20k $(BITSTREAM)

clean:
	-rm -rf project/impl/gwsynthesis project/impl/temp project/tmp
	-find project/impl/pnr -mindepth 1 ! -name device.cfg -delete
