[CmdletBinding()]
param(
    [Parameter(Mandatory)] [int] $DiskNumber,
    [Parameter(Mandatory)] [string] $ExpectedSerial,
    [Parameter(Mandatory)] [UInt64] $ExpectedSize,
    [string] $ExpectedHash,
    [string] $OutputPath
)

$ErrorActionPreference = 'Stop'

function Get-ValidatedTarget {
    $disk = Get-Disk -Number $DiskNumber
    $serial = ($disk.SerialNumber -replace '\s', '')
    $wantedSerial = ($ExpectedSerial -replace '\s', '')
    if ($disk.IsBoot -or $disk.IsSystem) {
        throw "Refusing to read boot/system disk $DiskNumber"
    }
    if ($disk.BusType -ne 'USB') {
        throw "Refusing non-USB disk $DiskNumber ($($disk.BusType))"
    }
    if ($disk.OperationalStatus -notcontains 'Online') {
        throw "Disk $DiskNumber is not online ($($disk.OperationalStatus))"
    }
    if ($serial -ne $wantedSerial -or [UInt64]$disk.Size -ne $ExpectedSize) {
        throw "Disk identity changed: got serial '$serial', size $($disk.Size)"
    }
    return $disk
}

$disk = Get-ValidatedTarget
$devicePath = "\\.\PhysicalDrive$DiskNumber"
$buffer = [byte[]]::new(4MB)
$empty = [byte[]]::new(0)
$sha256 = [Security.Cryptography.SHA256]::Create()
$stream = $null
[UInt64]$remaining = $ExpectedSize
[UInt64]$processed = 0
$lastPercent = -1

Write-Host "Hashing $devicePath ($ExpectedSize bytes)"
Write-Host "Target: $($disk.FriendlyName), serial $ExpectedSerial"

try {
    # Validate a second time immediately before opening the raw device. This
    # catches card removal or replacement between discovery and access.
    [void](Get-ValidatedTarget)
    $stream = [IO.FileStream]::new(
        $devicePath, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite, 4MB, [IO.FileOptions]::SequentialScan)
    while ($remaining -gt 0) {
        $wanted = [int][Math]::Min([UInt64]$buffer.Length, $remaining)
        $read = $stream.Read($buffer, 0, $wanted)
        if ($read -le 0) {
            throw "Short raw read after $processed of $ExpectedSize bytes"
        }
        [void]$sha256.TransformBlock($buffer, 0, $read, $null, 0)
        $remaining -= [UInt64]$read
        $processed += [UInt64]$read
        $percent = [int](100 * $processed / $ExpectedSize)
        if ($percent -ne $lastPercent) {
            Write-Progress -Activity 'Hashing complete SD card' `
                -Status "$percent% ($processed/$ExpectedSize bytes)" `
                -PercentComplete $percent
            $lastPercent = $percent
        }
    }
    [void]$sha256.TransformFinalBlock($empty, 0, 0)
} finally {
    Write-Progress -Activity 'Hashing complete SD card' -Completed
    if ($stream) { $stream.Dispose() }
}

$hashBytes = $sha256.Hash
$sha256.Dispose()
$hash = [BitConverter]::ToString($hashBytes).Replace('-', '')
if ($ExpectedHash) {
    $wantedHash = ($ExpectedHash -replace '[\s-]', '').ToUpperInvariant()
    if ($hash -ne $wantedHash) {
        throw "Full-card SHA-256 mismatch: got $hash, expected $wantedHash"
    }
    Write-Host 'Full-card hash matches the expected baseline.'
}

$lines = @(
    "DiskNumber=$DiskNumber"
    "Serial=$($ExpectedSerial -replace '\s', '')"
    "Size=$ExpectedSize"
    "SHA256=$hash"
    "TimestampUtc=$([DateTime]::UtcNow.ToString('o'))"
)
if ($OutputPath) {
    $fullOutput = [IO.Path]::GetFullPath($OutputPath)
    if (Test-Path -LiteralPath $fullOutput) {
        throw "Refusing to overwrite existing baseline: $fullOutput"
    }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullOutput))
    [IO.File]::WriteAllLines($fullOutput, $lines)
    Write-Host "Baseline written to $fullOutput"
}
$lines | Write-Output
