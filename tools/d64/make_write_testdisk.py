#!/usr/bin/env python3
"""Build writetest.d64: a D64 with the $DF0x sector-write hardware test.

The BASIC program pokes a pattern into the $DF0x sector buffer, writes it to
track 35 / sector 16 of the *mounted* image (i.e. this disk), reads it back
from the card and counts mismatches.  See tang20k_c64_top.vhd for the register
map ($DF08 track, $DF09 sector, $DF0A offset, $DF0B status/read, $DF0C data,
$DF0E write command).

Usage:
    python tools/d64/make_write_testdisk.py [-o roms/test_d64/writetest.d64]
"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from create_test_d64 import D64Builder  # noqa: E402

# BASIC V2 tokens, longest keyword first so e.g. PRINT wins over PR.
TOKENS = [
    ("PRINT", 0x99), ("POKE", 0x97), ("PEEK(", 0xC2), ("NEXT", 0x82),
    ("THEN", 0xA7), ("GOTO", 0x89), ("AND", 0xAF), ("FOR", 0x81),
    ("REM", 0x8F), ("END", 0x80), ("IF", 0x8B), ("TO", 0xA4),
    ("OR", 0xB0), (">", 0xB1), ("=", 0xB2), ("<", 0xB3),
    ("+", 0xAA), ("-", 0xAB), ("*", 0xAC), ("/", 0xAD),
]


def tokenize(line: str) -> bytes:
    """Tokenize one BASIC V2 line body (without the line number)."""
    out = bytearray()
    i = 0
    in_quotes = False
    in_rem = False
    while i < len(line):
        ch = line[i]
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
        for kw, tok in TOKENS:
            if line.startswith(kw, i):
                out.append(tok)
                if kw == "PEEK(":
                    out.append(ord("("))
                if kw == "REM":
                    in_rem = True
                i += len(kw)
                break
        else:
            out.append(ord(ch))
            i += 1
    return bytes(out)


def basic_prg(source: str) -> bytes:
    """Tokenize a BASIC listing into PRG payload (excluding the load address)."""
    load = 0x0801
    addr = load
    out = bytearray()
    for raw in source.strip().splitlines():
        raw = raw.strip()
        if not raw:
            continue
        num_str, body = raw.split(" ", 1)
        number = int(num_str)
        tokens = tokenize(body.upper())
        next_addr = addr + 4 + len(tokens) + 1
        out += bytes([next_addr & 0xFF, next_addr >> 8,
                      number & 0xFF, number >> 8])
        out += tokens
        out.append(0)
        addr = next_addr
    out += b"\x00\x00"
    return bytes(out)


# Register map (decimal): $DF08=57096 track, $DF09=57097 sector,
# $DF0A=57098 offset, $DF0B=57099 status (write bit0 -> read sector;
# read: bit1 busy, bit2 done, bit3 error), $DF0C=57100 data,
# $DF0E=57102 command (bit0 -> write buffered sector).
PROGRAM = """
10 REM $DF0X SCHREIBTEST + DIAGNOSE
15 PRINT "SCHREIBTEST T35/S16 (DIAG)"
20 POKE 57096,35: POKE 57097,16
30 REM -- PUFFER FUELLEN UND OHNE SD-ZUGRIFF ZURUECKLESEN --
40 FOR I=0 TO 255: POKE 57098,I: POKE 57100,(I+165) AND 255: NEXT
50 B=0: FOR I=0 TO 255: POKE 57098,I
60 IF PEEK(57100)<>((I+165) AND 255) THEN B=B+1
70 NEXT: PRINT "PUFFER-FEHLER (VOR WRITE):";B
80 IF B>0 THEN PRINT "-> CPU-STORE $DF0C DEFEKT": END
90 REM -- SEKTOR SCHREIBEN --
100 POKE 57102,1
110 IF (PEEK(57099) AND 2) THEN 110
120 IF (PEEK(57099) AND 8) THEN PRINT "SCHREIBFEHLER (STATUS BIT3)": END
130 REM -- ZURUECKLESEN --
140 POKE 57099,1
150 IF (PEEK(57099) AND 2) THEN 150
160 F=0: M=0-1: FOR I=0 TO 255: POKE 57098,I
170 IF PEEK(57100)=((I+165) AND 255) THEN M=I: GOTO 190
180 F=F+1
190 NEXT: PRINT "FEHLER:";F;"ERSTER MATCH BEI:";M
200 POKE 57098,0: PRINT "BYTE 0 =";PEEK(57100);
210 POKE 57098,91: PRINT " BYTE 91 =";PEEK(57100)
220 REM -- PARTNERSEKTOR T35/S17 (GLEICHER SD-BLOCK) --
230 POKE 57097,17: POKE 57099,1
240 IF (PEEK(57099) AND 2) THEN 240
250 POKE 57098,0: PRINT "S17 BYTE 0 =";PEEK(57100);
260 POKE 57098,1: PRINT " BYTE 1 =";PEEK(57100)
270 IF F=0 THEN PRINT "SCHREIBTEST OK"
"""


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-o", "--output", type=Path,
                    default=Path("roms/test_d64/writetest.d64"))
    ap.add_argument("--prg", type=Path,
                    default=Path("roms/test_d64/prg/writetest.prg"),
                    help="also write the bare PRG (for the UART loader)")
    args = ap.parse_args()

    builder = D64Builder()
    prg = basic_prg(PROGRAM)
    builder.add_prg("WRITETEST", 0x0801, prg)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(builder.build())
    print(f"wrote {args.output} ({args.output.stat().st_size} bytes, "
          f"PRG {len(prg) + 2} bytes)")

    args.prg.parent.mkdir(parents=True, exist_ok=True)
    args.prg.write_bytes(bytes([0x01, 0x08]) + prg)
    print(f"wrote {args.prg}")


if __name__ == "__main__":
    main()
