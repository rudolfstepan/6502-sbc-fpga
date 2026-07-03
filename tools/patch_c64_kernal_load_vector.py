#!/usr/bin/env python3
"""Patch the C64 KERNAL LOAD entry at $FFD5 to use the virtual-1541 hook.

Stock C64 KERNAL ROMs jump directly from $FFD5 into the ROM LOAD routine.
The FPGA SD hook (sw/c64_sd_fastload_hook.s: fastloader + disk menu) lives in
RAM at $C000 after upload.  A direct `JMP $C003` would be unsafe before the
hook is resident, and the regular $0330 LOAD vector can be restored by
KERNAL/BASIC vector initialization.  The patched KERNAL therefore jumps to a
tiny guard stub in unused KERNAL space:

    $FFD5: JMP $ECB9
    $ECB9: PHA
           if $C000 == $4C then PLA : JMP $C003 else PLA : JMP $F49E

A holds the KERNAL LOAD/VERIFY flag at $FFD5, so the stub must preserve it
around the LDA $C700 signature check; clobbering A turns every LOAD into a
VERIFY inside the hook and in the stock $F4A5 path.

The stub overwrites the first 16 bytes of the CINT VIC-II register default
table at $ECB9 (sprite coordinates $D000-$D00F only, harmless while sprites
are disabled at reset).  $ECC9 onward ($D010 X-MSB, $D011 control, ...) stays
stock.

The script patches roms/c64/KERNAL.ROM in-place by default and creates a
KERNAL.ROM.orig backup before the first modification.
"""

from __future__ import annotations

import argparse
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ROM_DIR = ROOT / "roms" / "c64"
DEFAULT_CANDIDATES = (ROM_DIR / "KERNAL.ROM", ROM_DIR / "kernal.rom")
LOAD_ENTRY = 0xFFD5
KERNAL_BASE = 0xE000
PATCH_OFFSET = LOAD_ENTRY - KERNAL_BASE
STUB_ADDR = 0xECB9
STUB_OFFSET = STUB_ADDR - KERNAL_BASE
HOOK_BASE = 0xC000
HOOK_ENTRY = HOOK_BASE + 0x0003
HOOK_GUARD_ADDR = HOOK_BASE
HOOK_GUARD_VALUE = 0x4C  # JMP opcode at the start of c64_sd_fastload_hook.s
PATCH_BYTES = bytes((0x4C, STUB_ADDR & 0xFF, STUB_ADDR >> 8))  # JMP $ECB9
LEGACY_PATCH_BYTES = bytes((0x6C, 0x30, 0x03))  # JMP ($0330)
STOCK_BYTES = bytes((0x4C, 0x9E, 0xF4))  # JMP $F49E
STUB_BYTES = bytes(
    (
        0x48,                                                # PHA (save LOAD/VERIFY flag)
        0xAD, HOOK_GUARD_ADDR & 0xFF, HOOK_GUARD_ADDR >> 8,  # LDA hook base
        0xC9, HOOK_GUARD_VALUE,                              # CMP #$4C
        0xD0, 0x04,                                          # BNE stock
        0x68,                                                # PLA (restore A)
        0x4C, HOOK_ENTRY & 0xFF, HOOK_ENTRY >> 8,            # JMP hook LOAD entry
        0x68,                                                # PLA (restore A)
        0x4C, 0x9E, 0xF4,                                    # JMP $F49E
    )
)


def default_kernal_path() -> Path:
    for path in DEFAULT_CANDIDATES:
        if path.exists():
            return path
    return DEFAULT_CANDIDATES[0]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kernal", nargs="?", type=Path, default=default_kernal_path())
    parser.add_argument("--output", type=Path, help="Write patched ROM to this file instead of patching in-place")
    parser.add_argument("--no-backup", action="store_true", help="Do not create a .orig backup for in-place patching")
    args = parser.parse_args()

    src = args.kernal
    if not src.exists():
        raise SystemExit(f"{src}: KERNAL ROM not found")

    data = bytearray(src.read_bytes())
    if len(data) != 0x2000:
        raise SystemExit(f"{src}: expected 8192 bytes, got {len(data)}")

    old = bytes(data[PATCH_OFFSET:PATCH_OFFSET + 3])
    old_stub = bytes(data[STUB_OFFSET:STUB_OFFSET + len(STUB_BYTES)])
    if old == PATCH_BYTES and old_stub == STUB_BYTES:
        state = "already patched"
    elif old in (STOCK_BYTES, LEGACY_PATCH_BYTES, PATCH_BYTES):
        state = "patched"
        data[PATCH_OFFSET:PATCH_OFFSET + 3] = PATCH_BYTES
        data[STUB_OFFSET:STUB_OFFSET + len(STUB_BYTES)] = STUB_BYTES
    else:
        raise SystemExit(
            f"{src}: unexpected bytes at ${LOAD_ENTRY:04X}: "
            f"{old.hex(' ').upper()} (expected {STOCK_BYTES.hex(' ').upper()} "
            f"or {LEGACY_PATCH_BYTES.hex(' ').upper()} "
            f"or {PATCH_BYTES.hex(' ').upper()})"
        )

    dst = args.output or src
    if args.output is None and state == "patched" and not args.no_backup:
        backup = src.with_name(src.name + ".orig")
        if not backup.exists():
            backup.write_bytes(src.read_bytes())
            print(f"backup: {backup.relative_to(ROOT)}")

    if state == "patched" or args.output is not None:
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(data)

    print(
        f"{state}: {dst.relative_to(ROOT)} ${LOAD_ENTRY:04X} "
        f"{old.hex(' ').upper()} -> {PATCH_BYTES.hex(' ').upper()}"
    )
    if state == "patched":
        print(f"stub: ${STUB_ADDR:04X} {old_stub.hex(' ').upper()} -> {STUB_BYTES.hex(' ').upper()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
