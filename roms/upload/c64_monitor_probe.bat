@echo off
setlocal
cd /d "%~dp0..\.."
python tools\c64_uart_monitor_probe.py --port COM15 --verbose
pause
