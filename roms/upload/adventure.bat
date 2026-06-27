@echo off
@REM Upload the "Crypt of the 6502" adventure split ROM and start it at $A000.
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\adventure.rom" --split-rom --port COM15 --baud 115200 --run --verbose
