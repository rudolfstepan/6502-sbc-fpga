# Tang Primer 20K — 6502 SBC

Target: Sipeed Tang Primer 20K (Gowin GW2A-LV18PG256C8/I7)

## Board Specs

| Resource       | Value                        |
|----------------|------------------------------|
| FPGA           | Gowin GW2A-18C / `GW2A-LV18PG256C8/I7` |
| DDR3 SDRAM     | 64 MB onboard; disabled by default, optional via `USE_DDR3` |
| Clock          | 27 MHz oscillator; PLL derives 54 MHz SBC / 27 MHz pixel / 135 MHz TMDS |
| UART           | CH340 USB-UART / pins `M11/T13` |
| Video          | HDMI out                     |
| Storage        | On-board microSD/SDIO slot in SPI mode |
| Audio          | Dock PT8211 audio DAC        |
| GPIO           | 2× 40-pin headers            |

## Toolchain

- **Synthesis/P&R**: GowinEDA (GOWIN FPGA Designer) ≥ 1.9.9
- **Constraints**: CST format (`constraints/*.cst`)
- **Programming**: `openFPGALoader` or GowinEDA Programmer

## Differences from PIX16 (Xilinx)

| Aspect         | PIX16 (Spartan-6)       | Tang Primer 20K (GW2A-18) |
|----------------|-------------------------|---------------------------|
| BRAM primitive | `RAMB16BWER`            | `BSRAM` / `pROM`          |
| PLL            | `DCM_SP` / `PLL_BASE`   | `rPLL`                    |
| I/O standard   | `SSTL2_I`               | `LVCMOS33`                |
| Constraint fmt | UCF                     | CST                       |
| Project file   | `.xise` (ISE)           | `.gprj` (GowinEDA)        |

## Status

HDMI output uses a Tang-specific top-level wrapper. The TMDS stream is full HDMI
rather than bare DVI: `hdmi_encoder` inserts a per-frame data island carrying an
AVI InfoFrame (VIC 2, 720×480p) together with the video preamble and guard bands.
Bare DVI displayed fine on monitors but many USB HDMI capture devices stayed
black (or dropped every other frame); the AVI InfoFrame makes them lock onto the
format. The static InfoFrame packet (BCH ECC + TERC4) is precomputed offline by
`tools/gen_avi_infoframe.py` into `rtl/core/hdmi/hdmi_data_island_pkg.vhd`.

Timing is exact CEA-861 **720×480p** at 27 MHz pixel clock (858×525 total,
59.94 Hz, 31.47 kHz H-sync). The text/RGB332 renderer keeps its native 640-wide
content and pillarboxes it into the 720 active region (40 px black border each
side); the 180×120 RGB222 mode is instead scaled 4× to fill the whole 720×480
frame edge to edge. Earlier revisions used 800×525 totals (non-standard
33.75 kHz / 64.3 Hz) and then a 640-active-in-858 hybrid that monitors tolerated
but grabbers did not.

The SBC logic runs at 54 MHz. Its two-phase T65 bus advances the CPU every
second system clock, giving a 27 MHz maximum 6502 bus rate before VIC stalls.
The VIC uses `CLK_DIV=2`, so video timing remains at exactly 27 MHz.
VIC prefetch steals 82 of 1716 system clocks per scan line in text/legacy mode,
161 in RGB332, or 136 in RGB222. The corresponding bus overhead is about 4.8%,
9.4%, or 7.9%.

Clock derivation uses a single 270 MHz PLL root. TMDS FCLK is `270/2 = 135 MHz`,
the SBC is `270/5 = 54 MHz`, and OSER10 PCLK is derived directly from its FCLK as
`135/5 = 27 MHz`. The direct FCLK/PCLK relationship is required for stable HDMI.

On reset the FPGA shows the boot/status diagnostic screen while it initializes
the on-board microSD/SDIO slot in SPI mode and loads the 16 KB physical image
into shadow ROM. The CPU sees `$A000-$CFFF` and `$F000-$FFFF`; `$D000-$EFFF`
remains free for I/O, including SID at `$D400-$D418`. After a successful load
the CPU is released and HDMI switches to the SBC VIC output.

Current bring-up status:

- HDMI boot/status screen works on a monitor.
- CH340 UART works from the PC as a normal serial port, tested as `COM12`.
- The UART monitor is reachable through the same CH340 path.
- KEY0 (dock S0) is the reset button: a short press soft-resets the 6502, a long
  press (>1 s) is a full board reset.
