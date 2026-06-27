@echo off
@REM Upload the Professional_BMX_Simulator native SID player split ROM and start it at $A000.
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_professional_bmx_simulator.rom" --split-rom --port COM15 --baud 115200 --run --verbose
