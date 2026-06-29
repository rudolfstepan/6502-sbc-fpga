@echo off
cd /d "%~dp0\..\.."
python tools\c64_uart_prg_loader.py roms\diagnostics\rti_diag.prg --port COM15
