@echo off
cd /d "%~dp0\..\.."
python tools\c64_uart_prg_loader.py roms\v1541_hook.prg --port COM15
