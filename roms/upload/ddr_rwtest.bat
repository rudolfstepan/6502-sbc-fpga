@echo off
@REM DDR3 framebuffer read/write self-test. Reports PASS/FAIL over UART.
@REM Run on the current FB_DDR3 build (DDR3 calibrated / LED3 on) -- no resynth.
@REM Stays open and streams UART live (Ctrl+C to stop). Press the board reset to
@REM re-run the test. Expect: "BANK0 ERRS=00" + "BANK1 OK" = DDR3 R/W works.
python "%~dp0..\..\tools\upload_monitor_hex.py" "%~dp0..\ddr_rwtest.rom" --split-rom --port COM15 --baud 115200 --run --verbose --monitor=-1
