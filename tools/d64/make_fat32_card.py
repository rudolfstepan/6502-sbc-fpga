#!/usr/bin/env python3
"""Build a minimal FAT32 SD-card image containing .d64 files, for FPGA testing.

This produces a deterministic raw card image whose layout the FPGA fat32_reader
must be able to parse:

  LBA 0                : MBR with one partition entry (type 0x0C, FAT32 LBA)
  partition start      : FAT32 volume (reserved sectors + 2 FATs + data region)
  root directory       : 8.3 directory entries for each .d64 file
  data clusters        : the .d64 file bytes, written contiguously

The image is intentionally small and the files are placed contiguously so a
"contiguous + verify" reader (Version 1) can resolve a single start LBA and
confirm the FAT chain is linear.

Usage:
  python tools/d64/make_fat32_card.py -o sim/generated/fat32_card.img \
      roms/test_d64/testdisk.d64
"""

from __future__ import annotations

import argparse
from pathlib import Path
import struct
import sys

SECTOR = 512


def lfn_short_name(name: str) -> bytes:
    """Return an 8.3 short name (11 bytes, space padded), uppercased."""
    stem, _, ext = name.upper().rpartition(".")
    if not stem:  # no dot
        stem, ext = name.upper(), ""
    stem = stem[:8].ljust(8)
    ext = ext[:3].ljust(3)
    return (stem + ext).encode("ascii")


