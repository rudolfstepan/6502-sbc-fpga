@echo off
@REM Upload the Thats_the_Way_It_Is_intro native SID player split ROM and start it at $A000.
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_thats_the_way_it_is_intro.rom" --split-rom --port COM15 --baud 115200 --run --verbose
