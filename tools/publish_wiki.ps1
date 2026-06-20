param(
    [string]$WikiDir = ".wiki",
    [string]$Owner = "rudolfstepan",
    [string]$Repo = "6502-sbc-fpga",
    [string]$Branch = "main",
    [switch]$Push
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# This script lives in fpga/tools, so the repo root is its parent's parent.
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$wikiPath = Join-Path $repoRoot $WikiDir
$repoUrl = "https://github.com/$Owner/$Repo"
$wikiRemote = "git@github.com:$Owner/$Repo.wiki.git"
$rawBase = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch"

$imageExtensions = @(".jpg", ".jpeg", ".png", ".gif", ".svg", ".webp", ".bmp")

# Source Markdown -> wiki page name -> sidebar title.
$pages = @(
    @{ Source = "README.md"; Page = "Home"; Title = "Home" }
    @{ Source = "docs/INDEX.md"; Page = "Documentation-Index"; Title = "Documentation Index" }
    @{ Source = "docs/01_ARCHITECTURE.md"; Page = "Architecture"; Title = "Architecture" }
    @{ Source = "docs/02_MODULES.md"; Page = "Modules-Reference"; Title = "Modules Reference" }
    @{ Source = "docs/03_BUILDING.md"; Page = "Building-and-Synthesis"; Title = "Building and Synthesis" }
    @{ Source = "docs/04_TESTING.md"; Page = "Testing-Guide"; Title = "Testing Guide" }
    @{ Source = "docs/05_COMPONENTS.md"; Page = "Component-Reference"; Title = "Component Reference" }
    @{ Source = "docs/06_SIMULATION.md"; Page = "Simulation"; Title = "Simulation" }
    @{ Source = "docs/07_DEVELOPMENT.md"; Page = "Development-Guide"; Title = "Development Guide" }
    @{ Source = "docs/SOUND.md"; Page = "Sound-Chip"; Title = "Sound Chip" }
    @{ Source = "docs/UART_MONITOR.md"; Page = "UART-Monitor"; Title = "UART Monitor" }
    @{ Source = "docs/SD_BOOTLOADER_PLAN.md"; Page = "SD-Bootloader"; Title = "SD Bootloader" }
    @{ Source = "docs/FPGA_TOOLS_GUI.md"; Page = "FPGA-Tools-GUI"; Title = "FPGA Tools GUI" }
    @{ Source = "docs/HARDWARE_SUPPORT.md"; Page = "Hardware-Support"; Title = "Hardware Support" }
    @{ Source = "docs/images/README.md"; Page = "Hardware-Captures"; Title = "Hardware Captures" }
    @{ Source = "docs/roadmap.md"; Page = "Roadmap"; Title = "Roadmap" }
    @{ Source = "boards/pix16/README.md"; Page = "PIX16-Board-Guide"; Title = "PIX16 Board Guide" }
    @{ Source = "boards/tang_primer_20k/README.md"; Page = "Tang-Primer-20K-Guide"; Title = "Tang Primer 20K Guide" }
    @{ Source = "docs/FEATURE2_VIC_TEXT_DISPLAY.md"; Page = "VIC-Text-Display"; Title = "VIC Text Display" }
    @{ Source = "docs/FEATURE3_UART_COMPLETE.md"; Page = "UART-Implementation-Notes"; Title = "UART Implementation Notes" }
    @{ Source = "docs/EHBASIC_SYNTAX_ERROR_ANALYSIS.md"; Page = "EhBASIC-Syntax-Error-Analysis"; Title = "EhBASIC Syntax Error Analysis" }
    @{ Source = "docs/T65_INDIRECT_ADDRESSING_ANALYSIS.md"; Page = "T65-Indirect-Addressing-Analysis"; Title = "T65 Indirect Addressing Analysis" }
    @{ Source = "docs/T65_ROOT_CAUSE_FOUND.md"; Page = "T65-Root-Cause-Analysis"; Title = "T65 Root Cause Analysis" }
    @{ Source = "docs/TIER1_IMPLEMENTATION_PLAN.md"; Page = "Tier1-Implementation-Plan"; Title = "Tier1 Implementation Plan" }
)

function Convert-ToRepoPath {
    param([string]$Path)
    return ($Path -replace "\\", "/").TrimStart("./")
}

$pageBySource = @{}
foreach ($page in $pages) {
    $pageBySource[(Convert-ToRepoPath $page.Source).ToLowerInvariant()] = $page.Page
}

function Convert-ToRelativePath {
    param(
        [string]$BasePath,
        [string]$TargetPath
    )

    $baseUri = New-Object System.Uri((Join-Path (Resolve-Path $BasePath) ""))
    $targetUri = New-Object System.Uri($TargetPath)
    return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString())
}

