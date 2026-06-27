@echo off
@REM Upload the VIC-II raster register self-test ($D011/$D012) — UART report:
@REM   A $D012 change OK / B eq-wait OK / C $D011 bit7 OK / DONE
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\raster_test.rom" --split-rom --port COM15 --baud 115200 --run --verbose
