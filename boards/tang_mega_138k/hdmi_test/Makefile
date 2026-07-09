## Tang Mega 138K HDMI colorbar diagnostic
## Run from this directory: make <target>

BITSTREAM   := project/impl/pnr/tang138k_hdmi_colorbar.fs

GOWIN       ?= gw_sh
OPENLOAD    ?= openFPGALoader

.PHONY: build program flash clean

build:
	cd project && $(GOWIN) build.tcl

program: build
	$(OPENLOAD) -b tangmega138k $(BITSTREAM)

flash: build
	$(OPENLOAD) -b tangmega138k -f $(BITSTREAM)

clean:
	powershell -NoProfile -Command "$$paths = @('project/impl/gwsynthesis','project/impl/pnr','project/impl/temp','project/tmp','project/.cache'); Remove-Item -LiteralPath $$paths -Recurse -Force -ErrorAction SilentlyContinue; exit 0"
