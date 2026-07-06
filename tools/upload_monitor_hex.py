#!/usr/bin/env python3
"""
Upload a binary image through the FPGA UART monitor hex loader.

The board now runs the small c64_prg_upload_monitor, entered over UART by a
four-byte magic wake sequence (A5 5A C3 3C) instead of a hardware button, so no
button press is needed -- this script sends the wake automatically. Pass
--no-wake if the monitor is already active (e.g. entered with the physical key).

Default workflow:
  python tools/upload_monitor_hex.py --build-demo --run

EhBASIC workflow (split around the $D000-$DFFF I/O window):
  python tools/upload_monitor_hex.py --ehbasic --run

Standalone split-ROM workflow (for example soundsid.rom):
  python tools/upload_monitor_hex.py roms/soundsid.rom --split-rom --run

The monitor commands used are:
  <magic wake A5 5A C3 3C>   (enter the monitor)
  L <address>
  <hex bytes...>
  .
  G <address>   (only with --run; "G aaaa" runs, a bare "G" would just release)
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_PORT = "COM15"
DEFAULT_BAUD = 115200
DEFAULT_ADDR = 0xC000
# Four-byte magic wake sequence for c64_prg_upload_monitor (same as the C64 board
# and tools/c64_uart_monitor_wake.py). Sending this over UART enters the monitor.
WAKE_SEQUENCE = bytes([0xA5, 0x5A, 0xC3, 0x3C])
MONITOR_BANNER = b"FPGA MONITOR"
DEFAULT_IMAGE = Path(__file__).resolve().parent.parent / "roms" / "6502" / "upload_demo.rom"
ROMS_DIR = Path(__file__).resolve().parent.parent / "roms" / "6502"
EHBASIC_SEGMENTS = (
    (ROMS_DIR / "fpga_kernel_F000.bin", 0xF000),
    (ROMS_DIR / "fpga_ehbasic_A000.bin", 0xA000),
)


def require_pyserial():
    try:
        import serial  # type: ignore
    except ImportError:
        print("ERROR: pyserial is not installed.", file=sys.stderr)
        print("Install it with: python -m pip install pyserial", file=sys.stderr)
        raise SystemExit(2)
    return serial


def build_demo() -> None:
    script = Path(__file__).resolve().parent / "make_upload_demo_rom.py"
    subprocess.run([sys.executable, str(script)], check=True)


def hex_lines(data: bytes, bytes_per_line: int) -> list[str]:
    # The FPGA monitor accepts plain two-digit hex bytes. Keeping lines modest
    # gives the UART receiver and command parser slack while keeping uploads quick.
    lines = []
    for offset in range(0, len(data), bytes_per_line):
        chunk = data[offset : offset + bytes_per_line]
        lines.append(" ".join(f"{byte:02X}" for byte in chunk))
    return lines


def read_some(port, seconds: float) -> bytes:
    # The monitor is intentionally simple and does not use an ACK per data line.
    # We sample the serial input around command boundaries to show prompts/errors
    # without blocking the streaming upload path.
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


def wake_monitor(port, retries: int, wait: float, verbose: bool) -> bool:
    """Enter the PRG upload monitor by sending the 4-byte UART magic sequence.

    Returns True once the "FPGA MONITOR" banner is seen. The sequence is retried
    a few times because a byte can be lost while the port settles after opening.
    """
    for attempt in range(retries):
        if verbose:
            print(f"wake attempt {attempt + 1}/{retries}")
        port.reset_input_buffer()
        port.write(WAKE_SEQUENCE + b"\r")
        port.flush()
        deadline = time.monotonic() + wait
        buf = bytearray()
        while time.monotonic() < deadline:
            waiting = getattr(port, "in_waiting", 0)
            if waiting:
                buf.extend(port.read(waiting))
                if MONITOR_BANNER in buf:
                    if verbose:
                        print(buf.decode("ascii", errors="replace"), end="")
                    return True
            else:
                time.sleep(0.02)
    return False


def check_monitor_response(response: bytes, operation: str) -> None:
    """Stop instead of reporting success when the FPGA monitor rejected a command."""
    text = response.decode("ascii", errors="replace")
    if "MEM/IO ONLY" in text or "\r\n?\r\n" in text:
        raise SystemExit(f"ERROR: monitor rejected {operation}: {text.strip()}")


def load_image(image: Path, length: int | None = None) -> bytes:
    data = image.read_bytes()
    if length is not None:
        data = data[:length]

    if not data:
        raise SystemExit(f"ERROR: image is empty: {image}")
    return data


def upload_segment(
    port, image: Path, address: int, args: argparse.Namespace, data: bytes | None = None
) -> None:
    if data is None:
        data = load_image(image, args.length if not args.ehbasic else None)

    print(f"Starting monitor upload: {image.name} -> ${address:04X}, {len(data)} bytes")
    write_line(port, f"L {address:04X}", args.command_delay)
    if args.wait_load:
        response = read_some(port, args.wait_load)
        if args.verbose and response:
            print(response.decode("ascii", errors="replace"), end="")
        check_monitor_response(response, f"L {address:04X}")

    sent = 0
    for line in hex_lines(data, args.bytes_per_line):
        # Data lines are fire-and-forget; the final "." is where the monitor
        # reports OK/ERR after the last byte has been committed.
        write_line(port, line, args.line_delay)
        sent += min(args.bytes_per_line, len(data) - sent)
        if args.progress and (sent == len(data) or sent % args.progress == 0):
            print(f"  {sent:5d}/{len(data)} bytes")

    write_line(port, ".", args.command_delay)
    response = read_some(port, args.wait_done)
    if args.verbose and response:
        print(response.decode("ascii", errors="replace"), end="")
    check_monitor_response(response, f"upload at ${address:04X}")


def upload(args: argparse.Namespace) -> None:
    serial = require_pyserial()
    if args.ehbasic:
        segments = tuple((image, address, None) for image, address in EHBASIC_SEGMENTS)
        run_address = 0xA000
        missing = [str(image) for image, _, _ in segments if not image.is_file()]
        if missing:
            raise SystemExit(
                "ERROR: EhBASIC segment(s) not found; run "
                "tools/build_fpga_ehbasic.py first:\n  " + "\n  ".join(missing)
            )
    elif args.split_rom:
        image = Path(args.image)
        data = load_image(image)
        if len(data) != 0x4000:
            raise SystemExit(
                f"ERROR: --split-rom requires a 16 KB image, got {len(data)} bytes: {image}"
            )
        # Upload the high window first, then the entry window. The image uses
        # boot_shadow_rom physical order, matching rom_offset().
        segments = (
            (image, 0xF000, data[0x3000:0x4000]),
            (image, 0xA000, data[0x0000:0x3000]),
        )
        run_address = 0xA000
    else:
        image = Path(args.image)
        if args.address == 0xC000 and image.is_file() and image.stat().st_size == 0x4000:
            raise SystemExit(
                "ERROR: a contiguous 16 KB upload at $C000 crosses the $D000-$EFFF "
                "I/O hole; rebuild for the split ROM map and use --split-rom"
            )
        segments = ((image, args.address, None),)
        run_address = args.address

    print(f"Opening {args.port} @ {args.baud} baud")
    with serial.Serial(args.port, args.baud, timeout=0.05, write_timeout=2) as port:
        time.sleep(args.settle)
        if args.no_wake:
            banner = read_some(port, 0.25)
            if banner and args.verbose:
                print(banner.decode("ascii", errors="replace"), end="")
        else:
            print("Waking monitor (magic A5 5A C3 3C) ...")
            if not wake_monitor(port, args.wake_retries, args.wake_wait, args.verbose):
                raise SystemExit(
                    "ERROR: no 'FPGA MONITOR' banner after the magic wake sequence. "
                    "Check the port/baud, or use --no-wake if the monitor is already active."
                )

        for image, address, data in segments:
            upload_segment(port, image, address, args, data)

        if args.run:
            print(f"Starting CPU at ${run_address:04X}")
            write_line(port, f"G {run_address:04X}", args.command_delay)
            response = read_some(port, args.wait_done)
            if args.verbose and response:
                print(response.decode("ascii", errors="replace"), end="")

    print("Upload complete")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", nargs="?", default=DEFAULT_IMAGE, help="binary image to upload")
    parser.add_argument("--port", default=DEFAULT_PORT, help=f"serial port, default {DEFAULT_PORT}")
    parser.add_argument("--baud", type=int, default=DEFAULT_BAUD, help=f"baud rate, default {DEFAULT_BAUD}")
    parser.add_argument("--address", type=lambda s: int(s, 0), default=DEFAULT_ADDR, help="load address")
    parser.add_argument("--length", type=lambda s: int(s, 0), help="limit upload length")
    parser.add_argument("--bytes-per-line", type=int, default=32, help="hex bytes per monitor line")
    parser.add_argument("--line-delay", type=float, default=0.005, help="delay after each data line")
    parser.add_argument("--command-delay", type=float, default=0.05, help="delay after monitor commands")
    parser.add_argument("--settle", type=float, default=0.2, help="delay after opening the port")
    parser.add_argument("--wait-load", type=float, default=0.4, help="seconds to read after L command")
    parser.add_argument("--wait-done", type=float, default=0.8, help="seconds to read after . or G")
    parser.add_argument("--progress", type=int, default=1024, help="progress interval in bytes, 0 disables")
    parser.add_argument("--run", action="store_true", help="send G <address> after upload")
    parser.add_argument("--no-wake", action="store_true",
                        help="skip the magic wake (monitor already active, e.g. via key)")
    parser.add_argument("--wake-retries", type=int, default=3, help="magic wake attempts")
    parser.add_argument("--wake-wait", type=float, default=1.0, help="seconds to wait per wake attempt")
    parser.add_argument(
        "--ehbasic", action="store_true",
        help="upload kernel to $F000, then EhBASIC to $A000 (use --run to start at $A000)",
    )
    parser.add_argument(
        "--split-rom", action="store_true",
        help="upload a 16 KB split-map image to $F000 and $A000, then run at $A000",
    )
    parser.add_argument("--build-demo", action="store_true", help="generate the default demo ROM first")
    parser.add_argument("--verbose", action="store_true", help="print monitor responses")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.ehbasic and args.split_rom:
        raise SystemExit("ERROR: --ehbasic and --split-rom are mutually exclusive")
    if args.build_demo:
        build_demo()
    upload(args)


if __name__ == "__main__":
    main()
