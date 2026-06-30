#!/usr/bin/env python3
"""Compatibility launcher for the virtual 1541 UART GUI.

The real tool lives in tools/virtual_1541/c64_1541_uart_gui.py.
"""

from __future__ import annotations

import runpy
from pathlib import Path


TOOL = Path(__file__).resolve().parent / "virtual_1541" / "c64_1541_uart_gui.py"


if __name__ == "__main__":
    runpy.run_path(str(TOOL), run_name="__main__")
