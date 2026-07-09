@echo off
setlocal
@REM Upload the fireworks blitter demo as a split ROM (built with: make blit-demo-roms)
set "PORT=%~1"
if "%PORT%"=="" set "PORT=COM15"
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\fireworks_rom.bin" --split-rom --port "%PORT%" --baud 115200 --run --verbose
