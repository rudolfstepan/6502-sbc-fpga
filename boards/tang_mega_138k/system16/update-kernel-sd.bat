@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ===========================================================================
rem update-kernel-sd.bat  --  pack the current SD-profile kernel into the boot
rem container and write ONLY that to the SD card (SD-first boot: the GRV1 kernel
rem image at LBA 0 is what actually boots). The ext2 rootfs at LBA 32768 is left
rem intact, so this is a fast kernel/driver iteration -- no full card re-image.
rem
rem This does NOT recompile the kernel (that is the slow step). It reuses the
rem already-built kernel Image from the last WSL build. If you changed kernel
rem source, run  "make kernel-sd-wsl"  once first, then this script.
rem
rem Usage (from an ADMINISTRATOR command prompt -- raw disk write needs it):
rem     update-kernel-sd.bat <DiskNumber> [--prebuilt]
rem
rem --prebuilt skips the WSL import/repack step and writes the already checked
rem build/gorv32-linux-sd/gorv32-linux-sd-boot.bin. This is useful when only
rem the generated boot records were prepared on Windows.
rem
rem Find the disk number of your card reader with:
rem     powershell -NoProfile -Command "Get-Disk | Format-Table Number,FriendlyName,SerialNumber,Size,BusType"
rem
rem The FPGA bitstream (text-console build) must be programmed separately.
rem ===========================================================================

set "SYS16=%~dp0"
set "BOOTBIN=%SYS16%..\..\..\build\gorv32-linux-sd\gorv32-linux-sd-boot.bin"
set "WRITER=%SYS16%tools\write_sd_image.ps1"

rem --- require a disk number ---------------------------------------------------
if "%~1"=="" (
  echo Usage: %~nx0 ^<DiskNumber^> [--prebuilt]
  echo Find the disk number: run "Get-Disk" in PowerShell and read the Number column
  echo of your USB card reader ^(check FriendlyName/Size to be sure^).
  exit /b 1
)
set "DISK=%~1"
set "PREBUILT=0"
if /I "%~2"=="--prebuilt" set "PREBUILT=1"
if not "%~2"=="" if "%PREBUILT%"=="0" (
  echo ERROR: unknown option "%~2". Expected --prebuilt.
  exit /b 1
)

rem --- require administrator (raw \\.\PhysicalDrive write) ---------------------
net session >nul 2>&1
if errorlevel 1 (
  echo ERROR: run this from an Administrator command prompt -- the raw SD write needs it.
  exit /b 1
)

rem --- 1. pack the boot container from the last-built kernel (fast) -----------
if "%PREBUILT%"=="1" (
  echo === Using prebuilt, already packed boot image ===
) else (
  echo === Packing boot image ^(kernel not rebuilt^) ===
  pushd "%SYS16%"
  make gorv32-sd-boot-image
  if errorlevel 1 ( popd & echo. & echo ERROR: boot-image pack failed -- build the kernel once with "make kernel-sd-wsl". & exit /b 1 )
  popd
)

if not exist "%BOOTBIN%" (
  echo ERROR: %BOOTBIN% not found -- build the kernel once with "make kernel-sd-wsl".
  exit /b 1
)

rem --- 2. identify the target disk (auto-fill the writer's safety values) -----
for /f "usebackq delims=" %%S in (`powershell -NoProfile -Command "try{(Get-Disk -Number %DISK% -ErrorAction Stop).SerialNumber}catch{}"`) do set "SERIAL=%%S"
for /f "usebackq delims=" %%Z in (`powershell -NoProfile -Command "try{(Get-Disk -Number %DISK% -ErrorAction Stop).Size}catch{}"`)         do set "SIZE=%%Z"
for /f "usebackq delims=" %%F in (`powershell -NoProfile -Command "try{(Get-Disk -Number %DISK% -ErrorAction Stop).FriendlyName}catch{}"`) do set "FNAME=%%F"

if "%SIZE%"=="" (
  echo ERROR: disk %DISK% not found.
  exit /b 1
)

echo.
echo Target disk %DISK%: %FNAME%
echo   serial : %SERIAL%
echo   size   : %SIZE% bytes
echo   write  : %BOOTBIN%
echo   note   : overwrites the boot area (LBA 0); rootfs at LBA 32768 is kept.
echo.
set "CONFIRM="
set /p "CONFIRM=Type YES to write the kernel to this disk: "
if /I not "%CONFIRM%"=="YES" ( echo Aborted. & exit /b 2 )

rem --- 3. write the boot container raw to LBA 0 via the guarded writer --------
rem     (write_sd_image.ps1 refuses boot/system and non-USB disks, then verifies
rem      the written bytes with a SHA-256 read-back.)
powershell -NoProfile -ExecutionPolicy Bypass -File "%WRITER%" -ImagePath "%BOOTBIN%" -DiskNumber %DISK% -ExpectedSerial "%SERIAL%" -ExpectedSize %SIZE%
if errorlevel 1 ( echo. & echo ERROR: SD write failed. & exit /b 1 )

echo.
echo === Done. Kernel updated on SD disk %DISK% (rootfs untouched). ===
endlocal
