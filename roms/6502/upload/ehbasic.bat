@echo off
@REM Build and upload the split EhBASIC ROM around the $D000-$DFFF I/O window, then run it.
python "%~dp0..\..\..\tools\upload_monitor_hex.py" --ehbasic --build-ehbasic --port COM15 --baud 115200 --run --verbose
