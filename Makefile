GHDL          ?= C:\Users\oe3sr\AppData\Local\ghdl\bin\ghdl.exe
PYTHON        ?= python
GHDL_FLAGS    ?= --std=08 --ieee=synopsys
GHDL_RUN_FLAGS ?= --ieee-asserts=disable-at-0
C64_DIAG_DIR  = roms/diagnostics
C64_PRG_DIR   = roms/c64/prg

CHESS_ROM_HEX        = sim/generated/chess_rom.hex
SBC_ROM_HEX          = sim/generated/sbc_rom.hex
SBC_EHBASIC_ROM_HEX  = sim/generated/sbc_ehbasic_rom.hex
SBC_EHBASIC_SD_IMG   = sim/generated/sbc_ehbasic_sd.img
SBC_TEST_SD_IMG      = sim/generated/sbc_test_sd.img
TEST_D64             = roms/test_d64/testdisk.d64
FAT32_CARD_IMG       = sim/generated/fat32_card.img
FAT32_CARD_PAD_IMG   = sim/generated/fat32_card_pad.img
FAT32_CARD_SF_IMG    = sim/generated/fat32_card_sf.img
MISTER64_FAT16_IMG   ?= build/mister64_fat16.img
MISTER64_FAT16_SIZE  ?= 32M
MISTER64_D64S        ?= roms/test_d64/testdisk.d64 roms/test_d64/multipart.d64
C64_SD_D64_SELECTOR_TABLE = sw/c64_sd_d64_select_table.inc

T65_RTL = third_party/t65/rtl/T65_Pack.vhd third_party/t65/rtl/T65_ALU.vhd \
          third_party/t65/rtl/T65_MCode.vhd third_party/t65/rtl/T65.vhd

RTL = rtl/core/sbc_pkg.vhd rtl/core/bus_decode.vhd \
      rtl/core/mem/sync_ram.vhd rtl/core/mem/fb_ram.vhd rtl/core/mem/rom.vhd \
      boards/tang_primer_20k/sbc/rtl/bram_byte_bridge.vhd \
      rtl/core/mem/boot_shadow_rom.vhd \
      rtl/core/mem/sdram_if.vhd rtl/core/mem/sdram_ctrl.vhd \
      rtl/core/mem/char_rom.vhd \
      rtl/core/peripherals/reg_stub.vhd rtl/core/peripherals/via6522.vhd \
      rtl/core/peripherals/d64_sector_map.vhd \
      rtl/core/peripherals/d64_drive.vhd rtl/core/peripherals/fat32_reader.vhd \
      rtl/core/peripherals/d64_subsystem.vhd \
      rtl/core/peripherals/uart6551.vhd rtl/core/peripherals/vic_core.vhd \
      rtl/core/peripherals/uart_rx_ser.vhd rtl/core/peripherals/uart_tx_ser.vhd \
      rtl/core/peripherals/vic_pixel_gen.vhd rtl/core/peripherals/vic_vga.vhd \
      rtl/core/audio/legacy_sound/sound_voice.vhd rtl/core/peripherals/pt8211_dac.vhd \
      rtl/core/audio/legacy_sound/sound_voice_full.vhd rtl/core/audio/legacy_sound/sound_chip4.vhd \
      rtl/core/audio/sid/sid6581.vhd rtl/core/peripherals/cia6526.vhd \
      rtl/core/boot/boot_debug_uart.vhd rtl/core/boot/boot_vga_debug.vhd \
      rtl/core/boot/boot_sdram_test.vhd rtl/core/boot/uart_debug_monitor.vhd \
      rtl/core/peripherals/math_copro.vhd \
      rtl/core/cpu/t65_adapter.vhd rtl/core/cpu6502_slot.vhd rtl/core/sbc_top.vhd \
      rtl/core/sbc_t65_top.vhd rtl/core/sbc_t65_boot_top.vhd \
      rtl/core/sbc_t65_sdram_boot_top.vhd \
      rtl/core/hdmi/hdmi_data_island_pkg.vhd rtl/core/hdmi/tmds_encoder.vhd \
      rtl/core/hdmi/hdmi_encoder.vhd

SIM = sim/tb/tb_bus_decode.vhd sim/tb/tb_sbc_reset.vhd sim/tb/tb_sbc_bus_write.vhd \
      sim/tb/tb_sbc_sram_readback.vhd sim/tb/tb_via6522.vhd sim/tb/tb_uart6551.vhd \
      sim/tb/tb_rom_image.vhd sim/tb/tb_t65_adapter.vhd sim/tb/tb_sbc_t65_boot.vhd \
      sim/tb/tb_sbc_t65_uart.vhd sim/tb/tb_sbc_t65_via.vhd sim/tb/tb_sbc_t65_irq.vhd \
      sim/tb/tb_sbc_t65_kernel_smoke.vhd sim/tb/tb_vic_core.vhd sim/tb/tb_char_rom.vhd \
      sim/tb/tb_sbc_t65_boot_shadow.vhd sim/tb/tb_vic_pixel_gen.vhd \
      sim/tb/tb_vic_raster_irq.vhd sim/tb/tb_sbc_vic_display.vhd \
      sim/tb/tb_vic_color256.vhd \
      sim/tb/tb_vic_color64.vhd \
      sim/tb/tb_vic_color16.vhd sim/tb/tb_vic_border.vhd sim/tb/tb_cia6526.vhd \
      sim/tb/tb_bram_byte_bridge.vhd \
      sim/tb/tb_sound_voice.vhd sim/tb/tb_vram_steal_race.vhd \
      sim/tb/tb_vram_read_steal.vhd sim/tb/tb_sound_chip4.vhd \
      sim/tb/tb_d64_sector_map.vhd sim/tb/tb_d64_drive.vhd \
      sim/tb/tb_fat32_reader.vhd sim/tb/tb_d64_subsystem.vhd \
      sim/tb/tb_hdmi_encoder.vhd

