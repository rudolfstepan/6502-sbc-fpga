#!/usr/bin/env python3
"""Boot the SD Buildroot filesystem on QEMU RV32 and compile a C program."""
from __future__ import annotations
import subprocess
import time

def wsl_home() -> str:
    result = subprocess.run(
        ["wsl.exe", "--", "sh", "-lc", "printf '%s' ~"],
        check=True, text=True, capture_output=True)
    return result.stdout.strip()

probe = subprocess.run(
    ["wsl.exe", "--", "sh", "-lc", "command -v qemu-system-riscv32"],
    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
if probe.returncode:
    raise SystemExit("QEMU missing; in WSL run: "
                     "sudo apt install -y qemu-system-riscv")

home = wsl_home()
kernel = f"{home}/system16-out-qemu-sd/arch/riscv/boot/Image"
rootfs = f"{home}/system16-buildroot-sd/images/rootfs.ext2"
for path, label in ((kernel, "QEMU kernel"), (rootfs, "SD rootfs")):
    if subprocess.run(["wsl.exe", "--", "test", "-r", path]).returncode:
        raise SystemExit(f"{label} missing: {path}")

cmd = [
    "wsl.exe", "--", "qemu-system-riscv32",
    "-machine", "virt", "-m", "128M", "-smp", "1",
    "-nographic", "-monitor", "none", "-bios", "default",
    "-kernel", kernel,
    "-drive", f"file={rootfs},format=raw,if=none,id=rootfs",
    "-device", "virtio-blk-device,drive=rootfs",
    "-append", ("earlycon=sbi console=ttyS0 root=/dev/vda rw "
                "rootfstype=ext2 rootwait init=/bin/sh"),
]
process = subprocess.Popen(
    cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT, text=True)
assert process.stdin is not None
try:
    # UART input is buffered by QEMU until /bin/sh takes over the console.
    time.sleep(8)
    process.stdin.write(
        "printf 'QEMU_%s_OK\\n' ROOTFS\n"
        "gcc --version | head -n 1\n"
        "printf 'int main(void){return 0;}\\n' > /tmp/qemu-test.c\n"
        "gcc -Os /tmp/qemu-test.c -o /tmp/qemu-test && "
        "/tmp/qemu-test && printf 'QEMU_%s_OK\\n' GCC\n"
        "poweroff -f\n")
    process.stdin.flush()
    output, _ = process.communicate(timeout=90)
except subprocess.TimeoutExpired:
    process.kill()
    output, _ = process.communicate()

print(output, end="")
# The two guest-generated markers are stronger evidence than a particular
# kernel log wording: /bin/sh can print the first only after the requested
# root device became its rootfs, and the second only after native GCC linked
# and executed an RV32 binary from that filesystem.
missing = [marker for marker in ("QEMU_ROOTFS_OK", "QEMU_GCC_OK")
           if marker not in output]
if missing:
    raise SystemExit("QEMU FAIL: missing " + ", ".join(missing))
print("QEMU PASS: SD rootfs mounted and native GCC executed a test program")
