#!/usr/bin/env python3
"""Wrap a PSID payload in a standalone ROM that calls its native init/play."""
from pathlib import Path
import argparse


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sid", type=Path)
    ap.add_argument("output", type=Path)
    a = ap.parse_args()
    p = a.sid.read_bytes()
    if p[:4] not in (b"PSID", b"RSID"):
        raise SystemExit("not a PSID/RSID file")
    off = int.from_bytes(p[6:8], "big")
    load = int.from_bytes(p[8:10], "big")
    init = int.from_bytes(p[10:12], "big")
    play = int.from_bytes(p[12:14], "big")
    body = p[off:]
    if load == 0:
        load = int.from_bytes(body[:2], "little")
        body = body[2:]
    if load != 0x1000 or len(body) > 4096:
        raise SystemExit(f"expected <=4096 bytes at $1000, got {len(body)} at ${load:04X}")
    body += bytes(4096-len(body))

    lines = [f"; Native PSID playback: {a.sid.name}",
             "TIME_MS = $883A", "SRC = $F0", "DST = $F2", "LAST_MS = $0FFF", "",
             '.segment "CODE"', "reset:", "    sei", "    cld", "    ldx #$FF", "    txs",
             "    lda #<sid_data", "    sta SRC", "    lda #>sid_data", "    sta SRC+1",
             "    lda #<$1000", "    sta DST", "    lda #>$1000", "    sta DST+1",
             "    ldx #16", "@page:", "    ldy #0", "@copy:", "    lda (SRC),y",
             "    sta (DST),y", "    iny", "    bne @copy", "    inc SRC+1", "    inc DST+1",
             "    dex", "    bne @page", "    lda #0", "    tax", "    tay",
             f"    jsr ${init:04X}", "    lda TIME_MS", "    sta LAST_MS", "play_loop:",
             "@wait:", "    lda TIME_MS", "    sec", "    sbc LAST_MS", "    cmp #20",
             "    bcc @wait", "    lda TIME_MS", "    sta LAST_MS", f"    jsr ${play:04X}",
             "    jmp play_loop", "", '.segment "RODATA"', "sid_data:"]
    for i in range(0, len(body), 16):
        lines.append("    .byte " + ",".join(str(x) for x in body[i:i+16]))
    lines += ["", '.segment "VECTORS"', "    .word reset", "    .word reset", "    .word reset", ""]
    a.output.write_text("\n".join(lines), newline="\n")
    print(f"{len(body)} payload bytes, load=${load:04X} init=${init:04X} play=${play:04X} -> {a.output}")


if __name__ == "__main__":
    main()
