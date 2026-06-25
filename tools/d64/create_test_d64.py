#!/usr/bin/env python3
"""Generate a deterministic 35-track test D64 image for the FPGA GoDrive.

The image is built from scratch (no external tools) and contains a small set
of PRG files whose contents are fully reproducible, so emulator/FPGA tests can
assert exact bytes.

Default output: roms/test_d64/testdisk.d64

Layout produced:
  - Track 18/Sector 0 : BAM + disk name "TESTDISK"
  - Track 18/Sector 1+: directory entries (one chained sector is enough)
  - file data placed on tracks 1.. (avoiding the directory track 18)

This writer is intentionally simple: it allocates file blocks sequentially on
free tracks and writes a matching BAM. It is not a general-purpose D64 builder.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from d64_common import (  # noqa: E402
    D64_35_TRACK_SIZE,
    DIR_TRACK,
    SECTOR_SIZE,
    d64_byte_offset,
    sectors_per_track,
)

FT_PRG = 0x82  # closed (0x80) | PRG (0x02)


def petscii_name(name: str) -> bytes:
    """Encode an uppercase ASCII filename to 16 bytes padded with $A0.

    Version-1 filenames use the A-Z/0-9/space/._- subset, which is identical in
    ASCII and PETSCII uppercase, so a direct byte copy is sufficient.
    """
    raw = name.upper().encode("ascii")[:16]
    return raw + b"\xa0" * (16 - len(raw))


class D64Builder:
    def __init__(self) -> None:
        self.data = bytearray(b"\x00" * D64_35_TRACK_SIZE)
        # track -> next free sector to hand out (skip directory track entirely)
        self._next_sector = {t: 0 for t in range(1, 36)}
        self._used: set[tuple[int, int]] = set()
        self.dir_entries: list[bytes] = []

    # ── low-level sector access ─────────────────────────────────────────────
    def _write_sector(self, track: int, sector: int, payload: bytes) -> None:
        off = d64_byte_offset(track, sector)
        assert len(payload) == SECTOR_SIZE
        self.data[off : off + SECTOR_SIZE] = payload

    def _alloc(self, track: int) -> int:
        """Return the next free sector on `track`, marking it used."""
        s = self._next_sector[track]
        if s >= sectors_per_track(track):
            raise RuntimeError(f"track {track} full")
        self._next_sector[track] = s + 1
        self._used.add((track, s))
        return s

    def _alloc_block(self) -> tuple[int, int]:
        """Find a free (track, sector) on any data track (skip dir track 18)."""
        for track in list(range(1, DIR_TRACK)) + list(range(DIR_TRACK + 1, 36)):
            if self._next_sector[track] < sectors_per_track(track):
                return track, self._alloc(track)
        raise RuntimeError("disk full")

    # ── file placement ──────────────────────────────────────────────────────
    def add_prg(self, name: str, load_addr: int, payload: bytes) -> None:
        """Add a PRG file. `payload` excludes the 2-byte load address header."""
        body = bytes([load_addr & 0xFF, (load_addr >> 8) & 0xFF]) + payload

        # Split body into chained 254-byte data chunks.
        chunks = [body[i : i + 254] for i in range(0, len(body), 254)] or [b""]
        blocks = [self._alloc_block() for _ in chunks]

        for i, (track, sector) in enumerate(blocks):
            sec = bytearray(SECTOR_SIZE)
            chunk = chunks[i]
            if i + 1 < len(blocks):
                nt, ns = blocks[i + 1]
                sec[0] = nt
                sec[1] = ns
            else:
                # last block: next-track=0, next-sector = last used byte index
                sec[0] = 0x00
                sec[1] = len(chunk) + 1  # offset of final valid byte
            sec[2 : 2 + len(chunk)] = chunk
            self._write_sector(track, sector, bytes(sec))

        first_t, first_s = blocks[0]
        self._add_dir_entry(name, first_t, first_s, len(blocks))

    def _add_dir_entry(
        self, name: str, first_t: int, first_s: int, block_count: int
    ) -> None:
        entry = bytearray(32)
        entry[0] = FT_PRG
        entry[1] = first_t
        entry[2] = first_s
        entry[3:19] = petscii_name(name)
        entry[30] = block_count & 0xFF
        entry[31] = (block_count >> 8) & 0xFF
        self.dir_entries.append(bytes(entry))

    # ── BAM + directory ─────────────────────────────────────────────────────
    def _write_directory(self) -> None:
        # Directory sectors live on track 18, starting at sector 1.
        # Entries are placed at sector offset 2 + index*32 (matching the 6502
        # reader in sw/disk.s / sw/kernel.s).  With that offset only 7 full
        # 32-byte entries fit in a 256-byte sector (index 7 would end at byte
        # 257), so cap at 7 per sector and chain to the next directory sector.
        per_sector = 7
        groups = [
            self.dir_entries[i : i + per_sector]
            for i in range(0, len(self.dir_entries), per_sector)
        ] or [[]]
        dir_sectors = [self._alloc(DIR_TRACK) for _ in groups]
        # sector 0 on track 18 is the BAM; the first directory sector must be 1.
        # _alloc hands out 0 first, so reserve it for the BAM up front instead.

        for i, group in enumerate(groups):
            sec = bytearray(SECTOR_SIZE)
            if i + 1 < len(groups):
                sec[0] = DIR_TRACK
                sec[1] = dir_sectors[i + 1]
            else:
                sec[0] = 0x00
                sec[1] = 0xFF
            for j, entry in enumerate(group):
                sec[2 + j * 32 : 2 + j * 32 + 32] = entry
            self._write_sector(DIR_TRACK, dir_sectors[i], bytes(sec))
        self._first_dir_sector = dir_sectors[0]

    def _write_bam(self) -> None:
        bam = bytearray(SECTOR_SIZE)
        bam[0] = DIR_TRACK            # track of first directory sector
        bam[1] = self._first_dir_sector
        bam[2] = 0x41                 # DOS version 'A'
        bam[3] = 0x00
        # BAM entries: 4 bytes per track, tracks 1..35 at offset 4.
        for track in range(1, 36):
            total = sectors_per_track(track)
            free = sum(
                1 for s in range(total) if (track, s) not in self._used
            )
            base = 4 + (track - 1) * 4
            bam[base] = free
            bits = 0
            for s in range(total):
                if (track, s) not in self._used:
                    bits |= 1 << s
            bam[base + 1] = bits & 0xFF
            bam[base + 2] = (bits >> 8) & 0xFF
            bam[base + 3] = (bits >> 16) & 0xFF
        # Disk name (PETSCII, $A0 padded), id, DOS type.
        bam[0x90 : 0x90 + 16] = petscii_name("TESTDISK")
        bam[0xA0] = 0xA0
        bam[0xA1] = 0xA0
        bam[0xA2] = ord("0")          # disk ID
        bam[0xA3] = ord("0")
        bam[0xA4] = 0xA0
        bam[0xA5] = ord("2")          # DOS type "2A"
        bam[0xA6] = ord("A")
        bam[0xA7] = 0xA0
        self._write_sector(DIR_TRACK, 0, bytes(bam))

    def build(self) -> bytes:
        # Reserve track-18 sector 0 for the BAM before directory allocation.
        self._next_sector[DIR_TRACK] = 1
        self._used.add((DIR_TRACK, 0))
        self._write_directory()
        self._write_bam()
        return bytes(self.data)


def _hello_prg() -> bytes:
    # A tiny BASIC-like PRG payload; deterministic, content not executed by tests.
    return bytes(range(0, 200))


def _sample_files(builder: D64Builder) -> None:
    builder.add_prg("HELLO", 0x0801, _hello_prg())
    builder.add_prg("SOUNDTEST", 0x2000, bytes([0xAA]) * 600)
    builder.add_prg("MANDEL", 0x6000, bytes([0x55]) * 2000)
    builder.add_prg("DIRTEST1", 0x0801, bytes([0x01]) * 10)
    builder.add_prg("DIRTEST2", 0x0801, bytes([0x02]) * 10)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=Path("roms/test_d64/testdisk.d64"),
    )
    args = parser.parse_args(argv)

    builder = D64Builder()
    _sample_files(builder)
    image = builder.build()
    assert len(image) == D64_35_TRACK_SIZE

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(image)
    print(f"Wrote {args.output} ({len(image)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
