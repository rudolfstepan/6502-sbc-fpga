@echo off
@REM Upload the 320x240 16-colour framebuffer test (16 vertical colour bars).
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\fb16_test.rom" --split-rom --port COM15 --baud 115200 --run --verbose
