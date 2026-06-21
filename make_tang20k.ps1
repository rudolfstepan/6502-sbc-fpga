<#
.SYNOPSIS
    Builds the Tang Primer 20K bitstream using GowinEDA gw_sh.

.PARAMETER Program
    After a successful build, flash the bitstream to the board via openFPGALoader.

.PARAMETER NoClean
    Skip the default clean step and allow Gowin to reuse existing build output.

.EXAMPLE
    .\make_tang20k.ps1
    .\make_tang20k.ps1 -NoClean
    .\make_tang20k.ps1 -Program
#>
param(
    [switch]$Program,
    [switch]$NoClean
)

$ErrorActionPreference = 'Stop'

$ScriptDir   = $PSScriptRoot
$BoardDir    = Join-Path $ScriptDir 'boards\tang_primer_20k'
$ProjectDir  = Join-Path $BoardDir  'project'
$Bitstream   = Join-Path $ProjectDir 'impl\pnr\tang_sbc.fs'
$DeviceCfg   = Join-Path $ProjectDir 'impl\pnr\device.cfg'
$DeviceCfgText = if (Test-Path $DeviceCfg) {
    [IO.File]::ReadAllText($DeviceCfg)
} else {
    $null
}

# Locate gw_sh — check PATH first, then common install location
$GwSh = (Get-Command gw_sh -ErrorAction SilentlyContinue)?.Source
if (-not $GwSh) {
    $GwSh = 'C:\Gowin\Gowin_V1.9.8.08\IDE\bin\gw_sh.exe'
    if (-not (Test-Path $GwSh)) {
        Write-Error "gw_sh not found on PATH and not at '$GwSh'. Add GowinEDA bin/ to PATH or install to the default location."
    }
}

if (-not $NoClean) {
    Write-Host "Cleaning Gowin build outputs ..."
    # impl/pnr/device.cfg is a versioned input, not a disposable output.  It
    # carries the dual-purpose-pin and VCC/VCCX settings needed by the DDR3
    # implementation.  Deleting all of impl made Gowin recreate a reduced file
    # without those voltage settings, after which DDR calibration could fail.
    $CleanPaths = @(
        (Join-Path $ProjectDir 'impl\gwsynthesis'),
        (Join-Path $ProjectDir 'impl\temp'),
        (Join-Path $ProjectDir 'tmp'),
        (Join-Path $ProjectDir '.cache')
    )
    foreach ($Path in $CleanPaths) {
        if (Test-Path $Path) {
            Remove-Item -LiteralPath $Path -Recurse -Force
        }
    }
    $PnrDir = Join-Path $ProjectDir 'impl\pnr'
    if (Test-Path $PnrDir) {
        Get-ChildItem -LiteralPath $PnrDir -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'device.cfg' } |
            Remove-Item -Recurse -Force
    }
    Get-ChildItem -LiteralPath $ProjectDir -Force -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -like '*.log' -or
            $_.Name -like '*.jou' -or
            $_.Name -like '*.rpt' -or
            $_.Name -like '*.html'
        } |
        Remove-Item -Force
} else {
    Write-Host "Skipping clean step (-NoClean)."
}

Write-Host "Building Tang Primer 20K bitstream ..."
Write-Host "  gw_sh : $GwSh"
Write-Host "  script: $ProjectDir\build.tcl"

Push-Location $ProjectDir
try {
    & $GwSh build.tcl
    if ($LASTEXITCODE -ne 0) {
        Write-Error "gw_sh exited with code $LASTEXITCODE"
    }
} finally {
    Pop-Location
    # gw_sh rewrites device.cfg even when it was supplied as an input. Restore
    # the versioned configuration so the next GUI or CLI build starts with the
    # intended VCC/VCCX and dual-purpose-pin settings.
    if ($null -ne $DeviceCfgText) {
        [IO.File]::WriteAllText($DeviceCfg, $DeviceCfgText)
    }
}

if (-not (Test-Path $Bitstream)) {
    Write-Error "Build succeeded but bitstream not found: $Bitstream"
}

Write-Host "Bitstream: $Bitstream"

if ($Program) {
    $Loader = (Get-Command openFPGALoader -ErrorAction SilentlyContinue)?.Source
    if ($Loader) {
        Write-Host "Programming board with openFPGALoader ..."
        & $Loader -b tang_primer_20k $Bitstream
        if ($LASTEXITCODE -ne 0) {
            Write-Error "openFPGALoader exited with code $LASTEXITCODE"
        }
        Write-Host "Done."
    } else {
        $ProgrammerCli = 'C:\Gowin\Gowin_V1.9.8.08\Programmer\bin\programmer_cli.exe'
        if (-not (Test-Path $ProgrammerCli)) {
            Write-Error "Neither openFPGALoader nor Gowin programmer_cli found. Install openFPGALoader or Gowin Programmer CLI."
        }

        Write-Host "openFPGALoader not found; falling back to Gowin programmer_cli ..."

        # Try common cable selections for Tang Primer users:
        # 1 = Gowin USB Cable(FT2CH), 0 = Gowin USB Cable(GWU2X)
        $CableIndices = @(1, 0)
        $Programmed = $false

        foreach ($CableIndex in $CableIndices) {
            Write-Host "  Trying programmer_cli with cable-index $CableIndex ..."
            & $ProgrammerCli --device GW2A-18C --run 2 --fs $Bitstream --cable-index $CableIndex
            if ($LASTEXITCODE -eq 0) {
                $Programmed = $true
                break
            }
        }

        if (-not $Programmed) {
            Write-Error "programmer_cli failed to program the board. Check USB cable/driver and board connection."
        }

        Write-Host "Done."
    }
}
