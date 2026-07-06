@echo off
@REM Upload the Combat_School native SID player split ROM and start it at $A000.
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_combat_school.rom" --split-rom --port COM15 --baud 115200 --run --verbose
