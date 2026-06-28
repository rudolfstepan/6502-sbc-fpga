#!/usr/bin/env python3
"""
Load a C64 .prg through the FPGA UART monitor.

The Tang C64 bitstream enters the monitor when the PC sends any byte on the
CH340 UART. This tool sends a wake-up CR, uploads the PRG payload to the load
address stored in the first two bytes, fixes BASIC pointers for normal $0801
programs, then sends "G" without an address so the C64 resumes at READY.

Example:
  python tools/c64_uart_prg_loader.py demo.prg --port COM15

After upload of a BASIC PRG, type RUN on the C64.
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

DEFAULT_PORT = "COM15"
DEFAULT_BAUD = 115200
PROMPTS = (b"> ", b">", b". ", b".")


def require_pyserial():
    try:
        import serial  # type: ignore
    except ImportError:
        print("ERROR: pyserial is not installed.", file=sys.stderr)
        print("Install it with: python -m pip install pyserial", file=sys.stderr)
        raise SystemExit(2)
    return serial


def read_some(port, seconds: float) -> bytes:
    deadline = time.monotonic() + seconds
    out = bytearray()
    while time.monotonic() < deadline:
        waiting = getattr(port, "in_waiting", 0)
        if waiting:
            out.extend(port.read(waiting))
        else:
            time.sleep(0.02)
    return bytes(out)


def write_line(port, text: str, delay: float) -> None:
    port.write(text.encode("ascii") + b"\r")
    port.flush()
    if delay:
        time.sleep(delay)


def wait_for_prompt(port, timeout: float) -> bytes:
    deadline = time.monotonic() + timeout
    out = bytearray()
    while time.monotonic() < deadline:
        waiting = getattr(port, "in_waiting", 0)
        if waiting:
            out.extend(port.read(waiting))
            if any(prompt in out or out.endswith(prompt) for prompt in PROMPTS):
                break
        else:
            time.sleep(0.02)
    return bytes(out)


def enter_monitor(port, args: argparse.Namespace) -> bytes:
    out = bytearray()
    for attempt in range(args.wake_retries):
        if args.verbose:
            print(f"wake attempt {attempt + 1}/{args.wake_retries}")
        port.write(b"\r")
        port.flush()
        out.extend(wait_for_prompt(port, args.wait_prompt))
        if any(prompt in out for prompt in PROMPTS):
            return bytes(out)
        time.sleep(args.wake_gap)
    return bytes(out)


def check_monitor_response(response: bytes, operation: str) -> None:
    text = response.decode("ascii", errors="replace")
    if "MEM/IO ONLY" in text or "\r\n?\r\n" in text or text.strip() == "?":
        raise SystemExit(f"ERROR: monitor rejected {operation}: {text.strip()}")


def hex_lines(data: bytes, bytes_per_line: int) -> list[str]:
    return [
        " ".join(f"{byte:02X}" for byte in data[offset : offset + bytes_per_line])
        for offset in range(0, len(data), bytes_per_line)
    ]


def upload_bytes(port, address: int, data: bytes, args: argparse.Namespace, label: str) -> None:
    print(f"Uploading {label}: ${address:04X}-${address + len(data) - 1:04X} ({len(data)} bytes)")
    write_line(port, f"L {address:04X}", args.command_delay)
    response = read_some(port, args.wait_load)
    if args.verbose and response:
        print(response.decode("ascii", errors="replace"), end="")
    check_monitor_response(response, f"L ${address:04X}")

    sent = 0
    for line in hex_lines(data, args.bytes_per_line):
        write_line(port, line, args.line_delay)
        sent += min(args.bytes_per_line, len(data) - sent)
        if args.progress and (sent == len(data) or sent % args.progress == 0):
            print(f"  {sent:5d}/{len(data)} bytes")

    write_line(port, ".", args.command_delay)
    response = wait_for_prompt(port, args.wait_done)
    if args.verbose and response:
        print(response.decode("ascii", errors="replace"), end="")
    check_monitor_response(response, f"upload {label}")


def basic_pointer_patch(load_addr: int, end_addr: int) -> bytes:
    return bytes(
        [
            load_addr & 0xFF,
            load_addr >> 8,
            end_addr & 0xFF,
            end_addr >> 8,
            end_addr & 0xFF,
            end_addr >> 8,
            end_addr & 0xFF,
            end_addr >> 8,
        ]
    )


def load_prg(path: Path) -> tuple[int, bytes]:
    raw = path.read_bytes()
    if len(raw) < 3:
        raise SystemExit(f"ERROR: PRG is too small: {path}")
    load_addr = raw[0] | (raw[1] << 8)
    data = raw[2:]
    end_addr = load_addr + len(data)
    if end_addr > 0x10000:
        raise SystemExit(
            f"ERROR: PRG does not fit in 64K: load ${load_addr:04X}, {len(data)} bytes"
        )
    return load_addr, data


def upload(args: argparse.Namespace) -> None:
    serial = require_pyserial()
    image = Path(args.prg)
    load_addr, data = load_prg(image)
    end_addr = load_addr + len(data)

    print(f"Opening {args.port} @ {args.baud} baud")
    with serial.Serial(args.port, args.baud, timeout=0.05, write_timeout=2) as port:
        time.sleep(args.settle)
        port.reset_input_buffer()

        print("Entering FPGA UART monitor")
        banner = enter_monitor(port, args)
        if args.verbose and banner:
            print(banner.decode("ascii", errors="replace"), end="")
        if not any(prompt in banner for prompt in PROMPTS):
            preview = banner.decode("ascii", errors="replace").strip()
            if len(preview) > 500:
                preview = preview[-500:]
            detail = f"\nReceived while waiting:\n{preview}" if preview else ""
            raise SystemExit("ERROR: no monitor prompt received after wake-up" + detail)

        upload_bytes(port, load_addr, data, args, image.name)

        if args.basic or (args.auto_basic and load_addr == 0x0801):
            patch = basic_pointer_patch(load_addr, end_addr)
            upload_bytes(port, 0x002B, patch, args, "BASIC pointers $2B-$32")
            print(f"BASIC end set to ${end_addr:04X}")

        if not args.stay:
            print("Releasing C64 monitor")
            write_line(port, "G", args.command_delay)
            response = read_some(port, args.wait_done)
            if args.verbose and response:
                print(response.decode("ascii", errors="replace"), end="")

    print("Upload complete")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prg", help="C64 .prg file")
    parser.add_argument("--port", default=DEFAULT_PORT, help=f"serial port, default {DEFAULT_PORT}")
    parser.add_argument("--baud", type=int, default=DEFAULT_BAUD, help=f"baud rate, default {DEFAULT_BAUD}")
    parser.add_argument("--bytes-per-line", type=int, default=32, help="hex bytes per monitor line")
    parser.add_argument("--line-delay", type=float, default=0.005, help="delay after each data line")
    parser.add_argument("--command-delay", type=float, default=0.05, help="delay after monitor commands")
    parser.add_argument("--settle", type=float, default=0.2, help="delay after opening the port")
    parser.add_argument("--wait-prompt", type=float, default=2.0, help="seconds to wait for monitor prompt")
    parser.add_argument("--wake-retries", type=int, default=5, help="wake-up CR retries before failing")
    parser.add_argument("--wake-gap", type=float, default=0.15, help="delay between wake-up retries")
    parser.add_argument("--wait-load", type=float, default=0.4, help="seconds to read after L command")
    parser.add_argument("--wait-done", type=float, default=1.0, help="seconds to wait after upload or G")
    parser.add_argument("--progress", type=int, default=1024, help="progress interval in bytes, 0 disables")
    parser.add_argument("--basic", action="store_true", help="force BASIC pointer patch")
    parser.add_argument(
        "--no-auto-basic",
        dest="auto_basic",
        action="store_false",
        help="do not patch BASIC pointers automatically for load address $0801",
    )
    parser.add_argument("--stay", action="store_true", help="leave the FPGA monitor active after upload")
    parser.add_argument("--verbose", action="store_true", help="print monitor responses")
    parser.set_defaults(auto_basic=True)
    return parser.parse_args()


def main() -> None:
    upload(parse_args())


if __name__ == "__main__":
    main()
