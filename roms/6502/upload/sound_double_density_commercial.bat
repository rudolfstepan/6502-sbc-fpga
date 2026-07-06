@echo off
@REM Upload the Double_Density_Commercial native SID player split ROM and start it at $A000.
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_double_density_commercial.rom" --split-rom --port COM15 --baud 115200 --run --verbose
