@echo off
setlocal enableextensions
cd /d "%~dp0"

set "GWSH=C:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe"
if not exist "%GWSH%" (
    echo ERROR: gw_sh not found at:
    echo        %GWSH%
    exit /b 1
)

if exist "impl\gwsynthesis" rmdir /s /q "impl\gwsynthesis"
if exist "impl\temp"        rmdir /s /q "impl\temp"

echo.
echo Building Tang Primer 20K MiSTer C64 probe ...
"%GWSH%" build.tcl
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo BUILD FAILED ^(gw_sh exit code %RC%^)
    exit /b %RC%
)

if exist "impl\pnr\tang_mister_c64_probe.fs" (
    echo.
    echo BUILD OK -^> %CD%\impl\pnr\tang_mister_c64_probe.fs
) else (
    echo.
    echo gw_sh reported success but bitstream was not produced.
    exit /b 1
)
endlocal
