@echo off
@REM Upload the Soldier_of_Light native SID player split ROM and start it at $A000.
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_soldier_of_light.rom" --split-rom --port COM15 --baud 115200 --run --verbose
