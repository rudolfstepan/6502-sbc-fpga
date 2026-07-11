#!/usr/bin/env python3
"""Combine a GRV1 boot container and an ext2 rootfs into one SD image."""
from __future__ import annotations
import argparse
import shutil
from pathlib import Path

SECTOR_SIZE = 512
DEFAULT_ROOT_LBA = 32768

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("boot", type=Path)
    parser.add_argument("rootfs", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--root-lba", type=int, default=DEFAULT_ROOT_LBA)
    args = parser.parse_args()
    boot_size = args.boot.stat().st_size
    root_offset = args.root_lba * SECTOR_SIZE
    if boot_size > root_offset:
        raise SystemExit(f"boot container ({boot_size} bytes) overlaps rootfs "
                         f"at byte {root_offset}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("wb") as dst, args.boot.open("rb") as src:
        shutil.copyfileobj(src, dst)
        dst.seek(root_offset)
        with args.rootfs.open("rb") as root:
            shutil.copyfileobj(root, dst)
    print(f"created {args.output} ({args.output.stat().st_size} bytes)")
    print(f"  GRV1:  LBA 0..{(boot_size + 511) // 512 - 1}")
    print(f"  ext2:  LBA {args.root_lba} ({args.rootfs.stat().st_size} bytes)")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
