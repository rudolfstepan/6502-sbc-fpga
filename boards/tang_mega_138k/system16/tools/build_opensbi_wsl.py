#!/usr/bin/env python3
"""Build OpenSBI in WSL for the legacy-privilege VexRiscv System16 core."""
import subprocess

script = r'''
set -eu
cd ~/opensbi-system16
python3 -c 'from pathlib import Path
p=Path("firmware/fw_base.S")
s=p.read_text()
marker="System16 VexRiscv implements the pre-MDT"
if marker not in s:
    lines=s.splitlines(keepends=True)
    found=False
    for i in range(len(lines)-3):
        if (lines[i].strip()=="#if __riscv_xlen == 32" and
            "MSTATUSH_MDT" in lines[i+1] and
            "CSR_MSTATUSH" in lines[i+2] and
            lines[i+3].strip()=="#else"):
            nl="\n" if lines[i].endswith("\n") else ""
            lines[i:i+4]=[
                "#if __riscv_xlen == 32"+nl,
                "\t/* "+marker+" privilege architecture. */"+nl,
                "\t/* No mstatush access: MDT and virtualization are not implemented. */"+nl,
                "#else"+nl]
            found=True
            break
    if not found:
        raise SystemExit("unexpected fw_base.S: CLEAR_MDT block not found")
    p.write_text("".join(lines))'
make distclean
make CROSS_COMPILE=riscv64-linux-gnu- PLATFORM=generic \
  PLATFORM_RISCV_XLEN=32 PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei \
  FW_TEXT_START=0x00002000 FW_JUMP=y FW_JUMP_ADDR=0x00400000 \
  FW_JUMP_FDT_ADDR=0x003f0000 -j"$(nproc)"
riscv64-linux-gnu-objdump -d build/platform/generic/firmware/fw_jump.elf \
  --start-address=0x20b8 --stop-address=0x20c8
'''
raise SystemExit(subprocess.run(["wsl.exe", "--", "sh", "-lc", script]).returncode)
