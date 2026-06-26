@echo off
@REM DDR3 read-beat scanner. Requires a build with DBG_BEAT_SCAN=true.
@REM Writes $42 to word 0, then prints all 8 read beats. The beat# that shows
@REM "=42" is the correct RD_BEAT generic for this board.
@REM Stays open and streams UART live (Ctrl+C to stop); press board reset to re-run.
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\ddr_beatscan.rom" --split-rom --port COM15 --baud 115200 --run --verbose --monitor=-1
