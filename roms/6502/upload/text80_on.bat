@echo off
@REM Upload and run the tiny PRG that switches the FPGA text VIC to 80 columns.
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\text80_on.prg" --prg --port COM15 --baud 115200 --run --verbose
