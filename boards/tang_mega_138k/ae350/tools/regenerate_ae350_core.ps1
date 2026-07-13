[CmdletBinding()]
param(
    [string]$GowinRoot = 'C:\Gowin\Gowin_V1.9.12.03_x64'
)

$ErrorActionPreference = 'Stop'

$synthesisExe = Join-Path $GowinRoot 'IDE\bin\GowinSynthesis.exe'
$ipData = Join-Path $GowinRoot 'IDE\ipcore\RiscV_AE350_SOC\data'
$coreDir = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\project\src\riscv_ae350_soc')
)
$configDir = Join-Path $coreDir 'config'
$tempDir = Join-Path $coreDir 'temp\manual_138c'

if (-not (Test-Path -LiteralPath $synthesisExe -PathType Leaf)) {
    throw "GowinSynthesis.exe nicht gefunden: $synthesisExe"
}
if (-not (Test-Path -LiteralPath (Join-Path $ipData 'riscv_ae350_top.v') -PathType Leaf)) {
    throw "RiscV_AE350_SOC v1.2 ist unter $ipData nicht installiert."
}

New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $configDir 'riscv_ae350_config.v') -Destination $tempDir -Force
Copy-Item -LiteralPath (Join-Path $configDir 'gw_itcm_config.v') -Destination $tempDir -Force
Copy-Item -LiteralPath (Join-Path $configDir 'gw_dtcm_config.v') -Destination $tempDir -Force

function XmlPath([string]$Path) {
    return ([System.IO.Path]::GetFullPath($Path) -replace '\\', '/')
}

$data = XmlPath $ipData
$tmp = XmlPath $tempDir
$sources = @(
    'riscv_ae350_top.v',
    'riscv_ae350_soc.v',
    'riscv_ae350_ddr3.v',
    'riscv_ae350_flash.v',
    'ddr3_1_4code_hs.v',
    'DDR3_TOP.v',
    'fifo_top_32to128.v',
    'fifo_top_128to32.v',
    'gw_dtcm.v',
    'gw_itcm.v'
)
$fileList = ($sources | ForEach-Object {
    '        <File path="{0}/{1}" type="verilog"/>' -f $data, $_
}) -join [Environment]::NewLine

$projectXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE gowin-synthesis-project>
<Project>
    <Version>beta</Version>
    <Device id="GW5AST-138C" package="PBGA484A" speed="1" partNumber="GW5AST-LV138PG484AC1/I0"/>
    <FileList>
$fileList
    </FileList>
    <OptionList>
        <Option type="disable_insert_pad" value="1"/>
        <Option type="enable_dsrm" value="0"/>
        <Option type="include_path" value="$data/ddr3_default_settings"/>
        <Option type="include_path" value="$data"/>
        <Option type="include_path" value="$tmp"/>
        <Option type="output_file" value="riscv_ae350_soc.vg"/>
        <Option type="output_template" value="riscv_ae350_soc_tmp.v"/>
        <Option type="ram_balance" value="1"/>
        <Option type="ram_rw_check" value="1"/>
        <Option type="top_module" value="RiscV_AE350_SOC_Top"/>
        <Option type="vcc" value="0.9"/>
        <Option type="vccx" value="1.8"/>
        <Option type="verilog_language" value="sysv-2017"/>
    </OptionList>
</Project>
"@

$projectFile = Join-Path $tempDir 'riscv_ae350_soc.prj'
$projectXml | Set-Content -LiteralPath $projectFile -Encoding utf8

Push-Location $tempDir
try {
    & $synthesisExe -prj $projectFile
    if ($LASTEXITCODE -ne 0) {
        throw "AE350-IP-Synthese fehlgeschlagen (Exitcode $LASTEXITCODE)."
    }
} finally {
    Pop-Location
}

$generated = Join-Path $tempDir 'riscv_ae350_soc.vg'
$destination = Join-Path $coreDir 'riscv_ae350_soc.v'
Copy-Item -LiteralPath $generated -Destination $destination -Force
Write-Host "AE350-Netzliste fuer GW5AST-138C erzeugt: $destination"

