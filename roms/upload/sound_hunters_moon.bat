@echo off
@REM Upload the Hunters_Moon native SID player split ROM and start it at $A000.
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_hunters_moon.rom" --split-rom --port COM15 --baud 115200 --run --verbose
