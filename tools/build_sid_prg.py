#!/usr/bin/env python3
"""Wrap a PSID tune as a RAM-loadable PRG for the D64 GoDrive.

The PRG's **load address is also its entry point** (uniform with the other test
PRGs), so it is always run with `CALL <load address>`:

  PRG @ base (default $2000):
    [ player stub: copy payload to its native load addr, init, play loop ]
    [ embedded PSID payload ]
  At run time the stub copies the payload to the tune's native load address and
  plays it.  base is chosen above the tune's native region so the copy never
  overlaps, and the whole PRG must stay below the VIC bitmap window ($6000).

This trades a tiny startup copy for a single, predictable entry address.
"""
from __future__ import annotations

from pathlib import Path
import argparse
import subprocess
import tempfile

import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_native_sid_rom import parse_payload, SidUnsupported  # noqa: E402

VIC_BITMAP = 0x6000
RAM_FLOOR = 0x2000      # lowest safe PRG load addr (BASIC/loader live below this)
PLAYER_RESERVE = 0x80   # bytes reserved below the payload for the in-place player


def render_asm(name: str, base: int, load: int, init: int, play: int,
               pages: int) -> str:
    """Player linked at `base`: copy `pages` pages to `load`, init, play."""
    return "\n".join([
        f"; D64 PRG player for PSID: {name}",
        f"; linked at ${base:04X}; entry = load address; CALL {base} to run.",
        "TIME_MS = $883A", "SRC = $F0", "DST = $F2", "LAST_MS = $0FFF", "",
        '.segment "CODE"',
        "start:",
        "    sei", "    cld",
        "    lda #<sid_data", "    sta SRC", "    lda #>sid_data", "    sta SRC+1",
        f"    lda #<${load:04X}", "    sta DST", f"    lda #>${load:04X}", "    sta DST+1",
        f"    ldx #{pages}", "@page:", "    ldy #0", "@copy:", "    lda (SRC),y",
        "    sta (DST),y", "    iny", "    bne @copy", "    inc SRC+1", "    inc DST+1",
        "    dex", "    bne @page",
        "    lda #0", "    tax", "    tay",
        f"    jsr ${init:04X}",
        "    lda TIME_MS", "    sta LAST_MS",
        "play_loop:",
        "@wait:", "    lda TIME_MS", "    sec", "    sbc LAST_MS", "    cmp #20",
        "    bcc @wait", "    lda TIME_MS", "    sta LAST_MS", f"    jsr ${play:04X}",
        "    jmp play_loop",
        "", '.segment "RODATA"', "sid_data:",
    ])


def render_data(body: bytes) -> str:
    lines = []
    for i in range(0, len(body), 16):
        lines.append("    .byte " + ",".join(str(x) for x in body[i:i + 16]))
    return "\n".join(lines) + "\n"


def render_inplace_asm(name: str, entry: int, load: int, init: int,
                       play: int, song: int) -> str:
    """Player linked at `entry`, payload sitting in place at its native `load`.

    No startup copy: the D64 loader drops the payload straight at `load` (which
    is real RAM below the bitmap window), and the player -- a handful of bytes
    just below it -- inits the tune and polls play at ~50 Hz.  Used for tunes
    that load too high for the copy-up wrapper to keep two payload copies under
    the bitmap window, but whose single in-place image still fits.
    """
    return "\n".join([
        f"; In-place D64 PRG player for PSID: {name}",
        f"; payload @ ${load:04X} (native); player @ ${entry:04X} = entry; "
        f"CALL {entry} to run.",
        "TIME_MS = $883A", "LAST_MS = $0FFF",
        "CIA_TALO = $DC04", "CIA_TAHI = $DC05", "CIA_CRA = $DC0E", "",
        '.segment "CODE"',
        "start:",
        "    sei", "    cld",
        # free-running CIA Timer A so tunes that read $DC04 see it tick
        "    lda #0", "    sta CIA_CRA",
        "    lda #$FF", "    sta CIA_TALO", "    lda #$FF", "    sta CIA_TAHI",
        "    lda #$01", "    sta CIA_CRA",
        f"    lda #{song}", "    tax", "    tay", f"    jsr ${init:04X}",
        "    sei",        # re-mask: some inits CLI (no $0314 bridge in a RAM PRG)
        "    lda TIME_MS", "    sta LAST_MS",
        "play_loop:",
        "@wait:", "    lda TIME_MS", "    sec", "    sbc LAST_MS", "    cmp #20",
        "    bcc @wait", "    lda TIME_MS", "    sta LAST_MS", f"    jsr ${play:04X}",
        "    jmp play_loop",
        "", '.segment "PAYLOAD"', "sid_data:",
    ])


def make_inplace_cfg(entry: int, load: int, top: int) -> str:
    return (
        "MEMORY {\n"
        "    ZP:      start = $0000, size = $0100, type = rw;\n"
        f"    PLAYER:  start = ${entry:04X}, size = ${load - entry:04X}, "
        "file = %O, fill = yes;\n"
        f"    PAYLOAD: start = ${load:04X}, size = ${top - load:04X}, "
        "file = %O, fill = yes;\n"
        "}\n"
        "SEGMENTS {\n"
        "    ZEROPAGE: load = ZP,      type = zp, optional = yes;\n"
        "    CODE:     load = PLAYER,  type = ro;\n"
        "    PAYLOAD:  load = PAYLOAD, type = ro;\n"
        "}\n"
    )


