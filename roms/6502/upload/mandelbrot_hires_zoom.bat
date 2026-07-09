@echo off
@REM Upload the 640x400 hi-res Mandelbrot zoom animation and run at $A000.
@REM It renders once with the math coprocessor, then repeatedly zooms the image.
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\mandelbrot_hires_zoom.bin" --split-rom --port COM15 --baud 115200 --run --verbose
