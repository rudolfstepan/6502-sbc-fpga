#!/usr/bin/env python3
"""Pack a set of .prg files into a 35-track D64 image.

Each input .prg is a standard PRG: 2-byte little-endian load address followed by
the program bytes.  The D64 directory name is derived from the file stem
(uppercased, truncated to 16 chars).  Output is a standard 174848-byte image the
FPGA GoDrive can mount.

Usage:
  python tools/d64/pack_d64.py -o roms/test_d64/testdisk.d64 a.prg b.prg ...
  python tools/d64/pack_d64.py -o disk.d64 --name TUNES a.prg b.prg
"""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from create_test_d64 import D64Builder  # noqa: E402
from d64_common import D64_35_TRACK_SIZE  # noqa: E402


def d64_name(stem: str) -> str:
    out = []
    for ch in stem.upper():
        if ch.isalnum() or ch in " _-.":
            out.append(ch)
        else:
            out.append("_")
    return "".join(out)[:16]


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-o", "--output", type=Path, required=True)
    ap.add_argument("prg", nargs="+", type=Path, help="input .prg files")
    ap.add_argument("--name", default=None,
                    help="override the directory name for a single PRG")
    args = ap.parse_args(argv)

    b = D64Builder()
    for i, p in enumerate(args.prg):
        data = p.read_bytes()
        if len(data) < 3:
            raise SystemExit(f"{p}: too small to be a PRG")
        load = data[0] | (data[1] << 8)
        payload = data[2:]
        name = d64_name(args.name) if (args.name and len(args.prg) == 1) \
            else d64_name(p.stem)
        b.add_prg(name, load, payload)
        print(f"  +{name:16s} load=${load:04X} {len(payload)} bytes")

    img = b.build()
    assert len(img) == D64_35_TRACK_SIZE
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(img)
    print(f"Wrote {args.output} ({len(img)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
