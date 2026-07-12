[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$boardName = 'tang_console138k'
$amigaRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repoRoot = (Resolve-Path (Join-Path $amigaRoot '..\..\..')).Path
$nanoMigRoot = Join-Path $repoRoot 'third_party\NanoMig'
$nanoMigSrc = Join-Path $nanoMigRoot 'src'
$nanoMigPatch = Join-Path $amigaRoot 'patches\nanomig-tc138k.patch'
$expectedNanoMigCommit = 'b89a06657135af50538d7bbbe3c8b73c3a9d606e'
$sourceXml = Join-Path $nanoMigSrc 'misc\amiga.xml'
$sourceProject = Join-Path $nanoMigSrc 'nanomig_tc138k.gprj'
$sourceProcessConfig = Join-Path $nanoMigSrc 'impl\nanomig_tc138k_process_config.json'
$kickstartModule = Join-Path $amigaRoot 'rtl\kickstart_bram.sv'
$sdramVerifierModule = Join-Path $amigaRoot 'rtl\sdram_boot_verify.sv'
$bootReportModule = Join-Path $amigaRoot 'rtl\amiga_boot_report.sv'
$kickstartRom = 'E:\Emulatoren\Amiga\ROMS\Kickstart v1.3 rev 34.5 (1987)(Commodore)(A500-A1000-A2000-CDTV)[!].rom'
$projectDir = Join-Path $amigaRoot 'project'
$processDir = Join-Path $projectDir 'impl'
$generatedMenu = Join-Path $projectDir 'amiga_xml.hex'
$generatedKickstart = Join-Path $projectDir 'kickstart13_words.hex'
$generatedProject = Join-Path $projectDir 'nanomig_tc138k.gprj'
$generatedProcessConfig = Join-Path $processDir 'nanomig_tc138k_process_config.json'

if (-not (Test-Path -LiteralPath (Join-Path $nanoMigRoot '.git'))) {
    throw "NanoMig submodule is not initialized. Run 'git submodule update --init third_party/NanoMig'."
}
if (-not (Test-Path -LiteralPath $nanoMigPatch -PathType Leaf)) {
    throw "NanoMig board patch not found: '$nanoMigPatch'."
}

$nanoMigCommit = (& git -C $nanoMigRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $nanoMigCommit -ne $expectedNanoMigCommit) {
    throw "Expected NanoMig commit $expectedNanoMigCommit, got '$nanoMigCommit'."
}

# Keep third_party/NanoMig pinned to a public upstream commit. The local board
# adaptation is carried as a parent-repository patch and applied idempotently.
& git -C $nanoMigRoot apply --reverse --check $nanoMigPatch 2>$null
if ($LASTEXITCODE -ne 0) {
    & git -C $nanoMigRoot apply --check $nanoMigPatch
    if ($LASTEXITCODE -ne 0) {
        throw 'NanoMig sources contain changes that conflict with the Tang Console 138K patch.'
    }
    & git -C $nanoMigRoot apply $nanoMigPatch
    if ($LASTEXITCODE -ne 0) {
        throw 'Applying the Tang Console 138K NanoMig patch failed.'
    }
    Write-Host 'Applied NanoMig Tang Console 138K board patch.' -ForegroundColor Green
}

foreach ($requiredFile in @($sourceXml, $sourceProject, $sourceProcessConfig, $kickstartModule, $sdramVerifierModule, $bootReportModule, $kickstartRom)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required NanoMig file not found: '$requiredFile'."
    }
}

function Write-TextIfChanged {
    param(
        [string]$Path,
        [string]$Content
    )

    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and
        ([System.IO.File]::ReadAllText($Path) -ceq $Content)) {
        return $false
    }

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
    return $true
}

New-Item -ItemType Directory -Force -Path $projectDir, $processDir | Out-Null

# Convert the validated 256 KiB Kickstart image into 16-bit big-endian words
# for block-ROM inference. The top mirrors this image to fill its 512 KiB ROM
# window, so only 2 Mbit of BSRAM are required.
$expectedKickstartSha256 = 'EE05862D8102A08436AC4056DA7D549DB31625C7D47B24DFB7B3C9A5C113CA53'
$kickstartBytes = [System.IO.File]::ReadAllBytes($kickstartRom)
if ($kickstartBytes.Length -ne 256KB) {
    throw "Expected a 256 KiB Kickstart ROM, got $($kickstartBytes.Length) bytes."
}
$kickstartSha256 = (Get-FileHash -LiteralPath $kickstartRom -Algorithm SHA256).Hash.ToUpperInvariant()
if ($kickstartSha256 -ne $expectedKickstartSha256) {
    throw "Unexpected Kickstart SHA-256: $kickstartSha256"
}

$kickstartHexBuilder = [System.Text.StringBuilder]::new(655360)
for ($index = 0; $index -lt $kickstartBytes.Length; $index += 2) {
    $word = ([int]$kickstartBytes[$index] -shl 8) -bor [int]$kickstartBytes[$index + 1]
    [void]$kickstartHexBuilder.AppendFormat("{0:x4}`n", $word)
}
$kickstartChanged = Write-TextIfChanged -Path $generatedKickstart -Content $kickstartHexBuilder.ToString()

# Filter the board markers used by NanoMig's Tcl menu generator.
$sourceText = [System.IO.File]::ReadAllText($sourceXml)
$outputLines = [System.Collections.Generic.List[string]]::new()
$activeStack = [System.Collections.Generic.Stack[bool]]::new()
$active = $true

