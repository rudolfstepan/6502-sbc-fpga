BITSTREAM := project/impl/pnr/tang138k_usb_hid.fs
GOWIN ?= gw_sh
OPENLOAD ?= openFPGALoader
.PHONY: build program flash clean
build:
	cd project && $(GOWIN) build.tcl
program: build
	$(OPENLOAD) -b tangmega138k $(BITSTREAM)
flash: build
	$(OPENLOAD) -b tangmega138k -f $(BITSTREAM)
clean:
	powershell -NoProfile -Command "$$paths = @('project/impl','project/tmp','project/.cache'); Remove-Item -LiteralPath $$paths -Recurse -Force -ErrorAction SilentlyContinue; exit 0"