def make_cfg(base: int) -> str:
    return (
        "MEMORY {\n"
        "    ZP:   start = $0000, size = $0100, type = rw;\n"
        f"    MAIN: start = ${base:04X}, size = ${VIC_BITMAP - base:04X}, "
        "file = %O, fill = no;\n"
        "}\n"
        "SEGMENTS {\n"
        "    ZEROPAGE: load = ZP,   type = zp, optional = yes;\n"
        "    CODE:     load = MAIN, type = ro;\n"
        "    RODATA:   load = MAIN, type = ro;\n"
        "}\n"
    )


def build_inplace(a, info: dict, load: int, body: bytes, top: int,
                  entry: int) -> int:
    """Assemble + link the in-place PRG and write it out."""
    asm = render_inplace_asm(a.sid.name, entry, load, info["init"],
                             info["play"], info["song"]) + "\n" + render_data(body)
    with tempfile.TemporaryDirectory() as td:
        t = Path(td)
        (t / "p.s").write_text(asm, newline="\n")
        (t / "p.cfg").write_text(make_inplace_cfg(entry, load, top), newline="\n")
        subprocess.run([a.ca65, "--cpu", "6502", "-t", "none",
                        str(t / "p.s"), "-o", str(t / "p.o")], check=True)
        subprocess.run([a.ld65, "-C", str(t / "p.cfg"),
                        "-o", str(t / "p.bin"), str(t / "p.o")], check=True)
        payload = (t / "p.bin").read_bytes()

    prg = bytes([entry & 0xFF, (entry >> 8) & 0xFF]) + payload
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_bytes(prg)
    print(f"{a.sid.name}: in-place native ${load:04X}-${top:04X}; player @ "
          f"${entry:04X} ({len(prg)} bytes); CALL {entry} (${entry:04X}) to play "
          f" -> {a.output}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("sid", type=Path)
    ap.add_argument("output", type=Path, help="output .prg")
    ap.add_argument("--base", default="auto",
                    help="RAM load/entry address ('auto' = just above the tune's "
                         "native region, else a hex/decimal address; default auto)")
    ap.add_argument("--ca65", default="C:/tools/cc65/bin/ca65")
    ap.add_argument("--ld65", default="C:/tools/cc65/bin/ld65")
    a = ap.parse_args()

    try:
        info = parse_payload(a.sid.read_bytes())
    except SidUnsupported as e:
        raise SystemExit(f"{a.sid.name}: {e}")

    load = info["load"]
    body = info["body"]                 # page-padded payload
    pad_end = load + len(body)

    # Choose the PRG load/entry address.  The PRG (stub + an embedded copy of the
    # payload) lives at `base` and copies the payload down to `load` at run time,
    # so `base` must sit above the native region (or the native region above the
    # bitmap window).  "auto" puts the PRG one page above the native end, but at
    # least $2000 so it never collides with the BASIC/zero-page/stack area.
    if a.base == "auto":
        base = max(0x2000, (pad_end + 0xFF) & ~0xFF) if load < VIC_BITMAP else 0x2000
    else:
        base = int(a.base, 0)
    copyup_ok = (pad_end <= base or load >= VIC_BITMAP) \
        and (base + 64 + len(body) <= VIC_BITMAP)

    # Fallback: when the copy-up wrapper cannot fit two payload copies under the
    # bitmap window (auto base only), try the in-place layout -- the payload is
    # loaded straight at its native address with a small player just below it.
    if not copyup_ok and a.base == "auto":
        entry = load - PLAYER_RESERVE
        if pad_end <= VIC_BITMAP and entry >= RAM_FLOOR:
            return build_inplace(a, info, load, body, pad_end, entry)
        raise SystemExit(
            f"{a.sid.name}: cannot wrap -- copy-up overruns the bitmap and "
            f"in-place entry ${entry:04X}/payload ${load:04X}-${pad_end:04X} "
            f"does not fit ${RAM_FLOOR:04X}-${VIC_BITMAP:04X}")
    if not (pad_end <= base or load >= VIC_BITMAP):
        raise SystemExit(
            f"{a.sid.name}: native payload ${load:04X}-${pad_end:04X} overlaps "
            f"the PRG base ${base:04X}; pick a higher --base or a lower tune")
    # The PRG (stub ~64 B + the embedded payload copy) must fit below the bitmap.
    est_end = base + 64 + len(body)
    if est_end > VIC_BITMAP:
        raise SystemExit(
            f"{a.sid.name}: PRG @ ${base:04X} + payload would reach ${est_end:04X} "
            f">= VIC bitmap ${VIC_BITMAP:04X}; tune too large/high for RAM")
    # rebind so the rest of the function uses the resolved integer base
    a.base = base

    asm = render_asm(a.sid.name, a.base, load, info["init"], info["play"],
                     info["pages"]) + "\n" + render_data(body)
    with tempfile.TemporaryDirectory() as td:
        t = Path(td)
        (t / "p.s").write_text(asm, newline="\n")
        (t / "p.cfg").write_text(make_cfg(a.base), newline="\n")
        subprocess.run([a.ca65, "--cpu", "6502", "-t", "none",
                        str(t / "p.s"), "-o", str(t / "p.o")], check=True)
        subprocess.run([a.ld65, "-C", str(t / "p.cfg"),
                        "-o", str(t / "p.bin"), str(t / "p.o")], check=True)
        payload = (t / "p.bin").read_bytes()

    if a.base + len(payload) > VIC_BITMAP:
        raise SystemExit(f"{a.sid.name}: PRG overruns the VIC bitmap window")

    # PRG = 2-byte LE load address (= entry) + binary.
    prg = bytes([a.base & 0xFF, (a.base >> 8) & 0xFF]) + payload
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_bytes(prg)
    print(f"{a.sid.name}: native ${load:04X}-${pad_end:04X}; PRG @ ${a.base:04X} "
          f"({len(prg)} bytes); CALL {a.base} (${a.base:04X}) to play  -> {a.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
