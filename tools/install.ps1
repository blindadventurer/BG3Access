# Install the accessibility layer, in one command, on a machine that is not the one it was
# written on.
#
# Everything this does was already possible - graft-mod.ps1 and install-speech-service.ps1 do
# the work - but only if you knew both existed, knew they had to run in that order, and knew
# that neither would tell you the game was never found because the path was a guess baked in
# at the top of the file. That is three things to know before the first line of speech, and
# for a blind player trying the layer for the first time it is three ways to end up with
# silence and no idea which one happened.
#
# So this script takes it end to end and, more importantly, says out loud what it found and
# what it did: the console is not a reliable place to read from when the thing being installed
# is the reason you would be able to read it.
#
# Usage: install.bat                                 from the folder this was unpacked into
#        powershell -File tools\install.ps1          the same, if scripts are allowed to run
#        powershell -File tools\install.ps1 -GameDir "D:\Games\Baldurs Gate 3"
#        powershell -File tools\install.ps1 -Yes     ask nothing; assume yes
#        powershell -File tools\install.ps1 -NoSpeech -NoShortcut -NoExtender

param(
    [string]$GameDir = (& (Join-Path $PSScriptRoot "find-game.ps1")),
    [string]$HostModule = "GustavX",
    [switch]$NoSpeech,          # do not put the speech companion in Startup
    [switch]$NoShortcut,        # do not put a launcher-skipping shortcut on the Desktop
    [switch]$NoExtender,        # do not offer to download the Script Extender - only check
    [switch]$Yes,               # answer yes to everything this would otherwise ask
    [switch]$Silent             # print only; do not speak the result
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$root  = Split-Path $PSScriptRoot
$speak = Join-Path $PSScriptRoot "speak.ps1"

# What the run has to say at the end, collected as it goes. A blind player hears one summary,
# not twenty lines of progress, so the interesting parts are kept and the rest is only printed.
$problems = @()
$notes    = @()

function Step($text) { Write-Host "" ; Write-Host "== $text" }
function Ok($text)   { Write-Host "   $text" }
function Bad($text)  { Write-Host "   ! $text" ; $script:problems += $text }

# Speech goes through the same prism.dll the layer itself uses, which makes this the one honest
# test of the speech path: if the install cannot say "done", neither will the game.
#
# So the output is read rather than thrown away. speak.ps1 prints the backend it picked, and
# that name is the answer to the question a player cannot check for themselves - was the screen
# reader found, or is this about to be said by SAPI into a room where nobody is listening for
# it. An install that reports success while speech is silently broken is the worst outcome
# available here, and it was the first thing this script did wrong.
$backend = $null
$speechBroken = $false      # only once it has been *shown* to be, never merely unproven

function Say($text) {
    if ($Silent -or $speechBroken) { return }
    try { & $speak -Text $text *> $null } catch { }
}

Write-Host "BG3Access - installing the accessibility layer"
Write-Host "".PadRight(60, "-")

# --- 1. the game ---------------------------------------------------------------------------

Step "Baldur's Gate 3"
if ([string]::IsNullOrWhiteSpace($GameDir) -or -not (Test-Path $GameDir)) {
    Write-Host "   ! not found automatically."
    Write-Host ""
    Write-Host "   Run the install again and say where it is:"
    Write-Host '       powershell -File tools\install.ps1 -GameDir "D:\Games\Baldurs Gate 3"'
    Write-Host "   That is the folder containing bin\bg3.exe."
    Say "Baldur's Gate 3 was not found. Nothing was installed."
    exit 1
}
Ok $GameDir

# --- 2. the Script Extender ------------------------------------------------------------------
#
# Without it the game starts perfectly and runs no mod code at all, which sounds exactly like
# the layer being broken - so it is the one prerequisite that has to be dealt with rather than
# reported. It used to be only reported, and install-extender.ps1 carries the argument for why
# that was the wrong call for the people this is for. What is kept from it: the download is
# still asked for, still named out loud, and -NoExtender still gets the old behaviour.

Step "Script Extender"
$dwrite = Join-Path $GameDir "bin\DWrite.dll"
if (Test-Path $dwrite) {
    Ok ("bin\DWrite.dll, {0:yyyy-MM-dd}" -f (Get-Item $dwrite).LastWriteTime)
} elseif ($NoExtender) {
    Bad "the Script Extender is not installed - no mod code runs without it"
    Write-Host "     Get it from https://github.com/Norbyte/bg3se/releases"
    Write-Host "     (its zip holds one DWrite.dll, and that goes into $GameDir\bin)"
} else {
    # -Silent is passed through as itself and not quietly widened into -Yes. "Do not speak" is
    # a request about the voice; turning it into "download a binary without asking" would be
    # this script answering a question on the player's behalf that was put to them.
    $pass = @{}
    if ($Yes)    { $pass.Yes = $true }
    if ($Silent) { $pass.Silent = $true }
    try {
        & (Join-Path $PSScriptRoot "install-extender.ps1") -GameDir $GameDir @pass
        $code = $LASTEXITCODE
    } catch {
        Bad "the Script Extender install failed: $_"
        $code = 2
    }
    if ($code -ne 0) {
        Bad "the Script Extender is not installed - no mod code runs without it"
        Write-Host "     Everything else below was still done. Install it and run install.bat again."
    }
}

# --- 3. the Script Extender's own settings ----------------------------------------------------
#
# DeveloperMode is the one setting the layer has only ever been run with. It costs a player
# nothing, it is not a cheat and it changes nothing in the game itself - but leaving it off on
# some machines and on on others puts a variable into every bug report that nobody can see. So
# it is asserted, the old file is kept, and nothing else in there is touched: CreateConsole in
# particular belongs to whoever set it, and a console window that steals focus from the game is
# not something to switch on for someone who cannot see it appear.

Step "Script Extender settings"
$seSettings = Join-Path $GameDir "bin\ScriptExtenderSettings.json"

# Set-Content -Encoding UTF8 writes a byte order mark on PS 5.1, and this file is read by a
# C++ JSON parser that was never given a reason to expect one. The game writes it without a
# BOM; so does this. (build-mod.ps1 learned the same lesson on modsettings.lsx.)
function Write-Json($path, $text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}
if (Test-Path $seSettings) {
    try {
        $cfg = Get-Content $seSettings -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.DeveloperMode -eq $true) {
            Ok "DeveloperMode already on"
        } else {
            Copy-Item $seSettings "$seSettings.bak-a11y" -Force
            if ($cfg.PSObject.Properties.Name -contains "DeveloperMode") {
                $cfg.DeveloperMode = $true
            } else {
                $cfg | Add-Member -NotePropertyName DeveloperMode -NotePropertyValue $true
            }
            Write-Json $seSettings ($cfg | ConvertTo-Json -Depth 10)
            Ok "DeveloperMode turned on (old file kept as ScriptExtenderSettings.json.bak-a11y)"
        }
    } catch {
        Bad "could not read $seSettings - leave it alone and check it by hand"
    }
} else {
    Write-Json $seSettings "{`r`n    `"DeveloperMode`": true,`r`n    `"CreateConsole`": false`r`n}`r`n"
    Ok "written: bin\ScriptExtenderSettings.json"
}