.PHONY: analyze roms sd-boot-image sd-boot-test-image test test-sd-boot-shadow \
        clean pix16 pipistrello pipistrello-hdmi-test pipistrello-6502-hdmi pipistrello-6502-sd-hdmi pipistrello-c64 tang_primer_20k d64-test-image test-d64 test-d64-map \
        fat32-card-image test-d64-drive test-c1541-d64-source test-c1541-d64-sdram \
        test-c1541-v1541-uart test-c1541-sd-write test-fat32 test-d64-subsystem tunes-d64 \
        sid-disks reist adventure-rom multipart-d64 test-c64-vic test-c64-input \
        c64-kernal-load-vector-patch c64-roms c64-tang20k-build \
        c64-graphics-test-prg c64-sprite-test-prg c64-d016-scroll-test-prg \
        c64-math-copro-test-prg c64-mandelbrot-prg c64-mandelbrot-copro-prg \
        c64-ich-image-prg \
        c64-v1541-ping-prg \
        c64-spin-diag-prg c64-hang-diag-prg c64-hang-loop-diag-prg \
        c64-cli-noirq-diag-prg c64-rti-diag-prg c64-hang-raw-irq-diag-prg \
        c64-v1541-loadfirst-prg c64-v1541-hook-prg c64-v1541-hook-diag-prg \
        c64-v1541-hook-dummy-diag-prg \
        c64-sd-d64-selector-prg c64-sd-fat16-selector-prg \
        c64-sd-fastload-first-prg \
        c64-sd-fastload-hook-prg c64-sd-hook-test test-c64-sd-hook-boot \
        mister64-sd-hook-block \
        mister64-fat16-d64-card c64-sid-prgs c64-iec-test-rom

## ============================================================================
## Simulation targets
## ============================================================================

analyze:
	$(GHDL) -a $(GHDL_FLAGS) $(T65_RTL) $(RTL)

test-c64-vic:
	$(GHDL) -a $(GHDL_FLAGS) rtl/c64/c64_roms.vhd rtl/c64/vic_ii.vhd \
	  sim/tb/tb_vic_display.vhd sim/tb/tb_c64_vic_graphics_modes.vhd
	$(GHDL) -e $(GHDL_FLAGS) tb_vic_display
	$(GHDL) -r $(GHDL_FLAGS) tb_vic_display $(GHDL_RUN_FLAGS) --stop-time=20ms
	$(GHDL) -e $(GHDL_FLAGS) tb_c64_vic_graphics_modes
	$(GHDL) -r $(GHDL_FLAGS) tb_c64_vic_graphics_modes $(GHDL_RUN_FLAGS) --stop-time=200ms

test-c64-input:
	$(GHDL) -a $(GHDL_FLAGS) rtl/c64/c64_keyboard_matrix.vhd \
	  sim/tb/tb_c64_keyboard_matrix_joystick.vhd
	$(GHDL) -e $(GHDL_FLAGS) tb_c64_keyboard_matrix_joystick
	$(GHDL) -r $(GHDL_FLAGS) tb_c64_keyboard_matrix_joystick $(GHDL_RUN_FLAGS)

c64-kernal-load-vector-patch:
	$(PYTHON) tools/patch_c64_kernal_load_vector.py

c64-roms:
	$(PYTHON) tools/build_c64_roms.py

c64-tang20k-build: c64-roms
	cd boards/tang_primer_20k/c64/project && build.bat

c64-graphics-test-prg:
	$(CA65) --cpu 6502 -o roms/test.o sw/c64_vic_graphics_test.s
	$(LD65) -C sw/c64_vic_graphics_test.cfg -o roms/test.prg roms/test.o
	@$(PYTHON) -c "import pathlib; pathlib.Path('roms/test.o').unlink(missing_ok=True)"
	@echo "Built roms/test.prg (upload with tools/c64_uart_prg_loader.py, then RUN)"

c64-sprite-test-prg:
	$(CA65) --cpu 6502 -o roms/sprite_test.o sw/c64_vic_sprite_test.s
	$(LD65) -C sw/c64_vic_graphics_test.cfg -o roms/sprite_test.prg roms/sprite_test.o
	@$(PYTHON) -c "import pathlib; pathlib.Path('roms/sprite_test.o').unlink(missing_ok=True)"
	@echo "Built roms/sprite_test.prg (upload with tools/c64_uart_prg_loader.py, then RUN)"

c64-d016-scroll-test-prg:
	$(CA65) --cpu 6502 -o roms/d016_scroll_test.o sw/c64_vic_d016_scroll_test.s
	$(LD65) -C sw/c64_vic_graphics_test.cfg -o roms/d016_scroll_test.prg roms/d016_scroll_test.o
	@$(PYTHON) -c "import pathlib; pathlib.Path('roms/d016_scroll_test.o').unlink(missing_ok=True)"
	@echo "Built roms/d016_scroll_test.prg (upload with tools/c64_uart_prg_loader.py, then RUN)"

c64-math-copro-test-prg:
	$(CA65) --cpu 6502 -o roms/math_copro_test.o sw/c64_math_copro_test.s
	$(LD65) -C sw/c64_vic_graphics_test.cfg -o roms/math_copro_test.prg roms/math_copro_test.o
	@$(PYTHON) -c "import pathlib; pathlib.Path('roms/math_copro_test.o').unlink(missing_ok=True)"
	@echo "Built roms/math_copro_test.prg (upload with tools/c64_uart_prg_loader.py, then RUN)"

c64-mandelbrot-prg:
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_PRG_DIR)').mkdir(parents=True, exist_ok=True)"
	$(CA65) --cpu 6502 -o $(C64_PRG_DIR)/mandelbrot.o sw/c64/c64_mandelbrot_copro.s
	$(LD65) -C sw/c64/c64_mandelbrot_copro.cfg -o $(C64_PRG_DIR)/mandelbrot.prg $(C64_PRG_DIR)/mandelbrot.o
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_PRG_DIR)/mandelbrot.o').unlink(missing_ok=True)"
	@echo "Built $(C64_PRG_DIR)/mandelbrot.prg (C64 CPU-only; upload with tools/c64_uart_prg_loader.py, then RUN)"

