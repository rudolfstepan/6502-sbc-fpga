#!/usr/bin/env python3
"""Build a UART-loadable C64 BASIC V2 SAVE diagnostic PRG."""

from __future__ import annotations

from pathlib import Path


OUT = Path("roms/c64/diag/diagnose.prg")
BASIC_LOAD = 0x0801

# BASIC V2 tokens.  Keep longer spellings first so PRINT# wins over PRINT and
# CHR$ wins over a hypothetical CHR variable prefix.
TOKENS: list[tuple[str, int]] = [
    ("PRINT#", 0x98),
    ("INPUT#", 0x84),
    ("CHR$", 0xC7),
    ("PRINT", 0x99),
    ("INPUT", 0x85),
    ("NEXT", 0x82),
    ("GET", 0xA1),
    ("FOR", 0x81),
    ("IF", 0x8B),
    ("POKE", 0x97),
    ("GOSUB", 0x8D),
    ("RETURN", 0x8E),
    ("THEN", 0xA7),
    ("SAVE", 0x94),
    ("LET", 0x88),
    ("END", 0x80),
    ("TO", 0xA4),
    ("AND", 0xAF),
    ("INT", 0xB5),
    ("PEEK", 0xC2),
    (">", 0xB1),
    ("=", 0xB2),
    ("<", 0xB3),
    ("+", 0xAA),
    ("-", 0xAB),
    ("*", 0xAC),
    ("/", 0xAD),
]


PROGRAM = """
10 PRINT "D64 SAVE DIAG"
20 PRINT "ENTER UNIQUE NAME"
30 INPUT N$
40 POKE 57103,1
45 POKE 57104,128
50 PRINT "BEFORE":GOSUB 300
60 PRINT "SAVING ";N$
70 SAVE N$,8
80 PRINT "AFTER SAVE":GOSUB 300
90 PRINT "TRACE":GOSUB 600
100 PRINT "IF SAVE RETURNED,"
110 PRINT "CHECK DIR MANUALLY:"
120 PRINT "LOAD ";CHR$(34);"$";CHR$(34);",8"
130 PRINT "THEN LIST AND LOAD FILE"
140 END
300 LET B=PEEK(57095)
310 LET G=B AND 15
320 LET D=INT(B/16)
330 PRINT "DF07=";B;" SG=";G;" SD=";D
340 LET C=PEEK(57103)
350 LET W=C AND 15
360 LET K=INT(C/16)
370 PRINT "DF0F=";C;" GB=";W;" GC=";K
380 LET E=PEEK(57101)
390 LET L=E AND 15
400 LET F=INT(E/16)
410 PRINT "DF0D=";E;" BL=";L;" CF=";F
420 LET I=PEEK(57088)
430 LET J=PEEK(57089)
440 PRINT "CX=";I;" RX=";J
450 LET O=PEEK(57090)
460 LET P=PEEK(57091)
470 PRINT "P2=";O;" P1=";P
480 LET U=PEEK(57092)
490 LET V=U AND 127
500 LET Y=INT(U/128)
510 PRINT "IV=";V;" FO=";Y
520 LET H=PEEK(57102)
530 LET Q=H AND 15
540 LET R=INT(H/16)
550 PRINT "DF0E=";H;" WE=";Q;" ER=";R
560 RETURN
600 LET T=PEEK(57104) AND 63
610 PRINT "TR=";T
620 IF T=0 THEN RETURN
630 FOR Z=0 TO T-1
640 POKE 57104,Z
650 PRINT Z;":";PEEK(57105);PEEK(57106);PEEK(57107);PEEK(57108)
660 NEXT Z
670 RETURN
"""


def tokenize(body: str) -> bytes:
    out = bytearray()
    i = 0
    in_quotes = False
    in_rem = False
    text = body.upper()

    while i < len(text):
        ch = text[i]

        if in_quotes or in_rem:
            out.append(ord(ch))
            if ch == '"':
                in_quotes = False
            i += 1
            continue

        if ch == '"':
            in_quotes = True
            out.append(ord(ch))
            i += 1
            continue

        for kw, token in TOKENS:
            if text.startswith(kw, i):
                out.append(token)
                i += len(kw)
                break
        else:
            out.append(ord(ch))
            i += 1

    return bytes(out)


def basic_prg(source: str) -> bytes:
    out = bytearray([BASIC_LOAD & 0xFF, BASIC_LOAD >> 8])
    addr = BASIC_LOAD

    for raw in source.strip().splitlines():
        raw = raw.strip()
        if not raw:
            continue
        number_text, body = raw.split(" ", 1)
        number = int(number_text)
        line = tokenize(body)
        next_addr = addr + 4 + len(line) + 1
        out += bytes([
            next_addr & 0xFF,
            (next_addr >> 8) & 0xFF,
            number & 0xFF,
            (number >> 8) & 0xFF,
        ])
        out += line
        out.append(0)
        addr = next_addr

    out += b"\x00\x00"
    return bytes(out)


def main() -> int:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    prg = basic_prg(PROGRAM)
    OUT.write_bytes(prg)
    print(f"Wrote {OUT} ({len(prg)} bytes, load=${BASIC_LOAD:04X})")
    print("Upload: python tools/c64_uart_prg_loader.py roms/c64/diag/diagnose.prg --port COM15")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
