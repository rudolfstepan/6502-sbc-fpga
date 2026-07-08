# Hardware 2D Blitter for the DDR3 Framebuffer

## Why

The hi-res framebuffer lives in DDR3 (`vic_fb_ddr3.vhd`, at the board top next
to the Gowin DDR3 IP). The CPU reaches it through the `$6000-$7FFF` window as
**masked single-byte writes across a `clk_sys`↔`clk_x1` req/ack handshake** — so
the 6502 stalls for a full DDR3 round-trip *per pixel*. A wireframe cube plots
~3600 pixels/frame (12 erase + 12 draw edges) plus a one-time 512 KB clear;
every one of those is a stalled DDR3 write, which is why it renders at seconds
per frame. The 3D math is only ~4 % of the work — the bottleneck is framebuffer
write bandwidth, not computation.

The fix is **not** a 3D accelerator. It is a small 2D drawing engine that runs
the rasterizer in the DDR3 app-clock domain (`clk_x1`, ~100 MHz) and streams
writes to the app port back-to-back, so the CPU issues one high-level command
(LINE / FILL) and polls a busy flag instead of touching every pixel.

## Architecture

```
   6502 (clk_sys)                         DDR3 app domain (clk_x1, ~100 MHz)
 ┌───────────────┐   regs + trigger   ┌──────────────────────────────────────┐
 │ $8840-$884F   │ ─── CDC pulse ───► │  vic_blit  (Bresenham LINE / FILL)     │
 │ blit regs     │ ◄── busy (CDC) ─── │     │ fbo_we / fbo_addr / fbo_data     │
 └───────────────┘                    │     ▼                                  │
                                      │  vic_fb_ddr3 app-port FSM (arbiter):    │
   CPU $6000 window write ──────────► │   line-fetch  >  BLITTER  >  CPU        │
                                      │     │ app_cmd / app_wdata / mask        │
                                      └─────┼──────────────────────────────────┘
                                            ▼  Gowin DDR3 Memory Interface IP
```

- `vic_blit` is a **third master** on the single DDR3 app port. Priority stays
  *display line-fetch > blitter > CPU* so the scanline prefetch never starves
  (no display glitches); the blitter only draws during the app port's idle
  slots, which is almost all the time.
- The blitter never crosses `clk_sys` per pixel — only the command registers and
  the busy flag cross domains, once per operation.

## Register map (`$8840-$884F`)

Byte index into the active hi-res 640×400 8bpp frame. X is 10-bit (0..639),
Y is 9-bit (0..399). LINE uses both endpoints; FILL fills the inclusive
rectangle (x0,y0)-(x1,y1).

| Off | Addr   | Name    | R/W | Meaning |
|----:|--------|---------|-----|---------|
| 0   | `$8840`| X0_LO   | W   | x0[7:0] |
| 1   | `$8841`| X0_HI   | W   | x0[9:8] |
| 2   | `$8842`| Y0_LO   | W   | y0[7:0] |
| 3   | `$8843`| Y0_HI   | W   | y0[8]   |
| 4   | `$8844`| X1_LO   | W   | x1[7:0] |
| 5   | `$8845`| X1_HI   | W   | x1[9:8] |
| 6   | `$8846`| Y1_LO   | W   | y1[7:0] |
| 7   | `$8847`| Y1_HI   | W   | y1[8]   |
| 8   | `$8848`| COLOR   | W   | RGB332 pixel byte |
| 9   | `$8849`| OP      | W   | 0 = FILL, 3 = LINE |
| 10  | `$884A`| PAGE    | W   | target framebuffer page (bit 0), for double buffering |
| 15  | `$884F`| TRIGGER | W/R | write = start op; read bit7 = BUSY |

Software pattern:

```asm
    ; draw a line (x0,y0)-(x1,y1) in COLOR
    lda x0    : sta $8840
    lda x0+1  : sta $8841
    lda y0    : sta $8842
    lda y0+1  : sta $8843
    lda x1    : sta $8844
    lda x1+1  : sta $8845
    lda y1    : sta $8846
    lda y1+1  : sta $8847
    lda #col  : sta $8848
    lda #3    : sta $8849      ; OP = LINE
    sta $884F                  ; trigger (any value)
@wait:
    lda $884F                  ; bit7 = busy
    bmi @wait
```

Op codes match the emulator's blitter (`FILL=0`, `LINE=3`) so the emulator stays
the reference model. FILL clears the background (the cube uses it once at start);
LINE draws every edge.

## Status

- **Done & verified in simulation:** `rtl/core/peripherals/vic_blit.vhd` — the
  drawing engine (Bresenham LINE across all octants + rectangle FILL) against an
  abstract byte-write port. `sim/tb/tb_vic_blit.vhd` compares every framebuffer
  byte to a reference software Bresenham/fill and passes:
  ```
  ghdl -a --std=08 --ieee=synopsys rtl/core/peripherals/vic_blit.vhd sim/tb/tb_vic_blit.vhd
  ghdl --elab-run --std=08 tb_vic_blit --ieee-asserts=disable-at-0
  -> tb_vic_blit: PASS (fill + lines match reference)
  ```

## Remaining integration steps

1. **Register file + CDC** in `sbc_t65_boot_monitor_top.vhd`: capture
   `$8840-$884F` (already decoded to `DEV_VIC_BLIT`), form a clean trigger pulse
   into `clk_x1`, and expose BUSY (bit 7 of `$884F` read).
2. **Arbiter in `vic_fb_ddr3.vhd`**: add blitter states to the `clk_x1` FSM
   (priority below line-fetch, around the CPU write path), feeding the blitter's
   `fbo_*` writes to `app_cmd`/`app_wdata` with the same per-lane masking the CPU
   path uses. Add `HIRES_BASE_WORD` to the blitter byte address.
3. **Board top** wiring (`boards/tang_primer_20k/sbc/rtl/tang20k_sbc_top.vhd`):
   route the new blit register/busy signals through to `vic_fb_ddr3`.
4. **Burst FILL (optimization):** write full 16-byte bursts (unmasked) for
   16-aligned horizontal runs so a full-screen clear costs ~16 K bursts instead
   of 256 K masked writes.
5. **Emulator + software:** extend the emulator blitter to target the hi-res
   framebuffer with this register map, then rewrite `examples/cube.s` to issue
   LINE/FILL commands. Verify end-to-end in the emulator (which models the
   register contract) before synthesis; final timing validation is on the board.
```
