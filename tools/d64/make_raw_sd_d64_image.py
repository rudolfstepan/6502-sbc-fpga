#!/usr/bin/env python3
"""Create a raw SD-card image for the Tang MiSTer C64 SD backend.

The hardware SD backend keeps the FPGA small by avoiding FAT32.  It stores one
256-byte D64 sector in the lower half of one 512-byte SD block and ignores the
upper half.  This layout avoids depending on upper-half block reads in the FPGA.
"""

from __future__ import annotations

import argparse
from pathlib import Path


D64_SIZE = 174_848
D64_SECTOR_SIZE = 256
SD_BLOCK_SIZE = 512
D64_SECTORS = D64_SIZE // D64_SECTOR_SIZE
EXPANDED_SIZE = D64_SECTORS * SD_BLOCK_SIZE


def parse_size(text: str) -> int:
    s = text.strip().lower()
    mult = 1
    if s.endswith("k"):
        mult = 1024
        s = s[:-1]
    elif s.endswith("m"):
        mult = 1024 * 1024
        s = s[:-1]
    elif s.endswith("g"):
        mult = 1024 * 1024 * 1024
        s = s[:-1]
    return int(s, 0) * mult


def write_raw_sd_image(d64_path: Path, image_path: Path, image_size: int) -> None:
    """Write an expanded raw SD image for the Tang MiSTer C64 SD backend."""
    d64 = d64_path.read_bytes()
    if len(d64) != D64_SIZE:
        raise ValueError(f"expected {D64_SIZE} bytes, got {len(d64)}")

    if image_size < EXPANDED_SIZE:
        raise ValueError(
            f"image size is smaller than expanded D64 layout ({EXPANDED_SIZE} bytes)"
        )

    image_path.parent.mkdir(parents=True, exist_ok=True)
    with image_path.open("wb") as f:
        for index in range(D64_SECTORS):
            start = index * D64_SECTOR_SIZE
            f.write(d64[start:start + D64_SECTOR_SIZE])
            f.write(b"\xFF" * (SD_BLOCK_SIZE - D64_SECTOR_SIZE))
        f.write(b"\xFF" * (image_size - EXPANDED_SIZE))


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Pack a 35-track .d64 as one D64 sector per SD block."
    )
    ap.add_argument("d64", type=Path, help="input .d64 file, 174848 bytes")
    ap.add_argument("image", type=Path, help="output raw SD image file")
    ap.add_argument(
        "--size",
        default="4M",
        help="output image size, default 4M; suffixes k/m/g are accepted",
    )
    args = ap.parse_args()

    image_size = parse_size(args.size)
    try:
        write_raw_sd_image(args.d64, args.image, image_size)
    except ValueError as exc:
        raise SystemExit(f"ERROR: {exc}") from exc

    print(
        f"wrote {args.image} ({image_size} bytes), "
        f"{D64_SECTORS} D64 sectors at one sector per SD block"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
