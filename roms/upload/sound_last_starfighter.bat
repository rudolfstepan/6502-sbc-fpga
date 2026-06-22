@echo off
@REM Upload the Last_Starfighter native SID player split ROM and start it at $A000.
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_last_starfighter.rom" --split-rom --port COM15 --baud 115200 --run --verbose
