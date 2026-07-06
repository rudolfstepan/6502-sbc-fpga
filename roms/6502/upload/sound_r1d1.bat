@echo off
@REM Upload the R1D1 native SID player split ROM and start it at $A000.
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_r1d1.rom" --split-rom --port COM15 --baud 115200 --run --verbose
