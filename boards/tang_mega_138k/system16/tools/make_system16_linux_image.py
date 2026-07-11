#!/usr/bin/env python3
"""Pack OpenSBI, DTB and an RV32 Linux Image into a System16 raw SD image."""
from __future__ import annotations
import argparse
from pathlib import Path

SECTOR = 512
MAGIC = b"SYS16SD1"
LOAD = 0x001000
SHIM = 0x001000
SBI = 0x002000
DTB = 0x3F0000
KERNEL = 0x400000
END = 0xF00000

def put(image: bytearray, address: int, data: bytes, name: str) -> None:
    offset = address - LOAD
    if offset < 0 or address + len(data) > END:
        raise SystemExit(f"{name} does not fit in System16 SDRAM")
    image[offset:offset + len(data)] = data

def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("opensbi", type=Path)
    p.add_argument("dtb", type=Path)
    p.add_argument("kernel", type=Path)
    p.add_argument("output", type=Path)
    a = p.parse_args()
    # RV32 little-endian reset shim. Emit 'S' directly through the 16550 THR
    # first, then pass the generic OpenSBI boot arguments:
    #   lui t1,0xf0000; li t2,'S'; sb t2,0(t1)
    #   li a0,0; lui a1,0x3f0; lui t0,0x2; jr t0
    # Generic OpenSBI needs hartid in a0 and the input FDT address in a1.
    shim = bytes.fromhex(
        "370300f0 93033005 23007300 "
        "13050000 b7053f00 b7220000 67800200"
    )
    blobs = [(shim, SHIM, "shim"),
             (a.opensbi.read_bytes(), SBI, "OpenSBI"),
             (a.dtb.read_bytes(), DTB, "DTB"),
             (a.kernel.read_bytes(), KERNEL, "kernel")]
    payload_end = max(addr + len(data) for data, addr, _ in blobs)
    payload = bytearray(payload_end - LOAD)
    for data, addr, name in blobs:
        put(payload, addr, data, name)
    if len(payload) & 1:
        payload.append(0)
    header = bytearray(SECTOR)
    header[:8] = MAGIC
    header[8:11] = LOAD.to_bytes(3, "big")
    header[11:14] = SHIM.to_bytes(3, "big")
    header[14:18] = len(payload).to_bytes(4, "big")
    header[18:22] = (sum(payload) & 0xFFFFFFFF).to_bytes(4, "big")
    raw = header + payload
    raw.extend(bytes((-len(raw)) % SECTOR))
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_bytes(raw)
    print(f"created {a.output} ({len(raw)} bytes)")
    for data, addr, name in blobs:
        print(f"  {name:7} ${addr:06X}-${addr+len(data)-1:06X} ({len(data)} bytes)")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
