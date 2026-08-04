# Build the ZIP a player downloads.
#
# The repository is not that ZIP and should not be: it carries 180 KB of experiment log, a
# second diagnostic mod, a folder of console probes and the research that produced all of it.
# Every one of those is worth keeping and none of them is worth making someone wade through
# with a screen reader before they can hear the game.
#
# So the release is the running parts only, under a single top-level folder - a ZIP that
# unpacks into six loose files in Downloads is its own small accessibility problem.
#
# Usage: powershell -File package-release.ps1
#        powershell -File package-release.ps1 -Version 0.2.0

param(
    [string]$Version = "0.1.0",
    [string]$OutDir  = (Join-Path (Split-Path $PSScriptRoot) "dist")
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$root      = Split-Path $PSScriptRoot
$name      = "BG3Access-$Version"
$stageRoot = Join-Path $OutDir "_stage"
$stage     = Join-Path $stageRoot $name
$zip       = Join-Path $OutDir "$name.zip"

# What travels. Anything not named here stays behind, which is the point: a file added to the
# repository does not silently become part of what a stranger downloads and runs.
$FILES = @(
    "install.bat",
    "uninstall.bat",
    "status.bat",
    "PLAYING.md",
    "README.md",
    "LICENSE",
    "lua\*.lua",
    "BG3Access\Mods\BG3Access\meta.lsx",
    "BG3Access\Mods\BG3Access\ScriptExtender\Config.json",
    "BG3Access\Mods\BG3Access\ScriptExtender\Lua\BootstrapClient.lua",
    "BG3Access\Mods\BG3Access\ScriptExtender\Lua\BootstrapServer.lua",

    # The tools an install needs, and the two a bug report needs. Not push-lua, not the
    # console bridges, not the drive scripts: those talk to a game being developed against.
    "tools\find-game.ps1",
    "tools\find-controller.ps1",
    "tools\install.ps1",
    "tools\install-extender.ps1",
    "tools\uninstall.ps1",
    "tools\graft-mod.ps1",
    "tools\install-speech-service.ps1",
    "tools\speak.ps1",
    "tools\speech-log.ps1",
    "tools\mod-status.ps1",
    "tools\prism.dll"
)

if (Test-Path $stageRoot) { Remove-Item $stageRoot -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null

foreach ($pattern in $FILES) {
    $src = Join-Path $root $pattern
    $items = @(Get-Item $src -ErrorAction SilentlyContinue)
    if ($items.Count -eq 0) { Write-Error "release file missing: $pattern" }

    # The layout inside the ZIP is the repository's own, so every path printed by every
    # script - and every path in PLAYING.md - is true on the player's machine too.
    $destDir = Join-Path $stage (Split-Path $pattern)
    New-Item -ItemType Directory -Force $destDir | Out-Null
    foreach ($i in $items) { Copy-Item $i.FullName $destDir -Force }
}

if (Test-Path $zip) { Remove-Item $zip -Force }

# The entries are written one at a time, and the reason is the separator inside their names.
#
# The ZIP format says forward slash. On .NET Framework - which is what PS 5.1 runs on - both
# Compress-Archive and ZipFile.CreateFromDirectory use the platform separator instead, so every
# entry comes out as "BG3Access-0.1.0\tools\install.ps1". Windows Explorer opens that happily,
# which is how it survives being noticed; unzip warns and stops, and an archiver that refuses
# the download is a wall in front of exactly the person this release is for.
# Two assemblies, not one: ZipArchive and ZipArchiveMode live in System.IO.Compression, while
# ZipFile and the CreateEntryFromFile extension live in the FileSystem half.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$level = [System.IO.Compression.CompressionLevel]::Optimal
$staged = @(Get-ChildItem $stage -Recurse -File)
$archive = [System.IO.Compression.ZipFile]::Open($zip, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($f in $staged) {
        $entry = $f.FullName.Substring($stageRoot.Length + 1).Replace("\", "/")
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive, $f.FullName, $entry, $level)
    }
} finally { $archive.Dispose() }

$files = $staged.Count
Remove-Item $stageRoot -Recurse -Force
$size  = [math]::Round((Get-Item $zip).Length / 1KB, 1)
Write-Host "$zip  ($files files, $size KB)"
Write-Host ""
Write-Host "Publish it with:"
Write-Host "    gh release create v$Version `"$zip`" --title `"BG3Access $Version`" --notes-file <notes.md>"
