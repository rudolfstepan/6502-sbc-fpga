#!/usr/bin/env python3
"""Build a tiny D64 with real C64 BASIC V2 PRGs.

The existing FPGA/SBC test D64s may contain PRGs for the custom 6502 SBC.  This
helper creates plain C64-loadable BASIC programs at $0801 so the MiSTer C64 IEC
path can be tested with LOAD/RUN without external tools.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from create_test_d64 import D64Builder  # noqa: E402
from d64_common import D64_35_TRACK_SIZE  # noqa: E402


TOK_END = 0x80
TOK_NEXT = 0x82
TOK_FOR = 0x81
TOK_GOTO = 0x89
TOK_PRINT = 0x99
TOK_TO = 0xA4


def basic_prg(lines: list[tuple[int, bytes]]) -> bytes:
    """Return a standard C64 BASIC PRG including the $0801 load address."""
    load = 0x0801
    out = bytearray([load & 0xFF, load >> 8])
    addr = load
    encoded = []

    for number, body in lines:
        next_addr = addr + 4 + len(body) + 1
        encoded.append((next_addr, number, body))
        addr = next_addr

    for next_addr, number, body in encoded:
        out += bytes([
            next_addr & 0xFF,
            (next_addr >> 8) & 0xFF,
            number & 0xFF,
            (number >> 8) & 0xFF,
        ])
        out += body
        out.append(0)

    out += b"\x00\x00"
    return bytes(out)


def b(text: str) -> bytes:
    return text.encode("ascii")


def hello_prg() -> bytes:
    return basic_prg([
        (10, bytes([TOK_PRINT]) + b(' "HELLO FROM C64 BASIC"')),
        (20, bytes([TOK_END])),
    ])


def count_prg() -> bytes:
    return basic_prg([
        (10, b("A=A+1:") + bytes([TOK_PRINT]) + b(" A:") + bytes([TOK_GOTO]) + b(" 10")),
    ])


def color_prg() -> bytes:
    return basic_prg([
        (10, b("POKE 53280,0:POKE 53281,6")),
        (20, bytes([TOK_PRINT]) + b(' "BORDER OK"')),
        (30, bytes([TOK_END])),
    ])


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=Path("roms/test_d64/c64_basic_testdisk.d64"),
    )
    args = parser.parse_args(argv)

    builder = D64Builder()
    for name, prg in (
        ("HELLO", hello_prg()),
        ("COUNT", count_prg()),
        ("COLOR", color_prg()),
    ):
        load = prg[0] | (prg[1] << 8)
        builder.add_prg(name, load, prg[2:])
        print(f"  +{name:16s} load=${load:04X} {len(prg) - 2} bytes")

    image = builder.build()
    assert len(image) == D64_35_TRACK_SIZE
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(image)
    print(f"Wrote {args.output} ({len(image)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
