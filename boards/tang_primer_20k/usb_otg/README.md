# Tang Primer 20K — USB-OTG port (USB3317 ULPI PHY) bring-up

Minimal project for the dock's **USB-OTG connector**. Unlike the low-speed
`usb_kbd` project, this port is **not** a bare D+/D- pair — it is wired to an
on-board **Microchip USB3317 Hi-Speed USB PHY** over an 8-bit **ULPI** bus. So
the nand2mario bit-bang core does **not** apply here; ULPI needs a different
controller entirely.

This design is a **bring-up / PHY-alive test**, not a keyboard (yet). It wires
the existing `rtl/core/boot/usb_ulpi_diag.vhd` sampler to the PHY, releases it
from reset, reads the four USB3317 ULPI ID registers plus a scratch write/read
test, and reports the result over UART.

## What you should see

UART (CH340 / M11, **115200 8N1**), one line ~2×/second:

```text
ID=xxxx0424 S=xx
```

- The ID is printed MSB first as `reg3 reg2 reg1 reg0`. A healthy USB3317
  returns vendor ID **0x0424** (SMSC/Microchip): `reg0`=VID low=`0x24`,
  `reg1`=VID high=`0x04`, so **the line ends in `0424`**; the leading four hex
  digits are the product-ID registers (`reg3 reg2`).
- `S=` is the status byte:
  `[7]` ULPI clock seen · `[6]` domain running · `[5]` DIR seen · `[4]` NXT seen
  · `[3]` DATA changed · `[2]` DIR now · `[1]` NXT now · `[0]` 4 ID registers read.
- LEDs (active-low): `[0]` clk seen, `[1]` running, `[2]` DIR seen, `[3]` ID read done.

The scratch-register self-test is disabled (`DO_SCRATCH_TEST=false`); that is why
an earlier run showed `ID=EBC00358 S=F8` — an `E…` value is an *error snapshot*
(the scratch read-back timed out), not a real ID. With the test off the four ID
reads stand on their own.

If bit `[7]`/LED0 never lights, the FPGA is not receiving the 60 MHz ULPI clock
— check the PHY reset release and that the OTG cable/host is providing what the
PHY needs.

## Pins (on-board, no external wiring)

From the official Sipeed `TangPrimer-20K-example` USB demo constraints:

| Signal           | Pin                             | Dir                            |
|------------------|---------------------------------|--------------------------------|
| `ulpi_clk`       | T15                             | PHY → FPGA (60 MHz)            |
| `ulpi_dir`       | K12                             | PHY → FPGA                     |
| `ulpi_nxt`       | K13                             | PHY → FPGA                     |
| `ulpi_stp`       | K11                             | FPGA → PHY                     |
| `ulpi_rst`       | F10                             | FPGA → PHY (active-low RESETB) |
| `ulpi_data[7:0]` | R12 P13 R13 T14 H13 J12 H12 G11 | bidir                          |
| `clk_27mhz`      | H11                             | 27 MHz osc                     |
| `uart_tx`        | M11                             | CH340 TX                       |
| `led[3:0]`       | L16/L14/N14/N16                 | active-low                     |

## Build

```sh
cd boards/tang_primer_20k/usb_otg
gw_sh build.tcl
```

Bitstream: `impl/pnr/usb_otg.fs`. Or open `usb_otg.gprj` in Gowin EDA.

## From "PHY alive" to an actual keyboard

Getting a USB **keyboard** on this port is a much larger job than on the
low-speed port, because the FPGA must implement a full **USB host** over ULPI
(SOF generation, control-transfer enumeration, HID interrupt polling). Note that
even Sipeed's own USB example is a USB **device** (it enumerates as a COM port on
a PC), not a host — there is no drop-in ULPI HID **host** here.

Realistic next steps, in order:

1. **This project** — confirm `ID=0424…` and `S=` bit0 set. Foundation done.
2. Add a ULPI link/transmit layer (drive TX CMD / RX CMD, handle DIR turn-around
   at 60 MHz) — extend `usb_ulpi_diag` into a real ULPI PHY interface.
3. Add a minimal **USB host** on top: reset/enable the port, enumerate the
   device (GET_DESCRIPTOR / SET_ADDRESS / SET_CONFIGURATION), then poll the HID
   interrupt IN endpoint and decode boot-protocol keyboard reports.

Steps 2–3 are the real work and are not in this repo yet — tell me if you want
to go down that path and we'll scope it (port an open ULPI host core vs. build
a boot-keyboard-only host).
