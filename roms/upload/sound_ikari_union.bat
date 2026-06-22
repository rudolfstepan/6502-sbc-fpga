@echo off
@REM Upload the Ikari_Union native SID player split ROM and start it at $A000.
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_ikari_union.rom" --split-rom --port COM15 --baud 115200 --run --verbose
