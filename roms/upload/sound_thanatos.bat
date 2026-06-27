@echo off
@REM Upload the Thanatos native SID player split ROM and start it at $A000.
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_thanatos.rom" --split-rom --port COM15 --baud 115200 --run --verbose
