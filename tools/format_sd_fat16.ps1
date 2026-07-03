<#
.SYNOPSIS
  Format an SD card as a small FAT16 volume for FPGA/MiSTer64 tests.

.DESCRIPTION
  Windows 11's GUI often refuses FAT16 on modern SD cards.  This script creates
  an MBR partition table, a single small primary partition, and formats it as
  FAT (FAT16).  The rest of the card is intentionally left unpartitioned.

  The operation is destructive.  Always run with -List first and verify the disk
  number before formatting.

.EXAMPLE
  .\tools\format_sd_fat16.ps1 -List

.EXAMPLE
  .\tools\format_sd_fat16.ps1 -DiskNumber 4 -DriveLetter G -Label M64D64

.EXAMPLE
  .\tools\format_sd_fat16.ps1 -DiskNumber 4 -SizeMB 2048 -DriveLetter G -Confirm:$false
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
  [switch]$List,

  [int]$DiskNumber = -1,

  [ValidateRange(1, 2048)]
  [int]$SizeMB = 2048,

  [ValidatePattern("^[A-Z]$")]
  [string]$DriveLetter = "G",

  [ValidateLength(1, 11)]
  [string]$Label = "M64D64",

  [switch]$Force
)

$ErrorActionPreference = "Stop"

function Show-Disks {
  try {
    Write-Host "Disks:"
    Get-Disk |
      Select-Object Number,FriendlyName,SerialNumber,BusType,Size,PartitionStyle,OperationalStatus,IsBoot,IsSystem,IsReadOnly |
      Format-Table -AutoSize

    Write-Host ""
    Write-Host "Volumes:"
    Get-Volume |
      Sort-Object DriveLetter |
      Select-Object DriveLetter,FileSystemLabel,FileSystem,DriveType,Size,SizeRemaining,HealthStatus |
      Format-Table -AutoSize
  }
  catch {
    throw "Could not query disks. Run from an elevated PowerShell session. Original error: $($_.Exception.Message)"
  }
}

if ($List -or $DiskNumber -lt 0) {
  Show-Disks
  if (-not $List) {
    Write-Host ""
    Write-Host "Pass -DiskNumber <n> to format a card. Example:"
    Write-Host "  .\tools\format_sd_fat16.ps1 -DiskNumber 4 -DriveLetter G"
  }
  exit 0
}

$disk = Get-Disk -Number $DiskNumber

if ($disk.IsBoot -or $disk.IsSystem) {
  throw "Refusing to format boot/system disk $DiskNumber."
}

if ($disk.Size -gt 256GB -and -not $Force) {
  throw "Refusing to format disk larger than 256GB: $($disk.Size) bytes. Use -Force to override."
}

if ($disk.BusType -ne "USB" -and $disk.BusType -ne "SD" -and $disk.BusType -ne "MMC" -and -not $Force) {
  throw "Disk $DiskNumber is $($disk.BusType), not USB/SD/MMC. Use -Force to override."
}

$sizeBytes = [int64]$SizeMB * 1MB
if ($sizeBytes -gt $disk.Size) {
  throw "Requested partition size $SizeMB MB is larger than disk $DiskNumber."
}

$target = "Disk $DiskNumber ($($disk.FriendlyName), $([Math]::Round($disk.Size / 1GB, 2)) GB)"
$action = "erase all partitions, create MBR, create $SizeMB MB FAT16 volume $DriveLetter`: labeled $Label"

Write-Host "Target disk:"
$disk | Format-List Number,FriendlyName,SerialNumber,BusType,Size,PartitionStyle,OperationalStatus,IsBoot,IsSystem,IsReadOnly,IsOffline
Write-Host "Action: $action"

if (-not $PSCmdlet.ShouldProcess($target, $action)) {
  Write-Host "Cancelled."
  exit 1
}

if ($disk.IsReadOnly) {
  Write-Host "Clearing read-only flag"
  Set-Disk -Number $DiskNumber -IsReadOnly $false
}

if ($disk.IsOffline) {
  Write-Host "Setting disk online"
  Set-Disk -Number $DiskNumber -IsOffline $false
}

Write-Host "Clearing disk $DiskNumber"
Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false

Write-Host "Initializing MBR"
Initialize-Disk -Number $DiskNumber -PartitionStyle MBR

Write-Host "Creating $SizeMB MB partition"
$partition = New-Partition -DiskNumber $DiskNumber -Size $sizeBytes -DriveLetter $DriveLetter

Write-Host "Formatting $DriveLetter`: as FAT16"
Format-Volume -Partition $partition -FileSystem FAT -NewFileSystemLabel $Label -Confirm:$false -Force | Out-Host

Write-Host ""
Write-Host "Result:"
Get-Partition -DiskNumber $DiskNumber |
  Select-Object DiskNumber,PartitionNumber,DriveLetter,Type,Size,Offset |
  Format-Table -AutoSize
Get-Volume -DriveLetter $DriveLetter |
  Select-Object DriveLetter,FileSystemLabel,FileSystem,DriveType,Size,SizeRemaining,HealthStatus,OperationalStatus |
  Format-List
