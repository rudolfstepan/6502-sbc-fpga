@echo off
setlocal enableextensions
cd /d "%~dp0"

set "PYTHON_EXE="
if defined SYS16_PYTHON if exist "%SYS16_PYTHON%" set "PYTHON_EXE=%SYS16_PYTHON%"
if not defined PYTHON_EXE if defined PYTHON if exist "%PYTHON%" set "PYTHON_EXE=%PYTHON%"
if not defined PYTHON_EXE for /f "delims=" %%I in ('where python.exe 2^>nul') do if not defined PYTHON_EXE set "PYTHON_EXE=%%I"
if not defined PYTHON_EXE for /d %%D in ("%LOCALAPPDATA%\Programs\Python\Python*") do if exist "%%~fD\python.exe" if not defined PYTHON_EXE set "PYTHON_EXE=%%~fD\python.exe"

if not defined PYTHON_EXE (
    echo ERROR: python.exe was not found.
    echo Set SYS16_PYTHON to the complete python.exe path.
    pause
    exit /b 1
)

set "PORT=%~1"
if not defined PORT set "PORT=COM14"

if not exist "hello_sdram.bin" (
    echo ERROR: %CD%\hello_sdram.bin was not found.
    echo Run make sdram-demo first.
    pause
    exit /b 1
)

echo Python : %PYTHON_EXE%
echo Port   : %PORT%
"%PYTHON_EXE%" "%~dp0..\tools\upload_system16.py" "%~dp0hello_sdram.bin" --port "%PORT%" --address 0x001000 --verify --run
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
exit /b %RC%
