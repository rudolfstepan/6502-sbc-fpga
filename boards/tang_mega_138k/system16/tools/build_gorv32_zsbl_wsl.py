#!/usr/bin/env python3
"""Build the GoRV32 Plus ZSBL in WSL from the in-repo sources."""
import subprocess
from pathlib import Path

zsbl_dir = (Path(__file__).resolve().parent.parent / "linux" / "zsbl").as_posix()
script = f'cd "$(wslpath \'{zsbl_dir}\')" && bash build.sh'
raise SystemExit(subprocess.run(["wsl.exe", "--", "sh", "-lc", script]).returncode)
