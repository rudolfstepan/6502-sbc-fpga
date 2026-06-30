#!/usr/bin/env python3
"""Virtual 1541 UART drive with a small Tk GUI.

The tool mounts one `.d64` image from a user-selected folder and answers simple
drive commands over a USB-UART link.  It is intentionally host-heavy: D64 parsing
and file lookup happen on the PC, while the FPGA only needs a tiny UART packet
client.

Binary UART request frame, FPGA -> PC:
    C6 CMD LEN_LO LEN_HI PAYLOAD... CHECKSUM

Binary UART response frame, PC -> FPGA:
    64 CMD STATUS LEN_LO LEN_HI PAYLOAD... CHECKSUM

The checksum is the low byte of the sum from CMD through payload.  For quick
manual tests the same commands are also accepted as newline-terminated ASCII.
Besides the host-side shortcuts (PING, MOUNT, LOAD, SECTOR, ...), the server
also implements a small read-only 1541-like DOS/channel layer: DOS commands
(`I`, `UJ`, `B-R`, `B-P`, ...), OPEN/CLOSE/READ/WRITE and the status channel.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import queue
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import tkinter as tk
from tkinter import filedialog, messagebox, ttk

ROOT = Path(__file__).resolve().parents[2]
D64_TOOLS = ROOT / "tools" / "d64"
sys.path.insert(0, str(D64_TOOLS))

from d64_common import BAM_SECTOR, DIR_TRACK, D64_35_TRACK_SIZE, SECTOR_SIZE, d64_byte_offset, is_supported_size  # noqa: E402
from list_d64 import disk_name, iter_entries  # noqa: E402


REQ_MAGIC = 0xC6
RESP_MAGIC = 0x64

CMD_PING = 0x01
CMD_IMAGES = 0x10
CMD_MOUNT = 0x11
CMD_DIR = 0x12
CMD_LOAD_FIRST = 0x20
CMD_LOAD = 0x21
CMD_LOAD_FIRST_CHUNK = 0x22
CMD_LOAD_CHUNK = 0x23
CMD_SECTOR = 0x30
CMD_STATUS = 0x31
CMD_DOS = 0x40
CMD_OPEN = 0x41
CMD_CLOSE = 0x42
CMD_READ = 0x43
CMD_WRITE = 0x44

STATUS_OK = 0
STATUS_NO_DISK = 1
STATUS_NOT_FOUND = 2
STATUS_BAD_REQUEST = 3
STATUS_IO_ERROR = 4
STATUS_EOF = 5

CMD_NAMES = {
    CMD_PING: "PING",
    CMD_IMAGES: "IMAGES",
    CMD_MOUNT: "MOUNT",
    CMD_DIR: "DIR",
    CMD_LOAD_FIRST: "LOADFIRST",
    CMD_LOAD: "LOAD",
    CMD_LOAD_FIRST_CHUNK: "LOADFIRSTCHUNK",
    CMD_LOAD_CHUNK: "LOADCHUNK",
    CMD_SECTOR: "SECTOR",
    CMD_STATUS: "STATUS",
    CMD_DOS: "DOS",
    CMD_OPEN: "OPEN",
    CMD_CLOSE: "CLOSE",
    CMD_READ: "READ",
    CMD_WRITE: "WRITE",
}

BG = "#2b2a26"
APP_BG = "#24231f"
C64_BLUE = "#1d2a6d"
C64_BLUE_DARK = "#111844"
C64_BLUE_SEL = "#4d61c7"
C64_TEXT = "#d9dcff"
C64_MUTED = "#aeb3df"
C64_BORDER = "#79715f"
C64_BUTTON = "#d6cfb6"
C64_BUTTON_ACTIVE = "#efe6c9"
C64_FIELD = "#f4ecd2"
CASE_TOP = "#d8d0b6"
CASE_SIDE = "#b8ae92"
CASE_SHADOW = "#7d735e"
PANEL = "#2f332f"
PANEL_EDGE = "#151715"
SLOT = "#111311"
LABEL = "#3c3428"
BRAND_RED = "#b63a2c"
LED_OFF = "#3c1915"
LED_RED = "#e23425"
LED_GREEN_OFF = "#17321c"
LED_GREEN = "#42d35f"
INK = "#26231d"
UI_FONT = ("Consolas", 11)
UI_FONT_BOLD = ("Consolas", 11, "bold")
LOG_FONT = ("Consolas", 10)
LOADABLE_TYPES = {"PRG", "SEQ", "USR"}
TYPE_ALIASES = {
    "P": "PRG",
    "PRG": "PRG",
    "S": "SEQ",
    "SEQ": "SEQ",
    "U": "USR",
    "USR": "USR",
}
SPEED_PRESETS = {
    "SAFE": (8, 0.005),
    "BALANCED": (32, 0.002),
    "FAST": (64, 0.001),
    "TURBO": (128, 0.0),
}


DEFAULT_SETTINGS = {
    "folder": str(ROOT / "roms" / "test_d64"),
    "port": "COM12",
    "baud": 115200,
    "tx_chunk_size": 64,
    "tx_chunk_delay": 0.001,
    "sound_enabled": True,
    "mounted_image": "",
    "window_geometry": "1040x760",
}


def settings_path() -> Path:
    if sys.platform.startswith("win"):
        base = Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming"))
    else:
        base = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return base / "c64_virtual_1541_uart" / "settings.json"


def load_settings() -> dict[str, object]:
    path = settings_path()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def save_settings(data: dict[str, object]) -> None:
    path = settings_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def require_pyserial():
    try:
        import serial  # type: ignore
        from serial.tools import list_ports  # type: ignore
    except ImportError:
        return None, None
    return serial, list_ports


@dataclass(frozen=True)
class DirEntry:
    name: str
    type: str
    blocks: int
    first_track: int
    first_sector: int


@dataclass
class OpenChannel:
    name: str
    data: bytes
    pos: int = 0


def follow_prg_chain(data: bytes, track: int, sector: int) -> bytes:
    out = bytearray()
    seen: set[tuple[int, int]] = set()
    for _ in range(683):
        if (track, sector) in seen:
            raise ValueError(f"loop in file chain at T{track}/S{sector}")
        seen.add((track, sector))
        off = d64_byte_offset(track, sector)
        if off == 0xFFFFFFFF:
            raise ValueError(f"invalid file sector T{track}/S{sector}")
        sec = data[off : off + SECTOR_SIZE]
        if len(sec) != SECTOR_SIZE:
            raise ValueError(f"short file sector T{track}/S{sector}")
        next_t, next_s = sec[0], sec[1]
        if next_t == 0:
            if next_s >= 2:
                out.extend(sec[2 : next_s + 1])
            if len(out) < 2:
                raise ValueError("PRG has no load address")
            return bytes(out)
        out.extend(sec[2:])
        track, sector = next_t, next_s
    raise ValueError("file chain too long")


def decode_c64_name(raw: bytes) -> str:
    """Decode the KERNAL SETNAM byte string enough for D64 directory matching."""
    name = raw.strip(b"\x00 \xa0").strip(b'"')
    chars: list[str] = []
    for byte in name:
        if 0x20 <= byte < 0x7F:
            chars.append(chr(byte))
        elif 0x61 <= byte <= 0x7A:
            chars.append(chr(byte).upper())
        elif byte == 0xA0:
            chars.append(" ")
    return "".join(chars).strip()


def make_basic_prg(lines: list[tuple[int, str]]) -> bytes:
    addr = 0x0801
    body = bytearray()
    for line_no, text in lines:
        line = text.encode("ascii", errors="replace")
        next_addr = addr + 4 + len(line) + 1
        body.extend((next_addr & 0xFF, next_addr >> 8, line_no & 0xFF, line_no >> 8))
        body.extend(line)
        body.append(0)
        addr = next_addr
    body.extend((0, 0))
    return bytes((0x01, 0x08)) + bytes(body)


class D64Drive:
    def __init__(self) -> None:
        self.folder = ROOT / "roms" / "test_d64"
        self.images: list[Path] = []
        self.mounted_path: Path | None = None
        self.mounted_data: bytes | None = None
        self.entries: list[DirEntry] = []
        self.disk_title = ""
        self.channels: dict[int, OpenChannel] = {}
        self.last_status = "73,VIRTUAL 1541 UART,00,00"
        self.rescan()

    def rescan(self) -> None:
        if not self.folder.exists():
            self.images = []
            return
        self.images = sorted((p for p in self.folder.iterdir() if p.is_file() and p.suffix.lower() == ".d64"), key=lambda p: p.name.lower())

    def set_folder(self, folder: Path) -> None:
        self.folder = folder
        self.mounted_path = None
        self.mounted_data = None
        self.entries = []
        self.disk_title = ""
        self.channels.clear()
        self.last_status = "74,DRIVE NOT READY,00,00"
        self.rescan()

    def mount(self, image_name: str) -> None:
        image = self._resolve_image(image_name)
        data = image.read_bytes()
        if not is_supported_size(len(data)):
            raise ValueError(f"unsupported D64 size {len(data)} bytes, expected {D64_35_TRACK_SIZE}")

        parsed: list[DirEntry] = []
        for entry in iter_entries(data):
            parsed.append(
                DirEntry(
                    name=entry["name"],
                    type=entry["type"],
                    blocks=entry["blocks"],
                    first_track=entry["first_track"],
                    first_sector=entry["first_sector"],
                )
            )

        self.mounted_path = image
        self.mounted_data = data
        self.entries = parsed
        self.disk_title = disk_name(data)
        self.channels.clear()
        self._set_status(0, "OK")

    def _resolve_image(self, image_name: str) -> Path:
        wanted = Path(image_name).name.lower()
        for image in self.images:
            if image.name.lower() == wanted:
                return image
        raise FileNotFoundError(image_name)

    def image_list_payload(self) -> bytes:
        return "\n".join(image.name for image in self.images).encode("utf-8")

    def directory_payload(self) -> bytes:
        self._require_disk()
        lines = [f'0 "{self.disk_title}" 00 2A']
        for entry in self.entries:
            lines.append(f'{entry.blocks:>4} "{entry.name}" {entry.type}')
        lines.append(f"{self.free_blocks()} BLOCKS FREE.")
        return ("\r".join(lines) + "\r").encode("ascii", errors="replace")

    def directory_prg_payload(self) -> bytes:
        self._require_disk()
        lines = [(0, f'"{self.disk_title}" 00 2A')]
        for entry in self.entries:
            lines.append((entry.blocks, f'"{entry.name}" {entry.type}'))
        lines.append((self.free_blocks(), "BLOCKS FREE."))
        return make_basic_prg(lines)

    def free_blocks(self) -> int:
        assert self.mounted_data is not None
        bam = self.read_sector(DIR_TRACK, BAM_SECTOR)
        return sum(bam[4 + (track - 1) * 4] for track in range(1, 36))

    def status_payload(self) -> bytes:
        if self.mounted_path is None and self.last_status.startswith("00,"):
            self._set_status(74, "DRIVE NOT READY")
        return self.last_status.encode("ascii", errors="replace")

    def _set_status(self, code: int, message: str, track: int = 0, sector: int = 0) -> str:
        self.last_status = f"{code:02d},{message},{track:02d},{sector:02d}"
        return self.last_status

    def load_first_prg(self) -> bytes:
        return self.load_entry(self.first_load_entry())

    def load_prg(self, name: str) -> bytes:
        return self.load_file(name)

    def load_file(self, name: str, file_type: str = "") -> bytes:
        if name.strip().startswith("$"):
            return self.directory_prg_payload()
        return self.load_entry(self.find_load_entry(name, file_type))

    def dos_command(self, command: str | bytes) -> bytes:
        if isinstance(command, bytes):
            command = decode_c64_name(command)
        raw = command.strip().strip('"')
        upper = raw.upper()
        if not upper:
            return self.status_payload()

        if upper in ("I", "I0", "UJ", "UI", "UI+", "UI-"):
            self.channels.clear()
            if self.mounted_path is None:
                self._set_status(74, "DRIVE NOT READY")
            elif upper == "UJ":
                self.last_status = "73,VIRTUAL 1541 UART,00,00"
            else:
                self._set_status(0, "OK")
            return self.status_payload()

        if upper in ("V", "V0"):
            self._require_disk()
            self._set_status(0, "OK")
            return self.status_payload()

        if upper.startswith("B-R"):
            track, sector, channel = self._parse_block_command(raw, default_channel=2)
            data = self.read_sector(track, sector)
            self.channels[channel] = OpenChannel(f"#{track},{sector}", data)
            self._set_status(0, "OK", track, sector)
            return self.status_payload()

        if upper.startswith("B-P"):
            channel, pos = self._parse_buffer_pointer(raw)
            if channel not in self.channels:
                self.channels[channel] = OpenChannel(f"#{channel}", bytes(SECTOR_SIZE))
            self.channels[channel].pos = max(0, min(pos, len(self.channels[channel].data)))
            self._set_status(0, "OK")
            return self.status_payload()

        if upper.startswith(("B-W", "B-A", "B-F", "N:", "S:", "R:", "C:", "M-W", "M-E")):
            self._set_status(26, "WRITE PROTECT ON")
            return self.status_payload()

        if upper.startswith("M-R"):
            self._set_status(31, "SYNTAX ERROR")
            return self.status_payload()

        self._set_status(30, "SYNTAX ERROR")
        return self.status_payload()

    def open_channel(self, channel: int, name: str | bytes) -> bytes:
        channel &= 0x0F
        if isinstance(name, bytes):
            name = decode_c64_name(name)
        spec = name.strip().strip('"')
        upper = spec.upper()
        if channel == 15:
            self.channels[channel] = OpenChannel("STATUS", b"")
            if upper:
                return self.dos_command(spec)
            return self.status_payload()
        if upper.startswith("#"):
            self.channels[channel] = OpenChannel(spec or f"#{channel}", bytes(SECTOR_SIZE))
            self._set_status(0, "OK")
            return self.status_payload()

        file_name, file_type, mode = self._split_file_spec(spec)
        if "W" in mode or "A" in mode:
            self._set_status(26, "WRITE PROTECT ON")
            return self.status_payload()

        try:
            data = self.load_file(file_name, file_type)
        except FileNotFoundError:
            self._set_status(62, "FILE NOT FOUND")
            raise
        self.channels[channel] = OpenChannel(file_name, data)
        self._set_status(0, "OK")
        return self.status_payload()

    def close_channel(self, channel: int) -> bytes:
        self.channels.pop(channel & 0x0F, None)
        self._set_status(0, "OK")
        return self.status_payload()

    def read_channel(self, channel: int, size: int) -> bytes:
        channel &= 0x0F
        size = max(0, min(size, 0xFFFF))
        if channel == 15:
            return self.status_payload() + b"\r"
        if channel not in self.channels:
            self._set_status(61, "FILE NOT OPEN")
            raise RuntimeError("file not open")
        ch = self.channels[channel]
        out = ch.data[ch.pos : ch.pos + size]
        ch.pos += len(out)
        if not out and ch.pos >= len(ch.data):
            self._set_status(64, "END OF FILE")
        else:
            self._set_status(0, "OK")
        return out

    def write_channel(self, channel: int, payload: bytes) -> bytes:
        channel &= 0x0F
        if channel == 15:
            return self.dos_command(payload)
        self._set_status(26, "WRITE PROTECT ON")
        return self.status_payload()

    def load_chunk(self, name: str, offset: int, size: int) -> tuple[DirEntry, bytes]:
        if size < 0 or size > 0xFFFF:
            raise ValueError("invalid chunk size")
        if name.strip().startswith("$"):
            data = self.directory_prg_payload()
            entry = DirEntry("$", "PRG", 0, 18, 0)
            return entry, data[offset : offset + size]
        entry = self.find_load_entry(name)
        data = self.load_entry(entry)
        return entry, data[offset : offset + size]

    def first_prg_entry(self) -> DirEntry:
        return self.first_load_entry({"PRG"})

    def first_load_entry(self, allowed_types: set[str] | None = None) -> DirEntry:
        self._require_disk()
        allowed = allowed_types or LOADABLE_TYPES
        for entry in self.entries:
            if entry.type in allowed:
                return entry
        raise FileNotFoundError("no loadable file on mounted image")

    def find_prg_entry(self, name: str) -> DirEntry:
        return self.find_load_entry(name, "PRG")

    def find_load_entry(self, name: str, file_type: str = "") -> DirEntry:
        self._require_disk()
        target = self._normalize_file_name(name).upper()
        requested_type = TYPE_ALIASES.get(file_type.upper(), "")
        allowed = {requested_type} if requested_type else LOADABLE_TYPES
        if target in ("*", ""):
            return self.first_load_entry(allowed)

        candidates = [entry for entry in self.entries if entry.type in allowed]
        for entry in candidates:
            if entry.name.upper() == target:
                return entry
        if "*" in target or "?" in target:
            for entry in candidates:
                if fnmatch.fnmatchcase(entry.name.upper(), target):
                    return entry
        raise FileNotFoundError(name)

    def load_entry(self, entry: DirEntry) -> bytes:
        assert self.mounted_data is not None
        return follow_prg_chain(self.mounted_data, entry.first_track, entry.first_sector)

    def read_sector(self, track: int, sector: int) -> bytes:
        self._require_disk()
        assert self.mounted_data is not None
        off = d64_byte_offset(track, sector)
        if off == 0xFFFFFFFF:
            self._set_status(66, "ILLEGAL TRACK OR SECTOR", track, sector)
            raise ValueError(f"invalid sector T{track}/S{sector}")
        return self.mounted_data[off : off + SECTOR_SIZE]

    def _require_disk(self) -> None:
        if self.mounted_data is None:
            self._set_status(74, "DRIVE NOT READY")
            raise RuntimeError("no disk mounted")

    @staticmethod
    def _split_file_spec(spec: str) -> tuple[str, str, str]:
        parts = [part.strip() for part in spec.split(",")]
        file_name = D64Drive._normalize_file_name(parts[0] if parts else "")
        file_type = ""
        mode_parts: list[str] = []
        for part in parts[1:]:
            upper = part.upper()
            if upper in TYPE_ALIASES:
                file_type = TYPE_ALIASES[upper]
            else:
                mode_parts.append(upper)
        mode = "".join(mode_parts)
        return file_name, file_type, mode

    @staticmethod
    def _normalize_file_name(name: str) -> str:
        out = name.strip().strip('"')
        if ":" in out:
            _drive, out = out.split(":", 1)
        return out.strip().strip('"')

    @staticmethod
    def _numbers(command: str) -> list[int]:
        tail = command.split(":", 1)[1] if ":" in command else command
        parts = tail.replace(",", " ").split()
        out: list[int] = []
        for part in parts[1:] if parts and parts[0].upper().startswith("B-") else parts:
            try:
                out.append(int(part, 0))
            except ValueError:
                pass
        return out

    def _parse_block_command(self, command: str, default_channel: int) -> tuple[int, int, int]:
        nums = self._numbers(command)
        if len(nums) >= 4:
            channel, _drive, track, sector = nums[:4]
        elif len(nums) >= 3:
            channel, track, sector = nums[:3]
        elif len(nums) >= 2:
            channel, track, sector = default_channel, nums[0], nums[1]
        else:
            self._set_status(30, "SYNTAX ERROR")
            raise ValueError("B-R expects channel,drive,track,sector")
        return track, sector, channel & 0x0F

    def _parse_buffer_pointer(self, command: str) -> tuple[int, int]:
        nums = self._numbers(command)
        if len(nums) >= 2:
            return nums[0] & 0x0F, nums[1] & 0xFF
        self._set_status(30, "SYNTAX ERROR")
        raise ValueError("B-P expects channel,position")


class Protocol:
    def __init__(
        self,
        drive: D64Drive,
        log: Callable[[str], None],
        mounted: Callable[[], None],
        progress: Callable[[dict[str, object]], None] | None = None,
    ) -> None:
        self.drive = drive
        self.log = log
        self.mounted = mounted
        self.progress = progress

    def _progress(self, phase: str, channel: int, name: str, pos: int, total: int) -> None:
        if self.progress is None:
            return
        self.progress({"phase": phase, "channel": channel, "name": name, "pos": pos, "total": total})

    def handle_binary(self, cmd: int, payload: bytes) -> tuple[int, bytes]:
        name = CMD_NAMES.get(cmd, f"${cmd:02X}")
        if cmd != CMD_READ:
            self.log(f"< {name} {len(payload)} bytes")
        try:
            if cmd == CMD_PING:
                return STATUS_OK, b"V1541 UART READY"
            if cmd == CMD_IMAGES:
                self.drive.rescan()
                return STATUS_OK, self.drive.image_list_payload()
            if cmd == CMD_MOUNT:
                self.drive.mount(payload.decode("utf-8", errors="replace").strip())
                self.mounted()
                return STATUS_OK, self.drive.status_payload()
            if cmd == CMD_DIR:
                return STATUS_OK, self.drive.directory_payload()
            if cmd == CMD_LOAD_FIRST:
                entry = self.drive.first_load_entry()
                self.log(f"  loading \"{entry.name}\" {entry.type} T{entry.first_track}/S{entry.first_sector}")
                data = self.drive.load_entry(entry)
                self.log(f"  loaded {len(data)} bytes")
                return STATUS_OK, data
            if cmd == CMD_LOAD_FIRST_CHUNK:
                if len(payload) != 4:
                    return STATUS_BAD_REQUEST, b"LOADFIRSTCHUNK expects offset,length"
                offset = payload[0] | (payload[1] << 8)
                size = payload[2] | (payload[3] << 8)
                entry = self.drive.first_load_entry()
                data = self.drive.load_entry(entry)
                chunk = data[offset : offset + size]
                self.log(f"  chunk \"{entry.name}\" {entry.type} +{offset} {len(chunk)}/{size}")
                return STATUS_OK, chunk
            if cmd == CMD_LOAD_CHUNK:
                if len(payload) < 4:
                    return STATUS_BAD_REQUEST, b"LOADCHUNK expects offset,length,name"
                offset = payload[0] | (payload[1] << 8)
                size = payload[2] | (payload[3] << 8)
                req_name = decode_c64_name(payload[4:])
                entry, chunk = self.drive.load_chunk(req_name, offset, size)
                self.log(f"  chunk \"{entry.name}\" +{offset} {len(chunk)}/{size}")
                return STATUS_OK, chunk
            if cmd == CMD_LOAD:
                req_name = decode_c64_name(payload)
                if req_name.startswith("$"):
                    self.log("  loading directory as BASIC PRG")
                    data = self.drive.load_prg(req_name)
                    self.log(f"  loaded {len(data)} bytes")
                    return STATUS_OK, data
                entry = self.drive.find_load_entry(req_name)
                self.log(f"  loading \"{entry.name}\" {entry.type} T{entry.first_track}/S{entry.first_sector}")
                data = self.drive.load_entry(entry)
                self.log(f"  loaded {len(data)} bytes")
                return STATUS_OK, data
            if cmd == CMD_SECTOR:
                if len(payload) != 2:
                    return STATUS_BAD_REQUEST, b"SECTOR expects track,sector"
                return STATUS_OK, self.drive.read_sector(payload[0], payload[1])
            if cmd == CMD_STATUS:
                return STATUS_OK, self.drive.status_payload()
            if cmd == CMD_DOS:
                return STATUS_OK, self.drive.dos_command(payload)
            if cmd == CMD_OPEN:
                if len(payload) < 1:
                    return STATUS_BAD_REQUEST, b"OPEN expects channel,name"
                channel = payload[0] & 0x0F
                req_name = decode_c64_name(payload[1:])
                self.log(f'  open channel {channel} "{req_name}"')
                response = self.drive.open_channel(payload[0], payload[1:])
                opened = self.drive.channels.get(channel)
                if opened is not None and channel != 15:
                    self._progress("start", channel, opened.name, 0, len(opened.data))
                return STATUS_OK, response
            if cmd == CMD_CLOSE:
                if len(payload) != 1:
                    return STATUS_BAD_REQUEST, b"CLOSE expects channel"
                channel = payload[0] & 0x0F
                closing = self.drive.channels.get(channel)
                if closing is not None and channel != 15:
                    self._progress("done", channel, closing.name, len(closing.data), len(closing.data))
                return STATUS_OK, self.drive.close_channel(payload[0])
            if cmd == CMD_READ:
                if len(payload) != 3:
                    return STATUS_BAD_REQUEST, b"READ expects channel,length"
                channel = payload[0] & 0x0F
                size = payload[1] | (payload[2] << 8)
                data = self.drive.read_channel(payload[0], size)
                opened = self.drive.channels.get(channel)
                if opened is not None and channel != 15:
                    self._progress("progress", channel, opened.name, opened.pos, len(opened.data))
                if not data and channel != 15:
                    return STATUS_EOF, data
                return STATUS_OK, data
            if cmd == CMD_WRITE:
                if len(payload) < 1:
                    return STATUS_BAD_REQUEST, b"WRITE expects channel,data"
                return STATUS_OK, self.drive.write_channel(payload[0], payload[1:])
            return STATUS_BAD_REQUEST, b"unknown command"
        except FileNotFoundError as exc:
            self.log(f"! not found: {exc}")
            return STATUS_NOT_FOUND, str(exc).encode("utf-8", errors="replace")
        except RuntimeError as exc:
            self.log(f"! no disk: {exc}")
            return STATUS_NO_DISK, str(exc).encode("utf-8", errors="replace")
        except Exception as exc:
            self.log(f"! io error: {exc}")
            return STATUS_IO_ERROR, str(exc).encode("utf-8", errors="replace")

    def handle_ascii(self, line: str) -> bytes:
        self.log(f"< {line}")
        parts = line.strip().split(maxsplit=1)
        if not parts:
            return b"ERR empty command\n"

        cmd = parts[0].upper()
        arg = parts[1] if len(parts) > 1 else ""
        try:
            if cmd == "$":
                return self._ascii_data(self.drive.directory_prg_payload())
            if cmd == "PING":
                return b"OK V1541 UART READY\n"
            if cmd == "IMAGES":
                self.drive.rescan()
                payload = self.drive.image_list_payload()
                return b"OK IMAGES\n" + payload + b"\n.\n"
            if cmd == "MOUNT":
                self.drive.mount(arg)
                self.mounted()
                return b"OK MOUNTED " + self.drive.mounted_path.name.encode("utf-8") + b"\n"
            if cmd == "DIR":
                return self._ascii_data(self.drive.directory_payload())
            if cmd == "LOADFIRST":
                return self._ascii_data(self.drive.load_first_prg())
            if cmd == "LOADFIRSTCHUNK":
                parts = arg.replace(",", " ").split()
                if len(parts) != 2:
                    return b"ERR LOADFIRSTCHUNK expects: LOADFIRSTCHUNK <offset> <length>\n"
                data = self.drive.load_first_prg()
                offset = int(parts[0], 0)
                size = int(parts[1], 0)
                return self._ascii_data(data[offset : offset + size])
            if cmd == "LOADCHUNK":
                parts = arg.replace(",", " ").split(maxsplit=2)
                if len(parts) != 3:
                    return b"ERR LOADCHUNK expects: LOADCHUNK <offset> <length> <name>\n"
                offset = int(parts[0], 0)
                size = int(parts[1], 0)
                _entry, chunk = self.drive.load_chunk(parts[2], offset, size)
                return self._ascii_data(chunk)
            if cmd == "LOAD":
                return self._ascii_data(self.drive.load_prg(arg))
            if cmd == "SECTOR":
                ts = arg.replace(",", " ").split()
                if len(ts) != 2:
                    return b"ERR SECTOR expects: SECTOR <track> <sector>\n"
                return self._ascii_data(self.drive.read_sector(int(ts[0]), int(ts[1])))
            if cmd == "STATUS":
                return b"OK " + self.drive.status_payload() + b"\n"
            if cmd == "DOS" or cmd in ("I", "I0", "UJ", "UI", "UI+", "UI-", "V", "V0"):
                dos = arg if cmd == "DOS" else line.strip()
                return b"OK " + self.drive.dos_command(dos) + b"\n"
            if cmd.startswith(("B-R", "B-P", "B-W", "B-A", "B-F", "M-R", "M-W", "M-E", "N:", "S:", "R:", "C:")):
                return b"OK " + self.drive.dos_command(line.strip()) + b"\n"
            if cmd == "OPEN":
                args = arg.replace(",", " ").split(maxsplit=1)
                if not args:
                    return b"ERR OPEN expects: OPEN <channel> <name>\n"
                ch = int(args[0], 0)
                name = args[1] if len(args) > 1 else ""
                return b"OK " + self.drive.open_channel(ch, name) + b"\n"
            if cmd == "CLOSE":
                if not arg:
                    return b"ERR CLOSE expects: CLOSE <channel>\n"
                return b"OK " + self.drive.close_channel(int(arg, 0)) + b"\n"
            if cmd == "READ":
                args = arg.replace(",", " ").split()
                if not args:
                    return b"ERR READ expects: READ <channel> [length]\n"
                ch = int(args[0], 0)
                size = int(args[1], 0) if len(args) > 1 else 256
                return self._ascii_data(self.drive.read_channel(ch, size))
            if cmd == "WRITE":
                args = arg.split(maxsplit=1)
                if not args:
                    return b"ERR WRITE expects: WRITE <channel> <data>\n"
                ch = int(args[0], 0)
                data = args[1].encode("ascii", errors="replace") if len(args) > 1 else b""
                return b"OK " + self.drive.write_channel(ch, data) + b"\n"
            return b"ERR unknown command\n"
        except Exception as exc:
            return f"ERR {exc}\n".encode("utf-8", errors="replace")

    @staticmethod
    def _ascii_data(payload: bytes) -> bytes:
        return f"DATA {len(payload)}\n".encode("ascii") + payload + b"\nOK\n"


class SerialWorker:
    def __init__(
        self,
        port_name: str,
        baud: int,
        protocol: Protocol,
        log: Callable[[str], None],
        tx_chunk_size: int,
        tx_chunk_delay: float,
    ) -> None:
        serial, _ = require_pyserial()
        if serial is None:
            raise RuntimeError("pyserial is not installed")
        self.serial_mod = serial
        self.port_name = port_name
        self.baud = baud
        self.protocol = protocol
        self.log = log
        self.tx_chunk_size = max(tx_chunk_size, 1)
        self.tx_chunk_delay = max(tx_chunk_delay, 0.0)
        self.stop_event = threading.Event()
        self.thread: threading.Thread | None = None
        self.port = None

    def start(self) -> None:
        self.port = self.serial_mod.Serial(self.port_name, self.baud, timeout=0.05, write_timeout=2)
        self.thread = threading.Thread(target=self._run, name="v1541-uart", daemon=True)
        self.thread.start()

    def stop(self) -> None:
        self.stop_event.set()
        if self.thread is not None:
            self.thread.join(timeout=1)
        if self.port is not None and self.port.is_open:
            self.port.close()

    def _run(self) -> None:
        assert self.port is not None
        buf = bytearray()
        self.log(f"connected {self.port_name} @ {self.baud}")
        if self.tx_chunk_delay > 0.0:
            self.log(f"tx pacing: {self.tx_chunk_size} bytes / {self.tx_chunk_delay * 1000:.1f} ms")
        while not self.stop_event.is_set():
            chunk = self.port.read(128)
            if not chunk:
                continue
            buf.extend(chunk)
            self._consume(buf)
        self.log("serial worker stopped")

    def _consume(self, buf: bytearray) -> None:
        assert self.port is not None
        while buf:
            if buf[0] == REQ_MAGIC:
                if len(buf) < 5:
                    return
                cmd = buf[1]
                length = buf[2] | (buf[3] << 8)
                frame_len = 5 + length
                if len(buf) < frame_len:
                    return
                payload = bytes(buf[4 : 4 + length])
                checksum = buf[4 + length]
                expect = (cmd + buf[2] + buf[3] + sum(payload)) & 0xFF
                del buf[:frame_len]
                if checksum != expect:
                    self.log(f"! bad checksum for ${cmd:02X}: got ${checksum:02X}, expected ${expect:02X}")
                    self._write_response(make_response(cmd, STATUS_BAD_REQUEST, b"bad checksum"))
                    continue
                status, response = self.protocol.handle_binary(cmd, payload)
                frame = make_response(cmd, status, response)
                if cmd != CMD_READ:
                    self.log(f"> {CMD_NAMES.get(cmd, f'${cmd:02X}')} status={status} {len(response)} bytes")
                self._write_response(frame)
                continue

            newline = find_newline(buf)
            if newline < 0:
                if len(buf) > 512:
                    del buf[:-128]
                return
            line = bytes(buf[:newline]).decode("utf-8", errors="replace").strip()
            del buf[: newline + 1]
            response = self.protocol.handle_ascii(line)
            self._write_response(response)
            self.log(f"> ASCII {len(response)} bytes")

    def _write_response(self, data: bytes) -> None:
        assert self.port is not None
        if self.tx_chunk_delay <= 0.0 or len(data) <= self.tx_chunk_size:
            self.port.write(data)
            return
        for offset in range(0, len(data), self.tx_chunk_size):
            if self.stop_event.is_set():
                return
            self.port.write(data[offset : offset + self.tx_chunk_size])
            self.port.flush()
            time.sleep(self.tx_chunk_delay)


def make_response(cmd: int, status: int, payload: bytes) -> bytes:
    if len(payload) > 0xFFFF:
        payload = payload[:0xFFFF]
        status = STATUS_IO_ERROR
    lo = len(payload) & 0xFF
    hi = (len(payload) >> 8) & 0xFF
    checksum = (cmd + status + lo + hi + sum(payload)) & 0xFF
    return bytes([RESP_MAGIC, cmd, status, lo, hi]) + payload + bytes([checksum])


def find_newline(buf: bytearray) -> int:
    positions = [pos for pos in (buf.find(b"\n"), buf.find(b"\r")) if pos >= 0]
    return min(positions) if positions else -1


class DriveSound:
    def __init__(self) -> None:
        self.enabled = True
        self.stop_event = threading.Event()
        self.events: queue.Queue[str] = queue.Queue(maxsize=12)
        try:
            import winsound  # type: ignore
        except ImportError:
            self.winsound = None
        else:
            self.winsound = winsound
        self.thread: threading.Thread | None = None
        if self.winsound is not None:
            self.thread = threading.Thread(target=self._run, name="v1541-drive-sound", daemon=True)
            self.thread.start()

    @property
    def available(self) -> bool:
        return self.winsound is not None

    def play(self, kind: str) -> None:
        if not self.enabled or self.winsound is None:
            return
        try:
            self.events.put_nowait(kind)
        except queue.Full:
            pass

    def stop(self) -> None:
        self.stop_event.set()
        if self.thread is not None:
            self.thread.join(timeout=0.5)

    def _run(self) -> None:
        last_head = 0.0
        while not self.stop_event.is_set():
            try:
                kind = self.events.get(timeout=0.1)
            except queue.Empty:
                continue
            now = time.monotonic()
            if kind == "head" and now - last_head < 0.045:
                continue
            if kind == "head":
                last_head = now
            self._play_pattern(kind)

    def _play_pattern(self, kind: str) -> None:
        if self.winsound is None:
            return
        patterns = {
            "motor": ((92, 28), (118, 22), (84, 24)),
            "head": ((820, 7), (115, 15)),
            "seek": ((650, 7), (105, 18), (760, 7), (120, 14)),
        }
        for freq, duration in patterns.get(kind, patterns["head"]):
            if self.stop_event.is_set():
                return
            try:
                self.winsound.Beep(freq, duration)
            except RuntimeError:
                return


class App(tk.Tk):
    def __init__(
        self,
        initial_folder: Path,
        port: str,
        baud: int,
        tx_chunk_size: int,
        tx_chunk_delay: float,
        sound_enabled: bool = True,
        mounted_image: str = "",
        window_geometry: str = "",
    ) -> None:
        super().__init__()
        self.title("C64 Virtual 1541 UART Drive")
        try:
            self.geometry(window_geometry or str(DEFAULT_SETTINGS["window_geometry"]))
        except tk.TclError:
            self.geometry(str(DEFAULT_SETTINGS["window_geometry"]))
        self.minsize(920, 660)
        self.configure(bg=APP_BG)
        self.protocol("WM_DELETE_WINDOW", self.destroy)

        self.drive = D64Drive()
        try:
            self.drive.set_folder(initial_folder)
        except Exception:
            self.drive.set_folder(Path(str(DEFAULT_SETTINGS["folder"])))
        self.events: queue.Queue[tuple[str, object]] = queue.Queue()
        self.worker: SerialWorker | None = None
        self.hook_thread: threading.Thread | None = None
        self.drive_sound = DriveSound()
        self.drive_sound.enabled = bool(sound_enabled)
        self.serial_mod, self.list_ports = require_pyserial()
        self.power_on = False
        self.activity_after: str | None = None
        self.tx_chunk_size = tx_chunk_size
        self.tx_chunk_delay = tx_chunk_delay
        self.initial_mounted_image = mounted_image

        self.folder_var = tk.StringVar(value=str(self.drive.folder))
        self.port_var = tk.StringVar(value=port)
        self.baud_var = tk.StringVar(value=str(baud))
        self.speed_var = tk.StringVar(value=self._speed_preset_from_values(tx_chunk_size, tx_chunk_delay))
        self.status_var = tk.StringVar(value="DISCONNECTED")
        self.mount_var = tk.StringVar(value="No disk mounted")
        self.sound_enabled_var = tk.BooleanVar(value=bool(sound_enabled))
        self.transfer_var = tk.StringVar(value="IDLE")
        self.transfer_progress_var = tk.DoubleVar(value=0.0)

        self._build()
        self._refresh_ports()
        self._refresh_images()
        self._mount_initial_image()
        self._redraw_drive_face()
        self.after(100, self._poll_events)

    def _build(self) -> None:
        self._configure_styles()
        self.columnconfigure(0, weight=1)
        self.rowconfigure(3, weight=1)

        self.drive_canvas = tk.Canvas(self, height=250, bg=BG, highlightthickness=0)
        self.drive_canvas.grid(row=0, column=0, sticky="ew", padx=10, pady=(10, 6))
        self.drive_canvas.bind("<Configure>", lambda _event: self._redraw_drive_face())

        controls = ttk.Frame(self, padding=(12, 8, 12, 8), style="App.TFrame")
        controls.grid(row=1, column=0, sticky="ew")
        controls.columnconfigure(1, weight=1)

        ttk.Label(controls, text="D64 FOLDER", style="C64.TLabel").grid(row=0, column=0, sticky="w", padx=(0, 8))
        ttk.Entry(controls, textvariable=self.folder_var, style="C64.TEntry").grid(row=0, column=1, sticky="ew", padx=(0, 8))
        ttk.Button(controls, text="BROWSE", command=self._browse_folder, style="C64.TButton", width=10).grid(row=0, column=2, padx=(0, 8))
        ttk.Button(controls, text="RESCAN", command=self._rescan, style="C64.TButton", width=10).grid(row=0, column=3)

        serial = ttk.Frame(self, padding=(12, 0, 12, 10), style="App.TFrame")
        serial.grid(row=2, column=0, sticky="ew")
        serial.columnconfigure(1, weight=1)

        ttk.Label(serial, text="PORT", style="C64.TLabel").grid(row=0, column=0, sticky="w", padx=(0, 8))
        self.port_combo = ttk.Combobox(serial, textvariable=self.port_var, width=18, style="C64.TCombobox")
        self.port_combo.grid(row=0, column=1, sticky="w", padx=(0, 8))
        ttk.Button(serial, text="REFRESH", command=self._refresh_ports, style="C64.TButton", width=10).grid(row=0, column=2, padx=(0, 18))
        ttk.Label(serial, text="BAUD", style="C64.TLabel").grid(row=0, column=3, sticky="w", padx=(0, 8))
        ttk.Combobox(serial, textvariable=self.baud_var, width=10, values=("115200", "230400", "460800", "921600"), style="C64.TCombobox").grid(
            row=0, column=4, sticky="w", padx=(0, 8)
        )
        ttk.Label(serial, text="SPEED", style="C64.TLabel").grid(row=0, column=5, sticky="w", padx=(8, 8))
        self.speed_combo = ttk.Combobox(
            serial,
            textvariable=self.speed_var,
            width=10,
            values=tuple(SPEED_PRESETS.keys()),
            state="readonly",
            style="C64.TCombobox",
        )
        self.speed_combo.grid(row=0, column=6, sticky="w", padx=(0, 8))
        self.speed_combo.bind("<<ComboboxSelected>>", lambda _event: self._apply_speed_preset())
        self.connect_btn = ttk.Button(serial, text="CONNECT", command=self._toggle_connection, style="C64.TButton", width=12)
        self.connect_btn.grid(row=0, column=7, padx=(8, 0))
        self.hook_btn = ttk.Button(serial, text="SEND HOOK", command=self._send_hook, style="C64.TButton", width=12)
        self.hook_btn.grid(row=0, column=8, padx=(8, 0))
        ttk.Checkbutton(
            serial,
            text="DRIVE SOUND",
            variable=self.sound_enabled_var,
            command=self._toggle_drive_sound,
            style="C64.TCheckbutton",
        ).grid(row=0, column=9, padx=(12, 0))
        ttk.Label(serial, textvariable=self.status_var, style="Status.TLabel").grid(row=0, column=10, sticky="w", padx=14)

        panes = ttk.PanedWindow(self, orient=tk.HORIZONTAL, style="C64.TPanedwindow")
        panes.grid(row=3, column=0, sticky="nsew", padx=12, pady=(0, 12))

        left = ttk.Frame(panes, style="App.TFrame")
        left.columnconfigure(0, weight=1)
        left.rowconfigure(1, weight=1)
        panes.add(left, weight=1)

        ttk.Label(left, text="IMAGES", style="Header.TLabel").grid(row=0, column=0, sticky="w")
        self.image_list = tk.Listbox(
            left,
            exportselection=False,
            bg=C64_BLUE_DARK,
            fg=C64_TEXT,
            selectbackground=C64_BLUE_SEL,
            selectforeground="#ffffff",
            borderwidth=2,
            relief="ridge",
            highlightthickness=1,
            highlightbackground=C64_BORDER,
            highlightcolor=C64_BUTTON_ACTIVE,
            font=UI_FONT,
        )
        self.image_list.grid(row=1, column=0, sticky="nsew", pady=(5, 6))
        self.image_list.bind("<Double-Button-1>", lambda _event: self._mount_selected())
        ttk.Button(left, text="MOUNT SELECTED", command=self._mount_selected, style="C64.TButton").grid(row=2, column=0, sticky="ew")
        ttk.Label(left, textvariable=self.mount_var, style="Mount.TLabel", wraplength=170).grid(row=3, column=0, sticky="ew", pady=(8, 0))

        mid = ttk.Frame(panes, style="App.TFrame")
        mid.columnconfigure(0, weight=1)
        mid.rowconfigure(1, weight=1)
        panes.add(mid, weight=2)

        ttk.Label(mid, text="MOUNTED DIRECTORY", style="Header.TLabel").grid(row=0, column=0, sticky="w")
        self.dir_tree = ttk.Treeview(mid, columns=("name", "blocks", "type", "start"), show="headings", style="C64.Treeview")
        self.dir_tree.heading("name", text="Name")
        self.dir_tree.heading("blocks", text="Blocks")
        self.dir_tree.heading("type", text="Type")
        self.dir_tree.heading("start", text="Start")
        self.dir_tree.column("name", width=190, anchor="w")
        self.dir_tree.column("blocks", width=70, anchor="e")
        self.dir_tree.column("type", width=60, anchor="center")
        self.dir_tree.column("start", width=90, anchor="center")
        self.dir_tree.grid(row=1, column=0, sticky="nsew", pady=(5, 0))

        right = ttk.Frame(panes, style="App.TFrame")
        right.columnconfigure(0, weight=1)
        right.rowconfigure(2, weight=1)
        panes.add(right, weight=2)

        ttk.Label(right, text="UART LOG", style="Header.TLabel").grid(row=0, column=0, sticky="w")
        transfer = ttk.Frame(right, style="App.TFrame")
        transfer.grid(row=1, column=0, sticky="ew", pady=(5, 2))
        transfer.columnconfigure(0, weight=1)
        self.transfer_bar = ttk.Progressbar(
            transfer,
            variable=self.transfer_progress_var,
            maximum=100.0,
            style="C64.Horizontal.TProgressbar",
        )
        self.transfer_bar.grid(row=0, column=0, sticky="ew")
        ttk.Label(transfer, textvariable=self.transfer_var, style="Transfer.TLabel").grid(row=1, column=0, sticky="w", pady=(3, 0))
        self.log_text = tk.Text(
            right,
            height=20,
            wrap="word",
            state="disabled",
            bg="#101010",
            fg="#65ff6a",
            insertbackground="#65ff6a",
            selectbackground="#284c2a",
            selectforeground="#ffffff",
            borderwidth=2,
            relief="ridge",
            highlightthickness=1,
            highlightbackground=C64_BORDER,
            font=LOG_FONT,
        )
        self.log_text.grid(row=2, column=0, sticky="nsew", pady=(5, 6))
        ttk.Button(right, text="CLEAR LOG", command=self._clear_log, style="C64.TButton").grid(row=3, column=0, sticky="ew")

    def _configure_styles(self) -> None:
        style = ttk.Style(self)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        self.option_add("*Font", UI_FONT)
        self.option_add("*TCombobox*Listbox.background", C64_FIELD)
        self.option_add("*TCombobox*Listbox.foreground", INK)
        self.option_add("*TCombobox*Listbox.selectBackground", C64_BLUE_SEL)
        self.option_add("*TCombobox*Listbox.selectForeground", "#ffffff")

        style.configure("App.TFrame", background=APP_BG)
        style.configure("C64.TPanedwindow", background=APP_BG, borderwidth=0)
        style.configure("C64.TLabel", background=APP_BG, foreground="#e8e0ca", font=UI_FONT_BOLD)
        style.configure("Header.TLabel", background=APP_BG, foreground="#f4ecd2", font=("Consolas", 12, "bold"))
        style.configure("Status.TLabel", background=APP_BG, foreground=C64_MUTED, font=UI_FONT_BOLD)
        style.configure("Mount.TLabel", background=APP_BG, foreground="#f4ecd2", font=UI_FONT)
        style.configure("Transfer.TLabel", background=APP_BG, foreground="#65ff6a", font=LOG_FONT)
        style.configure(
            "C64.Horizontal.TProgressbar",
            troughcolor="#101010",
            background=LED_GREEN,
            bordercolor=C64_BORDER,
            lightcolor=LED_GREEN,
            darkcolor="#1d6d2a",
            thickness=14,
        )

        style.configure(
            "C64.TButton",
            background=C64_BUTTON,
            foreground=INK,
            bordercolor="#5e584a",
            focusthickness=2,
            focuscolor=C64_BUTTON_ACTIVE,
            font=UI_FONT_BOLD,
            padding=(12, 6),
            relief="raised",
        )
        style.map(
            "C64.TButton",
            background=[("pressed", "#bcb397"), ("active", C64_BUTTON_ACTIVE), ("disabled", "#766f60")],
            foreground=[("disabled", "#464136")],
            relief=[("pressed", "sunken"), ("!pressed", "raised")],
        )
        style.configure(
            "C64.TCheckbutton",
            background=APP_BG,
            foreground="#e8e0ca",
            indicatorcolor=C64_FIELD,
            indicatorbackground=C64_FIELD,
            font=UI_FONT_BOLD,
            padding=(6, 4),
        )
        style.map(
            "C64.TCheckbutton",
            background=[("active", APP_BG), ("disabled", APP_BG)],
            foreground=[("active", "#ffffff"), ("disabled", "#766f60")],
            indicatorcolor=[("selected", LED_GREEN), ("!selected", "#3b352d")],
        )

        style.configure(
            "C64.TEntry",
            fieldbackground=C64_FIELD,
            foreground=INK,
            insertcolor=INK,
            bordercolor=C64_BORDER,
            lightcolor=C64_BUTTON_ACTIVE,
            darkcolor="#4d473b",
            padding=(6, 4),
            font=UI_FONT,
        )
        style.configure(
            "C64.TCombobox",
            fieldbackground=C64_FIELD,
            background=C64_BUTTON,
            foreground=INK,
            arrowcolor=INK,
            bordercolor=C64_BORDER,
            lightcolor=C64_BUTTON_ACTIVE,
            darkcolor="#4d473b",
            padding=(4, 3),
            font=UI_FONT,
        )
        style.map(
            "C64.TCombobox",
            fieldbackground=[("readonly", C64_FIELD), ("!disabled", C64_FIELD)],
            selectbackground=[("readonly", C64_BLUE_SEL)],
            selectforeground=[("readonly", "#ffffff")],
        )

        style.configure(
            "C64.Treeview",
            background=C64_BLUE_DARK,
            fieldbackground=C64_BLUE_DARK,
            foreground=C64_TEXT,
            bordercolor=C64_BORDER,
            lightcolor=C64_BORDER,
            darkcolor="#0b102f",
            rowheight=26,
            font=UI_FONT,
        )
        style.configure(
            "C64.Treeview.Heading",
            background=C64_BLUE,
            foreground="#ffffff",
            relief="raised",
            font=UI_FONT_BOLD,
            padding=(6, 5),
        )
        style.map(
            "C64.Treeview",
            background=[("selected", C64_BLUE_SEL)],
            foreground=[("selected", "#ffffff")],
        )

    def _redraw_drive_face(self, activity: bool = False) -> None:
        canvas = self.drive_canvas
        width = max(canvas.winfo_width(), 860)
        height = max(canvas.winfo_height(), 240)
        canvas.delete("all")

        canvas.create_rectangle(0, 0, width, height, fill=BG, outline=BG)
        x0 = 64
        y0 = 18
        x1 = width - 64
        y1 = height - 18
        top_h = 84
        side_w = 34
        front_y0 = y0 + top_h
        front_y1 = y1 - 18

        # Drop shadow and beige case with a shallow 3D top/right side.
        canvas.create_polygon(x0 + 18, y0 + 20, x1 + 18, y0 + 42, x1 + 18, y1 + 4, x0 + 18, y1 + 4, fill="#171612", outline="")
        canvas.create_polygon(x0 + 18, y0, x1 - 8, y0, x1 - side_w, front_y0, x0, front_y0, fill="#b9b3a5", outline="#8d8778")
        canvas.create_polygon(x1 - side_w, front_y0, x1 - 8, y0, x1, y0 + 18, x1, front_y1, fill="#8e887c", outline="#5d584f")
        canvas.create_rectangle(x0, front_y0, x1 - side_w, front_y1, fill="#aaa397", outline="#686257", width=2)
        canvas.create_line(x0, front_y0, x1 - side_w, front_y0, fill="#70695e", width=2)
        canvas.create_line(x0, front_y1 - 1, x1 - side_w, front_y1 - 1, fill="#5d574d", width=2)

        # Subtle molded plastic texture on the case.
        for ix in range(x0 + 12, x1 - side_w - 8, 18):
            canvas.create_line(ix, y0 + 18, ix + 10, front_y0 - 10, fill="#c8c2b5", stipple="gray75")
        for iy in range(front_y0 + 10, front_y1 - 10, 12):
            canvas.create_line(x0 + 8, iy, x1 - side_w - 8, iy, fill="#948e83", stipple="gray75")

        badge_x0 = x0 + 44
        badge_y0 = y0 + 48
        badge_x1 = x1 - side_w - 44
        badge_y1 = badge_y0 + 58
        canvas.create_rectangle(badge_x0 + 2, badge_y0 + 5, badge_x1 + 2, badge_y1 + 5, fill="#262626", outline="")
        canvas.create_rectangle(badge_x0, badge_y0, badge_x1, badge_y1, fill="#4b4d4c", outline="#242424", width=2)

        logo_x = badge_x0 + 34
        logo_y = badge_y0 + 29
        canvas.create_oval(logo_x - 16, logo_y - 16, logo_x + 16, logo_y + 16, fill="#f7f7f2", outline="")
        canvas.create_oval(logo_x - 5, logo_y - 9, logo_x + 13, logo_y + 9, fill="#4b4d4c", outline="")
        canvas.create_rectangle(logo_x + 1, logo_y - 6, logo_x + 20, logo_y + 6, fill="#f7f7f2", outline="")
        canvas.create_text(logo_x + 34, logo_y + 1, anchor="w", text="commodore", fill="#f7f7f2", font=("Arial", 22, "bold"))

        stripe_x0 = badge_x0 + 360
        stripe_x1 = min(stripe_x0 + 300, badge_x1 - 250)
        stripe_colors = ("#ef1616", "#ff8d19", "#ffe72f", "#34e22d", "#1c61e7")
        for idx, color in enumerate(stripe_colors):
            y = badge_y0 + 14 + idx * 8
            canvas.create_rectangle(stripe_x0, y, stripe_x1, y + 5, fill=color, outline="")
        canvas.create_text(badge_x1 - 72, logo_y + 1, anchor="center", text="1541", fill="#f7f7f2", font=("Arial", 34, "bold"))

        lower_x0 = x0 + 112
        lower_x1 = x1 - side_w - 92
        lower_y0 = front_y0 + 30
        lower_y1 = front_y1 - 14
        canvas.create_rectangle(lower_x0 + 5, lower_y0 + 6, lower_x1 + 5, lower_y1 + 7, fill="#181818", outline="")
        canvas.create_rectangle(lower_x0, lower_y0, lower_x1, lower_y1, fill="#202120", outline="#0d0d0d", width=2)
        for iy in range(lower_y0 + 5, lower_y1, 6):
            canvas.create_line(lower_x0 + 4, iy, lower_x1 - 4, iy, fill="#2e302e", stipple="gray50")

        slot_x0 = lower_x0 + 32
        slot_x1 = lower_x1 - 32
        slot_y0 = lower_y0 + 26
        slot_y1 = lower_y0 + 58
        canvas.create_rectangle(slot_x0, slot_y0, slot_x1, slot_y1, fill="#050505", outline="#050505")
        canvas.create_polygon(slot_x0 + 16, slot_y0 + 9, slot_x1 - 16, slot_y0 + 9, slot_x1 - 36, slot_y1 - 8, slot_x0 + 36, slot_y1 - 8, fill="#24231f", outline="")
        canvas.create_line(slot_x0 + 18, slot_y0 + 10, slot_x1 - 18, slot_y0 + 10, fill="#777268", width=2)
        canvas.create_line(slot_x0 + 34, slot_y1 - 9, slot_x1 - 34, slot_y1 - 9, fill="#4e4a42", width=2)

        handle_w = 186
        handle_x0 = (slot_x0 + slot_x1 - handle_w) // 2
        handle_x1 = handle_x0 + handle_w
        handle_y0 = lower_y0 + 10
        handle_y1 = lower_y1 - 14
        canvas.create_rectangle(handle_x0 - 16, handle_y0 + 24, handle_x1 + 16, handle_y1, fill="#070707", outline="")
        canvas.create_rectangle(handle_x0, handle_y0, handle_x1, handle_y1, fill="#2f2d27", outline="#090909", width=2)
        canvas.create_line(handle_x0 + 18, handle_y0 + 7, handle_x1 - 18, handle_y0 + 7, fill="#797466", width=2)
        canvas.create_line(handle_x0 + 14, handle_y1 - 8, handle_x1 - 14, handle_y1 - 8, fill="#1a1916", width=4)

        led_y = lower_y0 + 72
        self._draw_led(canvas, x0 + 76, led_y, LED_GREEN if self.power_on else LED_GREEN_OFF)
        self._draw_led(canvas, lower_x0 + 105, led_y, LED_RED if activity else LED_OFF)
        canvas.create_text(x0 + 76, led_y + 26, anchor="center", text="POWER", fill="#e7e0d1", font=("Arial", 8, "bold"))
        canvas.create_text(lower_x0 + 105, led_y + 26, anchor="center", text="DRIVE", fill="#e7e0d1", font=("Arial", 8, "bold"))

    @staticmethod
    def _draw_led(canvas: tk.Canvas, x: int, y: int, fill: str) -> None:
        canvas.create_oval(x - 11, y - 11, x + 11, y + 11, fill="#080808", outline="#777")
        canvas.create_oval(x - 8, y - 8, x + 8, y + 8, fill=fill, outline="")
        canvas.create_oval(x - 4, y - 6, x + 2, y, fill="#ffffff", outline="", stipple="gray50")

    def _pulse_activity(self) -> None:
        if self.activity_after is not None:
            self.after_cancel(self.activity_after)
        self._redraw_drive_face(activity=True)
        self.activity_after = self.after(180, self._activity_off)

    def _activity_off(self) -> None:
        self.activity_after = None
        self._redraw_drive_face(activity=False)

    def _browse_folder(self) -> None:
        folder = filedialog.askdirectory(initialdir=self.folder_var.get() or str(ROOT))
        if folder:
            self.folder_var.set(folder)
            self._rescan()

    def _rescan(self) -> None:
        try:
            self.drive.set_folder(Path(self.folder_var.get()))
            self._refresh_images()
            self._refresh_directory()
            self._log(f"folder: {self.drive.folder}")
            self._redraw_drive_face()
            self._save_settings()
        except Exception as exc:
            messagebox.showerror("D64 folder error", str(exc))

    def _refresh_images(self) -> None:
        self.image_list.delete(0, tk.END)
        for image in self.drive.images:
            self.image_list.insert(tk.END, image.name)

    def _refresh_directory(self) -> None:
        self.dir_tree.delete(*self.dir_tree.get_children())
        for entry in self.drive.entries:
            self.dir_tree.insert(
                "",
                tk.END,
                values=(entry.name, entry.blocks, entry.type, f"T{entry.first_track}/S{entry.first_sector}"),
            )
        if self.drive.mounted_path is None:
            self.mount_var.set("No disk mounted")
        else:
            self.mount_var.set(f'Mounted: {self.drive.mounted_path.name}  "{self.drive.disk_title}"')
        self._redraw_drive_face()

    def _mount_initial_image(self) -> None:
        if not self.initial_mounted_image:
            return
        names = [image.name for image in self.drive.images]
        if self.initial_mounted_image not in names:
            return
        try:
            self.drive.mount(self.initial_mounted_image)
            self._refresh_directory()
            index = names.index(self.initial_mounted_image)
            self.image_list.selection_clear(0, tk.END)
            self.image_list.selection_set(index)
            self.image_list.see(index)
            self._log(f"restored mount {self.initial_mounted_image}")
        except Exception as exc:
            self._log(f"could not restore mount {self.initial_mounted_image}: {exc}")

    def _mount_selected(self) -> None:
        selection = self.image_list.curselection()
        if not selection:
            return
        name = self.image_list.get(selection[0])
        try:
            self.drive.mount(name)
            self._refresh_directory()
            self._log(f"mounted {name}")
            self._pulse_activity()
            self._save_settings()
        except Exception as exc:
            messagebox.showerror("Mount failed", str(exc))

    def _refresh_ports(self) -> None:
        if self.list_ports is None:
            self.port_combo["values"] = ()
            self.status_var.set("PYSERIAL MISSING")
            return
        ports = [port.device for port in self.list_ports.comports()]
        self.port_combo["values"] = ports
        if not self.port_var.get() and ports:
            self.port_var.set(ports[0])

    def _toggle_connection(self) -> None:
        if self.worker is not None:
            self._disconnect_worker()
            self._save_settings()
            return
        self._connect_worker()

    def _connect_worker(self) -> bool:
        protocol = Protocol(self.drive, self._thread_log, self._thread_mounted, self._thread_progress)
        try:
            worker = SerialWorker(
                self.port_var.get(),
                int(self.baud_var.get()),
                protocol,
                self._thread_log,
                self.tx_chunk_size,
                self.tx_chunk_delay,
            )
            worker.start()
        except Exception as exc:
            messagebox.showerror("Serial error", str(exc))
            return False

        self.worker = worker
        self.connect_btn.configure(text="DISCONNECT")
        self.status_var.set("CONNECTED")
        self.power_on = True
        self._redraw_drive_face()
        self._save_settings()
        return True

    def _disconnect_worker(self) -> None:
        if self.worker is None:
            return
        self.worker.stop()
        self.worker = None
        self.connect_btn.configure(text="CONNECT")
        self.status_var.set("DISCONNECTED")
        self.power_on = False
        self._redraw_drive_face()

    def _set_hook_busy(self, busy: bool) -> None:
        state = "disabled" if busy else "normal"
        self.hook_btn.configure(state=state)
        self.connect_btn.configure(state=state)

    def _send_hook(self) -> None:
        if self.hook_thread is not None and self.hook_thread.is_alive():
            return
        port = self.port_var.get().strip()
        if not port:
            messagebox.showerror("Hook upload", "No COM port selected")
            return
        try:
            baud = self._current_baud()
        except ValueError:
            messagebox.showerror("Hook upload", "Invalid baud rate")
            return

        if self.worker is not None:
            self._log("disconnecting drive UART for hook upload")
            self._disconnect_worker()

        hook_prg = ROOT / "roms" / "v1541_hook.prg"
        if not hook_prg.exists():
            messagebox.showerror("Hook upload", f"Hook PRG not found:\n{hook_prg}")
            return

        self._set_hook_busy(True)
        self.status_var.set("SENDING HOOK")
        self._log(f"sending hook {hook_prg} on {port} @ {baud}")
        self.hook_thread = threading.Thread(
            target=self._hook_upload_worker,
            args=(port, baud, hook_prg),
            name="v1541-hook-upload",
            daemon=True,
        )
        self.hook_thread.start()

    def _hook_upload_worker(self, port: str, baud: int, hook_prg: Path) -> None:
        cmd = [
            sys.executable,
            str(ROOT / "tools" / "c64_uart_prg_loader.py"),
            str(hook_prg),
            "--port",
            port,
            "--baud",
            str(baud),
        ]
        creationflags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
        try:
            result = subprocess.run(
                cmd,
                cwd=str(ROOT),
                capture_output=True,
                text=True,
                creationflags=creationflags,
                timeout=60,
            )
            payload = {
                "returncode": result.returncode,
                "stdout": result.stdout,
                "stderr": result.stderr,
            }
        except Exception as exc:
            payload = {
                "returncode": -1,
                "stdout": "",
                "stderr": str(exc),
            }
        self.events.put(("hook_done", payload))

    def _thread_log(self, text: str) -> None:
        self.events.put(("log", text))

    def _thread_mounted(self) -> None:
        self.events.put(("mounted", None))

    def _thread_progress(self, progress: dict[str, object]) -> None:
        self.events.put(("progress", progress))

    def _poll_events(self) -> None:
        try:
            while True:
                kind, payload = self.events.get_nowait()
                if kind == "log":
                    self._log(str(payload))
                elif kind == "mounted":
                    self._refresh_directory()
                elif kind == "progress":
                    self._update_transfer_progress(payload)
                elif kind == "hook_done":
                    self._hook_upload_done(payload)
        except queue.Empty:
            pass
        self.after(100, self._poll_events)

    def _hook_upload_done(self, payload: object) -> None:
        self._set_hook_busy(False)
        self.hook_thread = None
        result = payload if isinstance(payload, dict) else {}
        stdout = str(result.get("stdout", "")).strip()
        stderr = str(result.get("stderr", "")).strip()
        returncode = int(result.get("returncode", -1))

        for line in stdout.splitlines():
            if line.strip():
                self._log(f"hook: {line}")
        for line in stderr.splitlines():
            if line.strip():
                self._log(f"hook error: {line}")

        if returncode == 0:
            self._log("hook upload complete; type RUN on the C64 to install it")
            if self._connect_worker():
                self.status_var.set("CONNECTED - TYPE RUN")
            else:
                self.status_var.set("HOOK SENT - TYPE RUN")
        else:
            self.status_var.set("HOOK UPLOAD FAILED")
            messagebox.showerror("Hook upload failed", stderr or stdout or f"Loader returned {returncode}")

    @staticmethod
    def _format_bytes(value: int) -> str:
        if value >= 1024 * 1024:
            return f"{value / (1024 * 1024):.1f} MB"
        if value >= 1024:
            return f"{value / 1024:.1f} KB"
        return f"{value} B"

    def _update_transfer_progress(self, payload: object) -> None:
        if not isinstance(payload, dict):
            return
        phase = str(payload.get("phase", "progress"))
        name = str(payload.get("name", ""))
        try:
            pos = int(payload.get("pos", 0))
            total = int(payload.get("total", 0))
        except (TypeError, ValueError):
            return
        if total <= 0:
            percent = 0.0
        else:
            percent = max(0.0, min(100.0, pos * 100.0 / total))
        self.transfer_progress_var.set(percent)

        shown_name = name or "TRANSFER"
        if len(shown_name) > 32:
            shown_name = shown_name[:29] + "..."
        byte_text = f"{self._format_bytes(pos)} / {self._format_bytes(total)}" if total else self._format_bytes(pos)
        if phase == "start":
            self.drive_sound.play("motor")
            self.transfer_var.set(f"LOADING {shown_name}  0%  {byte_text}")
            self._log(f"loading {name}: {self._format_bytes(total)}")
        elif phase == "done":
            self.transfer_progress_var.set(100.0)
            self.transfer_var.set(f"DONE {shown_name}  100%  {byte_text}")
            self._log(f"loaded {name}: {self._format_bytes(total)}")
        else:
            self.drive_sound.play("head")
            self.transfer_var.set(f"LOADING {shown_name}  {percent:5.1f}%  {byte_text}")

    def _log(self, text: str) -> None:
        stamp = time.strftime("%H:%M:%S")
        self.log_text.configure(state="normal")
        self.log_text.insert(tk.END, f"[{stamp}] {text}\n")
        self.log_text.see(tk.END)
        self.log_text.configure(state="disabled")
        if text.startswith("<") or text.startswith(">") or text.startswith("mounted"):
            self._pulse_activity()
            self._play_drive_sound_for_log(text)

    def _clear_log(self) -> None:
        self.log_text.configure(state="normal")
        self.log_text.delete("1.0", tk.END)
        self.log_text.configure(state="disabled")

    def _toggle_drive_sound(self) -> None:
        self.drive_sound.enabled = bool(self.sound_enabled_var.get())
        self._save_settings()

    @staticmethod
    def _speed_preset_from_values(chunk_size: int, chunk_delay: float) -> str:
        for name, (preset_size, preset_delay) in SPEED_PRESETS.items():
            if int(chunk_size) == preset_size and abs(float(chunk_delay) - preset_delay) < 0.0005:
                return name
        return "CUSTOM"

    def _apply_speed_preset(self) -> None:
        preset = self.speed_var.get().upper()
        if preset not in SPEED_PRESETS:
            return
        self.tx_chunk_size, self.tx_chunk_delay = SPEED_PRESETS[preset]
        self._log(f"speed preset {preset}: {self.tx_chunk_size} bytes / {self.tx_chunk_delay * 1000:.1f} ms")
        if self.worker is not None:
            self._log("speed change applies on next reconnect")
        self._save_settings()

    def _play_drive_sound_for_log(self, text: str) -> None:
        if text.startswith("mounted"):
            self.drive_sound.play("motor")
        elif text.startswith("< OPEN") or text.startswith("< MOUNT"):
            self.drive_sound.play("motor")
        elif text.startswith("< LOADFIRST") or text.startswith("< LOAD "):
            self.drive_sound.play("seek")
        elif text.startswith("< READ") or text.startswith("< LOADCHUNK") or text.startswith("< LOADFIRSTCHUNK"):
            self.drive_sound.play("head")

    def _current_baud(self) -> int:
        try:
            return int(self.baud_var.get())
        except ValueError:
            return int(DEFAULT_SETTINGS["baud"])

    def _collect_settings(self) -> dict[str, object]:
        mounted = self.drive.mounted_path.name if self.drive.mounted_path is not None else ""
        return {
            "folder": self.folder_var.get() or str(self.drive.folder),
            "port": self.port_var.get(),
            "baud": self._current_baud(),
            "tx_chunk_size": self.tx_chunk_size,
            "tx_chunk_delay": self.tx_chunk_delay,
            "sound_enabled": bool(self.sound_enabled_var.get()),
            "mounted_image": mounted,
            "window_geometry": self.geometry(),
        }

    def _save_settings(self) -> None:
        try:
            save_settings(self._collect_settings())
        except Exception as exc:
            self._log(f"settings save failed: {exc}")

    def destroy(self) -> None:
        self._save_settings()
        if self.activity_after is not None:
            self.after_cancel(self.activity_after)
            self.activity_after = None
        if self.worker is not None:
            self.worker.stop()
            self.worker = None
        self.drive_sound.stop()
        super().destroy()


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--folder", type=Path, default=None, help="folder containing .d64 images")
    parser.add_argument("--port", default=None, help="UART port")
    parser.add_argument("--baud", type=int, default=None, help="UART baud rate")
    parser.add_argument("--tx-chunk-size", type=int, default=None, help="bytes per paced response chunk")
    parser.add_argument("--tx-chunk-delay", type=float, default=None, help="seconds between response chunks")
    return parser.parse_args(argv)


def setting_str(settings: dict[str, object], key: str) -> str:
    value = settings.get(key, DEFAULT_SETTINGS[key])
    return str(value)


def setting_int(settings: dict[str, object], key: str) -> int:
    try:
        return int(settings.get(key, DEFAULT_SETTINGS[key]))
    except (TypeError, ValueError):
        return int(DEFAULT_SETTINGS[key])


def setting_float(settings: dict[str, object], key: str) -> float:
    try:
        return float(settings.get(key, DEFAULT_SETTINGS[key]))
    except (TypeError, ValueError):
        return float(DEFAULT_SETTINGS[key])


def setting_bool(settings: dict[str, object], key: str) -> bool:
    value = settings.get(key, DEFAULT_SETTINGS[key])
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() not in ("0", "false", "no", "off")
    return bool(value)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    settings = load_settings()
    folder = args.folder if args.folder is not None else Path(setting_str(settings, "folder"))
    port = args.port if args.port is not None else setting_str(settings, "port")
    baud = args.baud if args.baud is not None else setting_int(settings, "baud")
    tx_chunk_size = args.tx_chunk_size if args.tx_chunk_size is not None else setting_int(settings, "tx_chunk_size")
    tx_chunk_delay = args.tx_chunk_delay if args.tx_chunk_delay is not None else setting_float(settings, "tx_chunk_delay")
    sound_enabled = setting_bool(settings, "sound_enabled")
    mounted_image = "" if args.folder is not None else setting_str(settings, "mounted_image")
    window_geometry = setting_str(settings, "window_geometry")
    app = App(folder, port, baud, tx_chunk_size, tx_chunk_delay, sound_enabled, mounted_image, window_geometry)
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
