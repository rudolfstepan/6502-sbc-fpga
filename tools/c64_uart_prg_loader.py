#!/usr/bin/env python3
"""
Load a C64 .prg through the FPGA UART monitor.

The Tang C64 bitstream enters the monitor when the PC sends the monitor wake
sequence on the CH340 UART. This tool sends that wake-up sequence, uploads the PRG
payload to the load address stored in the first two bytes, fixes BASIC pointers
for normal $0801 programs, then sends "G" without an address so the C64 resumes
at READY.

If a generated <file>.prg.segments.json sidecar exists, only the listed memory
segments are uploaded. This keeps normal PRGs compatible while avoiding large
zero-filled gaps between a BASIC header and high SID payloads.

The UART is fixed at 115200 baud in the current Tang C64 bitstream. Upload speed
therefore mostly comes from reducing Python/line overhead: the default streams
16 hex bytes per monitor line without an artificial inter-line delay. Use
`--safe` if a board/bitstream still needs the older one-byte pacing.

Example:
  python tools/c64_uart_prg_loader.py demo.prg --port COM15

After upload of a BASIC PRG, type RUN on the C64.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

DEFAULT_PORT = "COM15"
DEFAULT_BAUD = 115200
DEFAULT_WAKE_SEQUENCE = bytes([0xA5, 0x5A, 0xC3, 0x3C])
DEFAULT_BYTES_PER_LINE = 16
DEFAULT_LINE_DELAY = 0.0
SAFE_BYTES_PER_LINE = 1
SAFE_LINE_DELAY = 0.001
DEFAULT_COMMAND_DELAY = 0.08
DEFAULT_WAIT_LOAD = 1.0
DEFAULT_WAIT_DONE = 1.5
COMMAND_PROMPTS = (b". ",)
LOAD_PROMPTS = (b"> ",)
MONITOR_BANNER = b"FPGA MONITOR"
MONITOR_HELP = b"H for help"
MONITOR_USB_DIAG = b"USB CON="
MONITOR_ERROR_PROMPT = b"\r\n?\r\n. "
SEGMENT_FORMAT = "c64-uart-prg-segments-v1"


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


def write_line(port, text: str, delay: float, *, flush: bool = True) -> None:
    port.write(text.encode("ascii") + b"\r")
    if flush:
        port.flush()
    if delay:
        time.sleep(delay)


def parse_byte(value: str) -> int:
    try:
        byte = int(value, 0)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid byte value: {value}") from exc
    if byte < 0 or byte > 0xFF:
        raise argparse.ArgumentTypeError("byte value must be in range 0..255")
    return byte


def parse_wake_sequence(value: str) -> bytes:
    cleaned = value.replace(",", " ").replace(":", " ").replace("-", " ")
    parts = [part for part in cleaned.split() if part]
    if not parts:
        raise argparse.ArgumentTypeError("wake sequence must not be empty")
    try:
        data = bytes(parse_byte(part) for part in parts)
    except argparse.ArgumentTypeError:
        raise
    except Exception as exc:
        raise argparse.ArgumentTypeError(f"invalid wake sequence: {value}") from exc
    return data


def has_prompt(data: bytes, prompts: tuple[bytes, ...]) -> bool:
    for prompt in prompts:
        start = 0
        while True:
            pos = data.find(prompt, start)
            if pos < 0:
                break
            if pos == 0 or data[pos - 1] in (0x0A, 0x0D):
                return True
            start = pos + 1
    return False


def has_monitor_ready(data: bytes) -> bool:
    if (
        MONITOR_BANNER in data
        or MONITOR_HELP in data
        or MONITOR_USB_DIAG in data
    ) and has_prompt(data, COMMAND_PROMPTS):
        return True
    if MONITOR_ERROR_PROMPT in data or data.startswith(MONITOR_ERROR_PROMPT[2:]):
        return True
    return False


def response_preview(data: bytes, limit: int = 500) -> str:
    text = data.decode("ascii", errors="replace").strip()
    if len(text) > limit:
        text = text[-limit:]
    return text


def wait_for_prompt(port, timeout: float, prompts: tuple[bytes, ...]) -> bytes:
    deadline = time.monotonic() + timeout
    out = bytearray()
    while time.monotonic() < deadline:
        waiting = getattr(port, "in_waiting", 0)
        if waiting:
            out.extend(port.read(waiting))
            if has_prompt(out, prompts):
                break
        else:
            time.sleep(0.02)
    return bytes(out)


def wait_for_monitor_ready(port, timeout: float) -> bytes:
    deadline = time.monotonic() + timeout
    out = bytearray()
    while time.monotonic() < deadline:
        waiting = getattr(port, "in_waiting", 0)
        if waiting:
            out.extend(port.read(waiting))
            if has_monitor_ready(out):
                break
        else:
            time.sleep(0.02)
    return bytes(out)


def enter_monitor(port, args: argparse.Namespace) -> bytes:
    out = bytearray()
    for attempt in range(args.wake_retries):
        if args.verbose:
            print(f"wake attempt {attempt + 1}/{args.wake_retries}")
        port.write(args.wake_sequence + b"\r")
        port.flush()
        out.extend(wait_for_monitor_ready(port, args.wait_prompt))
        if has_monitor_ready(out):
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
    response = wait_for_prompt(port, args.wait_load, LOAD_PROMPTS)
    if args.verbose and response:
        print(response.decode("ascii", errors="replace"), end="")
    check_monitor_response(response, f"L ${address:04X}")
    if not has_prompt(response, LOAD_PROMPTS):
        preview = response_preview(response)
        detail = f"\nReceived after L command:\n{preview}" if preview else ""
        raise SystemExit(f"ERROR: monitor did not enter load mode at ${address:04X}" + detail)

    sent = 0
    start = time.monotonic()
    for line in hex_lines(data, args.bytes_per_line):
        write_line(port, line, args.line_delay, flush=False)
        sent += min(args.bytes_per_line, len(data) - sent)
        if args.progress and (sent == len(data) or sent % args.progress == 0):
            print(f"  {sent:5d}/{len(data)} bytes")
    port.flush()
    elapsed = max(time.monotonic() - start, 0.001)
    print(f"  data stream: {elapsed:.2f}s, {len(data) / elapsed:.0f} B/s")

    write_line(port, ".", args.command_delay)
    response = wait_for_prompt(port, args.wait_done, COMMAND_PROMPTS)
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


def load_prg(path: Path) -> tuple[int, bytes, bytes]:
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
    return load_addr, data, raw


def default_segment_paths(path: Path) -> list[Path]:
    return [
        path.with_suffix(path.suffix + ".segments.json"),
        path.with_suffix(".segments.json"),
    ]


def find_segment_path(path: Path, args: argparse.Namespace) -> Path | None:
    if args.no_segments:
        return None
    if args.segments:
        seg = Path(args.segments)
        if not seg.exists():
            raise SystemExit(f"ERROR: segment map not found: {seg}")
        return seg
    for seg in default_segment_paths(path):
        if seg.exists():
            return seg
    return None


def load_segment_map(path: Path, raw: bytes, args: argparse.Namespace):
    seg_path = find_segment_path(path, args)
    if seg_path is None:
        return None

    try:
        meta = json.loads(seg_path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"ERROR: cannot read segment map {seg_path}: {exc}") from exc

    if meta.get("format") != SEGMENT_FORMAT:
        raise SystemExit(f"ERROR: unsupported segment map format in {seg_path}")
    try:
        expected_size = int(meta.get("prg_size", len(raw)))
        expected_load = int(meta.get("load_address", raw[0] | (raw[1] << 8)))
    except (TypeError, ValueError) as exc:
        raise SystemExit(f"ERROR: invalid segment map metadata in {seg_path}") from exc
    if expected_size != len(raw):
        raise SystemExit(
            f"ERROR: segment map {seg_path.name} was built for {expected_size} bytes, "
            f"but {path.name} has {len(raw)} bytes"
        )
    actual_load = raw[0] | (raw[1] << 8)
    if expected_load != actual_load:
        raise SystemExit(
            f"ERROR: segment map {seg_path.name} load address ${expected_load:04X} "
            f"does not match {path.name} load address ${actual_load:04X}"
        )

    segments = []
    for index, item in enumerate(meta.get("segments", []), start=1):
        try:
            address = int(item["address"])
            offset = int(item["offset"])
            size = int(item["size"])
        except (KeyError, TypeError, ValueError) as exc:
            raise SystemExit(f"ERROR: invalid segment {index} in {seg_path}") from exc
        if address < 0 or address > 0xFFFF or size < 0 or address + size > 0x10000:
            raise SystemExit(f"ERROR: segment {index} address/size out of C64 RAM range")
        if offset < 0 or offset + size > len(raw):
            raise SystemExit(f"ERROR: segment {index} points outside {path.name}")
        if size == 0:
            continue
        label = str(item.get("name", f"segment {index}"))
        segments.append((address, raw[offset:offset + size], label))

    if not segments:
        raise SystemExit(f"ERROR: segment map {seg_path} has no uploadable segments")

    return {
        "path": seg_path,
        "segments": segments,
        "basic_end": meta.get("basic_end"),
    }


def upload(args: argparse.Namespace) -> None:
    serial = require_pyserial()
    image = Path(args.prg)
    load_addr, data, raw = load_prg(image)
    end_addr = load_addr + len(data)
    segment_map = load_segment_map(image, raw, args)
    if segment_map and segment_map["basic_end"] is not None:
        try:
            end_addr = int(segment_map["basic_end"])
        except (TypeError, ValueError) as exc:
            raise SystemExit(f"ERROR: invalid basic_end in {segment_map['path']}") from exc

    print(f"Opening {args.port} @ {args.baud} baud")
    with serial.Serial(args.port, args.baud, timeout=0.05, write_timeout=2) as port:
        time.sleep(args.settle)
        port.reset_input_buffer()

        print("Entering FPGA UART monitor")
        banner = enter_monitor(port, args)
        if args.verbose and banner:
            print(banner.decode("ascii", errors="replace"), end="")
        if not has_monitor_ready(banner):
            preview = response_preview(banner)
            detail = f"\nReceived while waiting:\n{preview}" if preview else ""
            raise SystemExit("ERROR: no monitor prompt received after wake-up" + detail)
        port.reset_input_buffer()

        if segment_map:
            total = sum(len(seg_data) for _, seg_data, _ in segment_map["segments"])
            print(
                f"Using segment map {segment_map['path'].name}: "
                f"{total} uploaded bytes instead of {len(data)}"
            )
            for address, seg_data, label in segment_map["segments"]:
                upload_bytes(port, address, seg_data, args, f"{image.name} {label}")
        else:
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
    parser.add_argument(
        "--wake-sequence",
        type=parse_wake_sequence,
        default=DEFAULT_WAKE_SEQUENCE,
        help="monitor wake byte sequence, default '0xA5 0x5A 0xC3 0x3C'",
    )
    parser.add_argument(
        "--wake-byte",
        type=parse_byte,
        default=None,
        help="legacy single-byte monitor wake override",
    )
    parser.add_argument(
        "--bytes-per-line",
        type=int,
        default=DEFAULT_BYTES_PER_LINE,
        help=f"hex bytes per monitor line, default {DEFAULT_BYTES_PER_LINE}",
    )
    parser.add_argument(
        "--line-delay",
        type=float,
        default=DEFAULT_LINE_DELAY,
        help=f"delay after each data line, default {DEFAULT_LINE_DELAY}",
    )
    parser.add_argument(
        "--safe",
        action="store_true",
        help=f"use old conservative pacing ({SAFE_BYTES_PER_LINE} byte/line, {SAFE_LINE_DELAY}s line delay)",
    )
    parser.add_argument(
        "--command-delay",
        type=float,
        default=DEFAULT_COMMAND_DELAY,
        help=f"delay after monitor commands, default {DEFAULT_COMMAND_DELAY}",
    )
    parser.add_argument("--settle", type=float, default=0.2, help="delay after opening the port")
    parser.add_argument("--wait-prompt", type=float, default=2.0, help="seconds to wait for monitor prompt")
    parser.add_argument("--wake-retries", type=int, default=5, help="wake sequence retries before failing")
    parser.add_argument("--wake-gap", type=float, default=0.15, help="delay between wake-up retries")
    parser.add_argument("--wait-load", type=float, default=DEFAULT_WAIT_LOAD, help="seconds to wait for load prompt")
    parser.add_argument("--wait-done", type=float, default=DEFAULT_WAIT_DONE, help="seconds to wait after upload or G")
    parser.add_argument("--progress", type=int, default=1024, help="progress interval in bytes, 0 disables")
    parser.add_argument("--basic", action="store_true", help="force BASIC pointer patch")
    parser.add_argument(
        "--no-auto-basic",
        dest="auto_basic",
        action="store_false",
        help="do not patch BASIC pointers automatically for load address $0801",
    )
    parser.add_argument("--stay", action="store_true", help="leave the FPGA monitor active after upload")
    parser.add_argument(
        "--segments",
        help="explicit JSON segment map; default auto-detects <file>.prg.segments.json",
    )
    parser.add_argument(
        "--no-segments",
        action="store_true",
        help="ignore sidecar segment maps and upload the contiguous PRG image",
    )
    parser.add_argument("--verbose", action="store_true", help="print monitor responses")
    parser.set_defaults(auto_basic=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.wake_byte is not None:
        args.wake_sequence = bytes([args.wake_byte])
    if args.safe:
        args.bytes_per_line = SAFE_BYTES_PER_LINE
        args.line_delay = SAFE_LINE_DELAY
    if args.bytes_per_line < 1:
        raise SystemExit("ERROR: --bytes-per-line must be at least 1")
    if args.line_delay < 0:
        raise SystemExit("ERROR: --line-delay must not be negative")
    upload(args)


if __name__ == "__main__":
    main()
