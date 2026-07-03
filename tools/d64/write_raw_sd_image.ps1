param(
  [Parameter(Mandatory=$true)]
  [string]$Image,

  [Parameter(Mandatory=$true)]
  [int]$DiskNumber,

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

function Dismount-TargetVolumes {
  param([int]$Number)

  $parts = Get-Partition -DiskNumber $Number -ErrorAction SilentlyContinue
  foreach ($part in $parts) {
    if ($part.DriveLetter) {
      Write-Host "Dismounting volume $($part.DriveLetter):"
      try {
        Dismount-Volume -DriveLetter $part.DriveLetter -Force -Confirm:$false -ErrorAction Stop
      }
      catch {
        Write-Host "Could not dismount $($part.DriveLetter): $($_.Exception.Message)"
      }

      Write-Host "Removing drive letter $($part.DriveLetter):"
      Remove-PartitionAccessPath -DiskNumber $Number -PartitionNumber $part.PartitionNumber -AccessPath "$($part.DriveLetter):\" -ErrorAction SilentlyContinue
    }
  }
}

Assert-Admin

$imagePath = (Resolve-Path -LiteralPath $Image).Path
$disk = Get-Disk -Number $DiskNumber

if ($disk.IsBoot -or $disk.IsSystem) {
  throw "Refusing to write boot/system disk $DiskNumber"
}

if ($disk.Size -gt 256GB) {
  throw "Refusing to write disk larger than 256GB: $($disk.Size) bytes"
}

if ($disk.BusType -ne "USB" -and -not $Force) {
  throw "Disk $DiskNumber is not USB ($($disk.BusType)). Use -Force to override."
}

$imageBytes = [System.IO.File]::ReadAllBytes($imagePath)
if ($imageBytes.Length -gt $disk.Size) {
  throw "Image is larger than target disk"
}

Write-Host "Target disk:"
$disk | Format-List Number,FriendlyName,BusType,Size,PartitionStyle,IsBoot,IsSystem
Write-Host "Image: $imagePath"
Write-Host "Bytes: $($imageBytes.Length)"

$wasOffline = $disk.IsOffline
$wasReadOnly = $disk.IsReadOnly
$offlineSucceeded = $false

if ($disk.IsReadOnly) {
  Write-Host "Clearing read-only flag"
  Set-Disk -Number $DiskNumber -IsReadOnly $false
}

Dismount-TargetVolumes -Number $DiskNumber

if (-not $disk.IsOffline) {
  Write-Host "Setting disk offline for raw write"
  try {
    Set-Disk -Number $DiskNumber -IsOffline $true
    $offlineSucceeded = $true
    Start-Sleep -Milliseconds 500
  }
  catch {
    Write-Host "Could not set disk offline, trying raw write after volume dismount: $($_.Exception.Message)"
  }
}

$path = "\\.\PhysicalDrive$DiskNumber"
$fs = $null
try {
  $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
  $fs.Write($imageBytes, 0, $imageBytes.Length)
  $fs.Flush($true)
}
catch {
  throw "Raw write to $path failed: $($_.Exception.Message). Close Explorer/windows using the SD card, keep the drive letter removed, and run this script from an elevated PowerShell session."
}
finally {
  if ($fs) {
    $fs.Dispose()
  }
}

if (-not $wasOffline -and $offlineSucceeded) {
  Write-Host "Setting disk online again"
  Set-Disk -Number $DiskNumber -IsOffline $false
}

if ($wasReadOnly) {
  Write-Host "Restoring read-only flag"
  Set-Disk -Number $DiskNumber -IsReadOnly $true
}

Write-Host "Wrote $($imageBytes.Length) bytes to $path"
