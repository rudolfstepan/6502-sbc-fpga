# FPGA Sound Chip

There are **two independent VHDL sound-chip versions**, both register-compatible
with the C emulator's sound chip (`src/soundchip.c`), so the same 6502 code runs
on either:

1. **Large 4-voice chip** (`sound_chip4.vhd` + `sound_voice_full.vhd`) — the full
   model: 4 voices, 5 waveforms, ADSR envelopes, note duration, and a mixer.
   **This is now wired into the Tang Primer 20K board** and drives the dock's
   **PT8211 (TM8211)** DAC. See [The Large 4-Voice Version](#the-large-4-voice-version).
2. **Bring-up single voice** (`sound_voice.vhd`) — one voice, square + noise, no
   envelope; the original minimal version, kept as a simpler alternative. The
   register-map / usage sections below apply to a single voice and are common to
   both (the 4-voice chip just has four such voices plus envelopes).

Files:

- RTL (bring-up): [`rtl/core/peripherals/sound_voice.vhd`](../rtl/core/peripherals/sound_voice.vhd) — oscillator + register file
- RTL (DAC): [`rtl/core/peripherals/pt8211_dac.vhd`](../rtl/core/peripherals/pt8211_dac.vhd) — I2S serializer for the PT8211
- RTL (large): [`rtl/core/peripherals/sound_voice_full.vhd`](../rtl/core/peripherals/sound_voice_full.vhd), [`rtl/core/peripherals/sound_chip4.vhd`](../rtl/core/peripherals/sound_chip4.vhd)
- BASIC examples: [`examples/soundtone.bas`](../../examples/soundtone.bas) (single tone), [`examples/soundtest.bas`](../../examples/soundtest.bas) (menu demo)

## Overview

| Property | Value |
| --- | --- |
| Voices | 1 (channel 0); channels 1–3 reserved in the address map, not yet in hardware |
| Waveforms | square, noise (LFSR) |
| Frequency | direct in Hz, 16-bit |
| Volume | 8-bit (0–255) |
| Output | signed 16-bit, two's complement, to PT8211 DAC |
| Sample rate | ≈47 kHz (BCK ≈1.5 MHz, 32 BCK/frame) |
| ADSR / duration | registers accepted but **not yet acted on** |

The oscillator is a 24-bit phase accumulator clocked at 27 MHz. The phase
increment is `inc = freq_hz * 2^24 / 27 MHz`, approximated in hardware as
`(freq * 159) >> 8` (error < 0.05 %). A note plays for as long as the CONTROL
gate bit is set — there is no automatic note-off yet, so software must clear the
gate to stop the tone.

## Register Map

Channel 0 occupies **`$8830`–`$8839`** (decimal `34864`–`34873`). Offsets match
`src/soundchip.h`:

| Address | Dec | Offset | Register | Function |
| --- | --- | --- | --- | --- |
| `$8830` | 34864 | +0 | FREQ_LO | Frequency low byte (Hz) |
| `$8831` | 34865 | +1 | FREQ_HI | Frequency high byte |
| `$8832` | 34866 | +2 | DUR_LO | Duration low — *accepted, unused* |
| `$8833` | 34867 | +3 | DUR_HI | Duration high — *accepted, unused* |
| `$8834` | 34868 | +4 | VOLUME | Peak amplitude 0–255 |
| `$8835` | 34869 | +5 | CONTROL | Waveform + gate (see below) |
| `$8836` | 34870 | +6 | ATTACK | *accepted, unused* |
| `$8837` | 34871 | +7 | DECAY | *accepted, unused* |
| `$8838` | 34872 | +8 | SUSTAIN | *accepted, unused* |
| `$8839` | 34873 | +9 | RELEASE | *accepted, unused* |
| `$883A` | 34874 | +10 | TIME_MS | free-running millisecond counter, low 8 bits |

`TIME_MS` is independent of CPU speed and wraps every 256 ms. Software should
subtract a saved start value from the current value; unsigned subtraction then
handles wraparound naturally for delays shorter than 256 ms.

### CONTROL register (`$8835`)

| Bits | Meaning |
| --- | --- |
| 6–4 | Waveform: `001` = square, `100` = noise (any other value → square) |
| 0 | Gate: `1` = note on, `0` = silence |

Common values: `$11` = square + gate on, `$41` = noise + gate on, `$00` = off.

The frequency is given **directly in Hz** (not as a divider). For example, 440 Hz
is `$01B8`: write `$B8` to FREQ_LO and `$01` to FREQ_HI.

## Usage

### 6502 assembly

```asm
SND     = $8830
FREQ_LO = SND+0
FREQ_HI = SND+1
VOLUME  = SND+4
CONTROL = SND+5

    LDA #$B8          ; 440 Hz = $01B8
    STA FREQ_LO
    LDA #$01
    STA FREQ_HI
    LDA #200          ; volume 0..255
    STA VOLUME
    LDA #$11          ; square + gate on
    STA CONTROL
    ; ... software delay for note length ...
    LDA #$00          ; gate off -> silence
    STA CONTROL
```

### BASIC

```basic
10 POKE 34864,184 : REM FREQ_LO (440 Hz = $01B8)
20 POKE 34865,1   : REM FREQ_HI
30 POKE 34868,255 : REM VOLUME
40 POKE 34869,17  : REM CONTROL = $11 = square + gate
50 FOR I=1 TO 500 : NEXT
60 POKE 34869,0   : REM gate off
```

See [`examples/soundtone.bas`](../../examples/soundtone.bas) for a minimal single
tone and [`examples/soundtest.bas`](../../examples/soundtest.bas) for a menu with
a scale, siren, noise burst, and a short melody. Because duration is not yet
honoured in hardware, note length is controlled by software delay loops that set
and then clear the gate bit.

## Hardware (Tang Primer 20K dock)

The synth's signed 16-bit sample is serialized to the dock's PT8211 audio DAC.
The serializer in `pt8211_dac.vhd` is a 1:1 VHDL port of Sipeed's proven Verilog
driver (`TangPrimer-20K-example/PT8211/src/pt8211_drive.v`): BCK is a
free-running ~1.5 MHz clock, a fresh sample is loaded at the start of each 16-bit
half-frame and shifted out MSB-first, and WS toggles a few BCK after the data
word (the PT8211's right-justified format).

### Pin assignment

| Signal | FPGA pin | I/O standard | Notes |
| --- | --- | --- | --- |
| `dac_bck` (BCK) | N15 | LVCMOS33 | bit clock |
| `dac_ws` (WS/LRCK) | P16 | LVCMOS33 | word/channel select |
| `dac_din` (DIN) | P15 | LVCMOS33 | serial data, MSB first |
| `pa_en` (PA_EN) | R16 | LVCMOS33 | **audio power-amp enable, held high** |

`PA_EN` (R16) **must be driven high** or the dock's headphone amplifier stays
off/floating and you hear only hiss. It is tied high in `tang20k_sbc_top.vhd`.

These pins are in Bank 1, whose VCCIO is locked to 3.3 V by other ports, so they
are constrained as `LVCMOS33`. (The standalone Sipeed demo omits `IO_TYPE` and
lets the bank default to 1.8 V — that is not possible here because the bank is
shared.)

> **Build note:** the sound sources must be listed in
> [`boards/tang_primer_20k/project/build.tcl`](../boards/tang_primer_20k/project/build.tcl).
> The PowerShell build (`make_tang20k.ps1`) drives `gw_sh build.tcl`, **not** the
> `.gprj` project file — if `sound_voice.vhd`/`pt8211_dac.vhd` are missing from
> `build.tcl`, GowinEDA synthesizes them as empty black boxes and the DAC pins
> float (noise / silence).

## Current Limitations

- Only channel 0 is implemented; `$8890`+ (channels 1–3) are reserved in the
  address map but have no hardware yet.
- Only square and noise waveforms (no sine / triangle / sawtooth).
- ADSR envelope and duration registers are captured but ignored — software must
  clear the gate bit to end a note.
- Mono only (the same sample feeds both DAC channels).

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Constant hiss, even when idle | `PA_EN` (R16) not driven high, or wrong DAC pins |
| No sound at all after a rebuild | Sound sources missing from `build.tcl`; black-box synthesis |
| `CT1136` bank VCCIO error at build | Audio pins need `IO_TYPE=LVCMOS33` (Bank 1 is 3.3 V) |
| Wrong pitch | Frequency is in Hz (16-bit); check FREQ_LO/FREQ_HI split |
| Note never stops | Clear CONTROL bit 0 (gate) in software; duration is not yet honoured |

## The Large 4-Voice Version

`sound_chip4.vhd` + `sound_voice_full.vhd` implement the **full** C-emulator
model in hardware — an independent second version alongside the bring-up voice
above. Both use the same per-voice register layout, so 6502 code is portable.

### What it adds over the bring-up voice

| Feature | Bring-up `sound_voice` | Large `sound_chip4` |
| --- | --- | --- |
| Voices | 1 | 4, mixed |
| Waveforms | square, noise | sine, square, sawtooth, triangle, noise |
| Envelope | none (gate only) | full ADSR (attack/decay/sustain/release) |
| Duration | ignored | honoured (note auto-stops) |
| Noise | 16-bit Galois LFSR | xorshift32 (same sequence as the C code) |

The CONTROL waveform field (bits 6–4) selects: `0`=sine, `1`=square,
`2`=sawtooth, `3`=triangle, `4`=noise — matching `src/soundchip.c`. Writing
CONTROL with bit 0 set captures all registers and (re)triggers the note, again
matching the emulator. ATTACK/DECAY/RELEASE are in units of 8 ms; SUSTAIN is a
0–255 level; duration is in ms; frequency in Hz (0 → 440 default, clamped
20–12000).

For SID-style pulse waves, three compatibility registers extend the otherwise
unchanged voice layout:

| Address | Register | Function |
| --- | --- | --- |
| `$883B` | PULSE0 | Voice 0 pulse width, upper 8 bits of the SID 12-bit value |
| `$883C` | PULSE1 | Voice 1 pulse width, upper 8 bits of the SID 12-bit value |
| `$883D` | PULSE2 | Voice 2 pulse width, upper 8 bits of the SID 12-bit value |

`$80` selects 50% duty cycle and is the reset default. The pulse output is
DC-balanced as its duty cycle changes, avoiding amplifier clicks during PWM.
The converted SID ROM updates these registers at the original 50 Hz player
rate; sine, sawtooth, triangle, and noise voices are unaffected.

### Implementation notes

- **Sine** uses a hard-coded 256-entry signed LUT (`SINE`), indexed by the top 8
  phase bits — no `math_real` needed at synthesis except for the phase-increment
  constant `PHASE_MUL = 2^PHASE_BITS·256 / CLK_HZ` (79 at the board's 54 MHz
  system clock).
- **Envelope** is time-based (mirrors `envelope_at()` in the C code): a 1 ms time
  base drives a small ATK/DEC/SUS/REL state machine, and each ramp uses a
  division-free Bresenham accumulator (≤1 envelope step per clock).
- **Pulse** uses a 12-bit phase comparator. Software-visible 8-bit pulse-width
  values provide 256 duty-cycle steps and inexpensive frame-rate PWM.
- **Mixer** sums the four signed voices; each voice is pre-scaled by `>>10`
  (volume/255 · env/255 · 0.25 headroom), so four max-volume voices sum without
  clipping. A hard clip guards corner cases.
- **Interface**: `cs(3:0)` (one chip-select per voice), shared `we`/`addr(3:0)`/
  `din`, muxed `dout`, signed 16-bit `sample_out`, and `active`.

### Status

Verified in simulation by [`sim/tb/tb_sound_chip4.vhd`](../sim/tb/tb_sound_chip4.vhd)
(envelope attack, waveform swing, multi-voice mix, duration auto-stop). It was
previously wired into the Tang top at `$8830`, `$8890`, `$889A`, and `$88A4`.
The current Tang bitstream instantiates `sid6581.vhd` instead and retains only
the free-running millisecond counter at `$883A` for player timing. The legacy
four-voice RTL remains in the repository for other targets and experiments.

### Legacy demo ROM (`soundtest.rom`)

[`fpga/sw/soundtest.s`](../sw/soundtest.s) is a standalone 6502 demo ROM that
exercises all four voices — each waveform on voice 0, an ADSR swell, and a
4-voice chord — and writes a "SOUND TEST" title to the HDMI text screen. It
currently retains the legacy contiguous `$C000-$FFFF` linker layout. It cannot
be uploaded into the current Tang split-ROM map because it crosses the
`$D000-$EFFF` I/O hole. Relink it like `soundsid.rom` before using it on the
current bitstream. The commands below apply only to a legacy single-window
build:

```sh
make -C fpga/sw soundtest          # -> fpga/sw/soundtest.rom (16 KB)

# board in monitor mode (press KEY0), then:
python fpga/tools/upload_monitor_hex.py fpga/sw/soundtest.rom \
       --port COM15 --baud 230400 --address 0xC000 --run --verbose
# or, build + upload in one step:
make -C fpga/sw upload-soundtest
```

The ROM's reset vector points at `$C000`, so it also runs from a cold boot if
written to the SD card (wrap it with `fpga/tools/make_sd_boot_image.py`).

## Native SID playback

`sid6581.vhd` exposes the standard MOS 6581 register window at `$D400–$D41C`.
The 25 write registers `$D400–$D418` read back the last written value; the read
registers are `$D419/$D41A` POTX/POTY (no paddle hardware → `$FF`), `$D41B` **OSC3**
(voice-3 oscillator MSB — the classic `LDA $D41B` random/sawtooth source) and
`$D41C` **ENV3** (voice-3 envelope). These were added for C64 compatibility so
tunes/effects that read OSC3/ENV3 work.
On the Tang Primer build it replaces the legacy four-voice synthesizer: running
both simultaneously exhausted the device's global clock networks and
destabilized DDR3 PHY calibration. The legacy RTL remains available for other
targets.

### Implemented 6581 features

The core has grown from a minimal oscillator block into a fairly complete 6581
model. What it now reproduces:

| Feature | Detail |
| --- | --- |
| Oscillators | 3 voices, 24-bit phase accumulators, clocked at the ~985 kHz PAL phi2 rate |
| Waveforms | 12-bit triangle, sawtooth, pulse (12-bit width) and noise (23-bit LFSR) |
| Combined waveforms | multiple waveform bits are wire-ANDed (the classic 6581 darker/hollow approximation); a single waveform is unchanged |
| ADSR | **cycle-accurate**: reSID rate-counter periods, linear attack, and the exponential decay/release divider (break-points at env `$5D/$36/$1A/$0E/$06`) |
| Filter | 2-pole **state-variable** multimode (LP/BP/HP) with per-voice routing (`$D417`), mode/volume (`$D418`) and an 11-bit cutoff |
| Cutoff curve | non-linear "dark 6581" approximation — mid-range register values stay low (e.g. FC≈1240 → ~2 kHz, not ~7.5 kHz of a linear map) so the bass is audibly rounded |
| Resonance | mapped to a deliberately **weak** Q (~0.7 … 2), matching the 6581 and avoiding output-limiter clipping |
| Hard sync | voice *v* oscillator resets when the previous voice's MSB rises (`CONTROL` bit 1) |
| Ring modulation | triangle fold bit XORed with the previous voice's MSB (`CONTROL` bit 2) |
| TEST bit | `CONTROL` bit 3 holds the oscillator at zero and resets the noise LFSR/edge state, giving deterministic noise restarts |
| Master volume / digis | `$D418` low nibble scales voices and feeds a high-pass volume-DAC path for 4-bit sample digis; voice-3 disconnect (`$D418` bit 7) honoured |

The filter runs once per SID tick over a 5-step internal pipeline (one multiply
per clock) so the two serial coefficient multiplies never share a single 54 MHz
path, and the filter states saturate to keep the SVF from blowing up.

**Not yet modelled:** the 6581's full analog DAC non-linearity / chip-specific
bias "warmth", and the sample-ROM-exact combined-waveform tables (the wire-AND
is an approximation).
The cutoff and resonance mappings are tunable in `sid6581.vhd` (`cutoff_coeff`
and the `dcoef_i` formula) if a brighter/darker or more/less resonant voicing is
wanted.

### Wrapping a `.sid` tune as a standalone ROM

`tools/build_native_sid_rom.py` turns a PSID/RSID tune into a playable ROM. It
does **not** do a lossy 50 Hz register conversion — it embeds the original 6502
payload, runs it at its native load address, calls the tune's `init` routine
once, then drives its `play` routine. All frequency, pulse-width, control, ADSR
**and filter** writes therefore reach the hardware exactly as the original
player produces them.

**Load-address layout** (chosen automatically from the tune's load address):

| Tune loads at | Layout | cc65 config |
| --- | --- | --- |
| `$0200-$5FFF` | wrapper at `$A000` copies the payload **down** to its load address | `sw/soundsid.cfg` |
| `$A000-$CFFF` | **RAM-under-BASIC ("page") mode** — the tune sits directly in the paged-out BASIC ROM window, no copy; the player lives at `$F000` | `sw/sid_page.cfg` |

Tunes that load anywhere else (`$6000-$9FFF`, `$E000+`) cannot be wrapped. The
payload must also fit the 12 KB `$A000-$CFFF` ROM window.

**Play drive** (chosen from the PSID `play` address):

- **`play != 0` → polled.** `init` once, then `play` every ~20 ms off the
  `$883A` millisecond counter. No interrupt needed, so it never depends on the
  CIA/VIC. A free-running CIA Timer A is also started so tunes that *read*
  `$DC04` see a live timer. The start song is `startSong - 1`.
- **`play == 0` → IRQ-driven.** The tune installs its own CIA timer + `$0314`
  handler in `init`; the wrapper only supplies a default `$0314` vector and a
  `$FFFE → JMP ($0314)` bridge. This path needs the FPGA CIA (`$DC00`).

After `jsr init` the wrapper always issues **`SEI`**. Some RSID `init` routines
end with `CLI` (they expect to run interrupt-driven); without re-masking, a
stray IRQ would vector through the ROM `$FFFE` bridge into an uninitialised
`$0314` and crash. For an ordinary tune whose `init` does not `CLI`, the `SEI`
is a harmless no-op.

**Raster-IRQ tunes — `OVERRIDES`.** A few RSID tunes declare `play=$0000` only
because their real per-frame update is buried inside a **VIC raster-interrupt**
handler — which the FPGA cannot service (no VIC interrupts, `$FFFE/$FFFF` is
ROM, no `$01` banking). The `OVERRIDES` table in `build_native_sid_rom.py`
points `play`/`song` at the inner update routine (found by disassembly) so the
**polled** path drives it directly and the interrupt is bypassed.

> Example — `sid_orig/Arkanoid.sid`: `init=$4000` installs a 2×-speed raster IRQ
> whose handler (`$4086`/`$40B3`) calls the actual SID update at `$4141`. The
> override plays single-speed song 0 by polling `$4141`, so it runs with no
> interrupt at all.

`roms/soundsid.rom` (`World_Record_2.sid`) and the bespoke
`roms/sound_commando.rom` are checked-in examples. Each wrapper is linked with a
`$F000` window and vectors at `$FFFA-$FFFF`, a 16 KB image in physical
shadow-RAM order. Upload with the split-image mode; on Windows
`roms\upload\sound_<name>.bat` uploads an already-built image:

```sh
python tools/upload_monitor_hex.py roms/sound_commando.rom --split-rom \
       --port COM15 --baud 115200 --run --verbose
python tools/build_native_sid_rom.py path/to/tune.sid sw/<name>.s   # one wrapper
```

### C64 UART SID PRGs

The native C64 core uses a different SID wrapper for UART-uploadable PRGs. These
files live in `roms/c64_uart_sid/`, load at `$0801`, include a BASIC `SYS` line,
and start with `RUN` after upload through `tools/c64_uart_prg_loader.py`:

```sh
make c64-sid-prgs
python tools/c64_uart_prg_loader.py roms/c64_uart_sid/Commando.prg --port COM15
```

The builder also emits `*.prg.segments.json` files. The UART loader detects
those sidecars automatically and uploads only the real BASIC stub plus
SID-player/payload ranges, skipping the zero-filled gap that many high-load
tunes need in a standard PRG image. Add `--no-segments` when you want to force a
contiguous PRG upload for debugging.

The default C64 wrapper tick is 50 Hz. If a SID needs a different CIA-driven
rate, rebuild that tune with `tools/build_sid_prg.py --target c64 --play-hz N`
(for example `--play-hz 100`). The generated segment map records the selected
rate and the original PSID speed flags. The bulk builder prints a short warning
list for built PRGs whose PSID header requests CIA-speed playback so they can be
checked separately.

The C64 PRG wrapper is **sound-only**. It runs the tune's native `init`, masks
CIA IRQ sources, disables VIC raster IRQs, clears `$D011.DEN`, and then polls CIA
Timer A for the selected player tick, 50 Hz by default. The C64 VIC
implementation treats `DEN=0` as "no display fetch", so the VIC stops asserting
BA/RDY while the tune
plays. That removes audible stalls from the single-port RAM sharing path; the
HDMI output is intentionally blank while these PRGs play.

This is separate from the `sound_*.rom` split-ROM path above. The split-ROM
wrappers target the SBC monitor/ROM map, while `roms/c64_uart_sid/*.prg` targets
the native C64 BASIC environment and UART PRG loader.

### Bulk-building a whole `.sid` collection

`tools/build_all_sid_roms.py` wraps **every** suitable tune under `sid_orig/` at
once, emitting `roms/sound_<name>.rom` and a matching
`roms/upload/sound_<name>.bat` for each (page-mode tunes are linked with
`sw/sid_page.cfg` automatically), and reporting the tunes it has to skip.

By default it also runs each tune through the bare-6502 SID emulator
(`tools/sid_dump_full.exe`) and **skips tunes that produce no sound here**. A
player must either gate audible voices or drive the `$D418` volume-DAC path to
produce output.

**Curated ROMs are protected.** `roms/sound_commando.rom` is a bespoke,
hand-made demo that the generic wrapper does **not** reproduce. Its base name is
listed in the `CURATED` set, so the bulk build never overwrites it; pass
`--rebuild-curated` to overwrite curated ROMs on purpose.

```sh
python tools/build_all_sid_roms.py             # build playable ROMs + .bat files
python tools/build_all_sid_roms.py --list      # classify only, build nothing
python tools/build_all_sid_roms.py --no-verify # build everything that fits memory
python tools/build_all_sid_roms.py --rebuild-curated  # also overwrite curated ROMs
python tools/build_all_sid_roms.py --port COM7 --baud 230400   # override uploader
```

Skip reasons fall into two groups: it cannot fit the memory map (loads outside
the supported windows, or payload too large), or it fits but is silent in this
environment.

`tools/sid_dump_full.exe tune.sid <seconds> out.raw` dumps all 25 SID registers
per 50 Hz frame, which is handy for checking which features (filter, sync, ring,
combined waveforms) a tune actually exercises before expecting to hear them.

### Verification

The core is regression-tested in simulation (GHDL):

| Testbench | Checks |
| --- | --- |
| [`sim/tb/tb_sid6581.vhd`](../sim/tb/tb_sid6581.vhd) | core produces audio (filter off, backward-compatible level) |
| [`sim/tb/tb_sid6581_filter.vhd`](../sim/tb/tb_sid6581_filter.vhd) | filter is bounded (no blow-up) and a low cutoff attenuates |
| [`sim/tb/tb_sid6581_combined.vhd`](../sim/tb/tb_sid6581_combined.vhd) | combined waveforms, ring mod and hard sync are wired, bounded and non-silent |

See [Split ROM and Native SID Update](./SPLIT_ROM_SID_UPDATE.md) for the full
memory-map migration and compatibility notes.

### EhBASIC SID demo

[`examples/siddemo.bas`](../examples/siddemo.bas) drives the SID registers
directly from EhBASIC. It demonstrates triangle, sawtooth and pulse waveforms,
packed SID ADSR values, a three-voice chord, and a short melody. Frequencies in
hertz are converted to PAL SID phase increments with
`INT(hz * 16777216 / 985248)`.

With EhBASIC running at its prompt:

```powershell
python tools\upload_basic_uart.py examples\siddemo.bas --port COM15 `
       --baud 115200 --new --run --verbose
```

## See Also

- [Architecture](./01_ARCHITECTURE.md) — memory map
- [Modules Reference](./02_MODULES.md) — `sound_voice.vhd`, `pt8211_dac.vhd`
- [Tang Primer 20K Guide](../boards/tang_primer_20k/README.md) — board wiring
- `src/soundchip.c` / `src/soundchip.h` — reference C implementation
</content>
