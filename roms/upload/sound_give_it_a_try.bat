@echo off
@REM Upload the Give_It_a_Try native SID player split ROM and start it at $A000.
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_give_it_a_try.rom" --split-rom --port COM15 --baud 115200 --run --verbose
