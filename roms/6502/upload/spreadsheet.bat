@echo off
setlocal

set "PORT=%~1"
if "%PORT%"=="" set "PORT=COM15"
set "MODE=%~2"
set "PRG=D:\Development\6502-sbc-emulator\data\disk\spreadsheet.prg"

if not exist "%PRG%" (
    echo ERROR: PRG not found: "%PRG%"
    exit /b 1
)

if /I "%MODE%"=="run" (
    python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%PRG%" --prg --port "%PORT%" --baud 115200 --run --verbose
) else (
    python "%~dp0..\..\..\tools\upload_monitor_hex.py" "%PRG%" --prg --port "%PORT%" --baud 115200 --release --verbose
)
