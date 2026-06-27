@echo off
@REM Upload the One_Man_and_His_Droid native SID player split ROM and start it at $A000.
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_one_man_and_his_droid.rom" --split-rom --port COM15 --baud 115200 --run --verbose
