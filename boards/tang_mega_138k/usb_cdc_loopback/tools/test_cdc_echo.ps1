[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^COM\d+$')]
    [string]$Port,

    [ValidateRange(1, 1048576)]
    [int]$ByteCount = 4096,

    [ValidateRange(1, 120)]
    [int]$TimeoutSeconds = 10
)

$expectedUsbId = 'VID_33AA&PID_0121'
$escapedPort = [regex]::Escape($Port)
$portDevices = @(
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.Class -eq 'Ports') -and
            ($_.FriendlyName -match "\($escapedPort\)")
        }
)

if ($portDevices.Count -eq 0) {
    throw "$Port ist kein aktuell erkannter Windows-COM-Port. Im Geraetemanager den neuen 'USB Serial Device'-Port ablesen."
}

$matchingDevice = @(
    $portDevices | Where-Object { $_.InstanceId -match $expectedUsbId }
)
if ($matchingDevice.Count -eq 0) {
    $found = ($portDevices | ForEach-Object {
        "$($_.FriendlyName) [$($_.InstanceId)]"
    }) -join ', '
    throw "$Port gehoert nicht zum System16 CDC Loopback ($expectedUsbId). Gefunden: $found"
}

$serial = [System.IO.Ports.SerialPort]::new(
    $Port,
    115200,
    [System.IO.Ports.Parity]::None,
    8,
    [System.IO.Ports.StopBits]::One
)
$serial.ReadTimeout = 250
$serial.WriteTimeout = $TimeoutSeconds * 1000
$serial.DtrEnable = $true
$serial.RtsEnable = $true

$sent = [byte[]]::new($ByteCount)
[System.Security.Cryptography.RandomNumberGenerator]::Fill($sent)
$received = [byte[]]::new($ByteCount)

try {
    $serial.Open()
    $serial.DiscardInBuffer()
    $serial.DiscardOutBuffer()

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $offset = 0
    $windowSize = 512
    while ($offset -lt $sent.Length) {
        if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            throw "Timeout: $offset von $($sent.Length) Bytes gespiegelt."
        }

        $windowLength = [math]::Min($windowSize, $sent.Length - $offset)
        $serial.Write($sent, $offset, $windowLength)

        $windowReceived = 0
        while (($windowReceived -lt $windowLength) -and
               ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)) {
            try {
                $windowReceived += $serial.Read(
                    $received,
                    $offset + $windowReceived,
                    $windowLength - $windowReceived
                )
            }
            catch [System.TimeoutException] {
                # Keep polling until the overall deadline expires.
            }
        }

        if ($windowReceived -ne $windowLength) {
            throw "Timeout: $($offset + $windowReceived) von $($sent.Length) Bytes empfangen."
        }
        $offset += $windowLength
    }

    if (-not [System.Linq.Enumerable]::SequenceEqual[byte]($sent, $received)) {
        throw 'Die empfangenen Daten unterscheiden sich von den gesendeten Daten.'
    }

    $rate = [math]::Round($sent.Length / $watch.Elapsed.TotalSeconds / 1024, 1)
    Write-Host "PASS: $($sent.Length) Bytes fehlerfrei ueber $Port gespiegelt ($rate KiB/s)."
}
finally {
    if ($serial.IsOpen) {
        $serial.Close()
    }
    $serial.Dispose()
}
