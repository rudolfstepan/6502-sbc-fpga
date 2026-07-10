#!/usr/bin/env python3
"""Upload a raw big-endian 68000 binary through the System16 UART monitor."""

from __future__ import annotations

import argparse
import re
import sys
import time
from pathlib import Path


SDRAM_BASE = 0x001000
SDRAM_END = 0xF00000


def parse_int(value: str) -> int:
    return int(value, 0)


def read_prompt(port, timeout: float) -> bytes:
    deadline = time.monotonic() + timeout
    response = bytearray()
    while time.monotonic() < deadline:
        chunk = port.read(256)
        if chunk:
            response.extend(chunk)
            if response.endswith(b"> "):
                return bytes(response)
    raise TimeoutError(f"monitor timeout; response={response!r}")


def command(port, text: str, timeout: float) -> bytes:
    port.write(text.encode("ascii"))
    port.flush()
    response = read_prompt(port, timeout)
    if b"ERROR" in response:
        raise RuntimeError(f"monitor rejected {text!r}: {response!r}")
    return response


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--port", required=True)
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--address", type=parse_int, default=SDRAM_BASE)
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--timeout", type=float, default=2.0)
    args = parser.parse_args()

    try:
        import serial  # type: ignore
    except ImportError:
        print("pyserial is required: python -m pip install pyserial", file=sys.stderr)
        return 2

    data = args.binary.read_bytes()
    if not data:
        raise ValueError("binary is empty")
    if args.address & 1:
        raise ValueError("load address must be even")
    if len(data) & 1:
        data += b"\x00"
    if args.address < SDRAM_BASE or args.address + len(data) > SDRAM_END:
        raise ValueError("binary does not fit in the external SDRAM range")

    words = [int.from_bytes(data[pos : pos + 2], "big") for pos in range(0, len(data), 2)]

    with serial.Serial(args.port, args.baud, timeout=0.05, write_timeout=2) as port:
        port.reset_input_buffer()
        command(port, "\r", args.timeout)

        for index, word in enumerate(words):
            address = args.address + 2 * index
            response = command(port, f"W{address:06X}{word:04X}", args.timeout)
            if b" OK" not in response:
                raise RuntimeError(f"write failed at ${address:06X}: {response!r}")
            if (index + 1) % 256 == 0 or index + 1 == len(words):
                print(f"uploaded {2 * (index + 1)}/{len(data)} bytes", flush=True)

        if args.verify:
            for index, expected in enumerate(words):
                address = args.address + 2 * index
                response = command(port, f"M{address:06X}", args.timeout)
                match = re.search(rb" = \$([0-9A-Fa-f]{4})", response)
                if match is None or int(match.group(1), 16) != expected:
                    raise RuntimeError(
                        f"verify failed at ${address:06X}: expected ${expected:04X}, "
                        f"response={response!r}"
                    )
            print(f"verified {len(data)} bytes", flush=True)

        if args.run:
            port.write(f"G{args.address:06X}".encode("ascii"))
            port.flush()
            try:
                response = read_prompt(port, args.timeout)
                sys.stdout.write(response.decode("ascii", errors="replace"))
            except TimeoutError:
                print(f"started program at ${args.address:06X}")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, TimeoutError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
