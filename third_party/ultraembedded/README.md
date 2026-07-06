# ultraembedded USB host + ULPI wrapper (vendored)

USB 1.1 full-speed **host** transaction layer and a **ULPI↔UTMI** link wrapper,
used to bring up a USB keyboard on the Tang Primer 20K OTG port (USB3317 PHY).
See `boards/tang_primer_20k/usb_kbd_otg/`.

| Directory | Source | Contents |
|-----------|--------|----------|
| `core_usb_host/src_v/` | https://github.com/ultraembedded/core_usb_host | `usbh_host.v` (AXI4-Lite reg IF + UTMI), `usbh_sie.v` (transaction engine), `usbh_crc5/16.v`, `usbh_fifo.v`, `usbh_host_defs.v` |
| `core_usb_host/sw/`    | same | C reference driver (`usb_hw.*`, `usb_core.*`, `usb_defs.h`) — **reference only, not built**; we reimplement enumeration + HID as VHDL |
| `core_ulpi_wrapper/`   | https://github.com/ultraembedded/core_ulpi_wrapper | `ulpi_wrapper.v` — UTMI+ to ULPI, tested against SMSC/Microchip USB3300 |

**Author:** Ultra-Embedded.com (admin@ultra-embedded.com), © 2015–2020.

## ⚠ License: GPLv3 (copyleft)

Both cores are **GNU GPL v3** (see each `LICENSE`). This is stronger copyleft than
the Apache-2.0 `usb_hid_host` core elsewhere in this repo. Practical implication:
if a bitstream/design **incorporating these cores is distributed**, the GPL
applies to the combined work. For private/personal FPGA use there is no issue.
The author offers a commercial (non-GPL) license on request. Keep this in mind
before shipping anything built on `usb_kbd_otg`.

## Local patches (deviations from upstream)

- **`ulpi_wrapper.v` — abort payload-phase DATA on RX turnaround** (marked
  `PATCH (6502-sbc-fpga)`, v2). Upstream only aborts register cycles
  (`STATE_REG`) when the PHY takes the bus. But the USB3317 reports its own TX
  end-of-packet linestate changes (SE0→J) as RX CMDs after *every* transmitted
  packet — interrupting the very next TXCMD. The PHY then discards its TXCMD
  context while the wrapper keeps driving the current *payload* byte; if that
  byte is `0x00` (e.g. SETUP token byte 1 = address 0) the PHY sees only ULPI
  NOOP and never NXTs again — link and PHY deadlock (hardware: frozen activity
  counters, `idle=0` forever). Fix: track the payload phase (`tx_in_payload_q`,
  first NXT seen) and abort `STATE_DATA` to IDLE on a turnaround *only then*;
  the packet is lost and the transaction layer retries (the device drops the
  truncated packet on CRC anyway). `STATE_CMD` / pre-NXT `STATE_DATA` are NOT
  aborted: the pending TXCMD byte is level-based and the PHY simply re-latches
  it (v1 aborted CMD too, which livelocked `mode_update` — its pending flag
  blocks the TX-buffer pop, so `txready` stuck low and all TX froze; observed
  on hardware as constant `F` counters with `S80000000`). Reproduced/verified
  in simulation with an adversarial PHY model (`tb_hang2.v`/`tb_hang3.v`:
  EOP-echo RX CMDs, startup dir-high, ACKing device).

- **`usbh_sie.v` — EOP-wait timeout for ULPI PHYs** (marked `PATCH (6502-sbc-fpga)`).
  Upstream waits for the SE0→J end-of-packet pattern on `linestate` after every
  transmit. Over ULPI, linestate only updates via PHY RX CMDs, and the USB3317
  does not report the link's *own* TX EOP that way — `wait_eop_q` stuck high and
  the SIE deadlocked in `STATE_TX_IFS` on the very first SOF (`USB_RX_STAT` =
  `80000000` forever). A 32-clock timeout force-clears the wait; the ULPI PHY
  enforces real inter-packet gaps itself via NXT. Root-caused and verified in
  simulation (Icarus, `tb_hang.v`: before = START_PEND never clears, after =
  SETUP dispatches and the DATA0 stage transmits).
- **`usbh_sie.v` — 2 ms busy watchdog** (marked `PATCH (6502-sbc-fpga)`).
  Defense in depth: no legal FS transaction keeps the SIE busy anywhere near
  2 ms, yet the USB3317 wedged individual transfers in ways the UTMI-designed
  FSM never anticipated (hardware: SIE never idle again after a device
  response, freezing SOFs and everything else). After 2 ms of continuous busy
  the FSM is forced back to IDLE; the caller sees idle + non-ACK response and
  retries. The register-level sequencer (`usb_host_seq.vhd`) additionally has
  a 10 ms watchdog on its own poll loops.
- **`usbh_sie.v` — response-timeout widened for low-speed** (marked `PATCH`).
  `RX_TIMEOUT` 511 → 4095 and `last_tx_time_q` 9 → 13 bits, so a 1.5 Mbps LS
  device's response (≈8× slower than FS) is not missed. Harmless for FS.
- **`usbh_host.v`** — default `USB_CLK_FREQ` changed 48 MHz → 60 MHz (our ULPI
  clock), so the timing localparams are correct even if generics don't cross
  the VHDL→Verilog boundary.

## What we build on top

These cores provide only the transaction layer (SOF, tokens, CRC5/CRC16, data,
handshakes) plus PHY functional-register control. Enumeration, HID boot-protocol
decoding, and VBUS enable are **ours** — implemented in VHDL under
`boards/tang_primer_20k/usb_kbd_otg/rtl/`.