foreach ($line in [System.Text.RegularExpressions.Regex]::Split($sourceText, '\r\n|\n|\r')) {
    if ($line -match '<!--\s*(IS|NOT)\s+(.+?)\s*-->') {
        $mode = $Matches[1]
        $boards = $Matches[2] -split '\s+'
        $matchesBoard = $boards -contains $boardName
        $activeStack.Push($active)
        $active = $active -and $(if ($mode -eq 'IS') { $matchesBoard } else { -not $matchesBoard })
        continue
    }

    if ($line -match '<!--\s*END\s*-->') {
        if ($activeStack.Count -eq 0) {
            throw 'Unexpected END marker in NanoMig menu XML.'
        }
        $active = $activeStack.Pop()
        continue
    }

    if (-not $active) {
        continue
    }

    $cleanLine = [System.Text.RegularExpressions.Regex]::Replace($line, '<!--.*?-->', '').Trim()
    if ($cleanLine.Length -ne 0) {
        $outputLines.Add($cleanLine)
    }
}

if ($activeStack.Count -ne 0) {
    throw 'Unclosed board marker in NanoMig menu XML.'
}

$menuXml = ($outputLines -join "`n") + "`n"
try {
    [void][xml]$menuXml
} catch {
    throw "Generated NanoMig menu is not valid XML: $($_.Exception.Message)"
}

$menuBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($menuXml)
$compressedStream = [System.IO.MemoryStream]::new()
$gzipStream = [System.IO.Compression.GZipStream]::new(
    $compressedStream,
    [System.IO.Compression.CompressionLevel]::Optimal,
    $true
)
$gzipStream.Write($menuBytes, 0, $menuBytes.Length)
$gzipStream.Dispose()
$compressedBytes = $compressedStream.ToArray()
$compressedStream.Dispose()

if ($compressedBytes.Length -gt 1536) {
    throw "Compressed NanoMig menu is too large: $($compressedBytes.Length) bytes."
}

$menuHex = (($compressedBytes | ForEach-Object { '{0:x2}' -f $_ }) -join "`n") + "`n"
$menuChanged = Write-TextIfChanged -Path $generatedMenu -Content $menuHex

# Keep implementation output local while all stable HDL remains in third_party.
$projectText = [System.IO.File]::ReadAllText($sourceProject)
$projectText = $projectText -replace '<\?xml version="1"', '<?xml version="1.0"'
$projectText = [System.Text.RegularExpressions.Regex]::Replace(
    $projectText,
    '(?m)^\s*<File path="tg68k/[^"]+"[^>]+/>\r?\n',
    ''
)
$projectText = [System.Text.RegularExpressions.Regex]::Replace(
    $projectText,
    '(?m)^\s*<File path="misc/flash_dspi\.v"[^>]+/>\r?\n',
    ''
)
$sourcePrefix = '../../../../third_party/NanoMig/src/'
$projectText = [System.Text.RegularExpressions.Regex]::Replace(
    $projectText,
    '<File path="([^"]+)"',
    { param($match) '<File path="' + $sourcePrefix + $match.Groups[1].Value + '"' }
)

if ($projectText -notmatch 'amiga_xml\.hex') {
    $menuEntry = '        <File path="amiga_xml.hex" type="file.other" enable="1"/>'
    $projectText = $projectText -replace '(\s*</FileList>)', "`r`n$menuEntry`$1"
}

if ($projectText -notmatch 'kickstart_bram\.sv') {
    $kickstartEntries = @(
        '        <File path="../rtl/kickstart_bram.sv" type="file.verilog" enable="1"/>'
        '        <File path="kickstart13_words.hex" type="file.other" enable="1"/>'
    ) -join "`r`n"
    $projectText = $projectText -replace '(\s*</FileList>)', "`r`n$kickstartEntries`$1"
}

if ($projectText -notmatch 'sdram_boot_verify\.sv') {
    $verifyEntry = '        <File path="../rtl/sdram_boot_verify.sv" type="file.verilog" enable="1"/>'
    $projectText = $projectText -replace '(\s*</FileList>)', "`r`n$verifyEntry`$1"
}

if ($projectText -notmatch 'amiga_boot_report\.sv') {
    $reportEntry = '        <File path="../rtl/amiga_boot_report.sv" type="file.verilog" enable="1"/>'
    $projectText = $projectText -replace '(\s*</FileList>)', "`r`n$reportEntry`$1"
}

$projectChanged = Write-TextIfChanged -Path $generatedProject -Content $projectText

# Preserve NanoMig's tested Gowin settings. The menu is already generated here,
# so the upstream pre-build Tcl hook must not run from the relocated project.
$processText = [System.IO.File]::ReadAllText($sourceProcessConfig)
$processText = [System.Text.RegularExpressions.Regex]::Replace(
    $processText,
    '"TclPre"\s*:\s*"[^"]*"',
    '"TclPre" : ""'
)
$processChanged = Write-TextIfChanged -Path $generatedProcessConfig -Content $processText

Write-Host 'NanoMig Tang Console 138K project prepared:' -ForegroundColor Green
Write-Host "  Menu:    $generatedMenu ($($compressedBytes.Length) compressed bytes)"
Write-Host "  KickROM: $generatedKickstart (embedded, SHA-256 $kickstartSha256)"
Write-Host "  Project: $generatedProject"
Write-Host "  Config:  $generatedProcessConfig"
if (-not $menuChanged -and -not $kickstartChanged -and -not $projectChanged -and -not $processChanged) {
    Write-Host '  No generated file changed; existing build state remains reusable.'
}
