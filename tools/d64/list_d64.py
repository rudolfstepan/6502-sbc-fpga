#!/usr/bin/env python3
"""Parse and print the directory of a D64 image (host-side reference reader).

This mirrors what the FPGA d64_drive / 6502 directory reader must do:
  - read BAM (track 18, sector 0) for the disk name
  - follow the directory chain starting at track 18, sector 1
  - decode 32-byte entries into type / size / name

Usage:  python tools/d64/list_d64.py roms/test_d64/testdisk.d64
"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from d64_common import (  # noqa: E402
    BAM_SECTOR,
    DIR_TRACK,
    SECTOR_SIZE,
    d64_byte_offset,
    is_supported_size,
)

FILE_TYPES = {0: "DEL", 1: "SEQ", 2: "PRG", 3: "USR", 4: "REL"}


def read_sector(data: bytes, track: int, sector: int) -> bytes:
    off = d64_byte_offset(track, sector)
    return data[off : off + SECTOR_SIZE]


def decode_name(raw: bytes) -> str:
    # Strip trailing $A0 padding; render printable ASCII subset.
    name = raw.rstrip(b"\xa0")
    return "".join(chr(b) if 0x20 <= b < 0x7F else "." for b in name)


def disk_name(data: bytes) -> str:
    bam = read_sector(data, DIR_TRACK, BAM_SECTOR)
    return decode_name(bam[0x90 : 0x90 + 16])


def iter_entries(data: bytes):
    track, sector = DIR_TRACK, 1
    seen = set()
    while track != 0:
        if (track, sector) in seen:
            raise ValueError("directory chain loop detected")
        seen.add((track, sector))
        sec = read_sector(data, track, sector)
        for j in range(8):
            entry = sec[2 + j * 32 : 2 + j * 32 + 32]
            ftype = entry[0]
            if ftype == 0:
                continue  # deleted / empty slot
            yield {
                "type_byte": ftype,
                "type": FILE_TYPES.get(ftype & 0x07, "???"),
                "closed": bool(ftype & 0x80),
                "first_track": entry[1],
                "first_sector": entry[2],
                "name": decode_name(entry[3:19]),
                "blocks": entry[30] | (entry[31] << 8),
            }
        track, sector = sec[0], sec[1]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    args = parser.parse_args(argv)

    data = args.image.read_bytes()
    if not is_supported_size(len(data)):
        print(f"WARNING: unsupported image size {len(data)} (expected 174848)")

    print(f'Disk name: {disk_name(data)}')
    print("Files:")
    for e in iter_entries(data):
        print(
            f"  {e['blocks']:4d}  {e['type']}  "
            f'"{e["name"]}"  @ T{e["first_track"]}/S{e["first_sector"]}'
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
