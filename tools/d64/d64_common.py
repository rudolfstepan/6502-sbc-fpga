#!/usr/bin/env python3
"""Shared D64 disk-image helpers for the FPGA 6502 GoDrive.

This module is the single source of truth for the D64 track/sector geometry.
The same logic is mirrored in the FPGA `d64_sector_map.vhd` module, and the
unit tests in `tools/d64/test_d64_common.py` lock both implementations to the
mapping table documented in future_works/TODO_D64_HYBRID_DRIVE_FULL.md.

Version 1 scope: standard 35-track, 683-sector, 256-byte/sector image with no
error-info bytes (174848 bytes total). Read-only.
"""

from __future__ import annotations

from dataclasses import dataclass

# ── Geometry constants ──────────────────────────────────────────────────────

SECTOR_SIZE = 256           # bytes per D64 sector
D64_35_TRACK_SECTORS = 683  # total sectors on a standard 35-track image
D64_35_TRACK_SIZE = D64_35_TRACK_SECTORS * SECTOR_SIZE  # 174848

INVALID_INDEX = 0xFFFFFFFF  # returned for out-of-range track/sector

DIR_TRACK = 18              # BAM + directory live on track 18
BAM_SECTOR = 0
DIR_FIRST_SECTOR = 1


def sectors_per_track(track: int) -> int:
    """Number of sectors on `track` (1-based). 0 if track is out of range.

    Standard 35-track zone layout:
        tracks  1..17 : 21 sectors
        tracks 18..24 : 19 sectors
        tracks 25..30 : 18 sectors
        tracks 31..35 : 17 sectors
    """
    if 1 <= track <= 17:
        return 21
    if 18 <= track <= 24:
        return 19
    if 25 <= track <= 30:
        return 18
    if 31 <= track <= 35:
        return 17
    return 0


def d64_sector_index(track: int, sector: int) -> int:
    """Linear sector index for a D64 (track, sector), or INVALID_INDEX.

    Tracks are 1-based, sectors are 0-based. Mirrors the C reference in the
    TODO spec exactly so the FPGA and host tooling agree byte-for-byte.
    """
    if 1 <= track <= 17:
        if sector >= 21:
            return INVALID_INDEX
        return (track - 1) * 21 + sector
    if 18 <= track <= 24:
        if sector >= 19:
            return INVALID_INDEX
        return 357 + (track - 18) * 19 + sector
    if 25 <= track <= 30:
        if sector >= 18:
            return INVALID_INDEX
        return 490 + (track - 25) * 18 + sector
    if 31 <= track <= 35:
        if sector >= 17:
            return INVALID_INDEX
        return 598 + (track - 31) * 17 + sector
    return INVALID_INDEX


def d64_byte_offset(track: int, sector: int) -> int:
    """Byte offset of (track, sector) within the D64 image, or INVALID_INDEX."""
    index = d64_sector_index(track, sector)
    if index == INVALID_INDEX:
        return INVALID_INDEX
    return index * SECTOR_SIZE


@dataclass(frozen=True)
class SdLocation:
    """Where a 256-byte D64 sector lives inside the 512-byte SD blocks of a file.

    `block` is relative to the file start (file_start_lba added by the caller).
    `half` is 0 for the lower 256 bytes of the block, 256 for the upper half.
    """

    block: int
    half: int  # 0x000 or 0x100


def sd_location(track: int, sector: int) -> SdLocation | None:
    """Map a D64 (track, sector) to its SD block + half-sector within the file.

    Returns None for an invalid track/sector. The file's start LBA is *not*
    added here — this is the within-file mapping only.
    """
    offset = d64_byte_offset(track, sector)
    if offset == INVALID_INDEX:
        return None
    return SdLocation(block=offset // 512, half=offset & 0x100)


def is_supported_size(size: int) -> bool:
    """True for image sizes Version 1 accepts (35-track, no error bytes)."""
    return size == D64_35_TRACK_SIZE
