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
manual tests the same commands are also accepted as newline-terminated ASCII:
PING, IMAGES, MOUNT <name>, DIR, LOADFIRST, LOAD <name>, SECTOR <track> <sector>,
STATUS.
"""

from __future__ import annotations

import argparse
import queue
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import tkinter as tk
from tkinter import filedialog, messagebox, ttk

ROOT = Path(__file__).resolve().parents[1]
D64_TOOLS = ROOT / "tools" / "d64"
sys.path.insert(0, str(D64_TOOLS))

from d64_common import D64_35_TRACK_SIZE, SECTOR_SIZE, d64_byte_offset, is_supported_size  # noqa: E402
from extract_prg import follow_chain  # noqa: E402
from list_d64 import disk_name, iter_entries  # noqa: E402


REQ_MAGIC = 0xC6
RESP_MAGIC = 0x64

CMD_PING = 0x01
CMD_IMAGES = 0x10
CMD_MOUNT = 0x11
CMD_DIR = 0x12
CMD_LOAD_FIRST = 0x20
CMD_LOAD = 0x21
CMD_SECTOR = 0x30
CMD_STATUS = 0x31

STATUS_OK = 0
STATUS_NO_DISK = 1
STATUS_NOT_FOUND = 2
STATUS_BAD_REQUEST = 3
STATUS_IO_ERROR = 4

CMD_NAMES = {
    CMD_PING: "PING",
    CMD_IMAGES: "IMAGES",
    CMD_MOUNT: "MOUNT",
    CMD_DIR: "DIR",
    CMD_LOAD_FIRST: "LOADFIRST",
    CMD_LOAD: "LOAD",
    CMD_SECTOR: "SECTOR",
    CMD_STATUS: "STATUS",
}

BG = "#2b2a26"
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


class D64Drive:
    def __init__(self) -> None:
        self.folder = ROOT / "roms" / "test_d64"
        self.images: list[Path] = []
        self.mounted_path: Path | None = None
        self.mounted_data: bytes | None = None
        self.entries: list[DirEntry] = []
        self.disk_title = ""
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
        lines.append("BLOCKS FREE.")
        return ("\r".join(lines) + "\r").encode("ascii", errors="replace")

    def status_payload(self) -> bytes:
        if self.mounted_path is None:
            return b"74,NO DISK,00,00"
        return b"00,OK,00,00"

    def load_first_prg(self) -> bytes:
        self._require_disk()
        for entry in self.entries:
            if entry.type == "PRG":
                return self._load_entry(entry)
        raise FileNotFoundError("no PRG file on mounted image")

    def load_prg(self, name: str) -> bytes:
        self._require_disk()
        target = name.strip().strip('"').upper()
        if target in ("*", ""):
            return self.load_first_prg()
        for entry in self.entries:
            if entry.type == "PRG" and entry.name.upper() == target:
                return self._load_entry(entry)
        raise FileNotFoundError(name)

    def read_sector(self, track: int, sector: int) -> bytes:
        self._require_disk()
        assert self.mounted_data is not None
        off = d64_byte_offset(track, sector)
        if off == 0xFFFFFFFF:
            raise ValueError(f"invalid sector T{track}/S{sector}")
        return self.mounted_data[off : off + SECTOR_SIZE]

    def _load_entry(self, entry: DirEntry) -> bytes:
        assert self.mounted_data is not None
        return follow_chain(self.mounted_data, entry.first_track, entry.first_sector)

    def _require_disk(self) -> None:
        if self.mounted_data is None:
            raise RuntimeError("no disk mounted")


class Protocol:
    def __init__(self, drive: D64Drive, log: Callable[[str], None], mounted: Callable[[], None]) -> None:
        self.drive = drive
        self.log = log
        self.mounted = mounted

    def handle_binary(self, cmd: int, payload: bytes) -> tuple[int, bytes]:
        name = CMD_NAMES.get(cmd, f"${cmd:02X}")
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
                return STATUS_OK, self.drive.load_first_prg()
            if cmd == CMD_LOAD:
                return STATUS_OK, self.drive.load_prg(payload.decode("utf-8", errors="replace"))
            if cmd == CMD_SECTOR:
                if len(payload) != 2:
                    return STATUS_BAD_REQUEST, b"SECTOR expects track,sector"
                return STATUS_OK, self.drive.read_sector(payload[0], payload[1])
            if cmd == CMD_STATUS:
                return STATUS_OK, self.drive.status_payload()
            return STATUS_BAD_REQUEST, b"unknown command"
        except FileNotFoundError as exc:
            return STATUS_NOT_FOUND, str(exc).encode("utf-8", errors="replace")
        except RuntimeError as exc:
            return STATUS_NO_DISK, str(exc).encode("utf-8", errors="replace")
        except Exception as exc:
            return STATUS_IO_ERROR, str(exc).encode("utf-8", errors="replace")

    def handle_ascii(self, line: str) -> bytes:
        self.log(f"< {line}")
        parts = line.strip().split(maxsplit=1)
        if not parts:
            return b"ERR empty command\n"

        cmd = parts[0].upper()
        arg = parts[1] if len(parts) > 1 else ""
        try:
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
            if cmd == "LOAD":
                return self._ascii_data(self.drive.load_prg(arg))
            if cmd == "SECTOR":
                ts = arg.replace(",", " ").split()
                if len(ts) != 2:
                    return b"ERR SECTOR expects: SECTOR <track> <sector>\n"
                return self._ascii_data(self.drive.read_sector(int(ts[0]), int(ts[1])))
            if cmd == "STATUS":
                return b"OK " + self.drive.status_payload() + b"\n"
            return b"ERR unknown command\n"
        except Exception as exc:
            return f"ERR {exc}\n".encode("utf-8", errors="replace")

    @staticmethod
    def _ascii_data(payload: bytes) -> bytes:
        return f"DATA {len(payload)}\n".encode("ascii") + payload + b"\nOK\n"


class SerialWorker:
    def __init__(self, port_name: str, baud: int, protocol: Protocol, log: Callable[[str], None]) -> None:
        serial, _ = require_pyserial()
        if serial is None:
            raise RuntimeError("pyserial is not installed")
        self.serial_mod = serial
        self.port_name = port_name
        self.baud = baud
        self.protocol = protocol
        self.log = log
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
                    self.port.write(make_response(cmd, STATUS_BAD_REQUEST, b"bad checksum"))
                    continue
                status, response = self.protocol.handle_binary(cmd, payload)
                self.port.write(make_response(cmd, status, response))
                self.log(f"> {CMD_NAMES.get(cmd, f'${cmd:02X}')} status={status} {len(response)} bytes")
                continue

            newline = find_newline(buf)
            if newline < 0:
                if len(buf) > 512:
                    del buf[:-128]
                return
            line = bytes(buf[:newline]).decode("utf-8", errors="replace").strip()
            del buf[: newline + 1]
            response = self.protocol.handle_ascii(line)
            self.port.write(response)
            self.log(f"> ASCII {len(response)} bytes")


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


class App(tk.Tk):
    def __init__(self, initial_folder: Path, port: str, baud: int) -> None:
        super().__init__()
        self.title("C64 Virtual 1541 UART Drive")
        self.geometry("1040x760")
        self.minsize(920, 660)
        self.configure(bg=BG)

        self.drive = D64Drive()
        self.drive.set_folder(initial_folder)
        self.events: queue.Queue[tuple[str, object]] = queue.Queue()
        self.worker: SerialWorker | None = None
        self.serial_mod, self.list_ports = require_pyserial()
        self.power_on = False
        self.activity_after: str | None = None

        self.folder_var = tk.StringVar(value=str(self.drive.folder))
        self.port_var = tk.StringVar(value=port)
        self.baud_var = tk.StringVar(value=str(baud))
        self.status_var = tk.StringVar(value="Disconnected")
        self.mount_var = tk.StringVar(value="No disk mounted")

        self._build()
        self._refresh_ports()
        self._refresh_images()
        self._redraw_drive_face()
        self.after(100, self._poll_events)

    def _build(self) -> None:
        self._configure_styles()
        self.columnconfigure(0, weight=1)
        self.rowconfigure(3, weight=1)

        self.drive_canvas = tk.Canvas(self, height=250, bg=BG, highlightthickness=0)
        self.drive_canvas.grid(row=0, column=0, sticky="ew", padx=10, pady=(10, 6))
        self.drive_canvas.bind("<Configure>", lambda _event: self._redraw_drive_face())

        controls = ttk.Frame(self, padding=(10, 0, 10, 8), style="App.TFrame")
        controls.grid(row=1, column=0, sticky="ew")
        controls.columnconfigure(1, weight=1)

        ttk.Label(controls, text="D64 folder").grid(row=0, column=0, sticky="w")
        ttk.Entry(controls, textvariable=self.folder_var).grid(row=0, column=1, sticky="ew", padx=6)
        ttk.Button(controls, text="Browse", command=self._browse_folder).grid(row=0, column=2, padx=(0, 6))
        ttk.Button(controls, text="Rescan", command=self._rescan).grid(row=0, column=3)

        serial = ttk.Frame(self, padding=(10, 0, 10, 8), style="App.TFrame")
        serial.grid(row=2, column=0, sticky="ew")
        serial.columnconfigure(1, weight=1)

        ttk.Label(serial, text="Port").grid(row=0, column=0, sticky="w")
        self.port_combo = ttk.Combobox(serial, textvariable=self.port_var, width=18)
        self.port_combo.grid(row=0, column=1, sticky="w", padx=6)
        ttk.Button(serial, text="Refresh", command=self._refresh_ports).grid(row=0, column=2, padx=(0, 10))
        ttk.Label(serial, text="Baud").grid(row=0, column=3, sticky="w")
        ttk.Combobox(serial, textvariable=self.baud_var, width=10, values=("115200", "230400", "460800", "921600")).grid(
            row=0, column=4, sticky="w", padx=6
        )
        self.connect_btn = ttk.Button(serial, text="Connect", command=self._toggle_connection)
        self.connect_btn.grid(row=0, column=5, padx=(8, 0))
        ttk.Label(serial, textvariable=self.status_var).grid(row=0, column=6, sticky="w", padx=12)

        panes = ttk.PanedWindow(self, orient=tk.HORIZONTAL)
        panes.grid(row=3, column=0, sticky="nsew", padx=10, pady=(0, 10))

        left = ttk.Frame(panes, style="App.TFrame")
        left.columnconfigure(0, weight=1)
        left.rowconfigure(1, weight=1)
        panes.add(left, weight=1)

        ttk.Label(left, text="Images").grid(row=0, column=0, sticky="w")
        self.image_list = tk.Listbox(left, exportselection=False)
        self.image_list.grid(row=1, column=0, sticky="nsew", pady=4)
        self.image_list.bind("<Double-Button-1>", lambda _event: self._mount_selected())
        ttk.Button(left, text="Mount selected", command=self._mount_selected).grid(row=2, column=0, sticky="ew")
        ttk.Label(left, textvariable=self.mount_var).grid(row=3, column=0, sticky="w", pady=(8, 0))

        mid = ttk.Frame(panes, style="App.TFrame")
        mid.columnconfigure(0, weight=1)
        mid.rowconfigure(1, weight=1)
        panes.add(mid, weight=2)

        ttk.Label(mid, text="Mounted directory").grid(row=0, column=0, sticky="w")
        self.dir_tree = ttk.Treeview(mid, columns=("name", "blocks", "type", "start"), show="headings")
        self.dir_tree.heading("name", text="Name")
        self.dir_tree.heading("blocks", text="Blocks")
        self.dir_tree.heading("type", text="Type")
        self.dir_tree.heading("start", text="Start")
        self.dir_tree.column("name", width=190, anchor="w")
        self.dir_tree.column("blocks", width=70, anchor="e")
        self.dir_tree.column("type", width=60, anchor="center")
        self.dir_tree.column("start", width=90, anchor="center")
        self.dir_tree.grid(row=1, column=0, sticky="nsew", pady=4)

        right = ttk.Frame(panes, style="App.TFrame")
        right.columnconfigure(0, weight=1)
        right.rowconfigure(1, weight=1)
        panes.add(right, weight=2)

        ttk.Label(right, text="UART log").grid(row=0, column=0, sticky="w")
        self.log_text = tk.Text(right, height=20, wrap="word", state="disabled")
        self.log_text.grid(row=1, column=0, sticky="nsew", pady=4)
        ttk.Button(right, text="Clear log", command=self._clear_log).grid(row=2, column=0, sticky="ew")

    def _configure_styles(self) -> None:
        style = ttk.Style(self)
        style.configure("App.TFrame", background=BG)
        style.configure("TLabel", background=BG, foreground="#e8e0ca")
        style.configure("TButton", padding=(10, 4))
        style.configure("Treeview", rowheight=24)

    def _redraw_drive_face(self, activity: bool = False) -> None:
        canvas = self.drive_canvas
        width = max(canvas.winfo_width(), 860)
        height = max(canvas.winfo_height(), 240)
        canvas.delete("all")

        x0 = 42
        y0 = 22
        x1 = width - 42
        y1 = height - 24
        body_h = y1 - y0
        front_top = y0 + 44
        front_bottom = y1 - 18
        panel_x0 = x0 + 34
        panel_x1 = x1 - 34
        panel_y0 = front_top + 24
        panel_y1 = front_bottom - 20

        canvas.create_rectangle(0, 0, width, height, fill=BG, outline=BG)
        canvas.create_rectangle(x0 + 10, y0 + 12, x1 + 10, y1 + 12, fill="#171612", outline="")
        canvas.create_rectangle(x0, y0, x1, y1, fill=CASE_SIDE, outline=CASE_SHADOW, width=2)
        canvas.create_polygon(x0, y0, x1, y0, x1 - 20, front_top, x0 + 20, front_top, fill=CASE_TOP, outline=CASE_SHADOW)
        canvas.create_rectangle(x0 + 20, front_top, x1 - 20, y1 - 12, fill="#c9bea0", outline=CASE_SHADOW)
        canvas.create_rectangle(panel_x0, panel_y0, panel_x1, panel_y1, fill=PANEL, outline=PANEL_EDGE, width=3)

        slot_x0 = panel_x0 + 52
        slot_y0 = panel_y0 + 52
        slot_x1 = panel_x1 - 235
        slot_y1 = slot_y0 + 36
        canvas.create_rectangle(slot_x0, slot_y0, slot_x1, slot_y1, fill=SLOT, outline="#050605", width=2)
        canvas.create_rectangle(slot_x0 + 16, slot_y0 + 10, slot_x1 - 16, slot_y1 - 10, fill="#262821", outline="")
        canvas.create_rectangle(slot_x1 - 90, slot_y0 + 8, slot_x1 - 26, slot_y1 - 8, fill="#77715f", outline="#afa78b")
        canvas.create_line(slot_x0 + 8, slot_y1 + 8, slot_x1 - 8, slot_y1 + 8, fill="#0a0b09", width=3)
        canvas.create_line(slot_x0 + 8, slot_y1 + 12, slot_x1 - 8, slot_y1 + 12, fill="#3d4037", width=1)

        badge_x = panel_x0 + 48
        canvas.create_rectangle(badge_x, panel_y0 + 14, badge_x + 210, panel_y0 + 38, fill="#d8d0b6", outline="")
        canvas.create_text(badge_x + 14, panel_y0 + 26, anchor="w", text="commodore", fill="#2b4f8d", font=("Arial", 13, "bold"))
        canvas.create_text(badge_x + 134, panel_y0 + 26, anchor="w", text="1541", fill=BRAND_RED, font=("Arial", 14, "bold"))

        right_x = panel_x1 - 190
        canvas.create_text(right_x, panel_y0 + 33, anchor="w", text="VIRTUAL DISK DRIVE", fill="#ddd5bf", font=("Arial", 10, "bold"))
        canvas.create_text(right_x, panel_y0 + 58, anchor="w", text="POWER", fill="#ddd5bf", font=("Arial", 9))
        canvas.create_text(right_x + 82, panel_y0 + 58, anchor="w", text="DRIVE", fill="#ddd5bf", font=("Arial", 9))
        self._draw_led(canvas, right_x + 18, panel_y0 + 82, LED_GREEN if self.power_on else LED_GREEN_OFF)
        self._draw_led(canvas, right_x + 100, panel_y0 + 82, LED_RED if activity else LED_OFF)

        canvas.create_text(x0 + 24, y0 + body_h - 10, anchor="w", text="UART 1541", fill=INK, font=("Arial", 11, "bold"))

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
        except Exception as exc:
            messagebox.showerror("Mount failed", str(exc))

    def _refresh_ports(self) -> None:
        if self.list_ports is None:
            self.port_combo["values"] = ()
            self.status_var.set("pyserial missing: python -m pip install pyserial")
            return
        ports = [port.device for port in self.list_ports.comports()]
        self.port_combo["values"] = ports
        if not self.port_var.get() and ports:
            self.port_var.set(ports[0])

    def _toggle_connection(self) -> None:
        if self.worker is not None:
            self.worker.stop()
            self.worker = None
            self.connect_btn.configure(text="Connect")
            self.status_var.set("Disconnected")
            self.power_on = False
            self._redraw_drive_face()
            return

        protocol = Protocol(self.drive, self._thread_log, self._thread_mounted)
        try:
            worker = SerialWorker(self.port_var.get(), int(self.baud_var.get()), protocol, self._thread_log)
            worker.start()
        except Exception as exc:
            messagebox.showerror("Serial error", str(exc))
            return

        self.worker = worker
        self.connect_btn.configure(text="Disconnect")
        self.status_var.set("Connected")
        self.power_on = True
        self._redraw_drive_face()

    def _thread_log(self, text: str) -> None:
        self.events.put(("log", text))

    def _thread_mounted(self) -> None:
        self.events.put(("mounted", None))

    def _poll_events(self) -> None:
        try:
            while True:
                kind, payload = self.events.get_nowait()
                if kind == "log":
                    self._log(str(payload))
                elif kind == "mounted":
                    self._refresh_directory()
        except queue.Empty:
            pass
        self.after(100, self._poll_events)

    def _log(self, text: str) -> None:
        stamp = time.strftime("%H:%M:%S")
        self.log_text.configure(state="normal")
        self.log_text.insert(tk.END, f"[{stamp}] {text}\n")
        self.log_text.see(tk.END)
        self.log_text.configure(state="disabled")
        if text.startswith("<") or text.startswith(">") or text.startswith("mounted"):
            self._pulse_activity()

    def _clear_log(self) -> None:
        self.log_text.configure(state="normal")
        self.log_text.delete("1.0", tk.END)
        self.log_text.configure(state="disabled")

    def destroy(self) -> None:
        if self.activity_after is not None:
            self.after_cancel(self.activity_after)
            self.activity_after = None
        if self.worker is not None:
            self.worker.stop()
            self.worker = None
        super().destroy()


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--folder", type=Path, default=ROOT / "roms" / "test_d64", help="folder containing .d64 images")
    parser.add_argument("--port", default="COM12", help="UART port, default COM12")
    parser.add_argument("--baud", type=int, default=115200, help="UART baud rate, default 115200")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    app = App(args.folder, args.port, args.baud)
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
