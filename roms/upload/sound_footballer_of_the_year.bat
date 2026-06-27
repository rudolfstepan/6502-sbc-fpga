@echo off
@REM Upload the Footballer_of_the_Year native SID player split ROM and start it at $A000.
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_footballer_of_the_year.rom" --split-rom --port COM15 --baud 115200 --run --verbose
