@echo off
@REM Upload the Another_Tune_for_Joanna native SID player split ROM and start it at $A000.
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_another_tune_for_joanna.rom" --split-rom --port COM15 --baud 115200 --run --verbose
