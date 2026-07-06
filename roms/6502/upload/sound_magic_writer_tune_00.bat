@echo off
@REM Upload the Magic_Writer_tune_00 native SID player split ROM and start it at $A000.
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_magic_writer_tune_00.rom" --split-rom --port COM15 --baud 115200 --run --verbose
