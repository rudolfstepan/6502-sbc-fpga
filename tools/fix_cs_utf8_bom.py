#!/usr/bin/env python3
"""Recursively re-save every C# (.cs) file as UTF-8 *with* a BOM.

Walks a directory tree, and for each ``*.cs`` file makes sure it begins with
the UTF-8 byte-order mark (``EF BB BF``). Files that already have the BOM are
left untouched (their modification time is not changed). Files in another
encoding are decoded and rewritten as UTF-8-with-BOM; byte content (including
CRLF/LF line endings) is otherwise preserved.

Usage:
    python tools/fix_cs_utf8_bom.py [ROOT] [--dry-run] [--verbose]

ROOT defaults to the current directory.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

UTF8_BOM = b"\xef\xbb\xbf"
UTF16_LE_BOM = b"\xff\xfe"
UTF16_BE_BOM = b"\xfe\xff"


def decode_bytes(raw: bytes) -> str:
    """Decode file bytes, trying the most likely encodings in order."""
    if raw.startswith(UTF16_LE_BOM) or raw.startswith(UTF16_BE_BOM):
        return raw.decode("utf-16")
    try:
        # plain UTF-8 (no BOM) — the common case for source files
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        # legacy Windows code page fallback (never raises, 1 byte = 1 char)
        return raw.decode("cp1252")


def convert_file(path: Path, dry_run: bool) -> bool:
    """Return True if the file needed conversion (and was converted)."""
    raw = path.read_bytes()
    if raw.startswith(UTF8_BOM):
        return False  # already UTF-8 with BOM

    text = decode_bytes(raw)
    new_bytes = UTF8_BOM + text.encode("utf-8")
    if not dry_run:
        path.write_bytes(new_bytes)
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("root", nargs="?", default=".", type=Path,
                    help="directory to scan recursively (default: current dir)")
    ap.add_argument("--dry-run", action="store_true",
                    help="report what would change without writing files")
    ap.add_argument("--verbose", "-v", action="store_true",
                    help="list every file that is (or would be) converted")
    args = ap.parse_args()

    if not args.root.is_dir():
        print(f"error: {args.root} is not a directory", file=sys.stderr)
        return 2

    scanned = converted = failed = 0
    for path in sorted(args.root.rglob("*.cs")):
        if not path.is_file():
            continue
        scanned += 1
        try:
            changed = convert_file(path, args.dry_run)
        except OSError as e:
            failed += 1
            print(f"FAILED  {path}: {e}", file=sys.stderr)
            continue
        if changed:
            converted += 1
            if args.verbose:
                verb = "would convert" if args.dry_run else "converted"
                print(f"{verb}: {path}")

    action = "would add BOM to" if args.dry_run else "added BOM to"
    print(f"scanned {scanned} .cs files, {action} {converted}, "
          f"{scanned - converted - failed} already OK, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
