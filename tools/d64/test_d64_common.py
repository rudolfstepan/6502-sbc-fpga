#!/usr/bin/env python3
"""Unit tests for the shared D64 mapping logic.

These vectors are copied verbatim from the mapping table in
future_works/TODO_D64_HYBRID_DRIVE_FULL.md (sections 5.3) and are the contract
that the FPGA d64_sector_map.vhd module must also satisfy.

Run with:  python -m pytest tools/d64/test_d64_common.py
       or:  python tools/d64/test_d64_common.py
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from d64_common import (  # noqa: E402
    D64_35_TRACK_SIZE,
    INVALID_INDEX,
    SECTOR_SIZE,
    d64_byte_offset,
    d64_sector_index,
    is_supported_size,
    sd_location,
    sectors_per_track,
)

# (track, sector, expected_index, expected_byte_offset)
VALID_CASES = [
    (1, 0, 0, 0),
    (1, 20, 20, 5120),
    (2, 0, 21, 5376),
    (17, 20, 356, 91136),
    (18, 0, 357, 91392),
    (18, 1, 358, 91648),
    (24, 18, 489, 125184),
    (25, 0, 490, 125440),
    (30, 17, 597, 152832),
    (31, 0, 598, 153088),
    (35, 16, 682, 174592),
]

INVALID_CASES = [
    (0, 0),
    (1, 21),
    (18, 19),
    (25, 18),
    (35, 17),
    (36, 0),
]


def test_valid_indices():
    for track, sector, index, offset in VALID_CASES:
        assert d64_sector_index(track, sector) == index, (track, sector)
        assert d64_byte_offset(track, sector) == offset, (track, sector)


def test_invalid_indices():
    for track, sector in INVALID_CASES:
        assert d64_sector_index(track, sector) == INVALID_INDEX, (track, sector)
        assert d64_byte_offset(track, sector) == INVALID_INDEX, (track, sector)


def test_sectors_per_track():
    assert sectors_per_track(0) == 0
    assert sectors_per_track(1) == 21
    assert sectors_per_track(17) == 21
    assert sectors_per_track(18) == 19
    assert sectors_per_track(24) == 19
    assert sectors_per_track(25) == 18
    assert sectors_per_track(30) == 18
    assert sectors_per_track(31) == 17
    assert sectors_per_track(35) == 17
    assert sectors_per_track(36) == 0


def test_total_sector_count():
    total = sum(sectors_per_track(t) for t in range(1, 36))
    assert total == 683
    assert total * SECTOR_SIZE == D64_35_TRACK_SIZE


def test_index_is_dense_and_monotonic():
    # Walking every valid sector in order must yield 0,1,2,...,682 with no gaps.
    expected = 0
    for track in range(1, 36):
        for sector in range(sectors_per_track(track)):
            assert d64_sector_index(track, sector) == expected, (track, sector)
            expected += 1
    assert expected == 683


def test_sd_location():
    # Track 18/Sector 0: offset 91392 -> block 178, upper half (offset & 0x100).
    loc = sd_location(18, 0)
    assert loc is not None
    assert loc.block == 178
    assert loc.half == 0x100
    # Track 18/Sector 1: offset 91648 -> block 179, lower half.
    loc = sd_location(18, 1)
    assert loc.block == 179
    assert loc.half == 0x000
    # Track 1/Sector 0: offset 0 -> block 0, lower half.
    loc = sd_location(1, 0)
    assert loc.block == 0
    assert loc.half == 0x000
    # Track 1/Sector 1: offset 256 -> block 0, upper half.
    loc = sd_location(1, 1)
    assert loc.block == 0
    assert loc.half == 0x100
    # Invalid input -> None.
    assert sd_location(0, 0) is None


def test_is_supported_size():
    assert is_supported_size(174848)
    assert not is_supported_size(175531)  # 35-track with error bytes
    assert not is_supported_size(196608)  # 40-track
    assert not is_supported_size(0)


def _run_standalone() -> int:
    funcs = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failures = 0
    for fn in funcs:
        try:
            fn()
            print(f"PASS {fn.__name__}")
        except AssertionError as exc:
            failures += 1
            print(f"FAIL {fn.__name__}: {exc}")
    print(f"\n{len(funcs) - failures}/{len(funcs)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(_run_standalone())
