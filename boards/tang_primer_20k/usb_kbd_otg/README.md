# USB keyboard on the OTG port (USB3317 ULPI)

> ## ⚠ STATUS: proof-of-concept — NOT working end-to-end
>
> The USB **host transmit path works** — a full SETUP (token + DATA0, e.g.
> `bmRequestType 0x80` visible on the ULPI bus) is sent correctly and the
> transaction completes to a clean response timeout. **But no keyboard tested
> ever ACKs / enumerates.** The USB3317 PHY constantly interrupts the host's
> packet mid-transmission with line-state RX CMDs, so no clean contiguous packet
> reaches the device. Root-causing the last mile needs a logic analyser / GAO on
> the real ULPI (or D+/D-) pins — blind register-level + simulated-PHY debugging
> hit its limit here (see the debug log below).
>
> **This is committed as a documented PoC / starting point, not a finished
> feature.** For an actually-working keyboard use the native bit-bang
> [`../usb_kbd/`](../usb_kbd/) project (full- *and* low-speed, on a PMOD USB
> breakout — not the OTG connector).
>
> What was built and learned along the way — 3 real deadlock bugs found & fixed
> in the vendored cores (all sim-reproduced), an on-chip ULPI recorder
> (`rtl/ulpi_rec.vhd`), the HS-mode trap, the VBUS attempt — is captured in
> [ROADMAP.md](ROADMAP.md) and `third_party/ultraembedded/README.md`.

Full USB **host** on the Tang Primer 20K OTG port, to reach a working USB
keyboard. Built in stages — see [ROADMAP.md](ROADMAP.md) for the architecture,
register map and plan. Uses the FPGA-verified `ultraembedded` transaction cores
(GPLv3, vendored under `third_party/ultraembedded/`) for the packet/CRC/SOF
layer; enumeration, HID and VBUS enable are our own VHDL.

**This build = Stage 2 (first milestone): enumeration transport.** It does not
type yet — it brings the host up, resets+detects the device, then performs a
control-read `GET_DESCRIPTOR(DEVICE, 18)` on EP0 and prints the 18-byte device
descriptor over UART. That proves the whole control-transfer path (SETUP + IN
data + OUT status + toggles) works; keystrokes come after (Stages 2b/3).

## What to expect

- **LEDs (4 normal-IO dock LEDs, active-low, lit = signal true):**
  `LED0` host running · `LED1` device present · `LED2` **descriptor read OK** ·
  `LED3` **heartbeat** (~1 Hz blink). (LED4/LED5 are on config pins, unused.)
- **UART (115200 8N1, M11):** `DESC: 12 01 .. .. .. ..` about once a second once
  a device is plugged in. The bytes are the USB device descriptor:
  `[0]=12` (length 18), `[1]=01` (DEVICE), `[8..9]`=idVendor (LE),
  `[10..11]`=idProduct (LE). So a keyboard shows its **VID/PID** in there.

Read it in order:

1. **LED3 blinking?** If not, the 60 MHz ULPI clock is not reaching the fabric.
2. **Plug in a keyboard →** LED0 (running) + LED1 (present) light.
3. **LED2 lights + `DESC:` line appears** → the control transfer succeeded and
   the descriptor was read. If LED2 never lights / no `DESC:` line, enumeration
   is failing (the sequencer retries every ~1 s); the descriptor transport is
   the thing to debug next.

## Build

```sh
cd boards/tang_primer_20k/usb_kbd_otg
gw_sh build.tcl
```

Bitstream: `impl/pnr/usb_kbd_otg.fs`. Or open `usb_kbd_otg.gprj` in Gowin EDA.

Note: `usbh_host` is parameterised for the 60 MHz ULPI clock via a VHDL generic
(`USB_CLK_FREQ => 60000000`). If your Gowin version does not pass generics to
Verilog parameters, set the default in
`third_party/ultraembedded/core_usb_host/src_v/usbh_host.v` to `60000000`.

LED4/LED5 are on the READY (A13) / DONE (C13) dual-purpose config pins. `build.tcl`
frees them with `-use_ready_as_gpio 1` / `-use_done_as_gpio 1`. In the Gowin EDA
GUI set the equivalent: Project → Configuration → **Dual-Purpose Pin** → enable
"Use DONE/READY as regular IO".

## Reset

Power-on only (the dock buttons are on dedicated SSPI/config pins). The PHY
RESETB is timed from `clk_27mhz`; the ULPI-domain logic self-times its reset off
the first 60 MHz clocks. To restart: reprogram or power-cycle / replug.

## License note

The vendored `ultraembedded` cores are **GPLv3** (copyleft). Fine for private
use; relevant if you ever distribute a bitstream built from this project. See
`third_party/ultraembedded/README.md`.
