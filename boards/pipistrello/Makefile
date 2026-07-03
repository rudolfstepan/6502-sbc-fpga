## Pipistrello (Xilinx Spartan-6 LX45) - ISE build

XTCLSH ?= xtclsh

PROJECT_DIR  := project
PROJECT_NAME := pipistrello_sbc_minimal
PROJECT_ISE  := $(PROJECT_DIR)/$(PROJECT_NAME).xise
HDMI_TEST_ISE := $(PROJECT_DIR)/pipistrello_hdmi_test.xise
SBC_HDMI_ISE := $(PROJECT_DIR)/pipistrello_6502_hdmi.xise
SBC_SD_HDMI_ISE := $(PROJECT_DIR)/pipistrello_6502_sd_hdmi.xise
C64_ISE := $(PROJECT_DIR)/pipistrello_c64.xise

.PHONY: project generate-project hdmi-test sbc-hdmi sbc-sd-hdmi c64 build program clean

project: $(PROJECT_ISE)
	@echo "ISE project: $(PROJECT_ISE)"

generate-project:
	$(XTCLSH) scripts/create_minimal_ise_project.tcl

build: $(PROJECT_ISE)
	@echo "Open $(PROJECT_ISE) in Xilinx ISE 14.7 and run Process > Run All"

hdmi-test: $(HDMI_TEST_ISE)
	@echo "ISE HDMI test project: $(HDMI_TEST_ISE)"

sbc-hdmi: $(SBC_HDMI_ISE)
	@echo "ISE 6502 HDMI project: $(SBC_HDMI_ISE)"

sbc-sd-hdmi: $(SBC_SD_HDMI_ISE)
	@echo "ISE 6502 SD HDMI project: $(SBC_SD_HDMI_ISE)"

c64: $(C64_ISE)
	@echo "ISE C64 HDMI project: $(C64_ISE)"

program:
	@echo "Program the generated .bit/.mcs with your Pipistrello JTAG/SPI flow."

clean:
	-rm -rf $(PROJECT_DIR)/xst/ $(PROJECT_DIR)/_ngo/ $(PROJECT_DIR)/_xmsgs/
	-rm -rf $(PROJECT_DIR)/iseconfig/ $(PROJECT_DIR)/xlnx_auto_*
	-rm -f $(PROJECT_DIR)/*.ngd $(PROJECT_DIR)/*.ngc $(PROJECT_DIR)/*.ncd
	-rm -f $(PROJECT_DIR)/*.pcf $(PROJECT_DIR)/*.bld $(PROJECT_DIR)/*.mrp
	-rm -f $(PROJECT_DIR)/*.map $(PROJECT_DIR)/*.par $(PROJECT_DIR)/*.twr
	-rm -f $(PROJECT_DIR)/*.twx $(PROJECT_DIR)/*.bit $(PROJECT_DIR)/*.drc
	-rm -f $(PROJECT_DIR)/*.srp $(PROJECT_DIR)/*.lso $(PROJECT_DIR)/*.xrpt
