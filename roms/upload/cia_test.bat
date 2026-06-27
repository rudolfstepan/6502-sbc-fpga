@echo off
@REM Upload the CIA-1 Timer A self-test (UART report: A/B/C PASS/FAIL).
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\cia_test.rom" --split-rom --port COM15 --baud 115200 --run --verbose
