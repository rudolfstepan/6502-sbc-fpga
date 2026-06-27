@echo off
@REM Upload the Game_Music_3 native SID player split ROM and start it at $A000.
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\sound_game_music_3.rom" --split-rom --port COM15 --baud 115200 --run --verbose
