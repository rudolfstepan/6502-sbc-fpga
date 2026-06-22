#!/usr/bin/env python3
"""Wrap a PSID payload in a standalone ROM that calls its native init/play."""
from pathlib import Path
import argparse


class SidUnsupported(Exception):
    """Raised when a .sid file cannot be wrapped by the native player."""


# The wrapper + embedded payload live in the $A000-$CFFF shadow-ROM window
# (12 KB). The payload is copied to its native load address, which must sit in
# the board's only linear RAM ($0000-$5FFF) — above that are the VIC bitmap
# window ($6000-$7FFF), text VRAM ($8000-$87FF), I/O ($8800+) and ROM ($A000+).
# Leave a little ROM room for the ~90-byte wrapper.
RAM_TOP = 0x6000
ROM_PAYLOAD_MAX = 12000


def parse_payload(data: bytes) -> dict:
    """Parse a PSID/RSID image and return its payload + entry points.

    Raises SidUnsupported if the tune cannot be wrapped: it needs a real play
    address, a load address in linear RAM ($0200-$5FFF), and a payload that fits
    both that RAM region and the ROM window.
    """
    if data[:4] not in (b"PSID", b"RSID"):
        raise SidUnsupported("not a PSID/RSID file")
    off = int.from_bytes(data[6:8], "big")
    load = int.from_bytes(data[8:10], "big")
    init = int.from_bytes(data[10:12], "big")
    play = int.from_bytes(data[12:14], "big")
    body = data[off:]
    if load == 0:                       # load address taken from first 2 bytes
        load = int.from_bytes(body[:2], "little")
        body = body[2:]
    if play == 0:
        raise SidUnsupported("no play address (IRQ/CIA-driven tune)")
    if load < 0x0200:
        raise SidUnsupported(f"load ${load:04X} overlaps zero page/stack")
    payload_len = len(body)
    pages = (payload_len + 255) // 256
    padded = pages * 256
    if load + padded > RAM_TOP:
        raise SidUnsupported(
            f"payload ${load:04X}-${load + padded - 1:04X} overruns RAM (>= $A000)")
    if padded > ROM_PAYLOAD_MAX:
        raise SidUnsupported(f"payload {payload_len} bytes too large for ROM window")
    if init == 0:
        init = load                     # convention: init defaults to load addr
    body = body + bytes(padded - payload_len)
    return dict(load=load, init=init, play=play, body=body,
                payload_len=payload_len, pages=pages)


def render_asm(name: str, load: int, init: int, play: int, body: bytes, pages: int) -> str:
    """Render the 6502 wrapper source for a parsed payload."""
    lines = [f"; Native PSID playback: {name}",
             "TIME_MS = $883A", "SRC = $F0", "DST = $F2", "LAST_MS = $0FFF", "",
             '.segment "CODE"', "reset:", "    sei", "    cld", "    ldx #$FF", "    txs",
             "    lda #<sid_data", "    sta SRC", "    lda #>sid_data", "    sta SRC+1",
             f"    lda #<${load:04X}", "    sta DST", f"    lda #>${load:04X}", "    sta DST+1",
             f"    ldx #{pages}", "@page:", "    ldy #0", "@copy:", "    lda (SRC),y",
             "    sta (DST),y", "    iny", "    bne @copy", "    inc SRC+1", "    inc DST+1",
             "    dex", "    bne @page", "    lda #0", "    tax", "    tay",
             f"    jsr ${init:04X}", "    lda TIME_MS", "    sta LAST_MS", "play_loop:",
             "@wait:", "    lda TIME_MS", "    sec", "    sbc LAST_MS", "    cmp #20",
             "    bcc @wait", "    lda TIME_MS", "    sta LAST_MS", f"    jsr ${play:04X}",
             "    jmp play_loop", "", '.segment "RODATA"', "sid_data:"]
    for i in range(0, len(body), 16):
        lines.append("    .byte " + ",".join(str(x) for x in body[i:i+16]))
    lines += ["", '.segment "VECTORS"', "    .word reset", "    .word reset", "    .word reset", ""]
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sid", type=Path)
    ap.add_argument("output", type=Path)
    a = ap.parse_args()
    try:
        info = parse_payload(a.sid.read_bytes())
    except SidUnsupported as e:
        raise SystemExit(f"{a.sid.name}: {e}")
    asm = render_asm(a.sid.name, info["load"], info["init"], info["play"],
                     info["body"], info["pages"])
    a.output.write_text(asm, newline="\n")
    print(f"{info['payload_len']} payload bytes, load=${info['load']:04X} "
          f"init=${info['init']:04X} play=${info['play']:04X} -> {a.output}")


if __name__ == "__main__":
    main()
