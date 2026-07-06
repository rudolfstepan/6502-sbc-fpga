@echo off
@REM Upload the Way_of_the_Exploding_Fist native SID player split ROM and start it at $A000.
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_way_of_the_exploding_fist.rom" --split-rom --port COM15 --baud 115200 --run --verbose
