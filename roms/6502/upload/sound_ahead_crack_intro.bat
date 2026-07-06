@echo off
@REM Upload the Ahead_Crack_Intro native SID player split ROM and start it at $A000.
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_ahead_crack_intro.rom" --split-rom --port COM15 --baud 115200 --run --verbose
