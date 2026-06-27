@echo off
@REM Upload the Spriffs_II native SID player split ROM and start it at $A000.
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_spriffs_ii.rom" --split-rom --port COM15 --baud 115200 --run --verbose
