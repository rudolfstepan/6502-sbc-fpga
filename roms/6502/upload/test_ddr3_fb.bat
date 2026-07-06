@echo off
@REM Upload the DDR3 8bpp framebuffer test (8 vertical colour bars) and run at $A000.
@REM Enters the monitor over UART via the magic sequence automatically -- no button.
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\test_ddr3_fb.rom" --split-rom --port COM15 --baud 115200 --run --verbose
