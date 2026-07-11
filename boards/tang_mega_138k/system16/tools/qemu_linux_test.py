#!/usr/bin/env python3
"""Boot the WSL-built RV32 kernel on QEMU virt and check early console output."""
from __future__ import annotations
import subprocess
import sys

CHECK = "Linux version"
probe = subprocess.run(
    ["wsl.exe", "--", "sh", "-lc", "command -v qemu-system-riscv32"],
    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
if probe.returncode:
    raise SystemExit("QEMU missing; in WSL run: sudo apt update && "
                     "sudo apt install -y qemu-system-riscv")

cmd = ["wsl.exe", "--", "sh", "-lc", "exec qemu-system-riscv32 "
       "-machine virt -m 128M -smp 1 -nographic -monitor none "
       "-bios default -kernel ~/system16-out/arch/riscv/boot/Image "
       "-append 'earlycon=sbi console=ttyS0 loglevel=8'"]
try:
    run = subprocess.run(cmd, text=True, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, timeout=35)
except subprocess.TimeoutExpired as e:
    output = e.stdout or ""
    if isinstance(output, bytes):
        output = output.decode(errors="replace")
else:
    output = run.stdout
print(output, end="")
if CHECK not in output:
    raise SystemExit("QEMU FAIL: kernel produced no 'Linux version' message")
print("QEMU PASS: RV32 kernel reached Linux early console")