c64-mandelbrot-copro-prg:
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_PRG_DIR)').mkdir(parents=True, exist_ok=True)"
	$(CA65) --cpu 6502 -D USE_COPRO=1 -o $(C64_PRG_DIR)/mandelbrot-copo.o sw/c64/c64_mandelbrot_copro.s
	$(LD65) -C sw/c64/c64_mandelbrot_copro.cfg -o $(C64_PRG_DIR)/mandelbrot-copo.prg $(C64_PRG_DIR)/mandelbrot-copo.o
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_PRG_DIR)/mandelbrot-copo.o').unlink(missing_ok=True)"
	@echo "Built $(C64_PRG_DIR)/mandelbrot-copo.prg (C64-DDR math coprocessor; upload with tools/c64_uart_prg_loader.py, then RUN)"

c64-ich-image-prg:
	$(PYTHON) tools/c64_c16_to_hires.py sw/ich_image_c16.bin --out sw/ich_image_c64
	$(CA65) --cpu 6502 -I sw -o roms/ich_image.o sw/c64_ich_image.s
	$(LD65) -C sw/c64_ich_image.cfg -o roms/ich_image.prg roms/ich_image.o
	@$(PYTHON) -c "import pathlib; pathlib.Path('roms/ich_image.o').unlink(missing_ok=True)"
	@echo "Built roms/ich_image.prg (upload with tools/c64_uart_prg_loader.py, then RUN)"

c64-hang-diag-prg:
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)').mkdir(parents=True, exist_ok=True)"
	$(CA65) --cpu 6502 -o $(C64_DIAG_DIR)/hang_diag.o sw/c64_hang_diag.s
	$(LD65) -C sw/c64_vic_graphics_test.cfg -o $(C64_DIAG_DIR)/hang_diag.prg $(C64_DIAG_DIR)/hang_diag.o
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)/hang_diag.o').unlink(missing_ok=True)"
	@echo "Built $(C64_DIAG_DIR)/hang_diag.prg (no-drive READY/IRQ hang diagnostic)"

c64-spin-diag-prg:
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)').mkdir(parents=True, exist_ok=True)"
	$(CA65) --cpu 6502 -o $(C64_DIAG_DIR)/spin_diag.o sw/c64_spin_diag.s
	$(LD65) -C sw/c64_vic_graphics_test.cfg -o $(C64_DIAG_DIR)/spin_diag.prg $(C64_DIAG_DIR)/spin_diag.o
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)/spin_diag.o').unlink(missing_ok=True)"
	@echo "Built $(C64_DIAG_DIR)/spin_diag.prg (absolute no-stack spin diagnostic)"

c64-hang-loop-diag-prg:
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)').mkdir(parents=True, exist_ok=True)"
	$(CA65) --cpu 6502 -o $(C64_DIAG_DIR)/hang_loop_diag.o sw/c64_hang_loop_diag.s
	$(LD65) -C sw/c64_vic_graphics_test.cfg -o $(C64_DIAG_DIR)/hang_loop_diag.prg $(C64_DIAG_DIR)/hang_loop_diag.o
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)/hang_loop_diag.o').unlink(missing_ok=True)"
	@echo "Built $(C64_DIAG_DIR)/hang_loop_diag.prg (no-drive/no-IRQ CPU loop diagnostic)"

c64-cli-noirq-diag-prg:
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)').mkdir(parents=True, exist_ok=True)"
	$(CA65) --cpu 6502 -o $(C64_DIAG_DIR)/cli_noirq_diag.o sw/c64_cli_noirq_diag.s
	$(LD65) -C sw/c64_vic_graphics_test.cfg -o $(C64_DIAG_DIR)/cli_noirq_diag.prg $(C64_DIAG_DIR)/cli_noirq_diag.o
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)/cli_noirq_diag.o').unlink(missing_ok=True)"
	@echo "Built $(C64_DIAG_DIR)/cli_noirq_diag.prg (CLI with CIA/VIC IRQs masked)"

c64-rti-diag-prg:
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)').mkdir(parents=True, exist_ok=True)"
	$(CA65) --cpu 6502 -o $(C64_DIAG_DIR)/rti_diag.o sw/c64_rti_diag.s
	$(LD65) -C sw/c64_vic_graphics_test.cfg -o $(C64_DIAG_DIR)/rti_diag.prg $(C64_DIAG_DIR)/rti_diag.o
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)/rti_diag.o').unlink(missing_ok=True)"
	@echo "Built $(C64_DIAG_DIR)/rti_diag.prg (manual stack frame RTI diagnostic)"

c64-hang-raw-irq-diag-prg:
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)').mkdir(parents=True, exist_ok=True)"
	$(CA65) --cpu 6502 -o $(C64_DIAG_DIR)/hang_raw_irq_diag.o sw/c64_hang_raw_irq_diag.s
	$(LD65) -C sw/c64_vic_graphics_test.cfg -o $(C64_DIAG_DIR)/hang_raw_irq_diag.prg $(C64_DIAG_DIR)/hang_raw_irq_diag.o
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)/hang_raw_irq_diag.o').unlink(missing_ok=True)"
	@echo "Built $(C64_DIAG_DIR)/hang_raw_irq_diag.prg (CINV CIA1 IRQ heartbeat diagnostic)"

c64-v1541-ping-prg:
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)').mkdir(parents=True, exist_ok=True)"
	$(CA65) --cpu 6502 -o $(C64_DIAG_DIR)/v1541_ping.o sw/c64_v1541_ping.s
	$(LD65) -C sw/c64_vic_graphics_test.cfg -o $(C64_DIAG_DIR)/v1541_ping.prg $(C64_DIAG_DIR)/v1541_ping.o
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)/v1541_ping.o').unlink(missing_ok=True)"
	@echo "Built $(C64_DIAG_DIR)/v1541_ping.prg (upload, start tools/virtual_1541/c64_1541_uart_gui.py, then RUN)"

