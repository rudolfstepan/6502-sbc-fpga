@echo off
@REM Upload the Strike_Force_Introtune native SID player split ROM and start it at $A000.
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_strike_force_introtune.rom" --split-rom --port COM15 --baud 115200 --run --verbose
