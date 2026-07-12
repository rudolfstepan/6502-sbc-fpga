# Tang Mega 138K Gowin USB 2.0 host-controller test

Standalone synthesis and bring-up project for the generated Gowin
`USB20_Host_Controller_Top` EHCI core. The generated encrypted source lives in
`project/src/usb20_host_controller/`; the old low-speed HID sources from
`third_party/usb_hid_host` are not part of this project anymore.

## Current safe smoke test

Open `project/tang138k_usb_hid.gprj` in Gowin EDA, or run:

```
make build
make program
```

UART is on U15 at 115200 baud, 8N1. The expected startup line is:

```
Gowin USB20 core active irq=0 dma=0 rst=0
```

This proves that the encrypted core is accepted by synthesis, placed in the
GW5AST-138C design, released from reset and visible to surrounding logic.

## ULPI hardware still required

This controller is connected through the generated Gowin USB 2.0 SoftPHY to the
Tang Console's dedicated 480-Mbit/s USB-C SoftPHY circuit. It does not use the
USB-A D+/D- GPIO pins H13/G13 from the old low-speed design. The transmit pair
is J19/H19; dedicated receive pairs are H17/H18 and H20/G20.

Important: Gowin documents this SoftPHY as a **USB peripheral-mode** PHY, and
the Console schematic labels the USB-C circuit as `USB Soft Device`. Its
device pull-up/termination controls are therefore deliberately not connected
in this host-controller smoke test. Connecting them also creates incompatible
I/O-bank requirements in this generated configuration. A real host needs a
host-capable PHY/port with VBUS sourcing and host pull-down/role handling.

For real USB traffic, a processor or state machine must still initialize the
EHCI registers and descriptors through the core's 8-bit register/DMA interface.
The generated core itself does not decode HID reports.