# --- 4. the layer itself -----------------------------------------------------------------------

Step "The layer"

# Nothing here is tied to where the game lives - the graft is Data\Mods\<host>\ScriptExtender
# inside whatever folder was found, and everything the layer reads or writes at runtime it asks
# the Script Extender for by relative name. What it *is* tied to is the host module existing in
# the load order, and that is worth proving rather than assuming: GustavX is the Patch 8
# campaign module, so its absence means a game this was never tested against, and a graft onto
# a module the game does not load is silence with nothing anywhere to explain it.
$hostPak = Join-Path $GameDir "Data\$HostModule.pak"
if (-not (Test-Path $hostPak)) {
    Bad "no Data\$HostModule.pak - this is not the game version the layer was built for"
}

try {
    & (Join-Path $PSScriptRoot "graft-mod.ps1") -GameDir $GameDir -HostModule $HostModule -Quiet
} catch {
    Bad "the install failed: $_"
    Say "The install failed. Nothing is running."
    exit 1
}

# --- 5. the half that cannot live inside the game ------------------------------------------------

if ($NoSpeech) {
    Step "Speech companion"
    Ok "skipped (-NoSpeech) - start it by hand with tools\speak.ps1 -Watch"
    $notes += "the speech companion was not installed"
} else {
    Step "Speech companion"
    try {
        & (Join-Path $PSScriptRoot "install-speech-service.ps1")
    } catch {
        Bad "the speech companion did not install: $_"
    }

    # And does it actually reach a screen reader. speak.ps1 prints the backend it picked, which
    # is the one fact nobody can check for themselves from inside the game: NVDA and JAWS mean
    # the install is done, SAPI means the screen reader was not running when this was asked and
    # everything will be said by the system voice instead.
    Step "Speech"
    try {
        # *>&1, not 2>&1: speak.ps1 reports through Write-Host, which since PS 5 goes to the
        # information stream and not to stdout - merging only stderr captured an empty string
        # and turned a working install into a reported failure.
        $out = & $speak -Text "BG3 access installed." *>&1 | Out-String
        $m = [regex]::Match($out, "backend:\s*(.+)")
        if ($m.Success) {
            $backend = $m.Groups[1].Value.Trim()
            Ok "speaking through $backend"
            if ($backend -match "sapi") {
                $notes += "SAPI, not a screen reader - start NVDA or JAWS before the game"
            }
        } else {
            $speechBroken = $true
            Bad ("nothing to speak with: " + ($out -replace "\r?\n", " ").Trim())
        }
    } catch {
        $speechBroken = $true
        Bad "the speech test failed: $_"
    }
}

