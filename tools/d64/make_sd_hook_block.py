#!/usr/bin/env python3
"""Emit the raw C64HOOK1 boot block for an SD card.

Builds the same header+code block that make_fat16_d64_card.py embeds with
--hook-image, but writes it to a plain file so it can be copied onto an
already formatted card at LBA 8 (see tools/write_sd_hook_block.ps1) without
touching the FAT16 filesystem or the .d64 files on it.

Usage:
    python tools/d64/make_sd_hook_block.py -o build/sd_hook_block.bin \
        roms/diagnostics/sd_fastload_hook.prg
"""

from __future__ import annotations

import argparse
from pathlib import Path

from make_fat16_d64_card import build_hook_block


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prg", type=Path, help="hook PRG with .segments.json next to it")
    parser.add_argument("-o", "--output", type=Path, required=True)
    args = parser.parse_args()

    block = build_hook_block(args.prg)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(block)
    print(f"wrote {args.output} ({len(block)} bytes, "
          f"{(len(block) + 511) // 512} SD blocks)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
