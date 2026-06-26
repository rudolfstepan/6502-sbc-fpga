@echo off
@REM Upload the DDR3 framebuffer smoke test (320x200 8bpp colour gradient) and
@REM start it at $A000. Requires an FPGA build with FB_DDR3 enabled.
@REM Pattern visible -> fb display + DDR3 read/write + bank switching work.
@REM Screen black     -> DDR3 not calibrated or read/write protocol wrong.
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\fb_test.rom" --split-rom --port COM15 --baud 115200 --run --verbose
