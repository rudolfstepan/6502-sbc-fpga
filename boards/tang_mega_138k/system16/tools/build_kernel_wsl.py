#!/usr/bin/env python3
"""Run the profile-aware Linux build script inside WSL."""
from __future__ import annotations
import argparse
import subprocess
from pathlib import Path

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("profile", choices=("flash", "sd", "rescue", "qemu-sd"))
    args = parser.parse_args()
    script = Path(__file__).resolve().parent.parent / "linux" / "build-kernel.sh"
    command = (f"chmod +x \"$(wslpath '{script.as_posix()}')\" && "
               f"\"$(wslpath '{script.as_posix()}')\" {args.profile}")
    return subprocess.run(["wsl.exe", "--", "sh", "-lc", command]).returncode

if __name__ == "__main__":
    raise SystemExit(main())
