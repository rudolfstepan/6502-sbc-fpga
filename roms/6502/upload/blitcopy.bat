@echo off
setlocal
@REM Upload the blitter COPY/COPYT test ROM (built with: make blitcopy-rom)
set "PORT=%~1"
if "%PORT%"=="" set "PORT=COM15"
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\blitcopy.bin" --split-rom --port "%PORT%" --baud 115200 --run --verbose
