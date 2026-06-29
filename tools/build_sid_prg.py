#!/usr/bin/env python3
"""Wrap a PSID tune as a RAM-loadable PRG.

By default the SBC target keeps the PRG's **load address also its entry point**
(uniform with the other test PRGs), so it is run with `CALL <load address>`:

  PRG @ base (default $2000):
    [ player stub: copy payload to its native load addr, init, play loop ]
    [ embedded PSID payload ]
  At run time the stub copies the payload to the tune's native load address and
  plays it.  base is chosen above the tune's native region so the copy never
  overlaps, and the whole PRG must stay below the VIC bitmap window ($6000).

This trades a tiny startup copy for a single, predictable entry address.

The C64 target adds a normal BASIC `10 SYS <entry>` stub at $0801 by default and
uses CIA Timer A for a PAL-like 50 Hz player tick, so the resulting PRG can be
loaded through the C64 UART monitor and started with `RUN`.
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
BASIC_LOAD = 0x0801
C64_PAL_FRAME_PERIOD = 19999  # 1 MHz PHI2 / 50 Hz, minus one for CIA underflow


def target_symbols(target: str) -> list[str]:
    if target == "c64":
        return ["CIA_TALO = $DC04", "CIA_TAHI = $DC05",
                "CIA_ICR = $DC0D", "CIA_CRA = $DC0E",
                "VIC_D011 = $D011", "VIC_D01A = $D01A",
                "SRC = $F0", "DST = $F2", ""]
    return ["TIME_MS = $883A", "LAST_MS = $0FFF",
            "CIA_TALO = $DC04", "CIA_TAHI = $DC05", "CIA_CRA = $DC0E",
            "SRC = $F0", "DST = $F2", ""]


def target_timer_init(target: str) -> list[str]:
    if target != "c64":
        return []
    period = C64_PAL_FRAME_PERIOD
    return [
        # Drive PAL SID updates from CIA Timer A (~50 Hz). Polling ICR keeps the
        # wrapper independent of KERNAL IRQ vectors and avoids 60 Hz video timing.
        "    lda #0", "    sta CIA_CRA",
        "    lda #$7F", "    sta CIA_ICR",  # mask all CIA IRQ sources
        f"    lda #${period & 0xFF:02X}", "    sta CIA_TALO",
        f"    lda #${period >> 8:02X}", "    sta CIA_TAHI",
        "    lda #$11", "    sta CIA_CRA",  # start + force-load
        "    lda CIA_ICR",
    ]


def target_video_quiet(target: str) -> list[str]:
    if target != "c64":
        return []
    return [
        # Pure SID PRGs do not need the VIC display. Clearing DEN stops VIC RAM
        # fetches in this core, removing playback jitter from RDY bus steals.
        "    lda VIC_D011", "    and #$EF", "    sta VIC_D011",
        "    lda #0", "    sta VIC_D01A",
    ]


def target_wait_loop(target: str, play: int) -> list[str]:
    if target == "c64":
        return [
            "play_loop:",
            "@wait_timer:", "    lda CIA_ICR", "    and #$01", "    beq @wait_timer",
            f"    jsr ${play:04X}",
            "    jmp play_loop",
        ]
    return [
        "    lda TIME_MS", "    sta LAST_MS",
        "play_loop:",
        "@wait:", "    lda TIME_MS", "    sec", "    sbc LAST_MS", "    cmp #20",
        "    bcc @wait", "    lda TIME_MS", "    sta LAST_MS", f"    jsr ${play:04X}",
        "    jmp play_loop",
    ]


def render_asm(name: str, base: int, load: int, init: int, play: int,
               pages: int, target: str) -> str:
    """Player linked at `base`: copy `pages` pages to `load`, init, play."""
    lines = [
        f"; {target.upper()} PRG player for PSID: {name}",
        f"; linked at ${base:04X}; entry = load address; CALL/SYS {base} to run.",
    ] + target_symbols(target) + [
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
        "    sei",
    ] + target_video_quiet(target) + target_timer_init(target) + target_wait_loop(target, play) + [
        "", '.segment "RODATA"', "sid_data:",
    ]
    return "\n".join(lines)


def render_data(body: bytes) -> str:
    lines = []
    for i in range(0, len(body), 16):
        lines.append("    .byte " + ",".join(str(x) for x in body[i:i + 16]))
    return "\n".join(lines) + "\n"


def basic_stub(entry: int) -> bytes:
    sys_text = str(entry).encode("ascii")
    next_line = BASIC_LOAD + 2 + 2 + 1 + len(sys_text) + 1
    return bytes(
        [
            next_line & 0xFF,
            next_line >> 8,
            10,
            0,
            0x9E,
        ]
    ) + sys_text + b"\x00\x00\x00"


def make_prg(entry: int, payload: bytes, basic_run: bool) -> bytes:
    if not basic_run:
        return bytes([entry & 0xFF, (entry >> 8) & 0xFF]) + payload

    stub = basic_stub(entry)
    payload_offset = entry - BASIC_LOAD
    if payload_offset < len(stub):
        raise SystemExit(
            f"cannot add BASIC RUN stub: entry ${entry:04X} overlaps the BASIC line")
    return (
        bytes([BASIC_LOAD & 0xFF, BASIC_LOAD >> 8])
        + stub
        + bytes(payload_offset - len(stub))
        + payload
    )


def render_inplace_asm(name: str, entry: int, load: int, init: int,
                       play: int, song: int, target: str) -> str:
    """Player linked at `entry`, payload sitting in place at its native `load`.

    No startup copy: the D64 loader drops the payload straight at `load` (which
    is real RAM below the bitmap window), and the player -- a handful of bytes
    just below it -- inits the tune and polls play at ~50 Hz.  Used for tunes
    that load too high for the copy-up wrapper to keep two payload copies under
    the bitmap window, but whose single in-place image still fits.
    """
    lines = [
        f"; In-place {target.upper()} PRG player for PSID: {name}",
        f"; payload @ ${load:04X} (native); player @ ${entry:04X} = entry; "
        f"CALL/SYS {entry} to run.",
    ] + target_symbols(target) + [
        '.segment "CODE"',
        "start:",
        "    sei", "    cld",
    ] + [
        f"    lda #{song}", "    tax", "    tay", f"    jsr ${init:04X}",
        "    sei",        # re-mask: some inits CLI (no $0314 bridge in a RAM PRG)
    ] + target_video_quiet(target) + target_timer_init(target) + target_wait_loop(target, play) + [
        "", '.segment "PAYLOAD"', "sid_data:",
    ]
    return "\n".join(lines)


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
                             info["play"], info["song"], a.target) + "\n" + render_data(body)
    with tempfile.TemporaryDirectory() as td:
        t = Path(td)
        (t / "p.s").write_text(asm, newline="\n")
        (t / "p.cfg").write_text(make_inplace_cfg(entry, load, top), newline="\n")
        subprocess.run([a.ca65, "--cpu", "6502", "-t", "none",
                        str(t / "p.s"), "-o", str(t / "p.o")], check=True)
        subprocess.run([a.ld65, "-C", str(t / "p.cfg"),
                        "-o", str(t / "p.bin"), str(t / "p.o")], check=True)
        payload = (t / "p.bin").read_bytes()

    prg = make_prg(entry, payload, a.basic_run)
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_bytes(prg)
    print(f"{a.sid.name}: {a.target} in-place native ${load:04X}-${top:04X}; "
          f"player @ ${entry:04X} ({len(prg)} bytes); "
          f"{'RUN' if a.basic_run else f'SYS {entry} (${entry:04X})'} "
          f"to play -> {a.output}")
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
    ap.add_argument("--target", choices=("sbc", "c64"), default="sbc",
                    help="player timing target: sbc uses $883A, c64 uses CIA Timer A")
    ap.add_argument("--basic-run", dest="basic_run", action="store_true",
                    help="prepend BASIC 10 SYS <entry> at $0801 so RUN starts the PRG")
    ap.add_argument("--no-basic-run", dest="basic_run", action="store_false",
                    help="keep load address equal to the machine-code entry")
    ap.set_defaults(basic_run=None)
    a = ap.parse_args()
    if a.basic_run is None:
        a.basic_run = a.target == "c64"

    try:
        info = parse_payload(a.sid.read_bytes(), a.sid.name)
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
                     info["pages"], a.target) + "\n" + render_data(body)
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

    # PRG = either 2-byte LE entry/load address + binary, or a $0801 BASIC
    # wrapper that SYSes to the entry and leaves the machine-code payload at it.
    prg = make_prg(a.base, payload, a.basic_run)
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_bytes(prg)
    print(f"{a.sid.name}: {a.target} native ${load:04X}-${pad_end:04X}; "
          f"player @ ${a.base:04X} ({len(prg)} bytes); "
          f"{'RUN' if a.basic_run else f'SYS {a.base} (${a.base:04X})'} "
          f"to play -> {a.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