c64-v1541-loadfirst-prg:
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)').mkdir(parents=True, exist_ok=True)"
	$(CA65) --cpu 6502 -o $(C64_DIAG_DIR)/v1541_loadfirst.o sw/c64_v1541_loadfirst.s
	$(LD65) -C sw/c64_v1541_loadfirst.cfg -o $(C64_DIAG_DIR)/v1541_loadfirst.prg $(C64_DIAG_DIR)/v1541_loadfirst.o
	$(PYTHON) tools/build_c64_v1541_segment_map.py $(C64_DIAG_DIR)/v1541_loadfirst.prg
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)/v1541_loadfirst.o').unlink(missing_ok=True)"
	@echo "Built $(C64_DIAG_DIR)/v1541_loadfirst.prg (upload, start tools/virtual_1541/c64_1541_uart_gui.py, then RUN)"

c64-v1541-hook-prg:
	$(CA65) --cpu 6502 -o roms/v1541_hook.o sw/c64_v1541_kernal_hook.s
	$(LD65) -C sw/c64_v1541_hook.cfg -o roms/v1541_hook.prg roms/v1541_hook.o
	$(PYTHON) tools/build_c64_v1541_segment_map.py roms/v1541_hook.prg --code-address 0xC700
	@$(PYTHON) -c "import pathlib; pathlib.Path('roms/v1541_hook.o').unlink(missing_ok=True)"
	@echo "Built roms/v1541_hook.prg (upload, RUN once, then use LOAD\"*\",8,1)"

c64-v1541-hook-diag-prg:
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)').mkdir(parents=True, exist_ok=True)"
	$(CA65) --cpu 6502 -D DIAG_LOAD_RETURN -o $(C64_DIAG_DIR)/v1541_hook_diag.o sw/c64_v1541_kernal_hook.s
	$(LD65) -C sw/c64_v1541_hook.cfg -o $(C64_DIAG_DIR)/v1541_hook_diag.prg $(C64_DIAG_DIR)/v1541_hook_diag.o
	$(PYTHON) tools/build_c64_v1541_segment_map.py $(C64_DIAG_DIR)/v1541_hook_diag.prg --code-address 0xC700
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)/v1541_hook_diag.o').unlink(missing_ok=True)"
	@echo "Built $(C64_DIAG_DIR)/v1541_hook_diag.prg (prints LOAD return diagnostics)"

c64-v1541-hook-dummy-diag-prg:
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)').mkdir(parents=True, exist_ok=True)"
	$(CA65) --cpu 6502 -D DUMMY_DRIVE -D DIAG_LOAD_RETURN -o $(C64_DIAG_DIR)/v1541_hook_dummy_diag.o sw/c64_v1541_kernal_hook.s
	$(LD65) -C sw/c64_v1541_hook.cfg -o $(C64_DIAG_DIR)/v1541_hook_dummy_diag.prg $(C64_DIAG_DIR)/v1541_hook_dummy_diag.o
	$(PYTHON) tools/build_c64_v1541_segment_map.py $(C64_DIAG_DIR)/v1541_hook_dummy_diag.prg --code-address 0xC700
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)/v1541_hook_dummy_diag.o').unlink(missing_ok=True)"
	@echo "Built $(C64_DIAG_DIR)/v1541_hook_dummy_diag.prg (hardware dummy LOAD hook, no UART)"

c64-sd-d64-selector-prg:
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)').mkdir(parents=True, exist_ok=True)"
	$(CA65) --cpu 6502 -o $(C64_DIAG_DIR)/sd_d64_select.o sw/c64_sd_d64_select.s
	$(LD65) -C sw/c64_vic_graphics_test.cfg -o $(C64_DIAG_DIR)/sd_d64_select.prg $(C64_DIAG_DIR)/sd_d64_select.o
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)/sd_d64_select.o').unlink(missing_ok=True)"
	@echo "Built $(C64_DIAG_DIR)/sd_d64_select.prg (upload with tools/c64_uart_prg_loader.py, then RUN)"

mister64-sd-hook-block: c64-sd-fastload-hook-prg
	$(PYTHON) tools/d64/make_sd_hook_block.py -o build/sd_hook_block.bin $(C64_DIAG_DIR)/sd_fastload_hook.prg
	@echo "Write it below the FAT16 partition with tools/write_sd_hook_block.ps1 (elevated)"

test-c64-sd-hook-boot:
	$(GHDL) -a $(GHDL_FLAGS) boards/tang_primer_20k/mister_c64_probe/rtl/c64_sd_hook_boot_loader.vhd \
	  sim/tb/tb_c64_sd_hook_boot_loader.vhd
	$(GHDL) -e $(GHDL_FLAGS) tb_c64_sd_hook_boot_loader
	$(GHDL) -r $(GHDL_FLAGS) tb_c64_sd_hook_boot_loader $(GHDL_RUN_FLAGS)

c64-sd-hook-test: c64-sd-fastload-hook-prg
	@$(PYTHON) -c "import pathlib; pathlib.Path('build').mkdir(parents=True, exist_ok=True)"
	$(PYTHON) tools/d64/make_fat16_d64_card.py -o build/test_fat16_card.img roms/test_d64/c64_testdisk.d64 roms/test_d64/c64_basic_testdisk.d64 --size 32M --hook-image roms/diagnostics/sd_fastload_hook.prg
	$(PYTHON) tools/test_c64_sd_hook.py build/test_fat16_card.img
	$(PYTHON) tools/test_c64_sd_hook.py build/test_fat16_card.img --standalone

c64-sd-fat16-selector-prg:
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)').mkdir(parents=True, exist_ok=True)"
	$(CA65) --cpu 6502 -o $(C64_DIAG_DIR)/sd_fat16_select.o sw/c64_sd_fat16_select.s
	$(LD65) -C sw/c64_sd_fat16_select.cfg -o $(C64_DIAG_DIR)/sd_fat16_select.prg $(C64_DIAG_DIR)/sd_fat16_select.o
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)/sd_fat16_select.o').unlink(missing_ok=True)"
	@echo "Built $(C64_DIAG_DIR)/sd_fat16_select.prg (upload with tools/c64_uart_prg_loader.py, then RUN; scans FAT16 root dir)"

