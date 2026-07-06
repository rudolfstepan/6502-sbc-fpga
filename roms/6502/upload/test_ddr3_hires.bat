@echo off
@REM Upload the DDR3 hi-res framebuffer test (640x400 8bpp XOR texture) and run at $A000.
@REM Enters the monitor over UART via the magic sequence automatically -- no button.
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\test_ddr3_hires.rom" --split-rom --port COM15 --baud 115200 --run --verbose
