# Native C64 on Tang Primer 20K

A from-scratch Commodore 64 core that runs the **original** BASIC/KERNAL/CHARGEN
ROMs, kept entirely separate from the 6502 SBC so the existing system is
untouched. Reuses the SBC's proven board plumbing (T65 CPU, HDMI TX, PT8211 DAC,
PS/2 front-end concepts) and adds the C64-specific chips natively.

> Status: **Milestone 1 in progress** — boot to `READY.` with keyboard, then
> `LOAD` from a D64. The whole RTL hierarchy analyses and elaborates cleanly
> under GHDL; on-hardware bring-up and the D64 path are the open items.

## Layout

```
rtl/c64/                         # board-independent C64 core
  c64_pkg.vhd                    # memory map + PLA banking decode + I/O sub-decode
  c64_roms.vhd                   # GENERATED: BASIC/KERNAL/CHARGEN (tools/build_c64_roms.py)
  c64_ram.vhd                    # 64K x 8 DRAM (BSRAM), dual-port: CPU + VIC read
  colour_ram.vhd                 # 1K x 4 colour RAM, dual-port (CPU + VIC)
  cpu6510.vhd                    # T65 + $00/$01 processor port (ROM banking)
  cia6526_full.vhd              # full 6526: ports A/B, Timer A/B, TOD, ICR/IRQ
  c64_keyboard_matrix.vhd        # PS/2 -> 8x8 C64 keyboard matrix (+ RESTORE/NMI)
  vic_ii.vhd                     # VIC-II text mode + raster IRQ (HDMI-ready)
  c64_core.vhd                   # wires it all together (board independent)

boards/tang_primer_20k/c64/
  rtl/tang20k_c64_top.vhd        # board top: clocks (via hdmi_tx), reset, DAC
  constraints/tang20k_c64.cst    # pins (clock/reset/PS-2/HDMI/DAC)
  constraints/tang20k_c64.sdc    # 27 MHz clock + relaxed CPU multicycle
  project/tang_c64.gprj          # Gowin project
  project/build.tcl              # gw_sh batch build
```

## Building

1. Put the original ROMs in `roms/c64/` (`BASIC.ROM` 8K, `KERNAL.ROM` 8K,
   `CHAR.ROM` 4K) and generate the VHDL image:
   ```
   python tools/build_c64_roms.py
   ```
   (The ROMs themselves are not redistributed; this is run locally.)
2. Open `project/tang_c64.gprj` in Gowin IDE, or run `gw_sh project/build.tcl`.
3. Flash `impl/pnr/tang_c64.fs`.

Reset = KEY[0] (T10). Keyboard = PS/2 on PMOD0 (T7 clk / T8 data). Video = HDMI.

## Architecture

### Reused vs. new
- **Reused unchanged:** T65 (as the 6510's core), `sid6581`, the HDMI TX +
  encoder (`tang20k_hdmi_tx`, exact CEA-861 720x480p), `pt8211_dac`.
- **New, C64-accurate:** PLA banking, 6510 processor port, VIC-II, both CIAs,
  colour RAM, 64K RAM map, PS/2 keyboard matrix.
- **Deliberately omitted:** the SBC boot screen / SD ROM loader. The original
  KERNAL paints its own banner, and dropping the loader frees BSRAM + LUTs.

### Memory map (PLA, unexpanded machine GAME=EXROM=1)
| Range          | LORAM/HIRAM/CHAREN          | Maps to            |
|----------------|-----------------------------|--------------------|
| `$0000-$9FFF`  | always                      | RAM                |
| `$A000-$BFFF`  | LORAM & HIRAM               | BASIC ROM / RAM    |
| `$C000-$CFFF`  | always                      | RAM                |
| `$D000-$DFFF`  | (LORAM\|HIRAM) & CHAREN     | I/O                |
|                | (LORAM\|HIRAM) & !CHAREN    | CHARGEN ROM        |
|                | else                        | RAM                |
| `$E000-$FFFF`  | HIRAM                       | KERNAL ROM / RAM   |

I/O sub-decode: VIC `$D000`, SID `$D400`, colour `$D800`, CIA1 `$DC00`,
CIA2 `$DD00`. **Writes always reach the RAM beneath ROM** ("RAM under ROM"),
exactly as on hardware. `$00/$01` are the 6510 port (handled in `cpu6510`).

### Clocking
`tang20k_hdmi_tx` turns the 27 MHz oscillator into 135 MHz TMDS + 27 MHz pixel.
The whole core runs at 27 MHz; the CPU/CIAs advance on a ~1 MHz PHI2 clock-enable
(`PHI2_DIV` generic, `27 MHz / 27`). Main RAM is **dual-port**: the CPU owns
port A, the VIC reads screen codes on port B -- so the CPU never stalls and its
writes are never dropped (a single-port RAM that blocks writes during a VIC steal
silently corrupts memory, because a 6502 RDY only halts reads, not writes). The
colour RAM and CHARGEN are likewise read in parallel over their own ports.

> Sim note: a faithful boot needs `PHI2_DIV >= 2` so the 1-cycle synchronous
> RAM/ROM has settled before the CPU samples it. `PHI2_DIV=1` reads data one
> cycle early -- a simulation-only skew (hardware runs `PHI2_DIV=27`).

### IRQ/NMI
CIA1 IRQ + VIC raster IRQ -> CPU IRQ. CIA2 IRQ + RESTORE key -> CPU NMI.

## Milestones

- **M1a — boot to `READY.`** ✅ boots in simulation, ⏳ on-hardware verify
  6510 + processor port, 64K RAM, PLA banking, VIC-II text, CIA1 keyboard +
  Timer-A jiffy IRQ. `sim/tb/tb_c64_core.vhd` boots the real ROMs and prints the
  full banner + `38911 BASIC BYTES FREE` + `READY.` (GHDL, `PHI2_DIV=2`). On
  hardware expect the blue screen, border, banner, blinking cursor, PS/2 typing.
- **M1b — `LOAD` from D64** ⏳ next
  Integrate the existing `d64_subsystem` + SD path behind a KERNAL LOAD/IEC
  hook (stubbed in `c64_core` for now). Target `LOAD"*",8,1` + `RUN`.
- **M2 — full VIC-II**
  Hires/multicolour bitmap, ECM, 8 sprites + collisions, sprite/gfx priority,
  per-cycle accuracy, badlines. CHARGEN upper/lower set via `$D018` CB bits.

## Known limitations (M1)
- VIC-II is **text mode only**; bitmap/sprites/multicolour are M2.
- CHARGEN: always the upper-case set; `$D018` charset-base bit not yet decoded.
- CHARGEN read has 1-cycle latency (sync BSRAM) -> at most a 1-pixel horizontal
  shift; cosmetic for M1.
- CIA TOD is a simple BCD counter (no alarm); enough for the KERNAL fallback.
- 64K RAM + 20K ROM in BSRAM is tight on GW2A-18. If P&R runs out of block RAM,
  move `c64_ram` to the DDR3 backend (`ddr3_byte_bridge`) behind the same port.
- Keyboard layout is a first-pass positional map (US-style); umlaut/extra keys
  and shifted cursor up/left are TODO.
