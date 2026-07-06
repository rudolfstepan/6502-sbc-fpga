@echo off
@REM Upload the Think_Twice_IV native SID player split ROM and start it at $A000.
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_think_twice_iv.rom" --split-rom --port COM15 --baud 115200 --run --verbose
