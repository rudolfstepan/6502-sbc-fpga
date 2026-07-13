GOWIN ?= C:/Gowin/Gowin_V1.9.12.03_x64/IDE/bin/gw_sh.exe

.PHONY: build regenerate-core regenerate-pll clean

build:
	cd project && "$(GOWIN)" build.tcl

regenerate-core:
	powershell -NoProfile -ExecutionPolicy Bypass -File tools/regenerate_ae350_itcm_core.ps1

regenerate-pll:
	cd project && "$(GOWIN)" generate_pll.tcl

clean:
	powershell -NoProfile -Command "$$paths = @('project/impl/gwsynthesis','project/impl/pnr','project/impl/temp','project/tmp','project/.cache'); Remove-Item -LiteralPath $$paths -Recurse -Force -ErrorAction SilentlyContinue; exit 0"
