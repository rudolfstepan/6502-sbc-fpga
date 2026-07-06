@echo off
@REM Upload the Shadow_of_the_Beast_demo native SID player split ROM and start it at $A000.
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_shadow_of_the_beast_demo.rom" --split-rom --port COM15 --baud 115200 --run --verbose
