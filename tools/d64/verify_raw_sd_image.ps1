param(
  [Parameter(Mandatory=$true)]
  [string]$Image,

  [Parameter(Mandatory=$true)]
  [int]$DiskNumber,

  [int]$Bytes = 2097152,

  [switch]$Force
)

$ErrorActionPreference = "Stop"

$imagePath = (Resolve-Path -LiteralPath $Image).Path
$disk = Get-Disk -Number $DiskNumber

if ($disk.IsBoot -or $disk.IsSystem) {
  throw "Refusing to read boot/system disk $DiskNumber"
}

if ($disk.Size -gt 256GB) {
  throw "Refusing to read disk larger than 256GB: $($disk.Size) bytes"
}

if ($disk.BusType -ne "USB" -and -not $Force) {
  throw "Disk $DiskNumber is not USB ($($disk.BusType)). Use -Force to override."
}

$imageBytes = [System.IO.File]::ReadAllBytes($imagePath)
$compareBytes = [Math]::Min($Bytes, $imageBytes.Length)
if ($compareBytes -gt $disk.Size) {
  throw "Requested read size is larger than target disk"
}

Write-Host "Target disk:"
$disk | Format-List Number,FriendlyName,BusType,Size,PartitionStyle,IsBoot,IsSystem,IsOffline,IsReadOnly
Write-Host "Image: $imagePath"
Write-Host "Comparing bytes: $compareBytes"

$wasOffline = $disk.IsOffline
$wasReadOnly = $disk.IsReadOnly

if ($disk.IsReadOnly) {
  Write-Host "Clearing read-only flag"
  Set-Disk -Number $DiskNumber -IsReadOnly $false
}

if (-not $disk.IsOffline) {
  Write-Host "Setting disk offline for raw read"
  try {
    Set-Disk -Number $DiskNumber -IsOffline $true
    Start-Sleep -Milliseconds 500
  }
  catch {
    Write-Host "Could not set disk offline, trying raw read while online: $($_.Exception.Message)"
  }
}

$path = "\\.\PhysicalDrive$DiskNumber"
$buf = New-Object byte[] $compareBytes
$fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
try {
  $pos = 0
  while ($pos -lt $compareBytes) {
    $n = $fs.Read($buf, $pos, $compareBytes - $pos)
    if ($n -le 0) {
      throw "Short read at byte $pos"
    }
    $pos += $n
  }
}
finally {
  $fs.Dispose()
}

if (-not $wasOffline -and (Get-Disk -Number $DiskNumber).IsOffline) {
  Write-Host "Setting disk online again"
  Set-Disk -Number $DiskNumber -IsOffline $false
}

if ($wasReadOnly) {
  Write-Host "Restoring read-only flag"
  Set-Disk -Number $DiskNumber -IsReadOnly $true
}

$mismatch = -1
for ($i = 0; $i -lt $compareBytes; $i++) {
  if ($buf[$i] -ne $imageBytes[$i]) {
    $mismatch = $i
    break
  }
}

if ($mismatch -lt 0) {
  Write-Host "OK: first $compareBytes bytes match the image"
  exit 0
}

$expected = "0x{0:X2}" -f $imageBytes[$mismatch]
$actual = "0x{0:X2}" -f $buf[$mismatch]
throw "Mismatch at byte ${mismatch}: expected $expected, got $actual"
