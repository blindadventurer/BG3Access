# Take the layer back off, and leave nothing of it behind.
#
# The graft is new paths inside a folder the game owns, the companion is a file in Startup and
# a running process, and the settings change is one key in a file that was there first. Each of
# those is undone here, in the reverse order it was made, and each one says whether there was
# anything to undo - "nothing installed" is an answer, not a failure.
#
# The Script Extender is deliberately not removed: the player may well have it for other mods,
# and it is not this script's to take away. PLAYING.md says how, in one line, for anyone who
# wants the game back exactly as it shipped.
#
# Usage: uninstall.bat
#        powershell -File tools\uninstall.ps1

param(
    [string]$GameDir = (& (Join-Path $PSScriptRoot "find-game.ps1")),
    [string]$HostModule = "GustavX",
    [switch]$Silent
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$speak = Join-Path $PSScriptRoot "speak.ps1"

function Step($text) { Write-Host "" ; Write-Host "== $text" }
function Ok($text)   { Write-Host "   $text" }

# Said before the companion is stopped, because after that there is nothing left to say it.
if (-not $Silent) {
    try { & $speak -Text "Removing the BG3 accessibility layer." *> $null } catch { }
}

Write-Host "BG3Access - removing the accessibility layer"
Write-Host "".PadRight(60, "-")

Step "The layer"
if ([string]::IsNullOrWhiteSpace($GameDir) -or -not (Test-Path $GameDir)) {
    Write-Host "   ! game not found - pass -GameDir to remove the grafted files"
} else {
    & (Join-Path $PSScriptRoot "graft-mod.ps1") -GameDir $GameDir -HostModule $HostModule -Uninstall

    $seSettings = Join-Path $GameDir "bin\ScriptExtenderSettings.json"
    $backup = "$seSettings.bak-a11y"
    if (Test-Path $backup) {
        Move-Item $backup $seSettings -Force
        Ok "restored bin\ScriptExtenderSettings.json"
    }
}

Step "Speech companion"
& (Join-Path $PSScriptRoot "install-speech-service.ps1") -Uninstall

Step "Desktop shortcut"
$lnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "Baldurs Gate 3 (no launcher).lnk"
if (Test-Path $lnk) { Remove-Item $lnk -Force ; Ok "removed" } else { Ok "none" }

# By name, never the whole folder.
#
# <Script Extender>\A11y is shared ground: the layer writes its bridge and its boot report
# there, but so does every probe anyone has ever run against the game, and on a development
# machine that is hundreds of files worth of measurements. A -Recurse on the folder would take
# all of it, and explored.json with it - the record of where the player has already been, which
# is theirs, not the installer's, and which a reinstall picks straight back up.
Step "Saved state"
$a11y = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Script Extender\A11y"
$gone = 0
foreach ($f in @("speech.txt", "boot.json", "speech-log.txt", "speech-companion.log")) {
    $p = Join-Path $a11y $f
    if (Test-Path $p) { Remove-Item $p -Force ; $gone++ }
}
Ok $(if ($gone) { "removed $gone file(s) from $a11y" } else { "nothing to remove" })
if (Test-Path (Join-Path $a11y "explored.json")) {
    Ok "kept explored.json - where you have been is yours, and a reinstall reads it again"
}

Write-Host ""
Write-Host "".PadRight(60, "-")
Write-Host "Removed. The game is untouched - the Script Extender is still installed;"
Write-Host "delete bin\DWrite.dll if you want that gone too."