# --- 6. a way into the game that does not go through the launcher -----------------------------
#
# Larian's launcher is a CEF window with no accessibility tree at all - it is the first barrier
# of the evening and it is not one this mod can do anything about from the inside. The game
# executable takes no launcher with it, so a shortcut straight to it removes the barrier
# entirely. Steam still has to be running; it is the store's DRM that wants that, not the game.

if (-not $NoShortcut) {
    Step "Desktop shortcut"
    $exe = Join-Path $GameDir "bin\bg3_dx11.exe"
    if (-not (Test-Path $exe)) { $exe = Join-Path $GameDir "bin\bg3.exe" }
    if (Test-Path $exe) {
        try {
            $lnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "Baldurs Gate 3 (no launcher).lnk"
            $sh = New-Object -ComObject WScript.Shell
            $s = $sh.CreateShortcut($lnk)
            $s.TargetPath = $exe
            $s.WorkingDirectory = Split-Path $exe
            $s.Description = "Starts BG3 directly, skipping the launcher (Steam must be running)"
            $s.Save()
            Ok "Baldurs Gate 3 (no launcher).lnk"
        } catch {
            Bad "could not create the shortcut: $_"
        }
    } else {
        Bad "no game executable in $GameDir\bin"
    }
}

# --- 7. what actually happened ---------------------------------------------------------------

Write-Host ""
Write-Host "".PadRight(60, "-")

if ($problems.Count -eq 0) {
    Write-Host "Installed."
    Write-Host ""
    Write-Host "Next:"
    Write-Host "  1. Plug in a game controller. The layer reads the game's controller"
    Write-Host "     interface, and without a pad there is nothing for it to read."
    # ASCII only in this file: PS 5.1 reads a .ps1 with no BOM as ANSI, and the line the layer
    # actually speaks here is Russian - written out, it would print as mojibake.
    Write-Host "  2. Start the game. The layer says one short line out loud when it comes up."
    Write-Host "  3. If it stays silent, run status.bat and send what it prints."
    Write-Host ""
    Write-Host "The keys are in PLAYING.md."
    Say "BG3 access installed. Plug in a controller and start the game."
} else {
    Write-Host "Installed, but not ready:"
    foreach ($p in $problems) { Write-Host "  - $p" }
    Write-Host ""
    Write-Host "Fix those and run install.bat again. status.bat re-checks at any time."
    Say ("BG3 access installed, but " + $problems.Count + " problem" +
         $(if ($problems.Count -eq 1) { "" } else { "s" }) + " need attention. See the window.")
}
foreach ($n in $notes) { Write-Host "Note: $n" }

# Said in an exit code as well as in words, because one caller cannot read the words: the
# window inside BG3Access-Setup.exe closes itself when this succeeds and waits when it does
# not, and "did it work" has to be answerable without parsing what was printed.
if ($problems.Count) { exit 1 }
