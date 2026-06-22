# Math Coprocessor (FPU)

A small memory-mapped fixed-point multiplier that off-loads the operation the
8-bit 6502 is worst at: multiplication. It turns the FPGA's hardware **DSP
blocks** into a peripheral the CPU can drive with a few store/load instructions.

The coprocessor reduces each fixed-point multiply from a software shift-add loop
to a handful of memory-mapped stores and loads while moving from coarse 4.12 to
sharp **8.24** fixed-point. An earlier 320×200 renderer measured about 10 seconds
instead of 5–8 minutes on Tang Primer 20K; the current demo renders fewer,
individually coloured 180×120 RGB222 pixels and is not directly comparable.

Files:

- RTL: [`rtl/core/peripherals/math_copro.vhd`](../rtl/core/peripherals/math_copro.vhd) — the unit
- Bus decode: [`rtl/core/bus_decode.vhd`](../rtl/core/bus_decode.vhd) (`DEV_MATH`), addresses in [`rtl/core/sbc_pkg.vhd`](../rtl/core/sbc_pkg.vhd) (`ADDR_MATH_BASE`)
- Wiring: [`rtl/core/sbc_t65_boot_monitor_top.vhd`](../rtl/core/sbc_t65_boot_monitor_top.vhd) (`math_i`)
- Testbench: [`sim/tb/tb_math_copro.vhd`](../sim/tb/tb_math_copro.vhd)
- Self-test ROM: [`sw/copro_selftest.s`](../sw/copro_selftest.s)
- Demo ROM: [`sw/mandelbrot_copro.s`](../sw/mandelbrot_copro.s)

## Overview

| Property | Value |
| --- | --- |
| Operation | signed **32 × 32 → 64-bit** multiply |
| Output | the 64-bit product **and** an arithmetic-right-shifted result |
| Default format | **8.24** signed fixed-point (`SHIFT = 24`), range ≈ −128.0 … +127.999999 |
| Shift | writable register (0…63), so the same unit serves any Q-format (e.g. 4.12 with `SHIFT = 12`) |
| Address window | `$88B0–$88BF` (16 bytes), device `DEV_MATH` |
| Latency | 2 clocks (registered multiply + registered shift); no CPU wait states |
| FPGA cost | ~4 DSP18 macros (of 48 on the GW2A-18) + a 64-bit shifter and a few registers |

The unit is **stateless apart from its three registers** (operand A, operand B,
shift). It continuously multiplies whatever is latched in A and B; the CPU just
writes operands and reads the result a few cycles later.

## Why it exists

Fixed-point inner loops (fractals, DSP, scaling, rotation) are dominated by
multiplication, which the 6502 has no instruction for. The old Mandelbrot ROM
spent essentially all of its time in a software `fpmul` routine — a 16-iteration
shift-add loop plus sign handling plus a 4-bit normalising shift, roughly **~250
cycles per multiply**, called three times per iteration, up to 20 iterations, for
64 000 pixels.

One signed multiply maps to a single hardware DSP and completes in one clock. The
6502 only pays the cost of moving the operands across the 8-bit bus.

| | Software `fpmul` (4.12) | Coprocessor (8.24) |
| --- | --- | --- |
| Per multiply | ~250 cycles | ~12–20 cycles (8 stores + 4 loads) |
| Sign handling | manual abs/negate in 6502 | in hardware |
| `>> N` normalise | 4× `lsr/ror` chain in 6502 | free (in hardware) |
| Precision | 12 fractional bits | 24 fractional bits |
| Earlier 320×200 Mandelbrot frame | ~5–8 min | **~10 s** |

## Fixed-point format (8.24)

A value is a signed 32-bit integer interpreted as `value = raw / 2^24`:

- 8 integer bits (incl. sign) → range ≈ −128 … +127.99…
- 24 fractional bits → resolution 2⁻²⁴ ≈ 6 × 10⁻⁸

Examples (`raw = value × 16777216`):

