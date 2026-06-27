@echo off
@REM Upload the Dutch_Breeze_Flip_the_Flop native SID player split ROM and start it at $A000.
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_dutch_breeze_flip_the_flop.rom" --split-rom --port COM15 --baud 115200 --run --verbose
