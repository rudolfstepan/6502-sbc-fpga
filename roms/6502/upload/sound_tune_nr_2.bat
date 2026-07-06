@echo off
@REM Upload the Tune_Nr_2 native SID player split ROM and start it at $A000.
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_tune_nr_2.rom" --split-rom --port COM15 --baud 115200 --run --verbose
