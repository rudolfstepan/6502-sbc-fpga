# Tang Primer 20K — USB HID keyboard bring-up (minimal)

A standalone, minimum project to get a **USB keyboard** working on the Tang
Primer 20K Dock. It wraps the nand2mario `usb_hid_host` core (low-speed USB,
1.5 Mbps, GPIO bit-bang — no PHY chip) and does nothing else, so USB can be
debugged in isolation.

Shares nothing with the SBC/C64 builds. Reuses existing project files:
`rtl/core/usb/usb_hid_host.vhd`, `third_party/usb_hid_host/*`,
`rtl/core/peripherals/uart_tx_ser.vhd`.

## What it does

- **LEDs (active-low)** show the USB phase nibble:
  - `3` → idle / no device
  - `4` → device connected **and enumerated** (type recognised)
  - `F` → connection / protocol error
- **UART TX (M11, 115200 8N1)** — every printable key you press is sent as its
  ASCII byte. Open a serial terminal on the CH340 port and type to confirm.

## Hardware wiring

USB-A breakout on **PMOD 0** (Bank 3, LVCMOS33):

| Signal   | FPGA pin | Wire to        | Extra                          |
|----------|----------|----------------|--------------------------------|
| `usb_dp` | T7       | USB D+ (green) | 15 kΩ resistor D+ → GND        |
| `usb_dm` | T8       | USB D- (white) | 15 kΩ resistor D- → GND        |
| VBUS     | —        | USB 5 V (red)  | supply 5 V to the keyboard     |
| GND      | —        | USB GND (black)|                                |

The two 15 kΩ pull-downs are **required** (external — the core relies on them;
the `.cst` sets `PULL_MODE=NONE`). Provide 5 V VBUS to the keyboard from the
dock 5 V rail or an external supply — the FPGA does not power it.

Other pins: `clk_27mhz` = H11, `uart_tx` = M11 (CH340), `led[3:0]` =
L16/L14/N14/N16. Reset is power-on only (no button — the dock buttons are on
dedicated SSPI/config pins that can't be GPIO); replug/reprogram to reset.

## Build

Command line (from **this** directory — the CWD matters, see below):

```sh
cd boards/tang_primer_20k/usb_kbd
gw_sh build.tcl
```

Bitstream: `impl/pnr/usb_kbd.fs`. Or open `usb_kbd.gprj` in Gowin EDA and build
from the GUI.

> `usb_hid_host_rom.v` loads its microcode with `$readmemh("usb_hid_host_rom.hex")`
> using a bare relative path. A copy of that `.hex` sits in this directory and
> `gw_sh` resolves it against its working directory, so always launch the build
> from here.

## Clocks

- `clk_27mhz` — 27 MHz oscillator → register + UART domain.
- `usb_clk` — exact **12 MHz** from `Gowin_rPLL_USB`
  (`27 × 4 / 9 = 12 MHz`, VCO 576 MHz). The core requires 12 MHz on `usbclk`.

## Bring-up notes

A previous attempt (see `third_party/usb_hid_host/README.md`) detected connected
keyboards (phase cycled `3`↔`F`) but **enumeration never completed**. If you see
the same here, the likely suspects, in order:

1. **Keyboard compatibility** — this core is low-speed HID only. Use a simple,
   old, non-hub keyboard. Wireless dongles, USB-2.0-only, and hub-behind
   keyboards often will not enumerate.
2. **Signal integrity** — keep the PMOD-to-USB wires short; make sure both
   15 kΩ pull-downs are actually fitted and VBUS is solid 5 V.
3. **D+/D- swap** — if nothing is detected at all, try swapping `usb_dp`/`usb_dm`
   (T7/T8) in the `.cst`.

Phase reaching `4` and characters appearing on the UART = success.
