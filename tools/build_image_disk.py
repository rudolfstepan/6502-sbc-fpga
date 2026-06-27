#!/usr/bin/env python3
"""Build a D64 that displays a 320x240 16-colour image on the FPGA.

Pipeline:
  1. img2hires.py --color16  converts the source image to 38400 bytes
     (320x240, 4bpp, 2 px/byte).
  2. The data is split into five framebuffer-bank parts: IMG0..IMG3 = 8192 bytes,
     IMG4 = 5632 bytes.  Each part is a PRG whose load address is the $6000
     bitmap window, so DISK_LOAD drops it straight into fb_ram.
  3. show_image.s is assembled at $2000 (the loader) and packed with the five
     parts into a single D64.

On the board:
  LOAD "!"          (pick/mount this D64 if it is not already mounted)
  LOAD "SHOWIMG"
  CALL 8192

Usage:
  python tools/build_image_disk.py ich.png -o roms/ich_image.d64
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SW = ROOT / "sw"
BANK = 8192
FB_BASE = 0x6000


def run(cmd, **kw):
    print("  $", " ".join(str(c) for c in cmd))
    subprocess.run(cmd, check=True, **kw)


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image")
    ap.add_argument("-o", "--output", type=Path, default=ROOT / "roms" / "ich_image.d64")
    ap.add_argument("--saturation", type=float, default=1.1)
    ap.add_argument("--contrast", type=float, default=1.08)
    ap.add_argument("--keep", action="store_true", help="keep intermediate .prg files")
    args = ap.parse_args(argv)

    work = ROOT / "roms" / "_imgdisk"
    work.mkdir(parents=True, exist_ok=True)
    base = work / "img"

    # 1. convert -> 38400-byte color16 framebuffer
    run([sys.executable, str(ROOT / "tools" / "img2hires.py"), args.image,
         "--out", str(base), "--color16",
         "--saturation", str(args.saturation), "--contrast", str(args.contrast)])
    data = (Path(str(base) + "_c16.bin")).read_bytes()
    assert len(data) == 38400, f"expected 38400 bytes, got {len(data)}"

    # 2. split into 5 bank parts, each prefixed with the $6000 load address
    parts = []
    for i in range(5):
        chunk = data[i * BANK:(i + 1) * BANK]
        prg = work / f"img{i}.prg"
        prg.write_bytes(bytes([FB_BASE & 0xFF, FB_BASE >> 8]) + chunk)
        parts.append(prg)
        print(f"  IMG{i}: {len(chunk)} bytes -> {prg.name}")

    # 3. assemble the loader at $2000 and make showimg.prg
    obj = work / "show_image.o"
    raw = work / "show_image.bin"
    run(["ca65", "--cpu", "65c02", "-o", str(obj), str(SW / "show_image.s")])
    run(["ld65", "-C", str(SW / "prg2000.cfg"), "-o", str(raw), str(obj)])
    loader = work / "showimg.prg"
    loader.write_bytes(bytes([0x00, 0x20]) + raw.read_bytes())   # load addr $2000
    print(f"  loader: {raw.stat().st_size} bytes -> {loader.name}")

    # 4. pack the D64 (loader first so it lists at the top)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    run([sys.executable, str(ROOT / "tools" / "d64" / "pack_d64.py"),
         "-o", str(args.output), str(loader), *[str(p) for p in parts]])
    print(f"\nDisk ready: {args.output}")
    print("On the board:  LOAD \"!\"  ->  LOAD \"SHOWIMG\"  ->  CALL 8192")

    if not args.keep:
        for f in (obj, raw):
            f.unlink(missing_ok=True)


if __name__ == "__main__":
    main(sys.argv[1:])
