# Pipistrello

Initial Xilinx ISE board port for the Saanlima Pipistrello Spartan-6 LX45.

See [docs/README.md](docs/README.md) for the project overview, current hardware
status, repository layout, and ISE source/build-artifact policy.

## Build

```sh
make pipistrello
```

or from this directory:

```sh
make project
```

This creates an ISE project for `pipistrello_sbc_minimal_top`.

For a first HDMI/DVI output test:

```sh
make pipistrello-hdmi-test
```

Open `project/pipistrello_hdmi_test.xise` in ISE and build it. The top emits a
640x480 colour-bar test pattern on the Pipistrello TMDS/HDMI pins.

For the minimal 6502 SBC over HDMI:

```sh
make pipistrello-6502-hdmi
```

Open `project/pipistrello_6502_hdmi.xise` in ISE. This runs the SBC from the
25 MHz pixel clock and sends its VIC/VGA output through the Pipistrello HDMI
TMDS pins.

For SD-loaded BASIC/kernel over HDMI:

```sh
make sd-boot-image
make pipistrello-6502-sd-hdmi
```

Write `sim/generated/sbc_ehbasic_sd.img` raw to the Pipistrello SD card. The
FPGA reads sector 0 plus the following 32 sectors from the onboard SD slot.

For the native C64 core over HDMI/DVI:

```sh
make pipistrello-c64
```

Open `project/pipistrello_c64.xise` in ISE. This uses the C64 core ROM/RAM
path and a simple DVI TMDS encoder with Spartan-6 OSERDES output.

## Status

- Device default: `XC6SLX45-CSG324-3`
- Core: minimal 6502 SBC and native C64 bring-up
- Constraints: `constraints/pipistrello_minimal.ucf`

The UCF uses the onboard 50 MHz clock, reset switch, two LEDs, FT2232 channel B
UART and the VGA wing pinout used by the existing Pipistrello C64 port.
