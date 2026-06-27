#!/usr/bin/env python3
"""Wrap a PSID payload in a standalone, IRQ-driven ROM that calls its native
init/play through a CIA-1 Timer A interrupt.

The wrapper installs an IRQ handler (via the C64 $0314 vector, reached from the
ROM's own $FFFE through a JMP ($0314) bridge), so:

  * play != 0 : we program CIA-1 Timer A for ~50 Hz, and our handler acks the
    timer and JSRs the tune's play routine each interrupt.
  * play == 0 : a pure IRQ tune — its init sets up the timer and points $0314 at
    its own handler; we just provide the bridge and a safe default vector.

This needs the CIA-1 Timer A in the FPGA (cia6526 at $DC00). Tunes whose load
address sits above linear RAM, or whose payload is too big for the ROM window,
are still rejected.
"""
from pathlib import Path
import argparse


class SidUnsupported(Exception):
    """Raised when a .sid file cannot be wrapped by the native player."""


# The wrapper + embedded payload live in the $A000-$CFFF shadow-ROM window
# (12 KB). The payload is copied to its native load address, which must sit in
# the board's linear RAM below the VIC bitmap window ($6000). NOTE: physical RAM
# is currently 16 KB, so loads in $4000-$5FFF alias $0000-$1FFF.
RAM_TOP = 0x6000
ROM_PAYLOAD_MAX = 12000

# CIA-1 Timer A period for ~50 Hz at the FPGA's ~1 MHz PHI2 tick (1e6 / 50).
PERIOD_50HZ = 20000


def parse_payload(data: bytes) -> dict:
    """Parse a PSID/RSID image and return its payload + entry points.

    Raises SidUnsupported only for memory limits now (a missing play address is
    allowed: such tunes drive themselves from a CIA interrupt installed by init).
    """
    if data[:4] not in (b"PSID", b"RSID"):
        raise SidUnsupported("not a PSID/RSID file")
    off   = int.from_bytes(data[6:8], "big")
    load  = int.from_bytes(data[8:10], "big")
    init  = int.from_bytes(data[10:12], "big")
    play  = int.from_bytes(data[12:14], "big")
    start = int.from_bytes(data[16:18], "big")    # start song, 1-based
    body  = data[off:]
    if load == 0:                       # load address taken from first 2 bytes
        load = int.from_bytes(body[:2], "little")
        body = body[2:]
    if load < 0x0200:
        raise SidUnsupported(f"load ${load:04X} overlaps zero page/stack")
    payload_len = len(body)
    pages   = (payload_len + 255) // 256
    padded  = pages * 256
    top = load + padded
    if load >= 0xA000 and top <= 0xD000:
        # RAM-under-BASIC: tune sits directly in the $A000-$CFFF shadow window.
        mode = "page"
    elif top <= RAM_TOP:
        # copied into low RAM ($0200-$5FFF) by a wrapper that lives at $A000.
        mode = "low"
        if padded > ROM_PAYLOAD_MAX:
            raise SidUnsupported(f"payload {payload_len} bytes too large for ROM window")
    else:
        raise SidUnsupported(
            f"payload ${load:04X}-${top - 1:04X} fits neither low RAM "
            f"(<${RAM_TOP:04X}) nor the $A000-$CFFF window")
    if init == 0:
        init = load                     # convention: init defaults to load addr
    song = start - 1 if start > 0 else 0
    body = body + bytes(padded - payload_len)
    return dict(load=load, init=init, play=play, body=body,
                payload_len=payload_len, pages=pages, song=song, mode=mode)


def render_asm(name: str, info: dict) -> str:
    """Dispatch to the low-RAM (copy) or page (RAM-under-BASIC) wrapper."""
    if info.get("mode") == "page":
        return _render_page(name, info)
    return _render_low(name, info)


def _render_page(name: str, info: dict) -> str:
    """Tune sits at its native $A000-$CFFF load address (RAM-under-BASIC); a small
    player lives at $F000. play != 0 -> polled via $883A; play == 0 -> IRQ via
    the $0314 vector. No payload copy (the tune is already at its load address)."""
    load, init, play, song = info["load"], info["init"], info["play"], info["song"]
    has_play = play != 0
    lines = [
        f"; Native PSID playback (RAM-under-BASIC, tune @ ${load:04X}): {name}",
        "TIME_MS = $883A", "LAST_MS = $0FFF",
        "CIA_TALO = $DC04", "CIA_TAHI = $DC05", "CIA_ICR = $DC0D", "CIA_CRA = $DC0E",
        "IRQVEC = $0314", "",
        '.segment "ROMTUNE"',
    ]
    if load > 0xA000:
        lines.append(f"    .res ${load - 0xA000:04X}")   # pad to the load address
    lines.append("sid_data:")
    body = info["body"]
    for i in range(0, len(body), 16):
        lines.append("    .byte " + ",".join(str(x) for x in body[i:i+16]))
    lines += ['', '.segment "PLAYER"', "player_start:",
              "    sei", "    cld", "    ldx #$FF", "    txs"]
    if has_play:
        lines += [
            # free-running CIA Timer A for tunes that read $DC04
            "    lda #0", "    sta CIA_CRA",
            "    lda #$FF", "    sta CIA_TALO", "    lda #$FF", "    sta CIA_TAHI",
            "    lda #$01", "    sta CIA_CRA",
            f"    lda #{song}", "    tax", "    tay", f"    jsr ${init:04X}",
            "    lda TIME_MS", "    sta LAST_MS", "play_loop:", "@wait:",
            "    lda TIME_MS", "    sec", "    sbc LAST_MS", "    cmp #20", "    bcc @wait",
            "    lda TIME_MS", "    sta LAST_MS", f"    jsr ${play:04X}", "    jmp play_loop",
            "irq_rti:", "    rti",
        ]
        vectors = ["    .word irq_rti", "    .word player_start", "    .word irq_rti"]
    else:
        lines += [
            "    lda #<irq_svc", "    sta IRQVEC", "    lda #>irq_svc", "    sta IRQVEC+1",
            f"    lda #{song}", "    tax", "    tay", f"    jsr ${init:04X}",
            "    cli", "@loop:", "    jmp @loop", "",
            "irq_svc:", "    pha", "    lda CIA_ICR", "    pla", "    rti", "",
            "irqbridge:", "    jmp (IRQVEC)",
        ]
        vectors = ["    .word irqbridge", "    .word player_start", "    .word irqbridge"]
    lines += ["", '.segment "VECTORS"'] + vectors + [""]
    return "\n".join(lines)


