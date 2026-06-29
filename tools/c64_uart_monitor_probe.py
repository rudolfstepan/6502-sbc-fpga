#!/usr/bin/env python3
"""Enter the FPGA C64 UART monitor and dump diagnostic memory ranges.

Use this after the C64 appears frozen.  The tool sends the same monitor magic
sequence as the PRG loader, waits for the FPGA monitor prompt, then runs a set
of `M addr end` commands and stores the transcript in `.tmp`.
"""
from __future__ import annotations

import argparse
import sys
import time
from datetime import datetime
from pathlib import Path

from c64_uart_prg_loader import (
    COMMAND_PROMPTS,
    DEFAULT_BAUD,
    DEFAULT_PORT,
    DEFAULT_WAKE_SEQUENCE,
    enter_monitor,
    has_monitor_ready,
    parse_wake_sequence,
    read_some,
    response_preview,
    wait_for_prompt,
    write_line,
)


ROOT = Path(__file__).resolve().parents[1]

DEFAULT_RANGES = [
    ("zeropage", 0x0000, 0x00FF),
    ("stack", 0x0100, 0x01FF),
    ("basic-input", 0x0200, 0x02FF),
    ("vectors", 0x0300, 0x033F),
    ("screen", 0x0400, 0x07FF),
    ("basic-program", 0x0800, 0x08FF),
    ("hook-code", 0xC000, 0xC4FF),
    ("kernal-load", 0xF480, 0xF4BF),
    ("patched-ffd0", 0xFFD0, 0xFFFF),
]


def require_pyserial():
    try:
        import serial  # type: ignore
    except ImportError:
        print("ERROR: pyserial is not installed.", file=sys.stderr)
        print("Install it with: python -m pip install pyserial", file=sys.stderr)
        raise SystemExit(2)
    return serial


def parse_range(text: str) -> tuple[str, int, int]:
    label = "custom"
    spec = text
    if "=" in text:
        label, spec = text.split("=", 1)
        label = label.strip() or "custom"
    parts = spec.replace("-", " ").replace(":", " ").replace(",", " ").split()
    if len(parts) != 2:
        raise argparse.ArgumentTypeError("range must be START-END or LABEL=START-END")
    try:
        start = int(parts[0], 16)
        end = int(parts[1], 16)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid hex range: {text}") from exc
    if start < 0 or end > 0xFFFF or end < start:
        raise argparse.ArgumentTypeError("range must be inside $0000-$FFFF and END >= START")
    return label, start, end


def dump_range(port, label: str, start: int, end: int, args: argparse.Namespace) -> bytes:
    cmd = f"M {start:04X} {end:04X}"
    print(f"Dump {label}: ${start:04X}-${end:04X}")
    write_line(port, cmd, args.command_delay)
    response = wait_for_prompt(port, args.wait_dump, COMMAND_PROMPTS)
    if not response:
        response = read_some(port, 0.2)
    if args.verbose and response:
        print(response.decode("ascii", errors="replace"), end="")
    if not response:
        print(f"WARNING: no response for {cmd}", file=sys.stderr)
    return b"\r\n; " + label.encode("ascii", errors="replace") + b" " + cmd.encode("ascii") + b"\r\n" + response


def read_register_snapshot(port, args: argparse.Namespace) -> bytes:
    print("Read CPU/register snapshot")
    write_line(port, "R", args.command_delay)
    response = wait_for_prompt(port, args.wait_dump, COMMAND_PROMPTS)
    if not response:
        response = read_some(port, 0.2)
    if args.verbose and response:
        print(response.decode("ascii", errors="replace"), end="")
    if not response:
        print("WARNING: no response for R", file=sys.stderr)
    return b"\r\n; register snapshot R\r\n" + response


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", default=DEFAULT_PORT, help=f"serial port, default {DEFAULT_PORT}")
    parser.add_argument("--baud", type=int, default=DEFAULT_BAUD, help=f"baud rate, default {DEFAULT_BAUD}")
    parser.add_argument(
        "--wake-sequence",
        type=parse_wake_sequence,
        default=DEFAULT_WAKE_SEQUENCE,
        help="monitor wake byte sequence, default '0xA5 0x5A 0xC3 0x3C'",
    )
    parser.add_argument("--settle", type=float, default=0.2, help="delay after opening the port")
    parser.add_argument("--wait-prompt", type=float, default=2.0, help="seconds to wait for monitor prompt")
    parser.add_argument("--wake-retries", type=int, default=5, help="wake sequence retries before failing")
    parser.add_argument("--wake-gap", type=float, default=0.15, help="delay between wake-up retries")
    parser.add_argument("--command-delay", type=float, default=0.08, help="delay after monitor commands")
    parser.add_argument("--wait-dump", type=float, default=2.0, help="seconds to wait for each dump prompt")
    parser.add_argument(
        "--range",
        dest="ranges",
        action="append",
        type=parse_range,
        help="extra dump range as START-END or LABEL=START-END, hex without '$'",
    )
    parser.add_argument("--only-range", action="store_true", help="dump only --range entries, not defaults")
    parser.add_argument("--out", help="transcript output path, default .tmp/c64_monitor_probe_<timestamp>.txt")
    parser.add_argument("--resume", action="store_true", help="send G after dumping to release the C64")
    parser.add_argument("--verbose", action="store_true", help="print monitor transcript while dumping")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    serial = require_pyserial()

    ranges = [] if args.only_range else list(DEFAULT_RANGES)
    if args.ranges:
        ranges.extend(args.ranges)
    if not ranges:
        raise SystemExit("ERROR: no ranges selected")

    out_path = Path(args.out) if args.out else ROOT / ".tmp" / f"c64_monitor_probe_{datetime.now():%Y%m%d_%H%M%S}.txt"
    out_path.parent.mkdir(parents=True, exist_ok=True)

    print(f"Opening {args.port} @ {args.baud} baud")
    transcript = bytearray()
    with serial.Serial(args.port, args.baud, timeout=0.05, write_timeout=2) as port:
        time.sleep(args.settle)
        port.reset_input_buffer()

        print("Entering FPGA UART monitor")
        banner = enter_monitor(port, args)
        transcript.extend(banner)
        if args.verbose and banner:
            print(banner.decode("ascii", errors="replace"), end="")
        if not has_monitor_ready(banner):
            preview = response_preview(banner)
            detail = f"\nReceived while waiting:\n{preview}" if preview else ""
            raise SystemExit("ERROR: no monitor prompt received after wake-up" + detail)

        transcript.extend(read_register_snapshot(port, args))
        for label, start, end in ranges:
            transcript.extend(dump_range(port, label, start, end, args))

        if args.resume:
            print("Releasing C64 monitor")
            write_line(port, "G", args.command_delay)
            transcript.extend(read_some(port, 0.5))

    out_path.write_bytes(transcript)
    print(f"Wrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
