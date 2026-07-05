#!/usr/bin/env python3
"""Write a sparse UART-upload segment map for the C64 virtual-1541 loaders."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

SEGMENT_FORMAT = "c64-uart-prg-segments-v1"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prg", type=Path)
    parser.add_argument("--code-address", type=lambda s: int(s, 0), default=0xC000)
    parser.add_argument("--stub-size", type=lambda s: int(s, 0), default=0x0010)
    args = parser.parse_args(argv)

    raw = args.prg.read_bytes()
    if len(raw) < 2 + args.stub_size:
        raise SystemExit(f"ERROR: {args.prg} is too small")
    load_addr = raw[0] | (raw[1] << 8)
    sparse_code_offset = 2 + (args.code_address - load_addr)
    compact_code_offset = 2 + args.stub_size
    if 2 <= sparse_code_offset < len(raw):
        code_offset = sparse_code_offset
    elif compact_code_offset < len(raw):
        code_offset = compact_code_offset
    else:
        raise SystemExit(f"ERROR: could not locate code payload in {args.prg}")
    code_size = len(raw) - code_offset
    meta = {
        "format": SEGMENT_FORMAT,
        "source": args.prg.name,
        "load_address": load_addr,
        "entry": args.code_address,
        "basic_end": load_addr + args.stub_size,
        "prg_size": len(raw),
        "upload_size": args.stub_size + code_size,
        "segments": [
            {
                "name": "BASIC RUN stub",
                "address": load_addr,
                "offset": 2,
                "size": args.stub_size,
            },
            {
                "name": "V1541 loader",
                "address": args.code_address,
                "offset": code_offset,
                "size": code_size,
            },
        ],
    }
    args.prg.with_suffix(args.prg.suffix + ".segments.json").write_text(
        json.dumps(meta, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
