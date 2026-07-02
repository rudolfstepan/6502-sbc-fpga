@echo off
setlocal
cd /d "%~dp0\..\.."
python tools\d64\d64_to_sd_image_gui.py
