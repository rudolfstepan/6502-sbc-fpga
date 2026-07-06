@echo off
@REM Upload the math-coprocessor Mandelbrot split ROM and start it at $A000.
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\mandelbrot_copro.bin" --split-rom --port COM15 --baud 115200 --run --verbose
