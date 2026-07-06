@echo off
@REM Upload the 320x240 FULL-SCREEN true-colour Mandelbrot (RGB565) and run at $A000.
@REM Enters the monitor over UART via the magic sequence automatically -- no button.
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\mandelbrot_true240.bin" --split-rom --port COM15 --baud 115200 --run --verbose