- KEY1 enters the FPGA monitor and holds the 6502 CPU.
- Without a card in the on-board microSD slot, the boot debug output correctly
  reports that the SD card cannot be initialized/read.
- PS/2 keyboard input works via PMOD 0 — keystrokes are injected into the
  UART receive path so EhBASIC and the monitor see them without software changes.

The full 24 KB CPU main-RAM range (`$0000-$5FFF`) uses on-chip BSRAM by default.
The `$4000-$5FFF` portion can be switched back to the on-board DDR3 backend with
the `USE_DDR3` board-top generic; see *Main RAM backends* below.
The address range `$6000-$7FFF` is an 8-KB CPU window into a dedicated banked
16-KB VIC framebuffer. VIC MODE bit 2 selects the CPU bank. The framebuffer
supports legacy 320×200 1-bpp graphics, 160×100 RGB332, and packed 180×120
RGB222; EhBASIC's configured `$0200-$3FFF` workspace remains unaffected.
Pressing KEY1 enters the FPGA UART monitor, holds the 6502 CPU, and switches HDMI
back to the diagnostic screen while monitor operations run.

### Buttons (reset / monitor)

The two on-board push buttons are active-low with internal pull-ups:

| Button                 | FPGA pin | Function                               |
|------------------------|----------|----------------------------------------|
| **KEY0** (dock **S0**) | `T10`    | Reset button (see below)               |
| **KEY1** (rewired)     | `T6`     | Enter UART monitor / hold the 6502 CPU |

> **DDR3 bank conflict:** DDR3 occupies I/O banks 4, 5 and 6 (forced to
> SSTL15 / 1.5 V). The dock buttons S1–S5 all live in those banks (S1=`T3` is in
> Bank 4), so only S0 (`T10`, Bank 3) survives. `key[1]` is therefore moved to
> the free Bank-3 pin **`T6`** on PMOD0 (next to the PS/2 pins `T7`/`T8`). To use
> the monitor button, wire a momentary button from that header pin to GND; with
> nothing connected the internal pull-up reads it inactive, so the board still
> works (just without a monitor button).

KEY0 is a dual-action reset, debounced and synchronised in the 54 MHz `clk_sys`
domain:

- **Short press** → **CPU soft reset** (*warm start*). Only the 6502 is held in
  reset and then restarts via its reset vector. `boot_done`, the shadow ROM, and
  main RAM are kept, so a program uploaded over the UART monitor restarts
  in place — the SD boot loader is *not* re-run and RAM is *not* cleared. This is
  the reset to use during normal operation.
- **Long press (>1 s)** → **full board reset** (*cold start*). Asserts the global
  `reset_n`, which also resets the SD ROM loader and reloads the ROM from the SD
  card, and clears the selected `$4000-$5FFF` RAM backend. Main RAM is
  **zero-cleared** before the CPU is released, so nothing from the previous
  session survives. If there is no valid SD boot image, the CPU stays held
  afterwards (no `boot_done`), so use the short press for UART-uploaded ROMs.

The HDMI PLL is intentionally **not** gated by the reset button, so `clk_sys`
keeps running (the debounce/long-press timer needs it) and the picture stays up
through both reset types.

> **Pin note:** S0 is FPGA pin `T10` (matching Sipeed's own `Cam2HDMI` and HDMI
> `dk_video` examples, whose reset is `T10`). An earlier `T5` assignment was not
> the physical button and produced a dead reset key.

The CH340 UART is connected to the SBC UART at 115200 8N1 on FPGA pins `M11`
(`uart_tx`) and `T13` (`uart_rx`). On Windows this appears as a COM port such as
`COM12` and is used for normal SBC input and output. The USB-OTG connector for
peripherals is separate from this UART path.

UART ownership priority is:

1. FPGA monitor while KEY1 monitor mode is active.
2. Boot debug/status output while SD boot is still running or failed.
3. Normal 6502 UART 6551 after the ROM has booted.

On-board microSD slot wiring in SPI mode:

| SBC signal | FPGA pin | SDIO signal | SPI role |
|------------|----------|-------------|----------|
| `sd_dclk` | `N10` | CLK  | SCK |
| `sd_ncs`  | `N11` | DAT3 | CS, active low |
| `sd_mosi` | `R14` | CMD  | MOSI / DI |
| `sd_miso` | `M8`  | DAT0 | MISO / DO |

