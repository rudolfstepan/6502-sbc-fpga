@echo off
setlocal enableextensions enabledelayedexpansion
cd /d "%~dp0"

if /i "%~1"=="help" goto :usage
if /i "%~1"=="--help" goto :usage
if /i "%~1"=="-h" goto :usage

set "DO_CLEAN=0"
set "DO_FIRMWARE=1"
set "DO_BUILD=1"
if /i "%~1"=="clean" set "DO_CLEAN=1"
if /i "%~1"=="nofw" set "DO_FIRMWARE=0"
if /i "%~1"=="firmware" set "DO_BUILD=0"
if not "%~1"=="" if /i not "%~1"=="clean" if /i not "%~1"=="nofw" if /i not "%~1"=="firmware" (
    echo ERROR: Unknown option "%~1".
    goto :usage_error
)

rem Locate gw_sh. An existing GWSH environment variable has priority.
set "GWSH_EXE="
if defined GWSH if exist "%GWSH%" set "GWSH_EXE=%GWSH%"
if not defined GWSH_EXE for /f "delims=" %%I in ('where gw_sh.exe 2^>nul') do if not defined GWSH_EXE set "GWSH_EXE=%%I"
if not defined GWSH_EXE if exist "C:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe" set "GWSH_EXE=C:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe"
if not defined GWSH_EXE if exist "C:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe" set "GWSH_EXE=C:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe"

if not defined GWSH_EXE (
    echo ERROR: gw_sh.exe was not found.
    echo Set GWSH to the complete gw_sh.exe path or add it to PATH.
    exit /b 1
)

if "%DO_FIRMWARE%"=="1" (
    set "PYTHON_EXE="
    if defined SYS16_PYTHON if exist "!SYS16_PYTHON!" set "PYTHON_EXE=!SYS16_PYTHON!"
    if not defined PYTHON_EXE if defined PYTHON if exist "!PYTHON!" set "PYTHON_EXE=!PYTHON!"
    if not defined PYTHON_EXE for /f "delims=" %%I in ('where python.exe 2^>nul') do if not defined PYTHON_EXE set "PYTHON_EXE=%%I"
    if not defined PYTHON_EXE for /d %%D in ("%LOCALAPPDATA%\Programs\Python\Python*") do if exist "%%~fD\python.exe" if not defined PYTHON_EXE set "PYTHON_EXE=%%~fD\python.exe"

    if not defined PYTHON_EXE (
        echo ERROR: python.exe was not found.
        echo Set SYS16_PYTHON to the complete python.exe path.
        pause
        exit /b 1
    )

    where make.exe >nul 2>nul
    if errorlevel 1 (
        echo ERROR: make.exe was not found. Use "build.bat nofw" to keep the existing ROM image.
        pause
        exit /b 1
    )

    echo.
    echo Updating System16 boot firmware ...
    echo Python     : !PYTHON_EXE!
    set "PYTHON=!PYTHON_EXE!"
    make firmware
    if errorlevel 1 (
        echo ERROR: Firmware build failed.
        pause
        exit /b 1
    )
)

if "%DO_BUILD%"=="0" (
    echo.
    echo ================================================================
    echo FIRMWARE OK
    echo %CD%\rtl\sys16_boot_rom_image_pkg.vhd
    echo ================================================================
    exit /b 0
)

if "%DO_CLEAN%"=="1" (
    echo.
    echo Removing generated implementation data for a clean build ...
    if exist "project\impl\gwsynthesis" rmdir /s /q "project\impl\gwsynthesis"
    if exist "project\impl\pnr"         rmdir /s /q "project\impl\pnr"
    if exist "project\impl\temp"        rmdir /s /q "project\impl\temp"
    if exist "project\tmp"              rmdir /s /q "project\tmp"
)

echo.
echo Gowin shell : %GWSH_EXE%
echo Build script: %CD%\project\build.tcl
echo Mode        : %DO_CLEAN% ^(0=incremental, 1=clean^)
echo.

pushd "project"
"%GWSH_EXE%" build.tcl
set "RC=%ERRORLEVEL%"
popd

echo.
if not "%RC%"=="0" (
    echo ================================================================
    echo BUILD FAILED ^(gw_sh exit code %RC%^)
    echo ================================================================
    exit /b %RC%
)

if not exist "project\impl\pnr\tang138k_system16.fs" (
    echo ERROR: gw_sh returned success but no bitstream was produced.
    exit /b 1
)

echo ================================================================
echo BUILD OK
echo %CD%\project\impl\pnr\tang138k_system16.fs
echo ================================================================
exit /b 0

:usage
echo Usage: build.bat [clean^|nofw^|firmware]
echo.
echo   build.bat        Update firmware and build using existing Gowin data.
echo   build.bat clean  Update firmware and force synthesis plus P-and-R clean.
echo   build.bat nofw   Keep the existing generated boot ROM image.
echo   build.bat firmware  Update only the boot ROM image; do not run Gowin.
exit /b 0

:usage_error
echo Usage: build.bat [clean^|nofw^|firmware]
exit /b 2
