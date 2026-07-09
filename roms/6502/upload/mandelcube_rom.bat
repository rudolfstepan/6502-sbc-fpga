@echo off
setlocal
@REM Upload the Mandelbrot texture cube demo as a split ROM.
set "PORT=%~1"
if "%PORT%"=="" set "PORT=COM15"
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\mandelcube_rom.bin" --split-rom --port "%PORT%" --baud 115200 --run --verbose
