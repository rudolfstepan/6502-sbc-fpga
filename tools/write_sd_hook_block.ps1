# Writes the C64HOOK1 boot block to an already formatted SD card at LBA 8,
# below the FAT16 partition, without touching the filesystem or the .d64
# files on it.  The FPGA power-up loader (c64_sd_hook_boot_loader.vhd) reads
# the block from there.
#
# Build the block first:
#   make c64-sd-fastload-hook-prg
#   python tools/d64/make_sd_hook_block.py -o build/sd_hook_block.bin roms/diagnostics/sd_fastload_hook.prg
# Then run from an elevated PowerShell:
#   tools/write_sd_hook_block.ps1 -DriveLetter G

param(
  [string]$DriveLetter = "G",
  [string]$HookBlock = "build/sd_hook_block.bin",
  [int]$HookLba = 8,
  [switch]$Force
)

$ErrorActionPreference = "Stop"

function Assert-Admin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Raw disk writes require an elevated PowerShell session. Start PowerShell as Administrator."
  }
}

Assert-Admin

$blockPath = (Resolve-Path -LiteralPath $HookBlock).Path
$bytes = [System.IO.File]::ReadAllBytes($blockPath)
if ($bytes.Length -lt 16) {
  throw "$blockPath is too small to be a hook block"
}
$magic = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 8)
if ($magic -ne "C64HOOK1") {
  throw "$blockPath does not start with the C64HOOK1 magic"
}

# Raw device I/O needs whole sectors.
$paddedLen = [int]([math]::Ceiling($bytes.Length / 512.0) * 512)
$padded = New-Object byte[] $paddedLen
[Array]::Copy($bytes, $padded, $bytes.Length)

$part = Get-Partition -DriveLetter $DriveLetter
$diskNumber = $part.DiskNumber
$disk = Get-Disk -Number $diskNumber

if ($disk.IsBoot -or $disk.IsSystem) {
  throw "Refusing to write boot/system disk $diskNumber"
}
if ($disk.Size -gt 256GB) {
  throw "Refusing to write disk larger than 256GB: $($disk.Size) bytes"
}
if ($disk.BusType -ne "USB" -and $disk.BusType -ne "SD" -and -not $Force) {
  throw "Disk $diskNumber is not USB/SD ($($disk.BusType)). Use -Force to override."
}

# The block must end below the first partition so the filesystem stays intact.
$minOffset = (Get-Partition -DiskNumber $diskNumber | Measure-Object -Property Offset -Minimum).Minimum
$writeStart = [int64]$HookLba * 512
$writeEnd = $writeStart + $paddedLen
if ($writeEnd -gt $minOffset) {
  throw ("Hook block (bytes $writeStart-$writeEnd) would overlap the first partition " +
         "(starts at byte $minOffset). This card has no room before the filesystem.")
}

Write-Host "Target: disk $diskNumber ($($disk.FriendlyName), $($disk.BusType)), volume $($DriveLetter):"
Write-Host "Hook block: $blockPath ($($bytes.Length) bytes, $($paddedLen / 512) sectors at LBA $HookLba)"
Write-Host "First partition starts at byte $minOffset (LBA $($minOffset / 512)) - untouched."

$path = "\\.\PhysicalDrive$diskNumber"
$fs = $null
try {
  $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open,
                               [System.IO.FileAccess]::ReadWrite,
                               [System.IO.FileShare]::ReadWrite)
  $null = $fs.Seek($writeStart, [System.IO.SeekOrigin]::Begin)
  $fs.Write($padded, 0, $paddedLen)
  $fs.Flush($true)

  # Read back and verify.
  $null = $fs.Seek($writeStart, [System.IO.SeekOrigin]::Begin)
  $check = New-Object byte[] $paddedLen
  $read = 0
  while ($read -lt $paddedLen) {
    $n = $fs.Read($check, $read, $paddedLen - $read)
    if ($n -le 0) { throw "Read-back ended early at $read bytes" }
    $read += $n
  }
  for ($i = 0; $i -lt $paddedLen; $i++) {
    if ($check[$i] -ne $padded[$i]) {
      throw "Verify mismatch at byte offset $i"
    }
  }
}
catch {
  throw "Raw access to $path failed: $($_.Exception.Message)"
}
finally {
  if ($fs) { $fs.Dispose() }
}

Write-Host "OK: hook block written to LBA $HookLba and verified; filesystem untouched."
