#!/usr/bin/env python3
"""Create a raw System16 SD boot image from a big-endian 68000 binary."""

from __future__ import annotations

import argparse
from pathlib import Path


SECTOR_SIZE = 512
MIN_IMAGE_SIZE = 1024 * 1024
MAGIC = b"SYS16SD1"
SDRAM_BASE = 0x001000
SDRAM_END = 0xF00000


def parse_int(value: str) -> int:
    return int(value, 0)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--load", type=parse_int, default=SDRAM_BASE)
    parser.add_argument("--entry", type=parse_int)
    args = parser.parse_args()

    payload = args.binary.read_bytes()
    if not payload:
        raise SystemExit("input binary is empty")
    if len(payload) & 1:
        payload += b"\x00"

    entry = args.load if args.entry is None else args.entry
    if args.load & 1 or entry & 1:
        raise SystemExit("load and entry addresses must be even")
    if args.load < SDRAM_BASE or args.load + len(payload) > SDRAM_END:
        raise SystemExit("payload does not fit in System16 SDRAM")
    if entry < args.load or entry >= args.load + len(payload):
        raise SystemExit("entry address is outside the payload")

    checksum = sum(payload) & 0xFFFFFFFF
    header = bytearray(SECTOR_SIZE)
    header[0:8] = MAGIC
    header[8:11] = args.load.to_bytes(3, "big")
    header[11:14] = entry.to_bytes(3, "big")
    header[14:18] = len(payload).to_bytes(4, "big")
    header[18:22] = checksum.to_bytes(4, "big")

    image = header + payload
    padded_size = max(MIN_IMAGE_SIZE, (len(image) + SECTOR_SIZE - 1) // SECTOR_SIZE * SECTOR_SIZE)
    image.extend(bytes(padded_size - len(image)))
    args.output.write_bytes(image)
    print(
        f"created {args.output}: load=${args.load:06X}, entry=${entry:06X}, "
        f"payload={len(payload)} bytes, checksum=${checksum:08X}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
