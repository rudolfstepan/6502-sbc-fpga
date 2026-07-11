#!/usr/bin/env python3
"""Import and validate System16 Linux artifacts from the default WSL distro."""
from __future__ import annotations
import argparse
import re
import subprocess
from pathlib import Path

def wsl(*args: str, text: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["wsl.exe", "--", *args], check=True,
                          text=text, capture_output=True)

def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("destination", type=Path)
    p.add_argument("--opensbi", default="~/opensbi-system16/build/platform/generic/firmware")
    p.add_argument("--linux", default="~/system16-out")
    a = p.parse_args()
    cmd = (f"riscv64-linux-gnu-readelf -h {a.opensbi}/fw_jump.elf; "
           f"test -r {a.opensbi}/fw_jump.bin; "
           f"test -r {a.linux}/system16-rv32.dtb; "
           f"test -r {a.linux}/arch/riscv/boot/Image")
    info = wsl("sh", "-lc", cmd).stdout
    match = re.search(r"Entry point address:\s*(0x[0-9a-fA-F]+)", info)
    if not match or int(match.group(1), 16) != 0x2000:
        got = match.group(1) if match else "unknown"
        raise SystemExit(f"OpenSBI entry is {got}, expected 0x2000; rebuild it first")
    a.destination.mkdir(parents=True, exist_ok=True)
    files = {"fw_jump.bin": f"{a.opensbi}/fw_jump.bin",
             "system16-rv32.dtb": f"{a.linux}/system16-rv32.dtb",
             "arch/riscv/boot/Image": f"{a.linux}/arch/riscv/boot/Image"}
    for name, source in files.items():
        data = wsl("sh", "-lc", f"cat {source}", text=False).stdout
        target = a.destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        print(f"imported {name} ({len(data)} bytes)")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
