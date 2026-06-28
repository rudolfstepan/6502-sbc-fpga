@echo off
rem ============================================================================
rem  Native C64 - deterministic Gowin build (Tang Primer 20K).
rem
rem  Runs gw_sh on build.tcl, which reads the exact source file list fresh every
rem  time -- so it never suffers the Gowin *IDE* problem of not reloading changed
rem  or removed files (the cause of the phantom "80909.0909" build). Just run:
rem
rem      build.bat
rem
rem  Output: impl\pnr\tang_c64.fs   (flash that).
rem ============================================================================
setlocal enableextensions
cd /d "%~dp0"

rem --- locate gw_sh: PATH first, then the default GowinEDA install ------------
set "GWSH="
for /f "delims=" %%I in ('where gw_sh 2^>nul') do if not defined GWSH set "GWSH=%%I"
if not defined GWSH set "GWSH=C:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe"
if not exist "%GWSH%" (
    echo ERROR: gw_sh not found on PATH or at:
    echo        %GWSH%
    echo Edit GWSH at the top of build.bat, or add GowinEDA\IDE\bin to PATH.
    exit /b 1
)

rem --- preserve device.cfg: it holds SSPI/MSPI=regular_io for KEY0/T10 etc.,
rem     and gw_sh rewrites a reduced version during P&R ---------------------------
set "DEVCFG=impl\pnr\device.cfg"
if exist "%DEVCFG%" copy /y "%DEVCFG%" "%TEMP%\c64_device.cfg.bak" >nul

rem --- force a fresh synthesis (avoid any stale incremental output) -----------
if exist "impl\gwsynthesis" rmdir /s /q "impl\gwsynthesis"
if exist "impl\temp"        rmdir /s /q "impl\temp"

echo.
echo  gw_sh : %GWSH%
echo  script: %CD%\build.tcl
echo.
echo Building native C64 bitstream ...
"%GWSH%" build.tcl
set "RC=%ERRORLEVEL%"

rem --- restore the versioned device.cfg for the next build -------------------
if exist "%TEMP%\c64_device.cfg.bak" (
    copy /y "%TEMP%\c64_device.cfg.bak" "%DEVCFG%" >nul
    del /q "%TEMP%\c64_device.cfg.bak" >nul
)

echo.
if not "%RC%"=="0" (
    echo ====================================================================
    echo  BUILD FAILED  ^(gw_sh exit code %RC%^) -- see the messages above.
    echo ====================================================================
    exit /b %RC%
)

if exist "impl\pnr\tang_c64.fs" (
    echo ====================================================================
    echo  BUILD OK  -^>  %CD%\impl\pnr\tang_c64.fs
    echo  Flash this with the Gowin Programmer or openFPGALoader.
    echo ====================================================================
) else (
    echo  gw_sh reported success but impl\pnr\tang_c64.fs was not produced.
    exit /b 1
)
endlocal
