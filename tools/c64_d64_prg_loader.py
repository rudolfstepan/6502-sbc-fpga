#!/usr/bin/env python3
"""Extract a PRG from a C64 D64 image and upload it through the C64 UART monitor.

This is a pragmatic loader for single-file or cracked D64 games while the native
C64 core does not yet provide a full KERNAL/IEC/1541 path. It reads a standard
35-track `.d64` on the PC, extracts the first PRG (or a named PRG), then reuses
`c64_uart_prg_loader.py` so the program can be started with RUN on the C64.

Example:
  python tools/c64_d64_prg_loader.py --disk "E:\\Emulatoren\\C64\\Games\\game.d64" --port COM15
  python tools/c64_d64_prg_loader.py --folder "E:\\Emulatoren\\C64\\Games" --find "1942" --port COM15
  python tools/c64_d64_prg_loader.py --disk game.d64 --list
  python tools/c64_d64_prg_loader.py --disk game.d64 --extract-only --output game.prg
"""
from __future__ import annotations

import argparse
import tempfile
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
D64_TOOLS = ROOT / "tools" / "d64"
DEFAULT_GAMES = Path(r"E:\Emulatoren\C64\Games")
DEFAULT_FOLDER = DEFAULT_GAMES if DEFAULT_GAMES.exists() else ROOT / "roms" / "test_d64"

import sys

sys.path.insert(0, str(D64_TOOLS))
sys.path.insert(0, str(ROOT / "tools"))

from d64_common import D64_35_TRACK_SIZE, is_supported_size  # noqa: E402
from extract_prg import follow_chain  # noqa: E402
from list_d64 import disk_name, iter_entries  # noqa: E402
import c64_uart_prg_loader  # noqa: E402


def iter_d64s(folder: Path) -> list[Path]:
    if not folder.exists():
        raise SystemExit(f"ERROR: folder not found: {folder}")
    return sorted(
        (p for p in folder.rglob("*.d64") if p.is_file()),
        key=lambda p: str(p.relative_to(folder)).lower(),
    )


def resolve_disk(args: argparse.Namespace) -> Path:
    if args.disk:
        disk = Path(args.disk)
        if disk.exists():
            return disk
        candidate = Path(args.folder) / disk
        if candidate.exists():
            return candidate
        raise SystemExit(f"ERROR: D64 image not found: {args.disk}")

    matches = iter_d64s(Path(args.folder))
    if args.find:
        needle = args.find.lower()
        matches = [
            p for p in matches
            if needle in p.name.lower() or needle in str(p.parent).lower()
        ]
    if not matches:
        raise SystemExit("ERROR: no D64 images matched")
    if len(matches) > 1 and not args.first_match:
        print("Multiple D64 images matched; use --first-match or a more specific --find:")
        for p in matches[:30]:
            print(f"  {p}")
        if len(matches) > 30:
            print(f"  ... {len(matches) - 30} more")
        raise SystemExit(2)
    return matches[0]


def load_entries(image: Path):
    data = image.read_bytes()
    if len(data) < D64_35_TRACK_SIZE:
        raise SystemExit(
            f"ERROR: unsupported D64 size {len(data)} bytes in {image}; "
            f"expected at least {D64_35_TRACK_SIZE}"
        )
    if not is_supported_size(len(data)):
        print(
            f"WARNING: non-standard D64 size {len(data)} bytes; "
            f"using the first {D64_35_TRACK_SIZE} bytes"
        )
        data = data[:D64_35_TRACK_SIZE]
    return data, list(iter_entries(data))


def print_directory(image: Path, data: bytes, entries) -> None:
    print(f'Disk: {image}')
    print(f'Name: "{disk_name(data)}"')
    for entry in entries:
        print(
            f'{entry["blocks"]:4d}  {entry["type"]:<3}  '
            f'"{entry["name"]}"  T{entry["first_track"]}/S{entry["first_sector"]}'
        )


def select_prg(entries, name: str | None):
    prgs = [entry for entry in entries if entry["type"] == "PRG"]
    if not prgs:
        raise SystemExit("ERROR: selected D64 has no PRG entries")
    if not name:
        return prgs[0]

    target = name.strip().strip('"').upper()
    for entry in prgs:
        if entry["name"].upper() == target:
            return entry
    partial = [entry for entry in prgs if target in entry["name"].upper()]
    if len(partial) == 1:
        return partial[0]
    if partial:
        print(f'Multiple PRGs matched "{name}":')
        for entry in partial:
            print(f'  "{entry["name"]}"')
        raise SystemExit(2)
    raise SystemExit(f'ERROR: PRG not found on D64: "{name}"')


