@echo off
@REM Upload the split EhBASIC ROM around the $D000-$EFFF I/O window, then run it.
python "%~dp0..\..\tools\upload_monitor_hex.py" --ehbasic --port COM15 --baud 115200 --run --verbose