The slot also exposes `DAT1=M7`, `DAT2=M10`, and card-detect `DET_A=D15`; those
are not used by the current SPI-mode boot path.

### PS/2 keyboard on PMOD 0

The SBC accepts keyboard input via a PS/2 keyboard connected to the Dock board's
PMOD 0 connector (top-left, near the MIC ARRAY silkscreen).  Keystrokes are
automatically injected into the UART 6551 receive path so EhBASIC and the UART
monitor see them without any software changes.

Supported editing keys in BASIC:

- Arrow keys move the VIC hardware cursor across the 40x25 text screen.
- Enter after cursor movement reads the full screen line (C64-style), trims
  trailing spaces, and replays it to BASIC with echo suppressed.
- Home moves the cursor to the top-left cell.
- Shift+Home or Ctrl+L clears the text screen and homes the cursor.
- Ctrl+C sends BASIC STOP/RUN-STOP (`$03`).

| PS/2 signal | FPGA pin | PMOD 0 pin | Notes                    |
|-------------|----------|------------|--------------------------|
| `ps2_clk`   | `T7`     | signal     | Internal pull-up enabled |
| `ps2_data`  | `T8`     | signal     | Internal pull-up enabled |
| VCC         | —        | 5 V        | From board 5 V rail      |
| GND         | —        | GND        |                          |

No external pull-up resistors are needed; the FPGA internal pull-ups are
sufficient for the PS/2 open-collector bus.

The boot diagnostic screen (HDMI rows 17–18) shows real-time keyboard status:

```text
USB HID: CON=1  KEY=$xx  MOD=$xx
USB HID: PH=4 DATA=$xx POLL=1 EV=x
```

`CON=1` indicates the keyboard is detected (PS/2 clock activity), `PH=4` means
connected and active, and `KEY`/`DATA` update live as keys are pressed.

#### Why PS/2 instead of USB HID

An earlier version used the nand2mario `usb_hid_host` core for direct USB
low-speed bit-bang on D+/D−.  While the core detected connected keyboards
(boot screen showed `PH` cycling between `3` and `F`), USB enumeration never
completed successfully.  The root cause was not identified — possible
contributors include keyboard compatibility (hub-based or USB 2.0-only
keyboards), signal integrity on the PMOD wiring, or timing sensitivity in
the bit-bang protocol.  The nand2mario third-party source is still present
under `third_party/usb_hid_host/` for future investigation.  PS/2 works
reliably and was adopted as the primary keyboard interface.

The on-board SDIO slot uses pins M8 (sd_miso / DAT0) and M10 (unused) which are
dual-purpose SSPI pins on the GW2A-18C. The `make build` flow uses a Tcl script
(`sbc/project/build.tcl`) instead of the `.gprj` project file so that
`set_option -use_sspi_as_gpio 1` is passed to P&R before placement runs.
For the GUI flow, `impl/pnr/device.cfg` is checked into the repo with SSPI/MSPI
set to `regular_io = true`. Both paths avoid the `PR2017`/`PR2028` errors that
otherwise occur when SSPI/MSPI default to dedicated config pins. See
*Opening in GOWIN FPGA Designer* and *Why `build.tcl` instead of the `.gprj`*.

## Audio (PT8211 DAC)

The dock board's PT8211 (TM8211) audio DAC is driven by the single-voice sound
synthesizer at `$8830`–`$8839`. See [Sound Chip](../../docs/SOUND.md) for the
register map, BASIC/assembly usage, and the C-emulator-compatible programming
model.

| Signal | FPGA pin | Notes |
| --- | --- | --- |
| `dac_bck` (BCK) | N15 | bit clock |
| `dac_ws` (WS/LRCK) | P16 | word/channel select |
| `dac_din` (DIN) | P15 | serial data, MSB first |
| `pa_en` (PA_EN) | R16 | **amp enable — tied high; without it the amp only hisses** |

Pinout matches Sipeed's `TangPrimer-20K-example/PT8211`. These pins are in Bank 1
(VCCIO locked to 3.3 V by other ports), so they are constrained `LVCMOS33`.

