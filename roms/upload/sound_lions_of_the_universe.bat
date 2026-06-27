@echo off
@REM Upload the Lions_of_the_Universe native SID player split ROM and start it at $A000.
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_lions_of_the_universe.rom" --split-rom --port COM15 --baud 115200 --run --verbose
