@echo off
@REM Upload the 640x400 hi-res Mandelbrot (hardware math coprocessor) and run at $A000.
@REM Enters the monitor over UART via the magic sequence automatically -- no button.
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\mandelbrot_hires.bin" --split-rom --port COM15 --baud 115200 --run --verbose
