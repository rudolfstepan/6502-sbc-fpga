#!/usr/bin/env python3
"""Extract a named PRG from a D64 image, following the file block chain.

This is the host-side reference for the 6502 PRG loader: it follows the
track/sector chain, honours the last-sector byte count, and emits a standard
.prg file (2-byte little-endian load address + payload).

Usage:
  python tools/d64/extract_prg.py roms/test_d64/testdisk.d64 HELLO out/hello.prg
"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from d64_common import SECTOR_SIZE, d64_byte_offset  # noqa: E402
from list_d64 import iter_entries  # noqa: E402

MAX_BLOCKS = 683  # abort runaway chains (whole 35-track disk)


def read_sector(data: bytes, track: int, sector: int) -> bytes:
    off = d64_byte_offset(track, sector)
    if off == 0xFFFFFFFF:
        raise ValueError(f"invalid T{track}/S{sector} in file chain")
    return data[off : off + SECTOR_SIZE]


def follow_chain(data: bytes, track: int, sector: int) -> bytes:
    """Return the raw PRG body (including 2-byte load address)."""
    out = bytearray()
    count = 0
    while True:
        if count >= MAX_BLOCKS:
            raise ValueError("file chain too long (corrupt?)")
        sec = read_sector(data, track, sector)
        next_t, next_s = sec[0], sec[1]
        if next_t == 0:
            # last block: next_s = index of final valid byte (payload ends there)
            last = next_s
            if last < 2:
                break
            out += sec[2 : last + 1]
            break
        out += sec[2:SECTOR_SIZE]
        track, sector = next_t, next_s
        count += 1
    return bytes(out)


def find_file(data: bytes, name: str):
    target = name.upper()
    for e in iter_entries(data):
        if e["name"].upper() == target:
            return e
    return None


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("name")
    parser.add_argument("output", type=Path)
    args = parser.parse_args(argv)

    data = args.image.read_bytes()
    entry = find_file(data, args.name)
    if entry is None:
        print(f"file not found: {args.name}", file=sys.stderr)
        return 1

    body = follow_chain(data, entry["first_track"], entry["first_sector"])
    load_addr = body[0] | (body[1] << 8)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(body)
    print(
        f'Extracted "{entry["name"]}" load=${load_addr:04X} '
        f"payload={len(body) - 2} bytes -> {args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
