# Take the layer back off, and leave nothing of it behind.
#
# The graft is new paths inside a folder the game owns, the companion is a file in Startup and
# a running process, and the settings change is one key in a file that was there first. Each of
# those is undone here, in the reverse order it was made, and each one says whether there was
# anything to undo - "nothing installed" is an answer, not a failure.
#
# The Script Extender is still not removed by default, even now that the installer can put it
# there: by the time anyone uninstalls this layer it may be holding up three other mods, and a
# tidy-up that takes those with it is worse than a file left behind. What did change is that the
# installer writes down whether the extender is one it fetched, so this can say which of the two
# cases the player is in - and -WithExtender takes it away when it was ours.
#
# Usage: uninstall.bat
#        uninstall.bat -WithExtender
#        powershell -File tools\uninstall.ps1

param(
    [string]$GameDir = (& (Join-Path $PSScriptRoot "find-game.ps1")),
    [string]$HostModule = "GustavX",
    [switch]$WithExtender,      # also delete the DWrite.dll the installer downloaded
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

Step "Script Extender"
$marker = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Script Extender\A11y\extender.json"
$dll    = if ($GameDir) { Join-Path $GameDir "bin\DWrite.dll" } else { $null }
if (-not (Test-Path $marker)) {
    Ok "not ours - left alone (delete bin\DWrite.dll yourself if you want it gone)"
} elseif (-not $WithExtender) {
    $rec = $null
    try { $rec = Get-Content $marker -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    Ok ("installed by this installer" + $(if ($rec.release) { ", $($rec.release)" }) + " - kept")
    Ok "other mods may be using it by now. uninstall.bat -WithExtender removes it too"
} else {
    if ($dll -and (Test-Path $dll)) {
        if (Get-Process bg3, bg3_dx11 -ErrorAction SilentlyContinue) {
            Ok "the game is running - close it and run this again to remove bin\DWrite.dll"
        } else {
            Remove-Item $dll -Force
            Ok "removed bin\DWrite.dll"
            # Put back whatever was there before the installer overwrote it, if anything was.
            $bak = "$dll.bak-a11y"
            if (Test-Path $bak) { Move-Item $bak $dll -Force ; Ok "restored the DWrite.dll that was there first" }
            Remove-Item $marker -Force
        }
    } else {
        Ok "already gone"
        Remove-Item $marker -Force
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
Write-Host "Removed. The game is untouched - nothing it shipped with was replaced."
Write-Host "The Script Extender is dealt with above, on its own line."
