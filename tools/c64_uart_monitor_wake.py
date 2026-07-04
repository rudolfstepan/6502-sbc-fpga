#!/usr/bin/env python3
"""Wake the Tang C64 UART monitor and talk to it interactively.

The C64 bitstream shares the CH340 UART between the SD floppy debug output and
the small PRG upload monitor (c64_prg_upload_monitor). Sending the four-byte
wake sequence A5 5A C3 3C pauses the C64 and brings up the monitor prompt:

    FPGA MONITOR
    .

Commands the small monitor understands:
    L aaaa       enter hex load mode at address aaaa (then send hex bytes)
    .            leave load mode, back to the prompt
    M aaaa bbbb  hex dump aaaa..bbbb (RAM under ROM/I/O, 8 bytes per line
                 plus ASCII column, non-printable bytes shown as '.')
    G            release the C64 and leave the monitor

Examples:
    python tools/c64_uart_monitor_wake.py --port COM15          # wake + terminal
    python tools/c64_uart_monitor_wake.py --port COM15 --release
"""
from __future__ import annotations

import argparse
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("pyserial fehlt: pip install pyserial")

DEFAULT_PORT = "COM15"
DEFAULT_BAUD = 115200
WAKE_SEQUENCE = bytes([0xA5, 0x5A, 0xC3, 0x3C])
BANNER = b"FPGA MONITOR"
PROMPT = b". "


def read_available(port) -> bytes:
    waiting = getattr(port, "in_waiting", 0)
    return port.read(waiting) if waiting else b""


def wake_monitor(port, retries: int, wait: float, verbose: bool) -> bytes:
    out = bytearray()
    for attempt in range(retries):
        if verbose:
            print(f"wake attempt {attempt + 1}/{retries}")
        port.reset_input_buffer()
        port.write(WAKE_SEQUENCE + b"\r")
        port.flush()
        deadline = time.monotonic() + wait
        while time.monotonic() < deadline:
            out.extend(read_available(port))
            if BANNER in out and out.rstrip().endswith(PROMPT.rstrip()):
                return bytes(out)
            time.sleep(0.02)
    return bytes(out)


def terminal(port) -> None:
    print("verbunden -- Kommandos: L aaaa / . / M aaaa bbbb / G")
    print("(G beendet auch dieses Tool, Ctrl+C bricht ab, ohne den C64 freizugeben)")
    try:
        while True:
            line = input("> ").strip()
            if not line:
                continue
            port.write(line.encode("ascii", errors="replace") + b"\r")
            port.flush()
            # keep reading until the monitor has been quiet for a moment --
            # an M dump over a large range streams for a while
            response = bytearray()
            quiet = 0.0
            while quiet < 0.5:
                chunk = read_available(port)
                if chunk:
                    response.extend(chunk)
                    sys.stdout.write(chunk.decode("ascii", errors="replace"))
                    sys.stdout.flush()
                    quiet = 0.0
                else:
                    time.sleep(0.05)
                    quiet += 0.05
            if response and not bytes(response).endswith(b"\n"):
                print()
            if line.upper() == "G":
                print("C64 freigegeben.")
                return
    except (KeyboardInterrupt, EOFError):
        print("\nabgebrochen -- Monitor ist noch aktiv (C64 pausiert)!")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", default=DEFAULT_PORT,
                        help=f"serieller Port, Default {DEFAULT_PORT}")
    parser.add_argument("--baud", type=int, default=DEFAULT_BAUD,
                        help=f"Baudrate, Default {DEFAULT_BAUD}")
    parser.add_argument("--retries", type=int, default=3,
                        help="Anzahl Wake-Versuche, Default 3")
    parser.add_argument("--wait", type=float, default=1.0,
                        help="Wartezeit pro Versuch in Sekunden, Default 1.0")
    parser.add_argument("--release", action="store_true",
                        help="nur wecken und sofort mit G wieder freigeben")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    with serial.Serial(args.port, args.baud, timeout=0.1) as port:
        banner = wake_monitor(port, args.retries, args.wait, args.verbose)
        if BANNER not in banner:
            preview = banner.decode("ascii", errors="replace").strip()
            print(f"FEHLER: kein Monitor-Banner (empfangen: {preview!r})")
            return 1
        print(banner.decode("ascii", errors="replace"), end="")
        if not banner.endswith(b"\n"):
            print()

        if args.release:
            port.write(b"G\r")
            port.flush()
            print("C64 freigegeben.")
            return 0

        terminal(port)
    return 0


if __name__ == "__main__":
    sys.exit(main())
