# 6502 SBC FPGA

> 📖 **Documentation:** the full guide lives in the **[Wiki](https://github.com/rudolfstepan/6502-sbc-fpga/wiki)** (mirrors [docs/](docs/INDEX.md)).
> 🧩 **Part of:** the [6502 SBC emulator](https://github.com/rudolfstepan/6502-sbc-emulator) project ([emulator Wiki](https://github.com/rudolfstepan/6502-sbc-emulator/wiki)). This repo is linked there as the `fpga/` submodule.

This repository contains the hardware implementation track for the
[6502 SBC emulator](https://github.com/rudolfstepan/6502-sbc-emulator).
The goal is to rebuild the emulator's machine as synthesizable VHDL for real FPGA
targets while keeping the memory map and software-facing behavior compatible.

The FPGA build reuses ROMs and kernel sources from the parent emulator repository
(via `../roms/` and `../../tools/kernel/`), so check it out as the `fpga/`
submodule inside [6502-sbc-emulator](https://github.com/rudolfstepan/6502-sbc-emulator)
when building.

## Current Scope

The first milestone is a hardware skeleton:

- shared address/data bus types and constants
- fixed memory map decoder matching the C emulator
- FPGA top-level shell
- imported T65 6502-compatible VHDL CPU core plus local adapter
- synthesizable RAM/ROM building blocks
- a first synthesizable VIA 6522 MVP
- a first synthesizable UART 6551 MVP
- placeholder device blocks for disk MVP, VIC, and sound
- simulation entry points for incremental verification

The placeholders intentionally expose the intended bus contracts before each chip is
fully implemented. This lets us add real behavior one component at a time without
changing the top-level wiring repeatedly.

## PIX16 Spartan-6 Board Status

The checked-in Xilinx ISE project for the PIX16 board lives at:

```text
fpga/boards/pix16/project/fpga.xise
```

It targets `xc6slx16-ftg256-2`. The current hardware bring-up target is
`boards/pix16/rtl/pix16_sbc_sd_boot_top.vhd` with `boards/pix16/constraints/pix16_sd_boot.ucf`.
This top integrates the T65 CPU, SDRAM-backed main RAM, 2 KB text VRAM, VIA,
UART, VGA, SD-card ROM loading, a boot status screen, an SDRAM self-test, and a
UART hardware monitor.

The older `pix16_sbc_minimal_top` flow remains useful as a small VGA/T65 smoke
test. The SD boot top is the active path for firmware work because it loads the
16 KB ROM window `$C000-$FFFF` into writable shadow RAM.

For fast iteration, press the monitor button and upload a ROM over UART without
rewriting the SD card:

```sh
python fpga/tools/upload_monitor_hex.py --build-demo --port COM15 --run --verbose
```

See `docs/UART_MONITOR.md` for monitor commands, memory ranges, and ROM upload
details.

ISE build products are intentionally ignored by `.gitignore`; `fpga.xise` is the
project file that should be kept under version control.

## Tang Primer 20K Board Status

The Gowin project for the Tang Primer 20K lives at:

```text
fpga/boards/tang_primer_20k/project/tang_sbc.gprj
```

It targets the Sipeed Tang Primer 20K / Gowin GW2A-18. The current board top is
`boards/tang_primer_20k/rtl/tang20k_sbc_top.vhd`. It brings up HDMI (DVI-style
TMDS, 27 MHz pixel clock, CEA-861 480p timing for standard 640×480 @ 59.94 Hz),
displays the boot/status diagnostic screen first, initializes the on-board
microSD/SDIO slot in SPI mode, loads a 16 KB physical shadow-ROM image, and
releases the T65 CPU after a successful load. The current CPU mapping is
`$A000-$CFFF` plus `$F000-$FFFF`; `$D000-$EFFF` remains available for I/O.

Current verified bring-up:

- HDMI boot/status output works.
- CH340 UART works from the PC as the board serial port, tested as `COM12`.
- KEY1 enters the FPGA UART monitor and holds the 6502 CPU.
- PS/2 keyboard on PMOD 0 (`T7`/`T8`) works — keystrokes are injected into the
  UART receive path so EhBASIC sees them as serial input.
- Without a card in the on-board microSD slot, boot debug output correctly
  reports that SD initialization/read cannot complete.

The Tang path defaults to an all-BSRAM main-memory backend for lower power. The
original DDR3 backend remains selectable with `USE_DDR3=true`.
The CH340 UART runs at `115200 8N1`; the USB-OTG connector is separate and
is not the SBC UART. The on-board microSD slot is used in SPI mode on
`N10/N11/R14/M8` as documented in `boards/tang_primer_20k/README.md`.

EhBASIC and standalone ROMs are uploaded through the split-map modes:

```powershell
python tools\upload_monitor_hex.py --ehbasic --port COM15 --baud 115200 --run
python tools\upload_monitor_hex.py roms\soundsid.rom --split-rom --port COM15 --baud 115200 --run
```

See [Split ROM and Native SID Update](docs/SPLIT_ROM_SID_UPDATE.md) for what
changed and how to migrate old `$C000` ROMs.

USB HID keyboard input via the nand2mario `usb_hid_host` bit-bang core was
attempted but USB enumeration did not complete reliably (see
`boards/tang_primer_20k/README.md` for details). PS/2 was adopted instead.

## Current Tests

Run from this directory:

```sh
make test
```

The current GHDL tests cover:

- address decoding for all mapped device windows
- reset-vector fetch from ROM at `$FFFC-$FFFD`
- ROM-scripted bus write into SRAM address space
- SRAM readback after write
- VIA 6522 register, port-mask, IER/IFR, and timer-IRQ behavior
- UART 6551 status, TX, RX, overrun, programmed reset, and RX IRQ behavior
- conversion of a real emulator ROM into VHDL hex and reset-vector readback
- T65 adapter analysis/elaboration and defined bus outputs after reset
- T65 system boot from a tiny real 6502 ROM that executes `LDA #$42; STA $0002`
- T65 execution of a tiny real 6502 ROM that writes `$41` to UART DATA at `$8810`
- T65 execution of a tiny real 6502 ROM that drives VIA Port B through DDRB/ORB
- T65 handling of a VIA Timer 1 IRQ and execution of an IRQ handler through
  the `$FFFE-$FFFF` vector
- T65 boot smoke test with composed `kernel.rom + msbasic.rom`, verifying reset
  fetch, VIA DDRA init, and kernel screen-pointer setup

## CPU Core

The local third-party CPU import lives under `third_party/t65/`. It currently
contains the T65(b) VHDL core and a project-local adapter:

```text
third_party/t65/rtl/          imported T65 source files
rtl/core/cpu/t65_adapter.vhd  local 16-bit bus adapter
```

The adapter maps T65's 24-bit address bus down to the SBC's 16-bit address space,
exports write-enable/data signals, and feeds memory/peripheral read data directly
to T65's `DI` input for the documented 6502 instruction subset used so far.

For now, `sbc_top.vhd` still uses the script-driven `cpu6502_slot` so the existing
smoke tests remain deterministic. A second top-level, `rtl/sbc_t65_top.vhd`, swaps
in `t65_adapter` and is covered by a tiny real 6502 ROM boot test.

T65 currently uses the ROM and SRAM components' `ASYNC_READ` mode in
`sbc_t65_top.vhd`. The T65 system top advances the CPU every other system clock
and registers read data during the stable bus phase so FPGA-style synchronous
writes and asynchronous reads have deterministic simulation timing. The
script-driven smoke-test top keeps the default synchronous memory paths.

`sim/tb/tb_sbc_t65_indirect_vic.vhd` is kept as an experimental/quarantined test for
`STA ($zp),Y` into VIC text RAM. It currently exposes a T65 indirect-addressing
integration issue and is intentionally not part of the default `make test` target.

## ROM Conversion

The VHDL ROM loader reads text files in `offset byte` format. Convert emulator ROM
artifacts with:

```sh
python tools/bin_to_vhdl_hex.py --size 0x4000 --output sim/generated/chess_rom.hex ../roms/chess.rom
```

Multiple ROM windows can be composed with `file@offset`:

```sh
python tools/bin_to_vhdl_hex.py --size 0x4000 --output sim/generated/sbc_rom.hex ../roms/kernel.rom@0x0000 ../roms/msbasic.rom@0x1000
```

For the EhBASIC system image, keep the kernel at the same offset and replace only
the BASIC window:

```sh
python tools/bin_to_vhdl_hex.py --size 0x4000 --output sim/generated/sbc_ehbasic_rom.hex ../roms/kernel.rom@0x0000 ../roms/ehbasic.rom@0x1000
```

`make test` currently generates `sim/generated/chess_rom.hex` and
`sim/generated/sbc_rom.hex` automatically. `make roms` also generates
`sim/generated/sbc_ehbasic_rom.hex`. The generated SBC images compose
`kernel.rom` at offset `$0000` and the selected BASIC ROM at offset `$1000`.

## SD Boot Image

The PIX16 SD boot path keeps the FPGA bitstream stable and loads the 16 KB SBC
ROM window from the SD card into shadow RAM at reset:

```sh
# from fpga/:
make sd-boot-image
# from fpga/boards/pix16/:
cd boards/pix16 && xtclsh scripts/create_sd_boot_ise_project.tcl
```

If `xtclsh` is not in your normal shell PATH, run the project command from the
Xilinx ISE Command Prompt. The image file is
`sim/generated/sbc_ehbasic_sd.img` and contains `kernel.rom + ehbasic.rom` for
CPU addresses `$C000-$FFFF`.

The SD image is persistent across FPGA resets. The UART monitor upload is a
development shortcut that writes the same shadow-ROM RAM after boot and is lost
on reset/reprogramming.

For the Tang Primer 20K, `make -C sw fpga-ehbasic` builds the 16 KB ROM,
per-window `.bin` segments, **and** the raw SD boot image
(`roms/fpga_ehbasic_16kb.img`) in one step, so the boot card stays in sync with
the ROM.

## D64 GoDrive (virtual disk)

A second SD card (the `sd2_*` data disk) holds FAT32 `.d64` images. The FPGA
mounts one image and exposes its 256-byte D64 sectors to the 6502 at `$8824`;
the 6502 sees a simple disk and never parses FAT32. From BASIC: `LOAD "$"` lists
the directory, `LOAD "NAME"` loads a program (printing its `CALL` address), and
`CALL <addr>` runs it. The disk format is borrowed from Commodore D64 for
convenience only — the programs are this system's own code, **not** C64-compatible.

See [docs/D64_DRIVE.md](docs/D64_DRIVE.md) for the register map, kernel API,
tooling (`tools/d64/`, `tools/build_sid_prg.py`), and the runnable test disk
(`make tunes-d64`).

## REIST benchmark engine (research)

A standalone FPGA project (no 6502 files touched) that measures REIST
centered-remainder arithmetic against the Gowin Integer Division IP on the Tang
Primer 20K. On hardware the REIST reduction uses ~12.6× less logic and runs at
161.8 MHz vs the IP's 8.1 MHz, and is 4× fewer cycles per step in a dependency
chain. It is the hardware counterpart to the CPU benchmark suite
[**reist-crypto-bench**](https://github.com/rudolfstepan/reist-crypto-bench).
See [docs/REIST.md](docs/REIST.md) and run the simulation with `make reist`.

## Memory Maps

### Current Tang Primer 20K

```text
$0000-$3FFF   BRAM main RAM (EhBASIC workspace included)
$4000-$5FFF   8 KB BSRAM main RAM (optional DDR3 backend)
$6000-$7FFF   8 KB CPU window into 16 KB banked VIC framebuffer
$8000-$87FF   VIC text/color RAM
$8800-$88BF   VIA, UART, D64 GoDrive ($8824), sound timer, and math-coprocessor I/O
$9000-$900F   VIC control registers
$A000-$CFFF   Shadow ROM application window (EhBASIC/standalone ROM)
$D400-$D418   SID-compatible registers
$F000-$FFFF   Shadow ROM kernel/vector window
```

The physical shadow image is still 16 KB: offsets `$0000-$2FFF` map to
`$A000-$CFFF`, and `$3000-$3FFF` map to `$F000-$FFFF`.

### Legacy/PIX16 reference

```text
$0000-$7FFF   SRAM
$8000-$87FF   VIC text/color RAM
$8800-$880F   VIA 6522
$8810-$8813   UART 6551
$8820-$882F   DISK MVP
$8830-$8839   SOUND Voice 0
$8840-$884F   VIC blitter registers
$8850-$888F   VIC sprite registers
$8890-$8899   SOUND Voice 1
$889A-$88A3   SOUND Voice 2
$88A4-$88AD   SOUND Voice 3
$8900-$89FF   VIC sprite pixel data
$9000-$900F   VIC control registers
$9010-$AF4F   VIC bitmap RAM (legacy map)
$C000-$FFFF   ROM
```

## Suggested Milestones

1. Bus, reset, clocking, SRAM/ROM, and a trivial ROM-driven smoke test.
2. CPU core integration, ideally with Klaus Dormann functional-test compatibility.
3. VIA 6522 enough for keyboard/IRQ behavior.
4. UART 6551 transmit/receive with FPGA board UART pins.
5. VIC text mode, banked bitmap modes (320×200 1-bpp, 160×100 RGB332,
   180×120 RGB222), then raster IRQs, sprites, and blitter.
6. Sound voice register file, then waveform generation, ADSR, and mixer/PWM or I2S.
7. Board-specific constraints and PLL/clock-domain work.

## Layout

```text
fpga/
  boards/
    pix16/            PIX16 Spartan-6 board (self-contained)
      rtl/            board-specific top-level VHDL
      constraints/    UCF pin constraints
      scripts/        ISE build scripts
      project/        ISE project file (fpga.xise)
      bitstreams/     programming files (.mcs/.cfi)
    tang_primer_20k/  Gowin GW2A-18 board (HDMI, CH340 UART, on-board SD boot path)
  rtl/core/           board-agnostic synthesizable VHDL
    cpu/              CPU adapters
    mem/              RAM/ROM primitives
    peripherals/      memory-mapped chips
    boot/             boot subsystem modules
  sim/
    tb/               VHDL testbenches
    hex/              static ROM hex files
  sw/                 6502 firmware (assembly sources)
  tools/              build utilities
  third_party/        imported open-source cores
  docs/               FPGA implementation notes
```
