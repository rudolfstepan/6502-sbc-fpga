@echo off
@REM Upload the A_Little_Sample native SID player split ROM and start it at $A000.
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_a_little_sample.rom" --split-rom --port COM15 --baud 115200 --run --verbose