> The sound sources (`sound_voice.vhd`, `pt8211_dac.vhd`) must be listed in
> `sbc/project/build.tcl` — the PowerShell build drives `gw_sh build.tcl`, not the
> `.gprj`. If they are missing, GowinEDA synthesizes them as black boxes and the
> DAC outputs float (hiss / silence).

Quick test from BASIC:

```basic
10 POKE 34864,184 : POKE 34865,1 : REM 440 Hz
20 POKE 34868,255 : REM volume
30 POKE 34869,17  : REM square + gate on
40 FOR I=1 TO 1000 : NEXT
50 POKE 34869,0   : REM gate off
```

## Main RAM backends

`tang20k_sbc_top` exposes one stable `sram_ext_*` byte interface to the SBC core
and selects its implementation statically with the `USE_DDR3` generic.

### Default: low-power BSRAM (`USE_DDR3=false`)

- `$0000-$3FFF` remains in the core's 16-KB BSRAM.
- `bram_byte_bridge.vhd` provides another 8 KiB at `$4000-$5FFF`.
- The bridge zero-clears its RAM after cold reset before asserting `ram_ready`.
- The DDR PHY, 400-MHz memory PLL, DLL and DQS logic are absent from the netlist.
- External DDR pins are held safe: `RESET_n=0`, `CKE=0`, `ODT=0`, static clock,
  inactive commands, and high-impedance data/strobe pins.

Measured from Gowin's vectorless reports for the same design:

| Build | Power estimate | Dynamic | Junction @ 25 °C | BSRAM |
|---|---:|---:|---:|---:|
| DDR3 backend | 616.7 mW | 448.1 mW | 44.7 °C | 35/46 (76%) |
| BSRAM backend | 323.6 mW | 153.8 mW | 35.4 °C | 31/46 (67%) |

The absolute values are estimates without VCD/SAIF activity, but the removal of
the DDR clock domains and PHY is reflected directly in the synthesized netlist.

### Optional DDR3 (`USE_DDR3=true`)

The original Gowin DDR3 Memory Interface IP, 400-MHz PLL and
`ddr3_byte_bridge.vhd` remain in the source tree. To restore them:

1. Set the `USE_DDR3` generic in `tang20k_sbc_top.vhd` to `true` (or override it
   in the Gowin project elaboration settings).
2. In `sbc/constraints/tang20k_sbc.cst`, add `VREF=INTERNAL` to every `ddr_dq[*]`
   `IO_PORT` line and restore this placement constraint before the HDMI PLL line:

   ```text
   INS_LOC "ddr_backend_g.ddr_mem_pll_i/rpll_inst" PLL_L[0] exclusive;
   ```

3. Append the DDR clock profile to `sbc/constraints/tang20k_sbc.sdc`:

   ```tcl
   create_clock -name ddr_clk_x1 -period 10  [get_nets {ddr_clk_x1}]
   create_clock -name ddr_mem -period 2.5 [get_nets {ddr_memory_clk}]
   set_clock_groups -asynchronous \
     -group [get_clocks {ddr_clk_x1 ddr_mem}] -group [get_clocks {clk_27mhz}]
   ```

The re-enabled DDR profile has been synthesis/P&R tested after introducing the
backend generic. Gowin accepts only one effective CST/SDC profile in this flow,
so the DDR attributes must be restored in the base files rather than loaded as
small overlay files.

The DDR bridge performs fill/check/clear bring-up before `ram_ready`, and the CPU
is stalled for each DDR access. The CPU-visible address map is identical in both
backends, so ROMs and applications require no changes.

## Math coprocessor (FPU)

A small memory-mapped **signed 32×32 fixed-point multiplier** at `$88B0` turns the
GW2A's hardware DSP blocks into a peripheral the 6502 can drive, off-loading the
multiply that 8-bit fixed-point code spends all its time on. Default format is
**8.24**; the shift is a register, so any Q-format works.

The Mandelbrot renderer ([`sw/mandelbrot_copro.s`](../../sw/mandelbrot_copro.s))
uses the coprocessor in 8.24 format and renders directly into the packed
180×120 RGB222 VIC mode. Earlier 320×200 measurements showed roughly 10 seconds
versus 5–8 minutes with software multiplication; the current mode has a
different pixel count and should be timed separately.

Verify the coprocessor on hardware with [`sw/copro_selftest.s`](../../sw/copro_selftest.s)
(green screen + `COPRO 2.0*3.0=06000000 OK` over UART). Full register map, timing
and 6502 usage: **[Math Coprocessor (FPU)](../../docs/FPU.md)**.

