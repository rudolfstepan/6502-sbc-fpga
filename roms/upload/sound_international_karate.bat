@echo off
@REM Upload the International_Karate native SID player split ROM and start it at $A000.
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_international_karate.rom" --split-rom --port COM15 --baud 115200 --run --verbose
