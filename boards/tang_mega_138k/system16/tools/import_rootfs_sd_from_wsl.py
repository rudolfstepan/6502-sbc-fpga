#!/usr/bin/env python3
"""Import Buildroot's SD ext2 filesystem from WSL."""
from __future__ import annotations
import argparse
import subprocess
from pathlib import Path

DEFAULT_SOURCE = "~/system16-buildroot-sd/images/rootfs.ext2"

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=Path)
    parser.add_argument("--source", default=None)
    args = parser.parse_args()

    home_result = subprocess.run(
        ["wsl.exe", "--", "sh", "-lc", "printf '%s' ~"],
        check=True, text=True, capture_output=True)
    home = home_result.stdout.strip()
    if not home.startswith("/"):
        raise SystemExit(f"cannot determine WSL home directory: {home!r}")

    if args.source:
        source_arg = args.source
        if source_arg.startswith("~/"):
            source_arg = home + source_arg[1:]
        candidates = (source_arg,)
    else:
        # Recognize both the current out-of-tree build and older experiments.
        candidates = (
            f"{home}/system16-buildroot-sd/images/rootfs.ext2",
            f"{home}/system16-buildroot-sd/images/rootfs.ext4",
            f"{home}/buildroot-2025.02/output/images/rootfs.ext2",
            f"{home}/buildroot-2025.02/output/images/rootfs.ext4",
        )
    source = next((candidate for candidate in candidates
                   if subprocess.run(
                       ["wsl.exe", "--", "test", "-r", candidate]
                   ).returncode == 0), None)
    if source is None:
        expected = args.source or DEFAULT_SOURCE
        raise SystemExit(
            "SD root filesystem not found in WSL. Expected " + expected +
            "\nRun 'make rootfs-sd-wsl' first and check its first error; "
            "then verify with:\n  "
            "wsl ls -lh ~/system16-buildroot-sd/images/")
    args.destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.destination.with_suffix(args.destination.suffix + ".tmp")
    try:
        with temporary.open("wb") as output:
            result = subprocess.run(
                ["wsl.exe", "--", "cat", source],
                stdout=output)
        if result.returncode:
            raise SystemExit(f"failed to import WSL file {source}")
        temporary.replace(args.destination)
    finally:
        if temporary.exists():
            temporary.unlink()
    print(f"imported {args.destination} "
          f"({args.destination.stat().st_size} bytes)")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
