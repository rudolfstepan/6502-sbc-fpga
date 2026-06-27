@echo off
@REM Upload the Crazy_Sample_II_intro native SID player split ROM and start it at $A000.
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_crazy_sample_ii_intro.rom" --split-rom --port COM15 --baud 115200 --run --verbose