c64-sd-fastload-first-prg:
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)').mkdir(parents=True, exist_ok=True)"
	$(CA65) --cpu 6502 -o $(C64_DIAG_DIR)/sd_fastload_first.o sw/c64_sd_fastload_first.s
	$(LD65) -C sw/c64_v1541_loadfirst.cfg -o $(C64_DIAG_DIR)/sd_fastload_first.prg $(C64_DIAG_DIR)/sd_fastload_first.o
	$(PYTHON) tools/build_c64_v1541_segment_map.py $(C64_DIAG_DIR)/sd_fastload_first.prg --code-address 0xC000
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)/sd_fastload_first.o').unlink(missing_ok=True)"
	@echo "Built $(C64_DIAG_DIR)/sd_fastload_first.prg (upload, RUN; loads first PRG through $$DF08 fast sector port)"

c64-sd-fastload-hook-prg:
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)').mkdir(parents=True, exist_ok=True)"
	$(CA65) --cpu 6502 -o $(C64_DIAG_DIR)/sd_fastload_hook.o sw/c64_sd_fastload_hook.s
	$(LD65) -C sw/c64_sd_hook.cfg -o $(C64_DIAG_DIR)/sd_fastload_hook.prg $(C64_DIAG_DIR)/sd_fastload_hook.o
	$(PYTHON) tools/build_c64_v1541_segment_map.py $(C64_DIAG_DIR)/sd_fastload_hook.prg --code-address 0xC000
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)/sd_fastload_hook.o').unlink(missing_ok=True)"
	@echo "Built $(C64_DIAG_DIR)/sd_fastload_hook.prg (upload, RUN; LOAD hook with fastload + LOAD\"@\" disk menu)"

mister64-fat16-d64-card: c64-sd-fastload-hook-prg
	$(PYTHON) tools/d64/make_fat16_d64_card.py -o $(MISTER64_FAT16_IMG) $(MISTER64_D64S) --size $(MISTER64_FAT16_SIZE) --selector-table $(C64_SD_D64_SELECTOR_TABLE) --hook-image $(C64_DIAG_DIR)/sd_fastload_hook.prg
	$(MAKE) c64-sd-d64-selector-prg
	@echo "Built $(MISTER64_FAT16_IMG) (hook embedded at LBA 8) and matching $(C64_DIAG_DIR)/sd_d64_select.prg"

c64-iec-test-rom:
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)').mkdir(parents=True, exist_ok=True)"
	$(CA65) --cpu 6502 -o $(C64_DIAG_DIR)/c64_iec_test.o sw/c64_iec_test.s
	$(LD65) -C sw/c64diag.cfg -o $(C64_DIAG_DIR)/c64_cia2_iec_test.rom $(C64_DIAG_DIR)/c64_iec_test.o
	@$(PYTHON) -c "import pathlib; pathlib.Path('$(C64_DIAG_DIR)/c64_iec_test.o').unlink(missing_ok=True)"
	@echo "Built $(C64_DIAG_DIR)/c64_cia2_iec_test.rom (8 KB C64 KERNAL-slot CIA2/IEC test ROM)"

c64-sid-prgs:
	$(PYTHON) tools/build_c64_sid_prgs.py
	@echo Built C64 UART SID PRGs in roms/c64_uart_sid - upload, then RUN

## REIST benchmark engine (standalone, no 6502): unit + end-to-end GHDL run.
REIST_RTL = rtl/reist/reist_pkg.vhd rtl/reist/reist_core.vhd \
            rtl/reist/seq_divider.vhd rtl/reist/ip_divider.vhd \
            rtl/reist/reist_bench_engine.vhd \
            rtl/core/peripherals/uart_tx_ser.vhd rtl/reist/bench_report.vhd
reist:
	$(GHDL) -a $(GHDL_FLAGS) $(REIST_RTL) sim/tb/tb_reist_core.vhd sim/tb/tb_reist_bench.vhd
	$(GHDL) -e $(GHDL_FLAGS) tb_reist_core
	$(GHDL) -r $(GHDL_FLAGS) tb_reist_core $(GHDL_RUN_FLAGS) --stop-time=200ms
	$(GHDL) -e $(GHDL_FLAGS) tb_reist_bench
	$(GHDL) -r $(GHDL_FLAGS) tb_reist_bench $(GHDL_RUN_FLAGS) --stop-time=50ms

roms:
	$(PYTHON) tools/bin_to_vhdl_hex.py --size 0x4000 --output $(CHESS_ROM_HEX) ../roms/chess.rom
	$(PYTHON) tools/bin_to_vhdl_hex.py --size 0x4000 --output $(SBC_ROM_HEX) ../roms/kernel.rom@0x0000 ../roms/msbasic.rom@0x1000
	$(PYTHON) tools/bin_to_vhdl_hex.py --size 0x4000 --output $(SBC_EHBASIC_ROM_HEX) ../roms/kernel.rom@0x0000 ../roms/ehbasic.rom@0x1000

sd-boot-image:
	$(PYTHON) tools/make_sd_boot_image.py --output $(SBC_EHBASIC_SD_IMG) roms/fpga_ehbasic_16kb.rom@0x0000

sd-boot-test-image:
	$(PYTHON) tools/make_sd_boot_image.py --output $(SBC_TEST_SD_IMG) sim/hex/rom_welcome.hex@0x3800

## D64 GoDrive: regenerate the deterministic test disk image.
d64-test-image:
	$(PYTHON) tools/d64/create_test_d64.py --output $(TEST_D64)