def _render_low(name: str, info: dict) -> str:
    """Render the 6502 wrapper source for a parsed payload.

    play != 0 : POLLED — init once, then call play every ~20 ms off the $883A
    millisecond counter (works with or without the CIA, so it never regresses).
    A free-running CIA Timer A is also started so tunes that read $DC04 see a
    live timer.

    play == 0 : IRQ-DRIVEN — the tune's init installs its own CIA timer and
    $0314 handler; we only provide a default vector and a $FFFE -> JMP ($0314)
    bridge (this one needs the FPGA CIA).
    """
    load, init, play = info["load"], info["init"], info["play"]
    pages, song = info["pages"], info["song"]
    has_play = play != 0

    head = [
        f"; Native PSID playback: {name}",
        "TIME_MS = $883A", "LAST_MS = $0FFF",
        "SRC = $F0", "DST = $F2",
        "CIA_TALO = $DC04", "CIA_TAHI = $DC05", "CIA_ICR = $DC0D", "CIA_CRA = $DC0E",
        "IRQVEC = $0314", "",
        '.segment "CODE"', "reset:",
        "    sei", "    cld", "    ldx #$FF", "    txs",
        # copy payload to its native load address
        "    lda #<sid_data", "    sta SRC", "    lda #>sid_data", "    sta SRC+1",
        f"    lda #<${load:04X}", "    sta DST", f"    lda #>${load:04X}", "    sta DST+1",
        f"    ldx #{pages}", "@page:", "    ldy #0", "@copy:",
        "    lda (SRC),y", "    sta (DST),y", "    iny", "    bne @copy",
        "    inc SRC+1", "    inc DST+1", "    dex", "    bne @page",
    ]

    if has_play:
        body_code = [
            # free-running CIA Timer A (no IRQ) for tunes that read $DC04
            "    lda #0", "    sta CIA_CRA",
            "    lda #$FF", "    sta CIA_TALO", "    lda #$FF", "    sta CIA_TAHI",
            "    lda #$01", "    sta CIA_CRA",
            # init, then poll the ms timer and call play at ~50 Hz
            f"    lda #{song}", "    tax", "    tay", f"    jsr ${init:04X}",
            "    lda TIME_MS", "    sta LAST_MS", "play_loop:", "@wait:",
            "    lda TIME_MS", "    sec", "    sbc LAST_MS", "    cmp #20", "    bcc @wait",
            "    lda TIME_MS", "    sta LAST_MS", f"    jsr ${play:04X}", "    jmp play_loop",
        ]
        vectors = ["    .word reset", "    .word reset", "    .word reset"]
    else:
        body_code = [
            # pure IRQ tune: default $0314 -> safe ack/RTI; init sets up CIA + $0314
            "    lda #<irq_svc", "    sta IRQVEC", "    lda #>irq_svc", "    sta IRQVEC+1",
            f"    lda #{song}", "    tax", "    tay", f"    jsr ${init:04X}",
            "    cli", "@loop:", "    jmp @loop", "",
            "irq_svc:", "    pha", "    lda CIA_ICR", "    pla", "    rti", "",
            "irqbridge:", "    jmp (IRQVEC)",
        ]
        vectors = ["    .word irqbridge", "    .word reset", "    .word irqbridge"]

    lines = head + body_code + ["", '.segment "RODATA"', "sid_data:"]
    body = info["body"]
    for i in range(0, len(body), 16):
        lines.append("    .byte " + ",".join(str(x) for x in body[i:i+16]))
    lines += ["", '.segment "VECTORS"'] + vectors + [""]
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
    a.output.write_text(render_asm(a.sid.name, info), newline="\n")
    print(f"{info['payload_len']} payload bytes, load=${info['load']:04X} "
          f"init=${info['init']:04X} play=${info['play']:04X} song={info['song']} "
          f"-> {a.output}")


if __name__ == "__main__":
    main()
