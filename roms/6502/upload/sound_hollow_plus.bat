@echo off
@REM Upload the Hollow_plus native SID player split ROM and start it at $A000.
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_hollow_plus.rom" --split-rom --port COM15 --baud 115200 --run --verbose
