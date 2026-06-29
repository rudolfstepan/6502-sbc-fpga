@echo off
cd /d "%~dp0\..\.."
python tools\c64_uart_prg_loader.py roms\diagnostics\hang_raw_irq_diag.prg --port COM15