## D64 GoDrive: build a runnable test disk of RAM PRGs.
## Each program's entry point is its load address, so it runs with CALL <load>.
## SID tunes become player PRGs (CALL 8192 / $2000); the Mandelbrot copro demo
## is also a RAM PRG at $2000.  Override TUNES=... to choose tunes.
TUNES ?= sid_orig/Zoids.sid sid_orig/Cat.sid sid_orig/Last_Starfighter.sid \
         sid_orig/Ahead_Crack_Intro.sid sid_orig/3545_II.sid
TUNE_PRG_DIR = roms/test_d64/prg
CA65 ?= C:/tools/cc65/bin/ca65
LD65 ?= C:/tools/cc65/bin/ld65
tunes-d64:
	@mkdir -p $(TUNE_PRG_DIR)
	@rm -f $(TUNE_PRG_DIR)/*.prg
	@for s in $(TUNES); do \
	  n=$$(basename $$s .sid); \
	  $(PYTHON) tools/build_sid_prg.py $$s $(TUNE_PRG_DIR)/$$n.prg; \
	done
	# Mandelbrot coprocessor demo as a RAM PRG at $$2000 (CALL 8192).
	$(CA65) --cpu 65c02 -o $(TUNE_PRG_DIR)/mandel.o sw/mandelbrot_copro.s
	$(LD65) -C sw/mandelbrot_copro_prg.cfg -o $(TUNE_PRG_DIR)/mandel.bin $(TUNE_PRG_DIR)/mandel.o
	$(PYTHON) -c "import sys; b=open('$(TUNE_PRG_DIR)/mandel.bin','rb').read(); open('$(TUNE_PRG_DIR)/MANDEL.prg','wb').write(bytes([0x00,0x20])+b)"
	@rm -f $(TUNE_PRG_DIR)/mandel.o $(TUNE_PRG_DIR)/mandel.bin
	# Chess game, relinked from its $$C000 ROM down to a RAM PRG at $$2000 (CALL 8192).
	$(CA65) --cpu 6502 -o $(TUNE_PRG_DIR)/chess.o sw/chess.s
	$(LD65) -C sw/chess_prg.cfg -o $(TUNE_PRG_DIR)/chess.bin $(TUNE_PRG_DIR)/chess.o
	$(PYTHON) -c "import sys; b=open('$(TUNE_PRG_DIR)/chess.bin','rb').read(); open('$(TUNE_PRG_DIR)/CHESS.prg','wb').write(bytes([0x00,0x20])+b)"
	@rm -f $(TUNE_PRG_DIR)/chess.o $(TUNE_PRG_DIR)/chess.bin
	$(PYTHON) tools/d64/pack_d64.py -o $(TEST_D64) $(TUNE_PRG_DIR)/*.prg

## Crypt of the 6502 -- standalone, uploadable adventure ROM (16 KB split image).
## Upload: python tools/upload_monitor_hex.py roms/adventure.rom --split-rom --run
##     or: roms/upload/adventure.bat
adventure-rom:
	$(CA65) --cpu 6502 -o roms/adventure.o sw/adventure.s
	$(LD65) -C sw/adventure.cfg -o roms/adventure.rom roms/adventure.o
	@rm -f roms/adventure.o
	@echo "Built roms/adventure.rom (16 KB). Upload with roms/upload/adventure.bat"

## Multi-part loader demo: two RAM PRGs on a D64; PART1 chain-loads + runs PART2.
## On hardware: LOAD "PART1" : CALL 8192  (press a key -> PART2 auto-loads).
MP_DIR = roms/test_d64/mp
multipart-d64:
	@mkdir -p $(MP_DIR)
	$(CA65) --cpu 6502 -I sw -o $(MP_DIR)/p1.o sw/mp_part1.s
	$(LD65) -C sw/prg2000.cfg -o $(MP_DIR)/p1.bin $(MP_DIR)/p1.o
	$(PYTHON) -c "b=open('$(MP_DIR)/p1.bin','rb').read(); open('$(MP_DIR)/PART1.prg','wb').write(bytes([0x00,0x20])+b)"
	$(CA65) --cpu 6502 -I sw -o $(MP_DIR)/p2.o sw/mp_part2.s
	$(LD65) -C sw/prg2000.cfg -o $(MP_DIR)/p2.bin $(MP_DIR)/p2.o
	$(PYTHON) -c "b=open('$(MP_DIR)/p2.bin','rb').read(); open('$(MP_DIR)/PART2.prg','wb').write(bytes([0x00,0x20])+b)"
	@rm -f $(MP_DIR)/*.o $(MP_DIR)/*.bin
	$(PYTHON) tools/d64/pack_d64.py -o roms/test_d64/multipart.d64 $(MP_DIR)/PART1.prg $(MP_DIR)/PART2.prg
	@echo "Built roms/test_d64/multipart.d64 (LOAD \"PART1\" : CALL 8192)"

## D64 GoDrive: convert EVERY convertible SID tune to a RAM PRG and pack them
## into numbered disk images (roms/test_d64/sid/tunesNN.d64).  Tunes that can't
## run in this machine's RAM ($A000+/$E000 loads, IRQ-driven, too large) are
## skipped.  Each PRG runs with CALL <its load address> (LOAD prints it).
sid-disks:
	$(PYTHON) tools/build_sid_disks.py

## D64 GoDrive: build a FAT32 SD-card image embedding the test .d64 (for sims).
fat32-card-image: d64-test-image
	$(PYTHON) tools/d64/make_fat32_card.py -o $(FAT32_CARD_IMG) $(TEST_D64)
	$(PYTHON) tools/d64/make_fat32_card.py -o $(FAT32_CARD_PAD_IMG) --pad-root-entries 24 $(TEST_D64)
	$(PYTHON) tools/d64/make_fat32_card.py -o $(FAT32_CARD_SF_IMG) --superfloppy --pad-root-entries 24 $(TEST_D64)

## D64 GoDrive: host-side mapping + tooling unit tests (no GHDL required).
test-d64:
	$(PYTHON) tools/d64/test_d64_common.py

## D64 GoDrive: focused GHDL run of the d64_drive engine (needs the test .d64).
test-d64-drive: d64-test-image
	$(GHDL) -a $(GHDL_FLAGS) rtl/core/peripherals/d64_sector_map.vhd \
	  rtl/core/peripherals/d64_drive.vhd sim/tb/tb_d64_drive.vhd
	$(GHDL) -e $(GHDL_FLAGS) tb_d64_drive
	$(GHDL) -r $(GHDL_FLAGS) tb_d64_drive $(GHDL_RUN_FLAGS) --stop-time=10ms

## MiSTer C64 probe: SDRAM-backed D64 sector source (prefetch/valid handshake).
test-c1541-d64-source:
	$(GHDL) -a $(GHDL_FLAGS) \
	  boards/tang_primer_20k/mister_c64_probe/rtl/c1541_d64_sector_source.vhd \
	  sim/tb/tb_c1541_d64_sector_source.vhd
	$(GHDL) -e $(GHDL_FLAGS) tb_c1541_d64_sector_source
	$(GHDL) -r $(GHDL_FLAGS) tb_c1541_d64_sector_source $(GHDL_RUN_FLAGS) --stop-time=5ms

## MiSTer C64 probe: full D64 read chain (source -> read adapter -> sdram_ctrl model).
test-c1541-d64-sdram:
	$(GHDL) -a $(GHDL_FLAGS) \
	  boards/tang_primer_20k/mister_c64_probe/rtl/c1541_d64_sector_source.vhd \
	  boards/tang_primer_20k/mister_c64_probe/rtl/mister_c64_sdram_read_adapter.vhd \
	  sim/tb/tb_mister_c64_sdram_read_adapter.vhd
	$(GHDL) -e $(GHDL_FLAGS) tb_mister_c64_sdram_read_adapter
	$(GHDL) -r $(GHDL_FLAGS) tb_mister_c64_sdram_read_adapter $(GHDL_RUN_FLAGS) --stop-time=20ms

## Native C64 / probe: SD D64 write-back path (GCR write burst -> RMW flush).
test-c1541-sd-write:
	$(GHDL) -a $(GHDL_FLAGS) \
	  rtl/core/peripherals/d64_sector_map.vhd \
	  rtl/core/peripherals/uart_rx_ser.vhd rtl/core/peripherals/uart_tx_ser.vhd \
	  boards/tang_primer_20k/mister_c64_probe/rtl/c1541_sd_d64_sector_source.vhd \
	  sim/tb/tb_c1541_sd_write.vhd
	$(GHDL) -e $(GHDL_FLAGS) tb_c1541_sd_write
	$(GHDL) -r $(GHDL_FLAGS) tb_c1541_sd_write $(GHDL_RUN_FLAGS) --stop-time=500ms

## MiSTer C64 probe: virtual-1541 UART sector backend (CMD_SECTOR round trip).
test-c1541-v1541-uart:
	$(GHDL) -a $(GHDL_FLAGS) \
	  rtl/core/peripherals/uart_rx_ser.vhd rtl/core/peripherals/uart_tx_ser.vhd \
	  boards/tang_primer_20k/mister_c64_probe/rtl/c1541_v1541_uart_sector_source.vhd \
	  sim/tb/tb_c1541_v1541_uart_sector_source.vhd
	$(GHDL) -e $(GHDL_FLAGS) tb_c1541_v1541_uart_sector_source
	$(GHDL) -r $(GHDL_FLAGS) tb_c1541_v1541_uart_sector_source $(GHDL_RUN_FLAGS) --stop-time=10ms

## D64 GoDrive: focused GHDL run of the FAT32 reader (needs the FAT32 card image).
test-fat32: fat32-card-image
	$(GHDL) -a $(GHDL_FLAGS) rtl/core/peripherals/fat32_reader.vhd sim/tb/tb_fat32_reader.vhd
	$(GHDL) -e $(GHDL_FLAGS) tb_fat32_reader
	$(GHDL) -r $(GHDL_FLAGS) tb_fat32_reader $(GHDL_RUN_FLAGS) --stop-time=300ms
	$(GHDL) -r $(GHDL_FLAGS) tb_fat32_reader -gIMG_PATH=$(FAT32_CARD_PAD_IMG) $(GHDL_RUN_FLAGS) --stop-time=300ms
	$(GHDL) -r $(GHDL_FLAGS) tb_fat32_reader -gIMG_PATH=$(FAT32_CARD_SF_IMG) -gCARD_SECTORS=386 -gEXP_START_LBA=42 $(GHDL_RUN_FLAGS) --stop-time=300ms

## D64 GoDrive: focused GHDL run of the full subsystem (mount + read end-to-end).
test-d64-subsystem: fat32-card-image
	$(GHDL) -a $(GHDL_FLAGS) rtl/core/peripherals/d64_sector_map.vhd \
	  rtl/core/peripherals/d64_drive.vhd rtl/core/peripherals/fat32_reader.vhd \
	  rtl/core/peripherals/d64_subsystem.vhd sim/tb/tb_d64_subsystem.vhd
	$(GHDL) -e $(GHDL_FLAGS) tb_d64_subsystem
	$(GHDL) -r $(GHDL_FLAGS) tb_d64_subsystem $(GHDL_RUN_FLAGS) --stop-time=300ms

test: roms fat32-card-image
	$(GHDL) -a $(GHDL_FLAGS) $(T65_RTL) $(RTL) $(SIM)
	$(GHDL) -e $(GHDL_FLAGS) tb_bus_decode
	$(GHDL) -r $(GHDL_FLAGS) tb_bus_decode $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_sbc_reset
	$(GHDL) -r $(GHDL_FLAGS) tb_sbc_reset $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_sbc_bus_write
	$(GHDL) -r $(GHDL_FLAGS) tb_sbc_bus_write $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_sbc_sram_readback
	$(GHDL) -r $(GHDL_FLAGS) tb_sbc_sram_readback $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_via6522
	$(GHDL) -r $(GHDL_FLAGS) tb_via6522 $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_uart6551
	$(GHDL) -r $(GHDL_FLAGS) tb_uart6551 $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_vic_core
	$(GHDL) -r $(GHDL_FLAGS) tb_vic_core $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_char_rom
	$(GHDL) -r $(GHDL_FLAGS) tb_char_rom $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_vic_pixel_gen
	$(GHDL) -r $(GHDL_FLAGS) tb_vic_pixel_gen $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_vic_raster_irq
	$(GHDL) -r $(GHDL_FLAGS) tb_vic_raster_irq $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_sbc_vic_display
	$(GHDL) -r $(GHDL_FLAGS) tb_sbc_vic_display $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_vic_color256
	$(GHDL) -r $(GHDL_FLAGS) tb_vic_color256 $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_vic_color64
	$(GHDL) -r $(GHDL_FLAGS) tb_vic_color64 $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_vic_color16
	$(GHDL) -r $(GHDL_FLAGS) tb_vic_color16 $(GHDL_RUN_FLAGS) --stop-time=60ms
	$(GHDL) -e $(GHDL_FLAGS) tb_vic_border
	$(GHDL) -r $(GHDL_FLAGS) tb_vic_border $(GHDL_RUN_FLAGS) --stop-time=40ms
	$(GHDL) -e $(GHDL_FLAGS) tb_cia6526
	$(GHDL) -r $(GHDL_FLAGS) tb_cia6526 $(GHDL_RUN_FLAGS) --stop-time=5ms
	$(GHDL) -e $(GHDL_FLAGS) tb_hdmi_encoder
	$(GHDL) -r $(GHDL_FLAGS) tb_hdmi_encoder $(GHDL_RUN_FLAGS) --stop-time=30ms
	$(GHDL) -e $(GHDL_FLAGS) tb_bram_byte_bridge
	$(GHDL) -r $(GHDL_FLAGS) tb_bram_byte_bridge $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_sound_voice
	$(GHDL) -r $(GHDL_FLAGS) tb_sound_voice $(GHDL_RUN_FLAGS) --stop-time=5ms
	$(GHDL) -e $(GHDL_FLAGS) tb_vram_steal_race
	$(GHDL) -r $(GHDL_FLAGS) tb_vram_steal_race $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_vram_read_steal
	$(GHDL) -r $(GHDL_FLAGS) tb_vram_read_steal $(GHDL_RUN_FLAGS) -gREAD_LATENCY_FIX=true
	$(GHDL) -e $(GHDL_FLAGS) tb_sound_chip4
	$(GHDL) -r $(GHDL_FLAGS) tb_sound_chip4 $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_rom_image
	$(GHDL) -r $(GHDL_FLAGS) tb_rom_image $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_t65_adapter
	$(GHDL) -r $(GHDL_FLAGS) tb_t65_adapter $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_sbc_t65_boot
	$(GHDL) -r $(GHDL_FLAGS) tb_sbc_t65_boot $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_sbc_t65_uart
	$(GHDL) -r $(GHDL_FLAGS) tb_sbc_t65_uart $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_sbc_t65_via
	$(GHDL) -r $(GHDL_FLAGS) tb_sbc_t65_via $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_sbc_t65_irq
	$(GHDL) -r $(GHDL_FLAGS) tb_sbc_t65_irq $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_sbc_t65_kernel_smoke
	$(GHDL) -r $(GHDL_FLAGS) tb_sbc_t65_kernel_smoke $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_sbc_t65_boot_shadow
	$(GHDL) -r $(GHDL_FLAGS) tb_sbc_t65_boot_shadow $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_d64_sector_map
	$(GHDL) -r $(GHDL_FLAGS) tb_d64_sector_map $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_d64_drive
	$(GHDL) -r $(GHDL_FLAGS) tb_d64_drive $(GHDL_RUN_FLAGS) --stop-time=10ms
	$(GHDL) -e $(GHDL_FLAGS) tb_fat32_reader
	$(GHDL) -r $(GHDL_FLAGS) tb_fat32_reader $(GHDL_RUN_FLAGS) --stop-time=300ms
	$(GHDL) -e $(GHDL_FLAGS) tb_d64_subsystem
	$(GHDL) -r $(GHDL_FLAGS) tb_d64_subsystem $(GHDL_RUN_FLAGS) --stop-time=300ms

## D64 GoDrive: focused GHDL run of just the sector-mapper testbench.
test-d64-map:
	$(GHDL) -a $(GHDL_FLAGS) rtl/core/peripherals/d64_sector_map.vhd sim/tb/tb_d64_sector_map.vhd
	$(GHDL) -e $(GHDL_FLAGS) tb_d64_sector_map
	$(GHDL) -r $(GHDL_FLAGS) tb_d64_sector_map $(GHDL_RUN_FLAGS)

test-sd-boot-shadow:
	$(GHDL) -a $(GHDL_FLAGS) $(T65_RTL) $(RTL) sim/tb/tb_sbc_t65_boot_shadow.vhd
	$(GHDL) -e $(GHDL_FLAGS) tb_sbc_t65_boot_shadow
	$(GHDL) -r $(GHDL_FLAGS) tb_sbc_t65_boot_shadow $(GHDL_RUN_FLAGS)

clean:
	$(GHDL) --clean

## ============================================================================
## Hardware build targets — delegate to each board's Makefile
## ============================================================================

pix16:
	$(MAKE) -C boards/pix16

pipistrello:
	$(MAKE) -C boards/pipistrello

pipistrello-hdmi-test:
	$(MAKE) -C boards/pipistrello hdmi-test

pipistrello-6502-hdmi:
	$(MAKE) -C boards/pipistrello sbc-hdmi

pipistrello-6502-sd-hdmi:
	$(MAKE) -C boards/pipistrello sbc-sd-hdmi

pipistrello-c64:
	$(MAKE) -C boards/pipistrello c64

tang_primer_20k:
	$(MAKE) -C boards/tang_primer_20k
