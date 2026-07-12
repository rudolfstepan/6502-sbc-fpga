[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ImagePath,
    [Parameter(Mandatory)] [int] $DiskNumber,
    [Parameter(Mandatory)] [string] $ExpectedSerial,
    [Parameter(Mandatory)] [UInt64] $ExpectedSize
)

$ErrorActionPreference = 'Stop'
$image = Get-Item -LiteralPath (Resolve-Path -LiteralPath $ImagePath)
$header = [byte[]]::new(4)
$headerStream = [IO.File]::OpenRead($image.FullName)
try {
    if ($headerStream.Read($header, 0, 4) -ne 4 -or
        [Text.Encoding]::ASCII.GetString($header) -ne 'GRV1') {
        throw "Image does not start with the GRV1 header: $($image.FullName)"
    }
} finally {
    $headerStream.Dispose()
}

function Get-ValidatedTarget {
    $disk = Get-Disk -Number $DiskNumber
    $serial = ($disk.SerialNumber -replace '\s', '')
    $wantedSerial = ($ExpectedSerial -replace '\s', '')
    if ($disk.IsBoot -or $disk.IsSystem) {
        throw "Refusing to overwrite boot/system disk $DiskNumber"
    }
    if ($disk.BusType -ne 'USB') {
        throw "Refusing non-USB disk $DiskNumber ($($disk.BusType))"
    }
    if ($serial -ne $wantedSerial -or [UInt64]$disk.Size -ne $ExpectedSize) {
        throw "Disk identity changed: got serial '$serial', size $($disk.Size)"
    }
    if ($disk.IsReadOnly) {
        throw "Disk $DiskNumber is read-only"
    }
    if ([UInt64]$image.Length -gt [UInt64]$disk.Size) {
        throw "Image is larger than disk $DiskNumber"
    }
    return $disk
}

$disk = Get-ValidatedTarget
$sourceHash = (Get-FileHash -LiteralPath $image.FullName -Algorithm SHA256).Hash
Write-Host "Writing $($image.FullName) ($($image.Length) bytes)"
Write-Host "Target: PhysicalDrive$DiskNumber, $($disk.FriendlyName), serial $ExpectedSerial, $ExpectedSize bytes"

$driveLetters = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
    Where-Object DriveLetter | ForEach-Object DriveLetter
foreach ($letter in $driveLetters) {
    & mountvol.exe "$letter`:" /p
    if ($LASTEXITCODE -ne 0) {
        throw "Could not dismount volume $letter`:"
    }
}

$disk = Get-ValidatedTarget
$wasOffline = $disk.IsOffline
$madeOffline = $false
if (-not $wasOffline -and $disk.BusType -ne 'USB') {
    Set-Disk -Number $DiskNumber -IsOffline $true
    $madeOffline = $true
} elseif (-not $wasOffline) {
    # Windows does not support offlining media exposed by a removable USB
    # card reader. All mounted volumes were removed above before raw access.
    Write-Warning 'USB removable media remains online after volume dismount'
}

$deviceStream = $null
$sourceStream = $null
try {
    $devicePath = "\\.\PhysicalDrive$DiskNumber"
    Write-Host "Opening $devicePath for raw read/write"
    $deviceStream = [IO.FileStream]::new(
        $devicePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::ReadWrite, 4MB, [IO.FileOptions]::WriteThrough)
    Write-Host 'Raw device opened; writing image'
    $sourceStream = [IO.File]::OpenRead($image.FullName)
    $sourceStream.CopyTo($deviceStream, 4MB)
    $deviceStream.Flush($true)
    $sourceStream.Dispose()
    $sourceStream = $null
    $deviceStream.Dispose()
    $deviceStream = $null

    # Close the write-through handle before verification. Some removable USB
    # readers otherwise serve stale sectors when a read follows a raw write on
    # the same handle even after Flush(true).
    Start-Sleep -Milliseconds 500
    Write-Host 'Write complete; reopening device for read-back verification'
    $deviceStream = [IO.FileStream]::new(
        $devicePath, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite, 4MB, [IO.FileOptions]::SequentialScan)

    $deviceStream.Position = 0
    $remaining = [Int64]$image.Length
    $buffer = [byte[]]::new(4MB)
    $targetHasher = [Security.Cryptography.IncrementalHash]::CreateHash(
        [Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        while ($remaining -gt 0) {
            $wanted = [int][Math]::Min($buffer.Length, $remaining)
            $read = $deviceStream.Read($buffer, 0, $wanted)
            if ($read -ne $wanted) {
                throw "Short read during verification: wanted $wanted, got $read"
            }
            $targetHasher.AppendData($buffer, 0, $read)
            $remaining -= $read
        }
        $targetHash = [Convert]::ToHexString($targetHasher.GetHashAndReset())
    } finally {
        $targetHasher.Dispose()
    }
    if ($targetHash -ne $sourceHash) {
        throw "Verification failed: image $sourceHash, card $targetHash"
    }
    Write-Host "Verified SHA256: $targetHash"
} finally {
    if ($sourceStream) { $sourceStream.Dispose() }
    if ($deviceStream) { $deviceStream.Dispose() }
    if ($madeOffline) {
        Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction Continue
    }
}
