#!/usr/bin/env python3
"""Build C64 UART-loadable RUN PRGs for every convertible SID tune.

The generated PRGs use ``tools/build_sid_prg.py --target c64``. That target
adds a BASIC ``10 SYS ...`` line at $0801, so each file can be uploaded with
``tools/c64_uart_prg_loader.py`` and started with ``RUN``.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sid-dir", type=Path, default=ROOT / "sid_orig")
    ap.add_argument("--out-dir", type=Path, default=ROOT / "roms" / "c64_uart_sid")
    ap.add_argument("--python", default=sys.executable)
    ap.add_argument("--ca65", default="C:/tools/cc65/bin/ca65")
    ap.add_argument("--ld65", default="C:/tools/cc65/bin/ld65")
    ap.add_argument("--quiet", action="store_true", help="only print summary and failures")
    args = ap.parse_args()

    sids = sorted(args.sid_dir.glob("*.sid"))
    if not sids:
        raise SystemExit(f"ERROR: no .sid files found in {args.sid_dir}")

    args.out_dir.mkdir(parents=True, exist_ok=True)
    built: list[Path] = []
    failed: list[tuple[str, str]] = []
    builder = ROOT / "tools" / "build_sid_prg.py"

    for sid in sids:
        out = args.out_dir / f"{sid.stem}.prg"
        result = subprocess.run(
            [
                args.python,
                str(builder),
                str(sid),
                str(out),
                "--target",
                "c64",
                "--ca65",
                args.ca65,
                "--ld65",
                args.ld65,
            ],
            capture_output=True,
            text=True,
        )
        text = (result.stdout + result.stderr).strip()
        if result.returncode == 0:
            built.append(out)
            if not args.quiet and text:
                print(text)
        else:
            why = text.splitlines()[-1] if text else f"exit code {result.returncode}"
            failed.append((sid.name, why))
            if not args.quiet:
                print(f"SKIP {sid.name}: {why}")

    print(f"\nBuilt {len(built)} C64 SID PRG(s), skipped {len(failed)} of {len(sids)} SID(s).")
    if failed:
        print("\nSkipped:")
        for name, why in failed:
            print(f"  {name:42s} {why}")
    print(f"\nPRGs -> {args.out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