| Value | 8.24 raw |
| --- | --- |
| `+1.0` | `$01000000` |
| `+2.25` | `$02400000` |
| `−0.75` | `$FF400000` |
| `−2.0` | `$FE000000` |

The product of two 8.24 numbers is a 16.48 value (64-bit); shifting right by 24
brings it back to 8.24. That shift is exactly what the `SHIFT` register controls,
so other formats work by changing one register (e.g. `SHIFT = 12` gives 4.12).

## Register map (`$88B0`)

| Offset | Addr | Write | Read |
| --- | --- | --- | --- |
| 0 | `$88B0` | operand A, byte 0 (LSB) | raw product byte 0 (LSB) |
| 1 | `$88B1` | operand A, byte 1 | raw product byte 1 |
| 2 | `$88B2` | operand A, byte 2 | raw product byte 2 |
| 3 | `$88B3` | operand A, byte 3 (MSB) | raw product byte 3 |
| 4 | `$88B4` | operand B, byte 0 (LSB) | raw product byte 4 |
| 5 | `$88B5` | operand B, byte 1 | raw product byte 5 |
| 6 | `$88B6` | operand B, byte 2 | raw product byte 6 |
| 7 | `$88B7` | operand B, byte 3 (MSB) | raw product byte 7 (MSB) |
| 8 | `$88B8` | — | result `(A*B) >> SHIFT`, byte 0 (LSB) |
| 9 | `$88B9` | — | result byte 1 |
| 10 | `$88BA` | — | result byte 2 |
| 11 | `$88BB` | — | result byte 3 (MSB) |
| 12 | `$88BC` | `SHIFT` amount (0…63) | `SHIFT` amount |

All values are **little-endian** (byte 0 = least-significant), matching how the
6502 stores multi-byte words. Operands and the scaled result are 32-bit; the raw
product is the full 64-bit value, available for code that wants to apply its own
shift / rounding.

## Operation and timing

The multiply and shift are **registered** (a 2-clock pipeline):

```
write operands ──► product <= A * B ──► result <= product >> SHIFT ──► read result
                   (1 clock)             (1 clock)
```

The unit multiplies continuously, so there is no "start" strobe — the result
simply tracks the latched operands two clocks later. Because the 6502 needs
several cycles to issue the next read after writing the last operand byte, the
pipeline is always settled by the time the result is read: **no wait states are
required.** (The self-test ROM still inserts a few `NOP`s for an extra margin,
purely as a diagnostic.)

## Using it from the 6502

Pattern: write the 4 bytes of A, the 4 bytes of B, then read the 4 result bytes.
With `SHIFT = 24` the result is already scaled to 8.24 — no normalisation needed.

```asm
MUL       = $88B0
MUL_A     = MUL+0          ; operand A (4 bytes)
MUL_B     = MUL+4          ; operand B (4 bytes)
MUL_RES   = MUL+8          ; result    (4 bytes)
MUL_SHIFT = MUL+12

    lda #24                ; one-time: select 8.24
    sta MUL_SHIFT

    ; ZR2 = ZR * ZR   (ZR, ZR2 are 4-byte 8.24 values in zero page)
    lda ZR+0
    sta MUL_A+0
    lda ZR+1
    sta MUL_A+1
    lda ZR+2
    sta MUL_A+2
    lda ZR+3
    sta MUL_A+3
    lda ZR+0
    sta MUL_B+0
    lda ZR+1
    sta MUL_B+1
    lda ZR+2
    sta MUL_B+2
    lda ZR+3
    sta MUL_B+3            ; completes the operand set
    lda MUL_RES+0
    sta ZR2+0
    lda MUL_RES+1
    sta ZR2+1
    lda MUL_RES+2
    sta ZR2+2
    lda MUL_RES+3
    sta ZR2+3
```

[`sw/mandelbrot_copro.s`](../sw/mandelbrot_copro.s) wraps this in a `MUL32`
macro and uses it for the three products per Mandelbrot iteration
(`zr²`, `zi²`, `zr·zi`).

