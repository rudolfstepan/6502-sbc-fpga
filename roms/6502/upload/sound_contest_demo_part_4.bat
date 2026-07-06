@echo off
@REM Upload the Contest_Demo_part_4 native SID player split ROM and start it at $A000.
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_contest_demo_part_4.rom" --split-rom --port COM15 --baud 115200 --run --verbose
