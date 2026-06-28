# Commodore 64 ROMs

The native C64 core needs the three original Commodore ROMs. They are **not**
included in this repository — they are copyrighted (Commodore / Cloanto), so you
have to supply your own legally‑obtained copies. Nothing that contains ROM data
is ever committed: the raw dumps here, the generated `rtl/c64/c64_roms.vhd`, and
the synthesized C64 bitstreams are all git‑ignored.

## What you need

Drop these three files into `roms/c64/`:

| File         | Size      | Maps to        | Reference part |
|--------------|-----------|----------------|----------------|
| `BASIC.ROM`  | 8192 B    | `$A000–$BFFF`  | 901226-01      |
| `KERNAL.ROM` | 8192 B    | `$E000–$FFFF`  | 901227 (-02/-03) |
| `CHAR.ROM`   | 4096 B    | character gen. | 901225-01      |

Use exactly those names — on Linux/macOS the build matches them case‑sensitively.

This build is verified with:

```
79015323128650c742a3694c9429aa91f355905e  BASIC.ROM   (901226-01)
348eab23e920d14dfcbdd8659893ab4ef1041f80  KERNAL.ROM  (901227 series)
adc7c31e18c7c7413d54802ef2f4193da14711aa  CHAR.ROM    (901225-01)
```

Any compatible C64 ROM set of the right sizes works; check yours with
`sha1sum roms/c64/*.ROM`.

## Where to get them, legally

- Dump them from a real Commodore 64 you own.
- They ship with the **VICE** emulator under its `C64/` data directory
  (`basic-901226-01`, `kernal-901227-03`, `chargen-901225-01`) — copy them here
  and rename to `BASIC.ROM` / `KERNAL.ROM` / `CHAR.ROM`.
- **C64 Forever** (Cloanto) includes properly licensed copies.

## Build the ROM image

With the three files in place, generate the VHDL block‑ROM that the core
compiles in (this writes `rtl/c64/c64_roms.vhd`, also git‑ignored):

```
python tools/build_c64_roms.py
```

It emits the `basic_rom`, `kernal_rom` and `chargen_rom` entities used by
`rtl/c64/c64_core.vhd`. Re‑run it whenever you swap a ROM.

## Diagnostic ROM (optional)

To boot the hardware self‑test instead of BASIC — it replaces the KERNAL with
the diagnostic in `sw/c64diag.s` (RAM/CIA/IRQ/keyboard checks on screen):

```
python tools/build_c64_diag.py
```

Switch back to the real KERNAL with `python tools/build_c64_roms.py`.