function Resolve-DocLink {
    param(
        [string]$SourceFile,
        [string]$Url
    )

    if ($Url -match '^(https?:|mailto:|#)') {
        return $Url
    }

    $urlParts = $Url.Split("#", 2)
    $target = $urlParts[0]
    $anchor = ""
    if ($urlParts.Count -eq 2) {
        $anchor = "#" + $urlParts[1]
    }

    if ([string]::IsNullOrWhiteSpace($target)) {
        return $Url
    }

    $sourceDir = Split-Path (Convert-ToRepoPath $SourceFile) -Parent
    $combined = if ([string]::IsNullOrWhiteSpace($sourceDir)) { $target } else { Join-Path $sourceDir $target }
    $full = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $combined))
    $relative = Convert-ToRelativePath -BasePath $repoRoot -TargetPath $full
    $repoPath = Convert-ToRepoPath $relative
    $key = $repoPath.ToLowerInvariant()
    $encodedPath = ($repoPath -split "/" | ForEach-Object { [uri]::EscapeDataString($_) }) -join "/"

    # Images must resolve to raw URLs so they render inline in the wiki.
    if ($imageExtensions -contains [System.IO.Path]::GetExtension($repoPath).ToLowerInvariant()) {
        return "$rawBase/$encodedPath"
    }

    if ($pageBySource.ContainsKey($key)) {
        return "$repoUrl/wiki/$($pageBySource[$key])$anchor"
    }

    if (Test-Path (Join-Path $repoRoot $repoPath) -PathType Container) {
        return "$repoUrl/tree/$Branch/$encodedPath$anchor"
    }
    return "$repoUrl/blob/$Branch/$encodedPath$anchor"
}

function Convert-MarkdownForWiki {
    param(
        [string]$SourceFile,
        [string]$Markdown
    )

    $imageLinkCallback = {
        param($match)
        $image = $match.Groups["image"].Value
        $url = $match.Groups["url"].Value
        $converted = Resolve-DocLink -SourceFile $SourceFile -Url $url
        return "[$image]($converted)"
    }

    $callback = {
        param($match)
        $text = $match.Groups["text"].Value
        $url = $match.Groups["url"].Value
        $converted = Resolve-DocLink -SourceFile $SourceFile -Url $url
        return "[$text]($converted)"
    }

    $convertedMarkdown = [regex]::Replace($Markdown, '\[(?<image>!\[[^\]]+\]\([^)]+\))\]\((?<url>[^)]+)\)', $imageLinkCallback)
    return [regex]::Replace($convertedMarkdown, '\[(?<text>[^\]]+)\]\((?<url>[^)]+)\)', $callback)
}

if (-not (Test-Path $wikiPath)) {
    New-Item -ItemType Directory -Path $wikiPath | Out-Null
}

if (-not (Test-Path (Join-Path $wikiPath ".git"))) {
    Push-Location $wikiPath
    try {
        git init | Out-Host
        git remote add origin $wikiRemote
    }
    finally {
        Pop-Location
    }
}

foreach ($page in $pages) {
    $source = Convert-ToRepoPath $page.Source
    $sourcePath = Join-Path $repoRoot $source
    if (-not (Test-Path $sourcePath)) {
        throw "Missing source Markdown file: $source"
    }

    $markdown = Get-Content -Raw -Encoding UTF8 $sourcePath
    $converted = Convert-MarkdownForWiki -SourceFile $source -Markdown $markdown
    $header = "[Source file]($repoUrl/blob/$Branch/$source)"
    $body = "$header`n`n$converted"
    Set-Content -Encoding UTF8 -Path (Join-Path $wikiPath "$($page.Page).md") -Value $body
}

$sidebarGroups = [ordered]@{
    "Overview"  = @("Home", "Documentation-Index", "Roadmap")
    "Guide"     = @("Architecture", "Modules-Reference", "Building-and-Synthesis", "Testing-Guide", "Component-Reference", "Simulation", "Development-Guide")
    "Hardware"  = @("PIX16-Board-Guide", "Tang-Primer-20K-Guide", "Hardware-Support", "Hardware-Captures")
    "Subsystems" = @("Sound-Chip", "UART-Monitor", "SD-Bootloader", "FPGA-Tools-GUI")
    "Analysis & Plans" = @("VIC-Text-Display", "UART-Implementation-Notes", "EhBASIC-Syntax-Error-Analysis", "T65-Indirect-Addressing-Analysis", "T65-Root-Cause-Analysis", "Tier1-Implementation-Plan")
}

$titleByPage = @{}
foreach ($page in $pages) { $titleByPage[$page.Page] = $page.Title }

$sidebar = New-Object System.Collections.Generic.List[string]
$sidebar.Add("# 6502 SBC FPGA")
$sidebar.Add("")
foreach ($group in $sidebarGroups.Keys) {
    $sidebar.Add("## $group")
    foreach ($pageName in $sidebarGroups[$group]) {
        $title = $titleByPage[$pageName]
        $sidebar.Add("- [$title]($repoUrl/wiki/$pageName)")
    }
    $sidebar.Add("")
}
$sidebar.Add("## Project")
$sidebar.Add("- [Emulator Repository](https://github.com/rudolfstepan/6502-sbc-emulator)")
$sidebar.Add("- [Emulator Wiki](https://github.com/rudolfstepan/6502-sbc-emulator/wiki)")
Set-Content -Encoding UTF8 -Path (Join-Path $wikiPath "_Sidebar.md") -Value ($sidebar.ToArray() -join "`n")

$parentRepoUrl = "https://github.com/rudolfstepan/6502-sbc-emulator"
$footer = "Generated from [$Repo]($repoUrl) Markdown documentation. " +
    "Part of the [6502 SBC emulator]($parentRepoUrl) project " +
    "([emulator Wiki]($parentRepoUrl/wiki))."
Set-Content -Encoding UTF8 -Path (Join-Path $wikiPath "_Footer.md") -Value $footer

Push-Location $wikiPath
try {
    git add .
    if (-not (git diff --cached --quiet)) {
        git commit -m "Publish FPGA documentation wiki" | Out-Host
    }
    else {
        Write-Host "Wiki content is already up to date."
    }

    if ($Push) {
        git push -u origin master
    }
}
finally {
    Pop-Location
}
