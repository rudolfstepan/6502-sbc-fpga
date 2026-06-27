@echo off
@REM Upload the PCW-Tune_88 native SID player split ROM and start it at $A000.
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_pcw_tune_88.rom" --split-rom --port COM15 --baud 115200 --run --verbose
