@echo off
setlocal
cd /d "%~dp0..\.."
python tools\virtual_1541\c64_1541_uart_gui.py %*
if errorlevel 1 pause
