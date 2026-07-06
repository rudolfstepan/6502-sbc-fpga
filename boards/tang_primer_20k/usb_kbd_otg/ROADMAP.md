# USB keyboard on the OTG port (USB3317 ULPI) — build roadmap

Goal: a USB **boot-protocol keyboard** working on the Tang Primer 20K OTG port,
output as ASCII over UART (same end result as the low-speed `usb_kbd` project,
but via the on-board USB3317 Hi-Speed PHY over ULPI).

Decision (2026-07-06): **hybrid**. The hard, timing-critical transaction layer
uses the FPGA-verified `ultraembedded/core_usb_host` (+ `core_ulpi_wrapper`).
Enumeration, HID decode and VBUS enable are **our own VHDL** — that is the
"build our own host" part; we just don't hand-code SOF/CRC/packet timing.

## Architecture

```
 USB3317 PHY ──ULPI(60MHz)── [ulpi tristate] ── ulpi_wrapper ──UTMI── usbh_host ──AXI4-Lite── our host FSM ── UART
      ▲                                             │(pre-init)                                     │
      └── VBUS (DRV_VBUS via ulpi_vbus_init) ───────┘                                    HID boot report → ASCII
```

- **~~ulpi_vbus_init.vhd~~ (removed 2026-07-06):** a pre-init stage that wrote
  USB3317 OTG Control to set DrvVbus before handing the bus to the wrapper.
  Removed: VBUS is board-supplied on the dock (detect worked with DrvVbus
  clear — the wrapper rewrites OTG_CTRL=0x06 anyway), and a NXT-timeout during
  the pre-init could leave the PHY mid register cycle without an abort STP,
  after which it never NXT-ed the wrapper's TXCMDs (hardware: NXT counter
  stuck at 0). The wrapper owns ULPI from reset now. File kept on disk,
  dropped from build.tcl/.gprj.
- **ulpi_wrapper (vendored):** ULPI↔UTMI, runs on the 60 MHz `ulpi_clk`.
- **usbh_host (vendored):** UTMI transaction layer + AXI4-Lite regs; generates
  SOF, does CRC5/CRC16, token/data/handshake, timeout/retry. Param
  `USB_CLK_FREQ=60000000` (our ULPI clock, not the 48 MHz default).
- **our host FSM (ours):** drives the AXI regs to reset the bus, enable the root
  hub, enumerate, set boot protocol, and poll the interrupt IN endpoint.

## usbh_host register map (base + offset)

| Off | Name | Key fields |
|-----|------|-----------|
| 0x00 | `USB_CTRL` | [8]TX_FLUSH [7]DMPULLDOWN [6]DPPULLDOWN [5]TERMSELECT [4:3]XCVRSELECT [2:1]OPMODE [0]ENABLE_SOF |
| 0x04 | `USB_STATUS` | [31:16]SOF_TIME [2]RX_ERROR [1:0]LINESTATE |
| 0x08 | `USB_IRQ_ACK` | [3]DEVICE_DETECT [2]ERR [1]DONE [0]SOF (write-1-clear) |
| 0x0C | `USB_IRQ_STS` | same bits (status) |
| 0x10 | `USB_IRQ_MASK` | same bits (enable) |
| 0x14 | `USB_XFER_DATA` | [15:0]DATA_TX_LEN |
| 0x18 | `USB_XFER_TOKEN` | [31]START [30]IN [29]ACK [28]PID_DATAX(toggle) [23:16]PID [15:9]DEV_ADDR [8:5]EP_ADDR |
| 0x1C | `USB_RX_STAT` | [31]START_PEND [30]CRC_ERR [29]RESP_TIMEOUT [28]IDLE [23:16]RESP(handshake PID) [15:0]RX_COUNT |
| 0x20 | `USB_WR_DATA` (w) / `USB_RD_DATA` (r) | [7:0] TX-FIFO push / RX-FIFO pop |

### PHY config values (from the C driver)

- **Bus reset / SE0:** `USB_CTRL = 0xC4` — OPMODE=2, DP/DM pulldown=1, XCVR/TERM=0. Hold ~11 ms.
- **Host full-speed enable:** `USB_CTRL = 0x1E8` — XCVRSELECT=1, TERMSELECT=1,
  OPMODE=0, DP/DM pulldown=1, TX_FLUSH=1. (`|0x001` to also ENABLE_SOF → 0x1E9.)
- **Device detect:** read `USB_STATUS`; LINESTATE≠0 = device present; bit0=1 ⇒
  full-speed (D+ high), bit1=1 ⇒ low-speed (D- high).

### One transaction (via regs)

1. (OUT/SETUP) push payload bytes to `USB_WR_DATA`; set `USB_XFER_DATA`=tx_len.
2. Write `USB_XFER_TOKEN` with START=1, IN/OUT, PID (SETUP/IN/OUT), DEV_ADDR,
   EP_ADDR, PID_DATAX = data toggle, ACK=expect handshake.
3. Poll `USB_RX_STAT`: wait START_PEND=0 / IDLE=1. Check RESP (ACK/NAK/STALL),
   CRC_ERR, RESP_TIMEOUT; RX_COUNT + read `USB_RD_DATA` for IN data.

## Stages

- [x] **Stage 0 — PHY alive:** `usb_otg` project read USB3317 ID `00060424`.
- [x] **Stage 1 — host up + device detect:** VBUS + host FS + SOF; LINESTATE read
      a plugged-in keyboard as **FS** (`USB FS` on UART). Confirmed on hardware.
- [~] **Stage 2a — enumeration transport (in progress):** `usb_host_seq.vhd` does
      a control-read `GET_DESCRIPTOR(DEVICE,18)` on EP0 addr 0 and prints the
      descriptor as hex (`DESC: ...`). Validates SETUP + IN + OUT-status + toggle.
- [ ] **Stage 2b — full enumeration:** SET_ADDRESS(1) → SET_CONFIGURATION(1) →
      SET_PROTOCOL(boot,0) to the HID interface (same control-transfer pattern
      with different requests). Reference: `.../sw/usb_core.c`.
- [ ] **Stage 3 — HID polling + ASCII:** every frame, IN on the interrupt
      endpoint (EP1), decode the 8-byte boot keyboard report
      (`[0]`=modifiers, `[2..7]`=keycodes), map HID→ASCII (reuse the table in
      `rtl/core/usb/usb_hid_host.vhd`), emit over UART. Handle NAK (no data).

## Open risks / notes

- **VBUS:** dock feeds the OTG VBUS via a Schottky (D10) with CPEN gating; we set
  `DRV_VBUS` to be safe. If the keyboard never powers (LINESTATE stays SE0),
  VBUS is the first suspect.
- **Clocking:** everything downstream of the PHY runs on the 60 MHz `ulpi_clk`,
  which only exists after the PHY leaves reset — so `ulpi_rst` (PHY RESETB) is
  driven from a `clk_27mhz` power-on reset, and the ulpi-domain reset self-times
  off the first ulpi clocks.
- **License:** vendored cores are GPLv3 — fine privately, matters if distributed.
