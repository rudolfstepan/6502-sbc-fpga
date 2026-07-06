@echo off
@REM Upload the DDR3 true-colour test (320x200 RGB565 gradient) and run at $A000.
@REM Enters the monitor over UART via the magic sequence automatically -- no button.
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\test_ddr3_true.rom" --split-rom --port COM15 --baud 115200 --run --verbose