## Build

The default BSRAM build works through both `make_tang20k.ps1`/`gw_sh` and the
Gowin GUI. The optional DDR3 profile may depend on the Gowin GUI and installed
DDR3 IP support; restore the DDR attributes in the active CST/SDC files as
described under *Optional DDR3* before P&R.

### Prerequisites

| Tool              | Purpose                     | Notes                                    |
|-------------------|-----------------------------|------------------------------------------|
| GowinEDA >= 1.9.8 | Synthesis + P&R + bitstream | `gw_sh` must be on `PATH`               |
| openFPGALoader    | Flash bitstream to board    | Optional; GowinEDA Programmer also works |

On Windows, add `C:\Gowin\Gowin_V1.9.8.08\IDE\bin` to your `PATH` or set
`GOWIN=C:/Gowin/Gowin_V1.9.8.08/IDE/bin/gw_sh.exe` when invoking make.

### Building the bitstream

All steps run from this directory (`fpga/boards/tang_primer_20k/`).

```bash
make build
```

This executes `gw_sh sbc/project/build.tcl` from inside `sbc/project/` and runs the full
flow — synthesis, place & route, and bitstream generation — in one shot.

The output bitstream is:

```
project/impl/pnr/tang_sbc.fs
```

### Why `build.tcl` instead of the `.gprj` project file

The on-board microSD DAT0 line (`sd_miso`, pin M8) is a dual-purpose SSPI pin on
the GW2A-18C. GowinEDA regenerates `impl/pnr/device.cfg` from the `.gprj`
defaults at the start of every P&R run and defaults SSPI to `false`, which causes
errors `PR2017` / `PR2028`.

`sbc/project/build.tcl` calls `set_option -use_sspi_as_gpio 1` before `run all` so
gw_sh writes `set SSPI regular_io = true` into `device.cfg` on the first pass.
No post-build patching is needed.

### Opening in GOWIN FPGA Designer (GUI)

You can place & route from the GUI instead of `make build`. The GUI does **not**
read `build.tcl`, so the `set_option -use_sspi_as_gpio` / `-use_mspi_as_gpio`
lines have no effect there — it relies on `impl/pnr/device.cfg` instead. To save
the next person the trouble, that file is checked into the repo with the correct
settings, so a fresh checkout works out of the box:

1. Open `sbc/project/tang_sbc.gprj` in GOWIN FPGA Designer.
2. Run **Place & Route**.

The committed `impl/pnr/device.cfg` already contains:

```
set SSPI regular_io = true
set MSPI regular_io = true
```

which releases the dedicated SSPI pads so `sd_miso` (pin `M8`) and `key[0]`
(pin `T10`) can be placed, avoiding `PR2017` / `PR2028`.

If `device.cfg` is ever missing or reset to `false`, re-enable it via
**Project → Configuration → Dual-Purpose Pin** → tick **Use SSPI as regular IO**
and **Use MSPI as regular IO**, then save. `make build` also rewrites it to the
correct values, and `make clean` is set up to preserve it.

### Programming the board

With openFPGALoader (USB cable connected to the Tang Primer 20K JTAG port):

```bash
make program
```

Or manually:

```bash
openFPGALoader -b tang_primer_20k project/impl/pnr/tang_sbc.fs
```

GowinEDA Programmer can also be used: open `tang_sbc.fs` and select the
`GW2A-18C` device with the `SRAM Program` operation.

### Clean rebuild

```bash
make clean   # removes project/impl/ and project/tmp/
make build
```

### Troubleshooting

| Symptom | Fix |
|---------|-----|
| `gw_sh: command not found` | Add GowinEDA `bin/` to `PATH`, or set `GOWIN=<full path>` |
| `PR2017` / `PR2028` on `sd_miso` | Build is using the old `.gprj` flow; switch to `make build` which uses `build.tcl` |
| `PR2017` / `PR2028` on `sd_miso` or `key[0]` in the GUI | Enable **Use SSPI as regular IO** and **Use MSPI as regular IO** under **Project → Configuration → Dual-Purpose Pin** (see *Opening in GOWIN FPGA Designer*) |
| Newly added VHDL unit not compiled in `work` | Run `make clean && make build` to force full resynthesis |
| Stale objects from `tang_sbc.vg` | Run `make clean` — that file is a generated netlist, not source |
