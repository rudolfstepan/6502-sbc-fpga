@echo off
@REM Upload the 320x200 256-colour (RGB332) DDR3-framebuffer Mandelbrot split ROM
@REM and start it at $A000. Requires an FPGA build with FB_DDR3 enabled.
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\mandelbrot_fb.rom" --split-rom --port COM15 --baud 115200 --run --verbose
