param(
  [Parameter(Mandatory=$true)]
  [string]$Image,

  [Parameter(Mandatory=$true)]
  [int]$DiskNumber,

  [switch]$Force
)

$ErrorActionPreference = "Stop"

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

$parts = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue
foreach ($part in $parts) {
  if ($part.DriveLetter) {
    Write-Host "Removing drive letter $($part.DriveLetter):"
    Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $part.PartitionNumber -AccessPath "$($part.DriveLetter):\" -ErrorAction SilentlyContinue
  }
}

$wasOffline = $disk.IsOffline
$wasReadOnly = $disk.IsReadOnly

if ($disk.IsReadOnly) {
  Write-Host "Clearing read-only flag"
  Set-Disk -Number $DiskNumber -IsReadOnly $false
}

if (-not $disk.IsOffline) {
  Write-Host "Setting disk offline for raw write"
  Set-Disk -Number $DiskNumber -IsOffline $true
  Start-Sleep -Milliseconds 500
}

$path = "\\.\PhysicalDrive$DiskNumber"
$fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
try {
  $fs.Write($imageBytes, 0, $imageBytes.Length)
  $fs.Flush($true)
}
finally {
  $fs.Dispose()
}

if (-not $wasOffline) {
  Write-Host "Setting disk online again"
  Set-Disk -Number $DiskNumber -IsOffline $false
}

if ($wasReadOnly) {
  Write-Host "Restoring read-only flag"
  Set-Disk -Number $DiskNumber -IsReadOnly $true
}

Write-Host "Wrote $($imageBytes.Length) bytes to $path"
