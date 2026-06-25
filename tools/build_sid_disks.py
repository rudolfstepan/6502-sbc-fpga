#!/usr/bin/env python3
"""Convert every convertible PSID tune to a RAM PRG and pack them into one or
more D64 images.

Each tune is wrapped by build_sid_prg.py (entry = load address; the kernel/BASIC
loader prints the CALL address).  Tunes that cannot run in this machine's RAM
(load into $A000+/$E000, IRQ/CIA-driven with no play address, or too large) are
skipped.  PRGs are distributed across numbered D64 images, each filled up to the
35-track capacity.

Usage:
  python tools/build_sid_disks.py            # -> roms/test_d64/sid/tunesNN.d64
  python tools/build_sid_disks.py --out-dir roms/test_d64/sid --prefix tunes
"""
from __future__ import annotations

from pathlib import Path
import argparse
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(ROOT / "tools" / "d64"))

from build_native_sid_rom import parse_payload, SidUnsupported  # noqa: E402
from create_test_d64 import D64Builder  # noqa: E402
from d64_common import D64_35_TRACK_SIZE, sectors_per_track  # noqa: E402
from pack_d64 import d64_name  # noqa: E402

VIC_BITMAP = 0x6000
# Usable data blocks on a 35-track disk minus the directory track (18).
USABLE_BLOCKS = sum(sectors_per_track(t) for t in range(1, 36)) \
    - sectors_per_track(18)   # 683 - 19 = 664


def convertible_base(info: dict) -> int | None:
    """Return the auto PRG base for a tune, or None if it cannot run in RAM."""
    load = info["load"]
    pad_end = load + info["pages"] * 256
    base = max(0x2000, (pad_end + 0xFF) & ~0xFF) if load < VIC_BITMAP else 0x2000
    if not (pad_end <= base or load >= VIC_BITMAP):
        return None
    if base + 64 + info["pages"] * 256 > VIC_BITMAP:
        return None
    return base


def prg_blocks(prg_path: Path) -> int:
    """Directory block count a PRG will occupy (254 payload bytes per block)."""
    n = prg_path.stat().st_size           # includes 2-byte load address
    return max(1, (n + 253) // 254)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sid-dir", type=Path, default=ROOT / "sid_orig")
    ap.add_argument("--out-dir", type=Path, default=ROOT / "roms" / "test_d64" / "sid")
    ap.add_argument("--prg-dir", type=Path,
                    default=ROOT / "roms" / "test_d64" / "sid" / "prg")
    ap.add_argument("--prefix", default="tunes")
    ap.add_argument("--python", default=sys.executable)
    args = ap.parse_args(argv)

    args.prg_dir.mkdir(parents=True, exist_ok=True)
    args.out_dir.mkdir(parents=True, exist_ok=True)

    # 1. Convert every convertible tune to a PRG.
    prgs: list[Path] = []
    skipped = 0
    for sid in sorted(args.sid_dir.glob("*.sid")):
        try:
            info = parse_payload(sid.read_bytes())
        except SidUnsupported:
            skipped += 1
            continue
        if convertible_base(info) is None:
            skipped += 1
            continue
        out = args.prg_dir / (sid.stem + ".prg")
        r = subprocess.run(
            [args.python, str(ROOT / "tools" / "build_sid_prg.py"),
             str(sid), str(out)],
            capture_output=True, text=True)
        if r.returncode != 0:
            skipped += 1
            continue
        prgs.append(out)
    print(f"Converted {len(prgs)} tunes, skipped {skipped}.")

    # 2. Distribute PRGs across D64 images, filling each up to USABLE_BLOCKS.
    disk_idx = 0
    builder = D64Builder()
    used = 0
    count = 0

    def flush() -> None:
        nonlocal builder, used, disk_idx, count
        if count == 0:
            return
        img = builder.build()
        assert len(img) == D64_35_TRACK_SIZE
        out = args.out_dir / f"{args.prefix}{disk_idx:02d}.d64"
        out.write_bytes(img)
        print(f"  {out.name}: {count} tunes, {used} blocks")
        disk_idx += 1
        builder = D64Builder()
        used = 0
        count = 0

    for p in prgs:
        blocks = prg_blocks(p)
        if used + blocks > USABLE_BLOCKS:
            flush()
        data = p.read_bytes()
        load = data[0] | (data[1] << 8)
        builder.add_prg(d64_name(p.stem), load, data[2:])
        used += blocks
        count += 1
    flush()

    print(f"Wrote {disk_idx} disk image(s) to {args.out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
