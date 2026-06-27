@echo off
@REM Upload the $4000-$5FFF SRAM self-test (UART report: ERRS / FIRST@ / ALL OK).
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\sram_test.rom" --split-rom --port COM15 --baud 115200 --run --verbose
