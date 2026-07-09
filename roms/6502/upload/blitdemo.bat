@echo off
setlocal
@REM Upload the Amiga-style blitter feature demo (built with: make blitdemo-rom)
set "PORT=%~1"
if "%PORT%"=="" set "PORT=COM15"
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\blitdemo.bin" --split-rom --port "%PORT%" --baud 115200 --run --verbose
