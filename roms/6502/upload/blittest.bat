@echo off
setlocal

set "PORT=%~1"
if "%PORT%"=="" set "PORT=COM15"
set "PRG=D:\Development\6502-sbc-emulator\data\disk\blittest.prg"

if not exist "%PRG%" (
    echo ERROR: PRG not found: "%PRG%"
    echo Build it first:  ca65 -t none -o build/cube/blittest.o examples/blittest.s ^&^& ld65 -C examples/cube.cfg build/cube/blittest.o -o data/disk/blittest.prg
    exit /b 1
)

python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%PRG%" --prg --port "%PORT%" --baud 115200 --run --verbose
