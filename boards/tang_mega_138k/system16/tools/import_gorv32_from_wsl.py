#!/usr/bin/env python3
"""Import the GoRV32 Plus Linux artifacts from WSL and compile the DTB."""
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
    p.add_argument("--opensbi",
                   default="~/opensbi-system16/build-gorv32/platform/generic/firmware")
    p.add_argument("--linux", default="~/system16-out")
    p.add_argument("--dts", default="gorv32plus.dts",
                   help="DTS filename below linux/, or an absolute path")
    p.add_argument("--dtb-name", default="gorv32plus.dtb")
    a = p.parse_args()
    info = wsl("sh", "-lc",
               f"riscv64-linux-gnu-readelf -h {a.opensbi}/fw_jump.elf; "
               f"test -r {a.opensbi}/fw_jump.bin; "
               f"test -r {a.linux}/arch/riscv/boot/Image").stdout
    match = re.search(r"Entry point address:\s*(0x[0-9a-fA-F]+)", info)
    if not match or int(match.group(1), 16) != 0x0:
        got = match.group(1) if match else "unknown"
        raise SystemExit(f"OpenSBI entry is {got}, expected 0x0 for GoRV32; "
                         "run build_opensbi_gorv32_wsl.py first")
    a.destination.mkdir(parents=True, exist_ok=True)
    dts_arg = Path(a.dts)
    dts_path = dts_arg if dts_arg.is_absolute() else (
        Path(__file__).resolve().parent.parent / "linux" / dts_arg)
    dts = dts_path.as_posix()
    dtb = wsl("sh", "-lc",
              f"dtc -i \"$(wslpath '{dts_path.parent.as_posix()}')\" "
              f"-I dts -O dtb \"$(wslpath '{dts}')\"", text=False).stdout
    (a.destination / a.dtb_name).write_bytes(dtb)
    print(f"compiled {a.dtb_name} ({len(dtb)} bytes)")
    for name, source in (("fw_jump.bin", f"{a.opensbi}/fw_jump.bin"),
                         ("Image", f"{a.linux}/arch/riscv/boot/Image")):
        data = wsl("sh", "-lc", f"cat {source}", text=False).stdout
        (a.destination / name).write_bytes(data)
        print(f"imported {name} ({len(data)} bytes)")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
