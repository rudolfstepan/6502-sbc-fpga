@echo off
setlocal

set "PSEXE="
for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do if not defined PSEXE set "PSEXE=%%I"
if not defined PSEXE for /f "delims=" %%I in ('where powershell.exe 2^>nul') do if not defined PSEXE set "PSEXE=%%I"

if not defined PSEXE (
    echo ERROR: PowerShell was not found.
    exit /b 1
)

"%PSEXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\prepare_project.ps1"
if errorlevel 1 exit /b %ERRORLEVEL%

set "PROJECT=%~dp0project\nanomig_tc138k.gprj"

if not exist "%PROJECT%" (
    echo ERROR: NanoMig project not found:
    echo   %PROJECT%
    exit /b 1
)

set "GOWIN_IDE_EXE="
if defined GOWIN_IDE if exist "%GOWIN_IDE%" set "GOWIN_IDE_EXE=%GOWIN_IDE%"
if not defined GOWIN_IDE_EXE for /f "delims=" %%I in ('where gw_ide.exe 2^>nul') do if not defined GOWIN_IDE_EXE set "GOWIN_IDE_EXE=%%I"
if not defined GOWIN_IDE_EXE if exist "C:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_ide.exe" set "GOWIN_IDE_EXE=C:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_ide.exe"
if not defined GOWIN_IDE_EXE if exist "C:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_ide.exe" set "GOWIN_IDE_EXE=C:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_ide.exe"

if not defined GOWIN_IDE_EXE (
    echo Gowin IDE was not found automatically. Opening the project through
    echo the Windows file association instead.
    start "" "%PROJECT%"
    exit /b 0
)

start "" "%GOWIN_IDE_EXE%" "%PROJECT%"
exit /b 0
