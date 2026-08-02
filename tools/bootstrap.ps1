# The whole install as one line, for someone who has never installed a mod.
#
# The ZIP is not a hard way to install software, but it is four steps - find the releases page,
# work out which file, unpack it somewhere, find install.bat inside what you unpacked - and each
# one is a place to stop. Three of the four are Explorer, which is where "unpack it somewhere"
# turns into a folder inside a folder inside Downloads with the .bat two levels down. For a
# player using a screen reader that is the longest part of the entire install, and none of it
# is this mod.
#
# So: one line, pasted into the Run box or a PowerShell window, and everything after it is
# automatic except the questions install.ps1 asks out loud.
#
#     powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/blindadventurer/BG3Access/main/tools/bootstrap.ps1 | iex"
#
# It is worth being clear-eyed about what that line is: it runs a script from the internet
# sight unseen, which is the thing everyone is rightly told not to do. It is here because the
# alternative for these players is not "install it more carefully", it is "do not install it" -
# and because the URL is at least legible: a raw file, over HTTPS, in the repository whose
# releases page the ZIP would have come from anyway. Anyone who would rather read it first can:
# it is this file, and the ZIP install in PLAYING.md stays supported and always will.
#
# If the game lives somewhere find-game.ps1 will not look, set BG3_DIR first:
#     $env:BG3_DIR = "D:\Games\Baldurs Gate 3"

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$REPO = "blindadventurer/BG3Access"
$UA   = @{ "User-Agent" = "BG3Access-bootstrap" }

# Not %LOCALAPPDATA%\BG3Access: the speech companion owns that folder and its uninstall deletes
# it whole, which would mean an uninstall halfway through deleting the uninstaller running it.
# Programs\ is where per-user installs go on Windows and nothing else here touches it.
$home_ = Join-Path $env:LOCALAPPDATA "Programs\BG3Access"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = "SilentlyContinue"

Write-Host "BG3Access - downloading the accessibility layer"
Write-Host "".PadRight(60, "-")

try {
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$REPO/releases/latest" -Headers $UA -UseBasicParsing
} catch {
    Write-Host "   ! could not reach github.com: $_"
    Write-Host "     Download the ZIP by hand instead: https://github.com/$REPO/releases"
    exit 2
}

$asset = @($rel.assets | Where-Object { $_.name -like "*.zip" })[0]
if (-not $asset) {
    Write-Host "   ! release $($rel.tag_name) has no ZIP in it"
    Write-Host "     https://github.com/$REPO/releases"
    exit 2
}

Write-Host "   $($rel.tag_name): $($asset.name), $([math]::Round($asset.size / 1KB)) KB"

$tmp = Join-Path $env:TEMP ("BG3Access-dl-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $tmp | Out-Null
$zip = Join-Path $tmp $asset.name
try {
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -Headers $UA -UseBasicParsing
} catch {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "   ! the download failed: $_"
    exit 2
}

# Emptied first, not merged into. A file that was in 0.1.0 and dropped from 0.2.0 would
# otherwise still be sitting there being run by whatever still names it.
if (Test-Path $home_) { Remove-Item $home_ -Recurse -Force }
New-Item -ItemType Directory -Force $home_ | Out-Null

# Extracted entry by entry, and every destination checked to be inside the folder we made -
# a zip is a list of paths written by somebody else, and "..\..\Startup\anything.vbs" is a
# valid one. This archive is our own, which is exactly why the check is cheap to keep honest.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
try {
    $root = [System.IO.Path]::GetFullPath($home_)
    foreach ($e in $archive.Entries) {
        if (-not $e.Name) { continue }                          # a directory entry
        $to = [System.IO.Path]::GetFullPath((Join-Path $home_ $e.FullName))
        if (-not $to.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            throw "the archive wants to write outside $home_ : $($e.FullName)"
        }
        New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $to, $true)
    }
} finally {
    $archive.Dispose()
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# The ZIP holds one top-level folder (BG3Access-0.1.0), so the installer is one level down -
# found rather than spelled out, because the version is in the name.
$installer = @(Get-ChildItem $home_ -Recurse -Filter "install.ps1" -File)[0]
if (-not $installer) {
    Write-Host "   ! no install.ps1 in $($asset.name) - this is not a release this script understands"
    exit 2
}
$unpacked = Split-Path (Split-Path $installer.FullName)

Write-Host "   unpacked into $unpacked"
Write-Host ""
Write-Host "   Keep that folder: status.bat and uninstall.bat live in it and there is"
Write-Host "   no other copy of them."
Write-Host ""

# A new process rather than & : this script may well be running inside a PowerShell window whose
# execution policy is Restricted, where dot-calling a .ps1 that was just downloaded fails on the
# policy rather than on anything wrong with it. Same console, so what it prints is read and what
# it asks can be answered.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer.FullName
exit $LASTEXITCODE