The current standalone image is linked for the split ROM map: code starts at
`$A000`, vectors remain at `$FFFA-$FFFF`, and it renders directly into the
180×120 packed RGB222 framebuffer. Four 6-bit pixels occupy three bytes. The
`$6000-$7FFF` CPU window switches from bank 0 to bank 1 after byte 8191; every
pixel therefore receives its own colour rather than sharing a colour attribute
with an 8×8 cell. Build and upload it with:

```powershell
make -C sw mandelbrot-copro
python tools\upload_monitor_hex.py roms\mandelbrot_copro.bin --split-rom `
       --port COM15 --baud 115200 --run --verbose
```

For direct Windows uploads, use `roms\upload\mandelbrot_copro.bat`.

The software-multiply comparison image uses the same ROM and bitmap layout:

```powershell
make -C sw mandelbrot-bitmap
python tools\upload_monitor_hex.py roms\mandelbrot_bitmap.rom --split-rom `
       --port COM15 --baud 115200 --run --verbose
```

The corresponding Windows shortcut is `roms\upload\mandelbrot_bitmap.bat`.

## Integration

The unit follows the same memory-mapped pattern as the VIA/UART:

1. **Address window** — `ADDR_MATH_BASE = $88B0`, `ADDR_MATH_LAST = $88BF` in
   `sbc_pkg.vhd`; `DEV_MATH` added to `device_sel_t`.
2. **Decode** — `bus_decode.vhd` maps the window to `DEV_MATH`.
3. **Wiring** — in `sbc_t65_boot_monitor_top.vhd`: `math_cs`/`math_we` from the
   decoded select and the CPU write strobe, `cpu_addr(3 downto 0)` as the register
   offset, `cpu_dout` as write data, and `math_dout` fed into the CPU read mux
   (`when DEV_MATH => cpu_din <= math_dout`).
4. **Project files** — `math_copro.vhd` is listed in the Tang Primer 20K project
   (`tang_sbc.gprj`, `build.tcl`).

Adding a peripheral changes the synthesized design, so a board must be
**re-synthesised, re-placed-and-routed and re-flashed** before the coprocessor is
present. A bitstream built before this change reads `$FF` from `$88B8` (the
unmapped-address value) — see the self-test below.

## Verification

**Simulation** — [`sim/tb/tb_math_copro.vhd`](../sim/tb/tb_math_copro.vhd) drives
the register interface like the 6502 (byte writes then byte reads) and checks
signed products, including the Mandelbrot-critical values:

```
ghdl -a --std=08 rtl/core/peripherals/math_copro.vhd sim/tb/tb_math_copro.vhd
ghdl -e --std=08 tb_math_copro && ghdl -r --std=08 tb_math_copro
# ==== ALL MATH_COPRO TESTS PASSED ====
```

**On hardware** — [`sw/copro_selftest.s`](../sw/copro_selftest.s) computes
`2.0 × 3.0`, checks it equals `6.0` (`$06000000`), fills the screen **green** on
success / **red** on failure, and prints the result over UART:

```
COPRO 2.0*3.0=06000000 OK (green)     <- coprocessor present and correct
COPRO 2.0*3.0=FFFFFFFF FAIL (red)     <- reads $FF: coprocessor not in this bitstream
COPRO 2.0*3.0=00000000 FAIL (red)     <- returns zero: wrong SHIFT or DSP mapping
```

## Reuse and extension

- **Any Q-format** — write a different `SHIFT` (e.g. `12` for 4.12, `16` for
  16.16). The raw 64-bit product is also readable for custom scaling/rounding.
- **General math** — any fixed-point 6502 code (scaling, rotation, polynomial
  evaluation, audio) can use it, not just Mandelbrot.
- **Possible future work** — a multiply-accumulate mode, a hardware reciprocal /
  divide helper, or a full complex-iteration engine (the whole `z = z² + c` loop
  in hardware) for a further ~10× on fractals. See the design notes in the commit
  history.
