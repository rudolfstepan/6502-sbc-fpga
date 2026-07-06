@echo off
@REM Upload the Beastie_Boys_Intro_Music native SID player split ROM and start it at $A000.
python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_beastie_boys_intro_music.rom" --split-rom --port COM15 --baud 115200 --run --verbose
