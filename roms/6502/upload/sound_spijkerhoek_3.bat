@echo off
@REM Upload the Spijkerhoek_3 native SID player split ROM and start it at $A000.
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_spijkerhoek_3.rom" --split-rom --port COM15 --baud 115200 --run --verbose
