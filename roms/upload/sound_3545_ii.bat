@echo off
@REM Upload the 3545_II native SID player split ROM and start it at $A000.
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_3545_ii.rom" --split-rom --port COM15 --baud 115200 --run --verbose