class Fat32Builder:
    def __init__(
        self,
        sectors_per_cluster: int = 8,
        reserved_sectors: int = 32,
        num_fats: int = 2,
        partition_start_lba: int = 2048,
        pad_root_entries: int = 0,
        superfloppy: bool = False,
        realistic_prefix: bool = False,
    ) -> None:
        self.realistic_prefix = realistic_prefix
        self.spc = sectors_per_cluster
        self.reserved = reserved_sectors
        self.num_fats = num_fats
        # Superfloppy media (like a Windows-formatted SD card) have no MBR: the
        # FAT boot sector / BPB is at LBA 0 and the volume starts there.
        self.superfloppy = superfloppy
        self.part_start = 0 if superfloppy else partition_start_lba
        # Number of dummy directory entries to place before the real files, to
        # push them into later sectors of the root cluster (tests multi-sector
        # root scanning; e.g. Windows leaves System Volume Information first).
        self.pad_root_entries = pad_root_entries
        # Optional overrides to reproduce a real card's geometry (large FAT /
        # reserved area) that small images never exercise.
        self.force_reserved = reserved_sectors
        self.force_spf = None  # set via attribute before build() if needed
        self.files: list[tuple[str, bytes]] = []

    def add_file(self, name: str, data: bytes) -> None:
        self.files.append((name, data))

    def build(self) -> bytes:
        # Cluster sizing: root dir uses cluster 2, files follow.
        bytes_per_cluster = self.spc * SECTOR

        # Plan clusters: cluster 2 = root dir; then each file's clusters.
        root_clusters = 1
        layout = []  # (name, data, first_cluster, cluster_count)
        next_cluster = 2 + root_clusters
        for name, data in self.files:
            ccount = max(1, (len(data) + bytes_per_cluster - 1) // bytes_per_cluster)
            layout.append((name, data, next_cluster, ccount))
            next_cluster += ccount
        total_data_clusters = next_cluster - 2

        # FAT must cover clusters 0..(2+total_data_clusters-1); 4 bytes each.
        fat_entries = 2 + total_data_clusters
        fat_bytes = fat_entries * 4
        sectors_per_fat = max(1, (fat_bytes + SECTOR - 1) // SECTOR)
        # Optional: force a larger FAT to mimic a real (big) card's geometry.
        if self.force_spf is not None:
            sectors_per_fat = max(sectors_per_fat, self.force_spf)

        data_start_sector = self.reserved + self.num_fats * sectors_per_fat
        total_sectors_in_vol = data_start_sector + total_data_clusters * self.spc

        # ── Build FAT ────────────────────────────────────────────────────────
        fat = bytearray(sectors_per_fat * SECTOR)
        def set_fat(cluster: int, value: int) -> None:
            struct.pack_into("<I", fat, cluster * 4, value & 0x0FFFFFFF)
        set_fat(0, 0x0FFFFFF8)
        set_fat(1, 0x0FFFFFFF)
        # root dir: single cluster, EOC
        set_fat(2, 0x0FFFFFFF)
        for _, _, first, ccount in layout:
            for k in range(ccount):
                c = first + k
                set_fat(c, 0x0FFFFFFF if k == ccount - 1 else c + 1)

        # ── Build root directory cluster ──────────────────────────────────────
        root = bytearray(self.spc * SECTOR)
        off = 0

        def put(entry: bytes) -> None:
            nonlocal off
            root[off : off + 32] = entry
            off += 32

        # Optional realistic prefix reproducing a Windows-formatted SD card that
        # had a .d64 deleted before ours: volume label, a System Volume
        # Information LFN+8.3 pair, and a DELETED ($E5) entry whose extension is
        # still "D64" (must be skipped, not matched).
        if self.realistic_prefix:
            vol = bytearray(32)
            vol[0:11] = b"SD         "
            vol[11] = 0x08                 # volume label
            put(vol)
            lfn1 = bytearray(32); lfn1[0] = 0x42; lfn1[11] = 0x0F; put(lfn1)
            lfn2 = bytearray(32); lfn2[0] = 0x01; lfn2[11] = 0x0F; put(lfn2)
            sysdir = bytearray(32)
            sysdir[0:11] = b"SYSTEM~1   "
            sysdir[11] = 0x16              # hidden|system|dir
            put(sysdir)
            deleted = bytearray(32)
            deleted[0:11] = b"\xe5LTIMA1 D64"   # deleted, but ext is "D64"
            deleted[11] = 0x20
            put(deleted)

        # Optional filler entries that push the real files into later sectors.
        for n in range(self.pad_root_entries):
            entry = bytearray(32)
            entry[0:11] = (f"FILLER{n:02d}  "[:11]).encode("ascii")
            entry[11] = 0x20
            put(entry)
        for name, data, first, _ in layout:  # noqa: B007 (data unused here)
            entry = bytearray(32)
            entry[0:11] = lfn_short_name(name)
            entry[11] = 0x20  # archive
            entry[20] = (first >> 16) & 0xFF
            entry[21] = (first >> 24) & 0xFF
            entry[26] = first & 0xFF
            entry[27] = (first >> 8) & 0xFF
            struct.pack_into("<I", entry, 28, len(data))
            put(entry)

        # ── Assemble the volume ───────────────────────────────────────────────
        vol = bytearray(total_sectors_in_vol * SECTOR)

        # Boot sector (BPB)
        bs = bytearray(SECTOR)
        bs[0:3] = b"\xeb\x58\x90"
        bs[3:11] = b"MSDOS5.0"
        struct.pack_into("<H", bs, 11, SECTOR)              # bytes per sector
        bs[13] = self.spc                                   # sectors per cluster
        struct.pack_into("<H", bs, 14, self.reserved)       # reserved sectors
        bs[16] = self.num_fats                              # number of FATs
        struct.pack_into("<H", bs, 17, 0)                   # root entries (0 for FAT32)
        struct.pack_into("<H", bs, 19, 0)                   # total sectors 16 (0)
        bs[21] = 0xF8                                        # media descriptor
        struct.pack_into("<H", bs, 22, 0)                   # sectors per FAT 16 (0)
        struct.pack_into("<I", bs, 32, total_sectors_in_vol)  # total sectors 32
        struct.pack_into("<I", bs, 36, sectors_per_fat)     # sectors per FAT 32
        struct.pack_into("<I", bs, 44, 2)                   # root cluster
        struct.pack_into("<H", bs, 48, 1)                   # FSInfo sector
        struct.pack_into("<H", bs, 50, 6)                   # backup boot sector
        bs[510] = 0x55
        bs[511] = 0xAA
        vol[0:SECTOR] = bs

        # FATs
        for n in range(self.num_fats):
            base = (self.reserved + n * sectors_per_fat) * SECTOR
            vol[base : base + len(fat)] = fat

        # Root dir cluster (cluster 2)
        root_base = data_start_sector * SECTOR
        vol[root_base : root_base + len(root)] = root

        # File data clusters
        for name, data, first, _ in layout:
            cbase = (data_start_sector + (first - 2) * self.spc) * SECTOR
            vol[cbase : cbase + len(data)] = data

        if self.superfloppy:
            # No MBR: the volume *is* the card, starting at LBA 0.
            card = bytearray(vol)
        else:
            # ── Wrap in an MBR-partitioned card ──────────────────────────────
            card = bytearray((self.part_start + total_sectors_in_vol) * SECTOR)
            mbr = bytearray(SECTOR)
            # one partition: type 0x0C (FAT32 LBA), starting at part_start
            pe = bytearray(16)
            pe[0] = 0x00                       # not bootable
            pe[4] = 0x0C                       # partition type
            struct.pack_into("<I", pe, 8, self.part_start)         # start LBA
            struct.pack_into("<I", pe, 12, total_sectors_in_vol)   # size in sectors
            mbr[446:462] = pe
            mbr[510] = 0x55
            mbr[511] = 0xAA
            card[0:SECTOR] = mbr
            card[self.part_start * SECTOR : self.part_start * SECTOR + len(vol)] = vol

        # Stash computed metadata for tests / printing.
        self.meta = {
            "partition_start_lba": self.part_start,
            "reserved_sectors": self.reserved,
            "num_fats": self.num_fats,
            "sectors_per_fat": sectors_per_fat,
            "sectors_per_cluster": self.spc,
            "data_start_sector": self.part_start + data_start_sector,
            "root_cluster": 2,
            "files": [
                {
                    "name": name,
                    "first_cluster": first,
                    "size": len(data),
                    # absolute start LBA of file's first byte on the card
                    "start_lba": self.part_start
                    + data_start_sector
                    + (first - 2) * self.spc,
                }
                for name, data, first, _ in layout
            ],
        }
        return bytes(card)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-o", "--output", type=Path, required=True)
    parser.add_argument("d64", nargs="+", type=Path, help=".d64 files to embed")
    parser.add_argument("--spc", type=int, default=8, help="sectors per cluster")
    parser.add_argument(
        "--pad-root-entries", type=int, default=0,
        help="dummy entries before the files (push them into later root sectors)",
    )
    parser.add_argument(
        "--superfloppy", action="store_true",
        help="no MBR: BPB at LBA 0 (like a Windows-formatted SD card)",
    )
    parser.add_argument(
        "--reserved", type=int, default=32,
        help="reserved sectors (real cards use thousands, e.g. 2964)",
    )
    parser.add_argument(
        "--force-spf", type=int, default=None,
        help="force sectors-per-FAT (real cards use large values, e.g. 14902)",
    )
    parser.add_argument(
        "--realistic-prefix", action="store_true",
        help="prepend volume label, LFN pair, SYSTEM~1 dir, and a deleted .D64",
    )
    args = parser.parse_args(argv)

    b = Fat32Builder(
        sectors_per_cluster=args.spc,
        reserved_sectors=args.reserved,
        pad_root_entries=args.pad_root_entries,
        superfloppy=args.superfloppy,
        realistic_prefix=args.realistic_prefix,
    )
    b.force_spf = args.force_spf
    for p in args.d64:
        b.add_file(p.name, p.read_bytes())
    img = b.build()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(img)

    print(f"Wrote {args.output} ({len(img)} bytes)")
    for f in b.meta["files"]:
        print(
            f"  {f['name']}: first_cluster={f['first_cluster']} "
            f"size={f['size']} start_lba={f['start_lba']}"
        )
    print(f"  data_start_sector(abs)={b.meta['data_start_sector']} "
          f"spc={b.meta['sectors_per_cluster']} "
          f"spf={b.meta['sectors_per_fat']} "
          f"reserved={b.meta['reserved_sectors']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
