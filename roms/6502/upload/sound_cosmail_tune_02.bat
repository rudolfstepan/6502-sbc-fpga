@echo off
@REM Upload the CosMail_tune_02 native SID player split ROM and start it at $A000.
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_cosmail_tune_02.rom" --split-rom --port COM15 --baud 115200 --run --verbose
