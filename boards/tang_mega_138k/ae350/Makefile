GOWIN ?= C:/Gowin/Gowin_V1.9.12.03_x64/IDE/bin/gw_sh.exe

.PHONY: build regenerate-plls clean

build:
	cd project && "$(GOWIN)" build.tcl

regenerate-plls:
	cd project && "$(GOWIN)" generate_plls.tcl

clean:
	powershell -NoProfile -Command "$$paths = @('project/impl/gwsynthesis','project/impl/pnr','project/impl/temp','project/tmp','project/.cache'); Remove-Item -LiteralPath $$paths -Recurse -Force -ErrorAction SilentlyContinue; exit 0"

