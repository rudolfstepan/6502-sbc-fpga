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


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("sid", type=Path)
    ap.add_argument("output", type=Path, help="output .prg")
    ap.add_argument("--base", type=lambda s: int(s, 0), default=0x2000,
                    help="RAM load/entry address for the PRG (default $2000)")
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
    # The PRG (at base) must not overlap the tune's native payload region, and
    # everything must stay below the VIC bitmap window.
    if not (pad_end <= a.base or load >= VIC_BITMAP):
        raise SystemExit(
            f"{a.sid.name}: native payload ${load:04X}-${pad_end:04X} overlaps "
            f"the PRG base ${a.base:04X}; pick a higher --base or a lower tune")

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
