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
exit /b %ERRORLEVEL%
