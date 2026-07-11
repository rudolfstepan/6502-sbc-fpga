#!/usr/bin/env python3
"""Pack OpenSBI, DTB and kernel into a GRV1 image for the GoRV32 ZSBL.

One artifact serves both boot sources: burned at flash offset 0x510000 as
the normal source, or written raw to an SD card starting at LBA 0 as the
fallback. The ZSBL reads flash through the QSPI XIP window at 0x80010000 (base =
Flash_Burn_Address 0x500000; the Tang Console 138K flash is an 8 MB
XT25F64B). Format (little-endian u32):
  +0x00 magic "GRV1"
  +0x04 record count
  +0x08 u32 sum over every padded payload word
  +0x0C records: src_off (relative to image start), dst, len
  payload, each record aligned to a 512-byte boundary so the SD path can
  read whole sectors straight to the destination
"""
from __future__ import annotations
import argparse
import struct
from pathlib import Path

MAGIC = 0x31565247  # "GRV1"
SDRAM_SIZE = 0x1000000       # 16 MB DDR window backed by SDRAM0
# Flash space from 0x510000 to the 8 MB chip end; reads past the chip end
# would wrap onto the bitstream.
XIP_PAYLOAD_MAX = 0x2F0000
LOADS = ((0x000000, "OpenSBI"), (0x3F0000, "DTB"), (0x400000, "kernel"))

def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("opensbi", type=Path)
    p.add_argument("dtb", type=Path)
    p.add_argument("kernel", type=Path)
    p.add_argument("output", type=Path)
    p.add_argument("--require-flash-fit", action="store_true",
                   help="fail if GRV1 does not fit the primary flash slot")
    a = p.parse_args()
    blobs = [f.read_bytes() for f in (a.opensbi, a.dtb, a.kernel)]
    if len(blobs[0]) > LOADS[1][0]:
        raise SystemExit("OpenSBI would overlap the DTB at $3F0000")
    if len(blobs[1]) > LOADS[2][0] - LOADS[1][0]:
        raise SystemExit("DTB would overlap the kernel at $400000")
    records = []
    payload = bytearray()
    base = 12 + 12 * len(blobs)
    checksum = 0
    for (dst, name), data in zip(LOADS, blobs):
        if dst + len(data) > SDRAM_SIZE:
            raise SystemExit(f"{name} does not fit in 16 MB SDRAM")
        payload.extend(bytes((-(base + len(payload))) % 512))
        padded = data + bytes((-len(data)) % 4)
        for (word,) in struct.iter_unpack("<I", padded):
            checksum = (checksum + word) & 0xFFFFFFFF
        records.append((base + len(payload), dst, len(data)))
        payload.extend(padded)
    image = struct.pack("<III", MAGIC, len(records), checksum)
    for rec in records:
        image += struct.pack("<III", *rec)
    image += payload
    image += bytes((-len(image)) % 512)
    if a.require_flash_fit and len(image) > XIP_PAYLOAD_MAX:
        raise SystemExit(f"image is {len(image)} bytes; primary flash slot is "
                         f"only {XIP_PAYLOAD_MAX} bytes")
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_bytes(image)
    print(f"created {a.output} ({len(image)} bytes)")
    print("  SD:    optional fallback; write raw starting at sector 0")
    if len(image) > XIP_PAYLOAD_MAX:
        print("  Flash: too large for the primary slot at 0x510000 (2.9 MB),"
              " SD boot only")
    else:
        print("  Flash: burn at 0x510000 (primary)")
    for (dst, name), data in zip(LOADS, blobs):
        print(f"  {name:7} DDR ${dst:06X}-${dst+len(data)-1:06X} ({len(data)} bytes)")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
