@echo off
cd /d "%~dp0..\.."
python tools\c64_uart_prg_loader.py roms\diagnostics\diagnose.prg --port COM15
