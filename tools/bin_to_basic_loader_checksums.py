#!/usr/bin/env python3
"""
Convert a raw 6502 binary into a sparse text BASIC loader with DATA lines.

Unlike a linear loader, this script does not blindly POKE the whole binary range.
It skips long runs of filler bytes, typically $00, and emits address records:

  DATA <addr_lo>,<addr_hi>,<count>,<byte0>,...,<byteN>,<record_checksum>

The record checksum is sum(addr_lo, addr_hi, count, payload bytes) modulo 256.
The final checksum is sum(payload bytes actually emitted) modulo 256.

This is useful for ld65 ROM images that contain code near $C000 and vectors near
$FFFA, with a large zero-filled gap in between.

Example:
  python bin_to_basic_sparse_loader.py mandelbrot_copro.bin mandelbrot_copro_loader.bas \
      --addr 0xC000 --sys 0xC000 --bytes-per-line 16 --min-skip 32 --drop-vectors --crlf
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Run:
    addr: int
    data: bytes


def parse_int(value: str) -> int:
    return int(value, 0)


def basic_line(line_no: int, text: str) -> str:
    return f"{line_no} {text}"


def split_sparse_runs(data: bytes, base_addr: int, fill: int, min_skip: int) -> list[Run]:
    """Return runs, skipping filler spans whose length is at least min_skip."""
    runs: list[Run] = []
    start = 0
    i = 0
    n = len(data)

    while i < n:
        if data[i] != fill:
            i += 1
            continue

        gap_start = i
        while i < n and data[i] == fill:
            i += 1
        gap_len = i - gap_start

        if gap_len >= min_skip:
            if gap_start > start:
                runs.append(Run(base_addr + start, data[start:gap_start]))
            start = i

    if start < n:
        runs.append(Run(base_addr + start, data[start:n]))

    return [r for r in runs if r.data]


def chunk_runs(runs: list[Run], bytes_per_line: int) -> list[Run]:
    chunks: list[Run] = []
    for run in runs:
        for off in range(0, len(run.data), bytes_per_line):
            chunks.append(Run(run.addr + off, run.data[off:off + bytes_per_line]))
    return chunks


def checksum(values: list[int] | bytes) -> int:
    return sum(values) & 0xFF


def maybe_drop_vectors(data: bytes, base_addr: int) -> bytes:
    """Drop bytes whose target addresses are $FFFA..$FFFF."""
    vector_start = 0xFFFA
    vector_end_exclusive = 0x10000
    image_start = base_addr
    image_end = base_addr + len(data)

    if image_end <= vector_start or image_start >= vector_end_exclusive:
        return data

    keep_end = max(0, vector_start - image_start)
    return data[:keep_end]


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Create a sparse BASIC DATA loader from a raw 6502 binary with address records and checksums."
    )
    parser.add_argument("input_bin", help="Input raw binary, e.g. mandelbrot_copro.bin")
    parser.add_argument("output_bas", help="Output BASIC text file")
    parser.add_argument("--addr", type=parse_int, required=True, help="Image base/load address, e.g. 0xC000 or 49152")
    parser.add_argument("--sys", dest="sys_addr", type=parse_int, default=None, help="SYS entry address. Defaults to --addr")
    parser.add_argument("--bytes-per-line", type=int, default=16, help="Payload bytes per DATA record, default 16")
    parser.add_argument("--fill", type=parse_int, default=0x00, help="Filler byte to skip, default 0x00")
    parser.add_argument("--min-skip", type=int, default=32, help="Minimum filler run length to skip, default 32")
    parser.add_argument("--drop-vectors", action="store_true", help="Do not emit bytes mapped to $FFFA..$FFFF. Useful for SYS-loaded programs.")
    parser.add_argument("--line-start", type=int, default=1000, help="First DATA line number, default 1000")
    parser.add_argument("--line-step", type=int, default=10, help="DATA line number step, default 10")
    parser.add_argument("--no-run", action="store_true", help="Do not SYS automatically after loading")
    parser.add_argument(
        "--crlf",
        action="store_true",
        help="Write CRLF line endings. Default is LF. Use CRLF if your UART sender prefers it.",
    )
    args = parser.parse_args()

    data = Path(args.input_bin).read_bytes()
    if not data:
        raise SystemExit("Input binary is empty.")

    addr = args.addr
    sys_addr = args.sys_addr if args.sys_addr is not None else addr
    fill = args.fill & 0xFF

    if not (0 <= addr <= 65535):
        raise SystemExit("Load address outside 16-bit address space.")
    if not (0 <= sys_addr <= 65535):
        raise SystemExit("SYS address outside 16-bit address space.")
    if addr + len(data) > 65536:
        raise SystemExit(f"Binary does not fit: ${addr:04X} + {len(data)} bytes exceeds $FFFF.")
    if not (1 <= args.bytes_per_line <= 24):
        raise SystemExit("Use 1..24 bytes per DATA line. 16 is safest for short BASIC lines.")
    if args.min_skip < 1:
        raise SystemExit("min-skip must be at least 1.")
    if not (0 <= args.fill <= 255):
        raise SystemExit("fill must be a byte value, e.g. 0x00 or 255.")
    if args.line_step <= 0:
        raise SystemExit("Line step must be positive.")

    original_size = len(data)
    if args.drop_vectors:
        data = maybe_drop_vectors(data, addr)
        if not data:
            raise SystemExit("After --drop-vectors no data remains.")

    sparse_runs = split_sparse_runs(data, addr, fill, args.min_skip)
    chunks = chunk_runs(sparse_runs, args.bytes_per_line)
    if not chunks:
        raise SystemExit("No non-filler data found. Adjust --fill or --min-skip.")

    emitted_bytes = sum(len(c.data) for c in chunks)
    total_checksum = checksum(b"".join(c.data for c in chunks))

    lines: list[str] = []
    lines.append(basic_line(1, "REM GENERATED SPARSE MACHINE-CODE LOADER"))
    lines.append(basic_line(2, f"REM IMAGE ${addr:04X}, INPUT SIZE {original_size}, EMIT {emitted_bytes}, SYS ${sys_addr:04X}"))
    lines.append(basic_line(3, f"REM RECORDS {len(chunks)}, FILL {fill}, MIN-SKIP {args.min_skip}, SUM {total_checksum}"))

    # Conservative BASIC: decimal constants, no AND, no hex literals, no integer suffixes.
    lines.append(basic_line(10, f"L={len(chunks)}:N={emitted_bytes}:S=0:P=0"))
    lines.append(basic_line(20, 'PRINT "LOADING ML..."'))
    lines.append(basic_line(30, "FOR R=1 TO L"))
    lines.append(basic_line(40, "READ AL,AH,K:A=AL+256*AH:C=AL+AH+K"))
    lines.append(basic_line(50, "IF C>255 THEN C=C-256"))
    lines.append(basic_line(60, "IF C>255 THEN C=C-256"))
    lines.append(basic_line(70, "FOR J=1 TO K"))
    lines.append(basic_line(80, "READ B:POKE A,B:A=A+1:P=P+1"))
    lines.append(basic_line(90, "S=S+B:IF S>255 THEN S=S-256"))
    lines.append(basic_line(100, "C=C+B:IF C>255 THEN C=C-256"))
    lines.append(basic_line(110, "NEXT J"))
    lines.append(basic_line(120, "READ X"))
    lines.append(basic_line(130, 'IF C<>X THEN PRINT "REC CHECK ERR"'))
    lines.append(basic_line(140, "IF C<>X THEN PRINT R;C;X:STOP"))
    lines.append(basic_line(150, "NEXT R"))
    lines.append(basic_line(160, "READ T"))
    lines.append(basic_line(170, 'IF P<>N THEN PRINT "SIZE ERR":PRINT P;N:STOP'))
    lines.append(basic_line(180, 'IF S<>T THEN PRINT "TOTAL CHECK ERR"'))
    lines.append(basic_line(190, "IF S<>T THEN PRINT S;T:STOP"))
    lines.append(basic_line(200, 'PRINT "OK"'))
    if args.no_run:
        lines.append(basic_line(210, f'PRINT "SYS {sys_addr}"'))
    else:
        lines.append(basic_line(210, f"SYS {sys_addr}"))
    lines.append(basic_line(220, "END"))

    line_no = args.line_start
    for chunk in chunks:
        al = chunk.addr & 0xFF
        ah = (chunk.addr >> 8) & 0xFF
        k = len(chunk.data)
        values = [al, ah, k, *chunk.data]
        rec_checksum = checksum(values)
        lines.append(basic_line(line_no, "DATA " + ",".join(str(v) for v in [*values, rec_checksum])))
        line_no += args.line_step
        if line_no > 63999:
            raise SystemExit("Line numbers exceeded 63999. Increase bytes-per-line or reduce line-step.")

    lines.append(basic_line(line_no, f"DATA {total_checksum}"))

    newline = "\r\n" if args.crlf else "\n"
    Path(args.output_bas).write_text(newline.join(lines) + newline, encoding="ascii")

    print(
        f"Wrote {args.output_bas}: input {original_size} bytes, emitted {emitted_bytes} bytes, "
        f"skipped {original_size - emitted_bytes} bytes, records {len(chunks)}, "
        f"base ${addr:04X}, SYS ${sys_addr:04X}, checksum {total_checksum}"
    )


if __name__ == "__main__":
    main()
