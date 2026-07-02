#!/usr/bin/env python3
"""Tk GUI to convert a standard D64 into the Tang MiSTer C64 raw SD image.

The generated image uses the expanded layout expected by
`c1541_sd_d64_sector_source.vhd`: each 256-byte D64 sector is written to the
lower half of one 512-byte SD block.
"""

from __future__ import annotations

from pathlib import Path
import sys
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

ROOT = Path(__file__).resolve().parents[2]
D64_TOOLS = Path(__file__).resolve().parent
sys.path.insert(0, str(D64_TOOLS))

from d64_common import D64_35_TRACK_SIZE  # noqa: E402
from list_d64 import disk_name, iter_entries  # noqa: E402
from make_raw_sd_d64_image import (  # noqa: E402
    D64_SECTORS,
    EXPANDED_SIZE,
    parse_size,
    write_raw_sd_image,
)


BG = "#1f211c"
PANEL = "#292b25"
FG = "#e9e2c7"
MUTED = "#b9b197"
ACCENT = "#7bbf5b"
RED = "#d44335"


class D64ToSdImageGui(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("D64 -> Tang MiSTer C64 SD Image")
        self.geometry("820x600")
        self.minsize(760, 520)
        self.configure(bg=BG)

        self.d64_var = tk.StringVar()
        self.img_var = tk.StringVar(value=str(ROOT / "build" / "mister1541_sd.img"))
        self.size_var = tk.StringVar(value="4M")
        self.status_var = tk.StringVar(value="Ready")

        self._make_style()
        self._build_ui()

    def _make_style(self) -> None:
        style = ttk.Style(self)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure("TFrame", background=BG)
        style.configure("Panel.TFrame", background=PANEL)
        style.configure("TLabel", background=BG, foreground=FG)
        style.configure("Panel.TLabel", background=PANEL, foreground=FG)
        style.configure("Muted.TLabel", background=PANEL, foreground=MUTED)
        style.configure("TButton", padding=(12, 7))
        style.configure("Accent.TButton", padding=(14, 8))
        style.configure("TEntry", fieldbackground="#f4f0de")

    def _build_ui(self) -> None:
        root = ttk.Frame(self, padding=16)
        root.pack(fill=tk.BOTH, expand=True)

        title = tk.Label(
            root,
            text="D64 -> SD IMAGE",
            bg=BG,
            fg=FG,
            font=("Consolas", 22, "bold"),
        )
        title.pack(anchor="w")

        note = tk.Label(
            root,
            text=(
                "Konvertiert ein echtes 35-Track D64 in das raw expanded Image "
                "fuer den externen PMOD/GPIO SD-Reader."
            ),
            bg=BG,
            fg=MUTED,
            font=("Segoe UI", 10),
        )
        note.pack(anchor="w", pady=(2, 14))

        form = ttk.Frame(root, style="Panel.TFrame", padding=14)
        form.pack(fill=tk.X)

        self._path_row(form, 0, "D64", self.d64_var, self._browse_d64)
        self._path_row(form, 1, "SD image", self.img_var, self._browse_img)

        ttk.Label(form, text="Image size", style="Panel.TLabel").grid(row=2, column=0, sticky="w", pady=(10, 0))
        size_row = ttk.Frame(form, style="Panel.TFrame")
        size_row.grid(row=2, column=1, sticky="ew", padx=(8, 0), pady=(10, 0))
        ttk.Entry(size_row, textvariable=self.size_var, width=12).pack(side=tk.LEFT)
        ttk.Label(
            size_row,
            text=f"minimum {EXPANDED_SIZE} bytes, default 4M",
            style="Muted.TLabel",
        ).pack(side=tk.LEFT, padx=(10, 0))

        form.columnconfigure(1, weight=1)

        body = ttk.Frame(root)
        body.pack(fill=tk.BOTH, expand=True, pady=(14, 0))

        left = ttk.Frame(body, style="Panel.TFrame", padding=10)
        left.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=(0, 8))
        right = ttk.Frame(body, style="Panel.TFrame", padding=10)
        right.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=(8, 0))

        ttk.Label(left, text="D64 directory", style="Panel.TLabel").pack(anchor="w")
        self.dir_text = tk.Text(
            left,
            height=18,
            bg="#11130f",
            fg=FG,
            insertbackground=FG,
            relief=tk.FLAT,
            font=("Consolas", 10),
            wrap=tk.NONE,
        )
        self.dir_text.pack(fill=tk.BOTH, expand=True, pady=(8, 0))

        ttk.Label(right, text="Log", style="Panel.TLabel").pack(anchor="w")
        self.log_text = tk.Text(
            right,
            height=18,
            bg="#11130f",
            fg=FG,
            insertbackground=FG,
            relief=tk.FLAT,
            font=("Consolas", 10),
            wrap=tk.WORD,
        )
        self.log_text.pack(fill=tk.BOTH, expand=True, pady=(8, 0))

        actions = ttk.Frame(root)
        actions.pack(fill=tk.X, pady=(14, 0))
        ttk.Button(actions, text="Read directory", command=self._read_directory).pack(side=tk.LEFT)
        ttk.Button(actions, text="Convert to SD image", style="Accent.TButton", command=self._convert).pack(side=tk.LEFT, padx=(8, 0))
        ttk.Label(actions, textvariable=self.status_var).pack(side=tk.RIGHT)

    def _path_row(self, parent: ttk.Frame, row: int, label: str, var: tk.StringVar, command) -> None:
        ttk.Label(parent, text=label, style="Panel.TLabel").grid(row=row, column=0, sticky="w", pady=(0 if row == 0 else 10, 0))
        entry = ttk.Entry(parent, textvariable=var)
        entry.grid(row=row, column=1, sticky="ew", padx=(8, 8), pady=(0 if row == 0 else 10, 0))
        ttk.Button(parent, text="Browse", command=command).grid(row=row, column=2, sticky="e", pady=(0 if row == 0 else 10, 0))

    def _browse_d64(self) -> None:
        path = filedialog.askopenfilename(
            title="Select D64 image",
            initialdir=str(ROOT),
            filetypes=[("D64 images", "*.d64"), ("All files", "*.*")],
        )
        if path:
            self.d64_var.set(path)
            stem = Path(path).stem
            self.img_var.set(str(ROOT / "build" / f"{stem}_sd.img"))
            self._read_directory()

    def _browse_img(self) -> None:
        path = filedialog.asksaveasfilename(
            title="Save raw SD image",
            initialdir=str(ROOT / "build"),
            defaultextension=".img",
            filetypes=[("Raw images", "*.img"), ("All files", "*.*")],
        )
        if path:
            self.img_var.set(path)

    def _read_d64(self) -> bytes:
        path = Path(self.d64_var.get().strip())
        if not path.is_file():
            raise ValueError("select a D64 file first")
        data = path.read_bytes()
        if len(data) != D64_35_TRACK_SIZE:
            raise ValueError(f"unsupported D64 size: {len(data)} bytes, expected {D64_35_TRACK_SIZE}")
        return data

    def _read_directory(self) -> None:
        try:
            data = self._read_d64()
            self.dir_text.delete("1.0", tk.END)
            self.dir_text.insert(tk.END, f'Disk name: "{disk_name(data)}"\n\n')
            for entry in iter_entries(data):
                self.dir_text.insert(
                    tk.END,
                    f'{entry["blocks"]:4d}  {entry["type"]:<3}  '
                    f'"{entry["name"]}"  T{entry["first_track"]}/S{entry["first_sector"]}\n',
                )
            self.status_var.set("Directory OK")
        except Exception as exc:
            self.status_var.set("Directory error")
            self.dir_text.delete("1.0", tk.END)
            self.dir_text.insert(tk.END, f"ERROR: {exc}\n")

    def _convert(self) -> None:
        try:
            d64_path = Path(self.d64_var.get().strip())
            img_path = Path(self.img_var.get().strip())
            if not d64_path.is_file():
                raise ValueError("select a D64 file first")
            if not str(img_path):
                raise ValueError("select an output image path")
            image_size = parse_size(self.size_var.get())
            write_raw_sd_image(d64_path, img_path, image_size)
            self._log(f"Wrote {img_path}")
            self._log(f"Image size: {image_size} bytes")
            self._log(f"Layout: {D64_SECTORS} D64 sectors, one per SD block, lower 256 bytes")
            self.status_var.set("Image written")
            messagebox.showinfo("Done", f"Wrote SD image:\n{img_path}")
        except Exception as exc:
            self.status_var.set("Convert error")
            self._log(f"ERROR: {exc}")
            messagebox.showerror("Convert error", str(exc))

    def _log(self, text: str) -> None:
        self.log_text.insert(tk.END, text + "\n")
        self.log_text.see(tk.END)


def main() -> int:
    app = D64ToSdImageGui()
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