def safe_stem(text: str) -> str:
    return "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in text).strip("_") or "d64_prg"


def write_prg(image: Path, entry, data: bytes, output: Path | None) -> Path:
    body = follow_chain(data, entry["first_track"], entry["first_sector"])
    if len(body) < 3:
        raise SystemExit(f'ERROR: PRG "{entry["name"]}" is too small')
    load_addr = body[0] | (body[1] << 8)
    if output is None:
        out_dir = Path(tempfile.gettempdir()) / "c64_d64_prg_loader"
        out = out_dir / f"{safe_stem(image.stem)}__{safe_stem(entry['name'])}.prg"
    else:
        out = output
        out_dir = out.parent
    out_dir.mkdir(parents=True, exist_ok=True)
    out.write_bytes(body)
    print(
        f'Extracted "{entry["name"]}" from {image.name}: '
        f'load=${load_addr:04X}, {len(body) - 2} bytes'
    )
    return out


def make_upload_args(args: argparse.Namespace, prg: Path) -> SimpleNamespace:
    return SimpleNamespace(
        prg=str(prg),
        port=args.port,
        baud=args.baud,
        wake_byte=args.wake_byte,
        bytes_per_line=args.bytes_per_line,
        line_delay=args.line_delay,
        command_delay=args.command_delay,
        settle=args.settle,
        wait_prompt=args.wait_prompt,
        wake_retries=args.wake_retries,
        wake_gap=args.wake_gap,
        wait_load=args.wait_load,
        wait_done=args.wait_done,
        progress=args.progress,
        basic=args.basic,
        auto_basic=not args.no_auto_basic,
        stay=args.stay,
        segments=None,
        no_segments=True,
        verbose=args.verbose,
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--folder", type=Path, default=DEFAULT_FOLDER, help=f"D64 root folder, default {DEFAULT_FOLDER}")
    parser.add_argument("--disk", help="D64 image path or path relative to --folder")
    parser.add_argument("--find", help="search text for a D64 path below --folder")
    parser.add_argument("--first-match", action="store_true", help="use first --find match without asking")
    parser.add_argument("--program", help="PRG name to extract; default is first PRG")
    parser.add_argument("--list", action="store_true", help="only list the selected D64 directory")
    parser.add_argument("--extract-only", action="store_true", help="extract the selected PRG without uploading")
    parser.add_argument("--output", type=Path, help="output PRG path for --extract-only")

    parser.add_argument("--port", default=c64_uart_prg_loader.DEFAULT_PORT)
    parser.add_argument("--baud", type=int, default=c64_uart_prg_loader.DEFAULT_BAUD)
    parser.add_argument("--wake-byte", type=c64_uart_prg_loader.parse_byte, default=c64_uart_prg_loader.DEFAULT_WAKE_BYTE)
    parser.add_argument("--bytes-per-line", type=int, default=c64_uart_prg_loader.DEFAULT_BYTES_PER_LINE)
    parser.add_argument("--line-delay", type=float, default=c64_uart_prg_loader.DEFAULT_LINE_DELAY)
    parser.add_argument("--command-delay", type=float, default=c64_uart_prg_loader.DEFAULT_COMMAND_DELAY)
    parser.add_argument("--settle", type=float, default=0.2)
    parser.add_argument("--wait-prompt", type=float, default=2.0)
    parser.add_argument("--wake-retries", type=int, default=5)
    parser.add_argument("--wake-gap", type=float, default=0.15)
    parser.add_argument("--wait-load", type=float, default=c64_uart_prg_loader.DEFAULT_WAIT_LOAD)
    parser.add_argument("--wait-done", type=float, default=c64_uart_prg_loader.DEFAULT_WAIT_DONE)
    parser.add_argument("--progress", type=int, default=1024)
    parser.add_argument("--basic", action="store_true", help="force BASIC pointer patch")
    parser.add_argument("--no-auto-basic", action="store_true", help="do not auto-patch BASIC pointers for $0801")
    parser.add_argument("--stay", action="store_true", help="leave the FPGA monitor active after upload")
    parser.add_argument("--verbose", action="store_true", help="print monitor responses")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    image = resolve_disk(args)
    data, entries = load_entries(image)
    print_directory(image, data, entries)
    if args.list:
        return 0

    entry = select_prg(entries, args.program)
    prg = write_prg(image, entry, data, args.output)
    if args.extract_only:
        print(f"Wrote {prg}")
        return 0
    print("NOTE: This monitor path is for single-load PRGs. Multi-load games and fastloaders need a later IEC/1541 path.")
    c64_uart_prg_loader.upload(make_upload_args(args, prg))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
