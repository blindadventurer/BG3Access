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

# Can this account change the game folder at all?
#
# On Steam's default library - under Program Files - an ordinary user cannot, and that is where
# most people's copy is. This used to end the install: everything written back then went into
# the game folder, so no write access meant nothing could be done at all.
#
# That is no longer true. The layer installs as a mod, into %LOCALAPPDATA%, where a user always
# has write access. What still needs the game folder is the Script Extender (bin\DWrite.dll and
# its settings file) - so a player whose extender is already there, which is anyone who has ever
# installed a mod, can now install this layer with no elevation at all.
#
# So the answer is recorded rather than acted on, and each step below says for itself whether it
# needed it. Asked once, here, rather than discovered three steps down inside whichever write
# happens to come first: the failure that produces is an UnauthorizedAccessException with a path
# and no remedy, and guessing "right-click, Run as administrator" out of a .NET exception is not
# something to ask of somebody who cannot see it.
$gameWritable = $false
try {
    $binDir = Join-Path $GameDir "bin"
    $probe = Join-Path $binDir ".bg3access-write-test"
    [System.IO.File]::WriteAllText($probe, "")
    Remove-Item $probe -Force
    $gameWritable = $true
} catch {
    $gameWritable = $false
}
if ($gameWritable) {
    Ok "this account can change the game folder"
} else {
    Ok "read-only for this account - the layer does not need that, the Script Extender does"
}

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
} elseif (-not $gameWritable) {
    # Named as its own case rather than left to the download to discover, because the remedy is
    # different from every other problem on this page: not "install something", but "run this
    # again the other way". The rest of the install still happens - the layer goes in either way,
    # and coming back with one right-click is a much smaller ask than starting over.
    Bad "the Script Extender is missing and this account cannot write into the game folder"
    Write-Host "     The game is somewhere Windows will not let you change, usually under"
    Write-Host "     Program Files. Right-click install.bat, choose Run as administrator,"
    Write-Host "     and run it again - that step is the only one that needs it."
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

if (-not $gameWritable) {
    Ok "skipped - the game folder is read-only for this account"
    $notes += "DeveloperMode could not be set; the layer runs without it"
} else {

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
    # Guarded even though bin\ was proved writable above: it can carry its own ACL, and a
    # failure here must not take the install with it - the layer itself is not in this folder.
    try {
        Write-Json $seSettings "{`r`n    `"DeveloperMode`": true,`r`n    `"CreateConsole`": false`r`n}`r`n"
        Ok "written: bin\ScriptExtenderSettings.json"
    } catch {
        Bad "could not write $seSettings - set DeveloperMode there by hand"
    }
}

}   # end: the game folder is writable

# --- 4. the layer itself -----------------------------------------------------------------------

Step "The layer"

# The layer is an ordinary mod: a pak in %LOCALAPPDATA%\...\Mods\ and an entry in
# modsettings.lsx. Nothing of it goes into the game folder, which is why the read-only case
# above is survivable at all.
#
# It used to be a graft - the layer's ScriptExtender folder dropped inside GustavX's - because
# this project believed Patch 8 would not load a mod from outside its own manager. It does. What
# it would not load was our meta.lsx, still in the pre-Patch-7 format; see build-mod.ps1.
$appData = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3"
$modsDir = Join-Path $appData "Mods"

# Still worth proving rather than assuming: GustavX is the Patch 8 campaign module and the
# layer's meta declares a dependency on that generation of the game. Its absence means a version
# this was never tested against, and the failure that produces is silence with nothing anywhere
# to explain it.
if (-not (Test-Path (Join-Path $GameDir "Data\$HostModule.pak"))) {
    Bad "no Data\$HostModule.pak - this is not the game version the layer was built for"
}

# An upgrade from any release before this one arrives with a graft already in place, and the two
# routes cannot coexist: both declare "ModTable": "BG3Access", so the extender would be handed
# the same table twice. Taken away first, and never silently - somebody reading the log of a
# failed upgrade needs to see that this happened.
$graft = Join-Path $GameDir "Data\Mods\$HostModule\ScriptExtender"
if (Test-Path $graft) {
    if ($gameWritable) {
        try {
            # *> $null and not | Out-Null. Out-Null takes the success stream only, and every
            # script in here reports through Write-Host, which since PS 5 goes to the
            # information stream - so the called script's own narration lands in the middle of
            # this one's. That is noise on a page that is read out loud, and worse than noise
            # when it carries instructions meant for someone running that script directly.
            # An error still throws past this and into the catch; nothing is being hidden.
            & (Join-Path $PSScriptRoot "graft-mod.ps1") -GameDir $GameDir -HostModule $HostModule -Uninstall *> $null
            Ok "removed the graft left by an earlier version"
        } catch {
            Bad "could not remove the old graft at $graft - delete that folder by hand"
        }
    } else {
        Bad "an earlier version is grafted into the game folder and cannot be removed from here"
        Write-Host "     Both would run at once and conflict. Right-click install.bat and choose"
        Write-Host "     Run as administrator, or delete this folder yourself:"
        Write-Host "     $graft"
    }
}

# The pak travels beside this script in a release, and lands in dist\ on the machine it is
# built on. Both are checked so that a run out of a working copy behaves like a run out of a
# release, which is the only way the release path ever gets exercised before it ships.
$pak = $null
foreach ($cand in @((Join-Path $root "BG3Access.pak"), (Join-Path $root "dist\BG3Access.pak"))) {
    if (-not $pak -and (Test-Path $cand)) { $pak = $cand }
}
if (-not $pak) {
    Bad "BG3Access.pak is missing from this download - it cannot be installed without it"
    Say "The install failed: a file is missing from the download."
    exit 1
}

try {
    New-Item -ItemType Directory -Force $modsDir | Out-Null
    Copy-Item $pak (Join-Path $modsDir "BG3Access.pak") -Force
    Ok ("Mods\BG3Access.pak, {0:N0} KB" -f ((Get-Item $pak).Length / 1KB))
} catch {
    # The overwhelmingly likely cause, and the one the .NET message describes worst: a running
    # game holds an open handle on every pak it loaded, so upgrading while playing fails with
    # "the process cannot access the file". Named plainly, because "close the game and run this
    # again" is a thing anybody can do and "IOException 0x80070020" is not.
    if (Get-Process bg3, bg3_dx11 -ErrorAction SilentlyContinue) {
        Bad "Baldur's Gate 3 is running - close it and run install.bat again"
        Say "Baldur's Gate 3 is still running. Close it and install again."
    } else {
        Bad "the layer could not be installed: $_"
        Say "The install failed. Nothing is running."
    }
    exit 1
}

# Installed and switched on are two different things, and a pak nobody enabled is a mod the game
# ignores in silence. The identity is read out of the shipped meta.lsx rather than written here
# as constants, so it cannot drift from the pak it describes.
try {
    $meta = Join-Path $root "BG3Access\Mods\BG3Access\meta.lsx"
    & (Join-Path $PSScriptRoot "register-mod.ps1") -Meta $meta *> $null
    Ok "switched on in modsettings.lsx"
} catch {
    Bad "the layer is installed but could not be switched on: $_"
    Write-Host "     Run: powershell -File tools\register-mod.ps1 -Meta BG3Access\Mods\BG3Access\meta.lsx"
}

# --- 4b. the thing the layer reads through -------------------------------------------------
#
# BG3 only raises its controller interface when it sees a pad, and that interface is what the
# layer reads. No pad means an install where every line above says OK and the game says nothing -
# indistinguishable, from the inside, from the mod being broken.
#
# This used to be handled by telling everybody to plug one in, checked or nothing. A miss is
# still not called a failure: the detector is honest about not being able to see every pad (see
# find-controller.ps1), so it goes in the notes and into the sentence spoken at the end, and
# never into $problems - a false miss must not turn a good install into a reported failure.
Step "Controller"
$pad = $null
try { $pad = @(& (Join-Path $PSScriptRoot "find-controller.ps1")) } catch { }
if ($pad) {
    Ok $pad[0]
} else {
    Ok "none found"
    $notes += "no game controller was found - the layer has nothing to read without one"
}

# --- 5. the half that cannot live inside the game ------------------------------------------------

# Found here rather than down in the shortcut step, because the speech companion wants it too:
# the play launcher it writes is "start the companion if it is missing, then start this".
$exe = Join-Path $GameDir "bin\bg3_dx11.exe"
if (-not (Test-Path $exe)) { $exe = Join-Path $GameDir "bin\bg3.exe" }
if (-not (Test-Path $exe)) { $exe = $null }

if ($NoSpeech) {
    Step "Speech companion"
    Ok "skipped (-NoSpeech) - start it by hand with tools\speak.ps1 -Watch"
    $notes += "the speech companion was not installed"
} else {
    Step "Speech companion"
    try {
        $speechArgs = @{}
        if ($exe) { $speechArgs.GameExe = $exe }
        & (Join-Path $PSScriptRoot "install-speech-service.ps1") @speechArgs
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

# --- 5b. did any of that actually land on the machine ------------------------------------------
#
# An installer that checks its own work with its own eyes can be lied to, and on 2026-08-05 this
# one was, for four days running.
#
# Windows lets a process be given a private copy of the user profile. A packaged application does
# it to its own children - everything they write under %LOCALAPPDATA% or %APPDATA% is quietly
# redirected into
#
#     %LOCALAPPDATA%\Packages\<package>\LocalCache\...
#
# while reads still fall through to the real file when no private copy exists. Inside that view
# an install is perfect: every file is where it was put, Test-Path says yes, status.bat says yes.
# Outside it, %LOCALAPPDATA%\BG3Access does not exist at all. The Startup launcher - which is one
# of the few paths *not* redirected - was real, and pointed into a folder that was not, so it
# failed silently at every logon; the only companion that ever ran was one started inside the
# private view, and it died with the process that started it.
#
# So the writes get checked from the outside in the only way that needs no help: put a file with
# a name nothing else could have, and see whether it turns up somewhere it was not sent.
Step "Where the files went"
$installedDir = Join-Path $env:LOCALAPPDATA "BG3Access"
if (Test-Path $installedDir) {
    $probeName = ".write-probe-" + [guid]::NewGuid().ToString("N")
    $probe = Join-Path $installedDir $probeName
    try {
        Set-Content -LiteralPath $probe -Value "x" -Encoding ASCII
        $shadow = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA "Packages\*\LocalCache\*\BG3Access\$probeName") -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        if ($shadow) {
            Bad "these files were not written to the machine - they went into a private copy of your profile"
            Write-Host "     $($shadow[0].DirectoryName)"
            Write-Host ""
            Write-Host "     This happens when the install is run from inside another application"
            Write-Host "     rather than from Windows itself. Nothing here will work: the game will"
            Write-Host "     run the layer and say every line into a file nobody is reading."
            Write-Host "     Open the unpacked folder in Explorer and double-click install.bat."
            Say ("The files were written into a private copy of your profile, not to the machine. " +
                 "Run install dot bat from Windows itself.")
        } else {
            Ok "$installedDir - on the machine, not in a private copy"
        }
    } catch {
        Ok "could not be checked: $_"
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
    if ($exe) {
        try {
            # Through the play launcher when there is one, straight at the executable when there
            # is not. The launcher checks the companion before it starts the game, which is the
            # moment that answer matters most; the watchdog installed alongside it covers every
            # other way in, so this is now the quick path rather than the only safe one.
            #
            # The icon is set back to the game's own: a .lnk takes its icon from its target, and
            # the target is now a script file. Nothing about what this starts has changed.
            $play = Join-Path $env:LOCALAPPDATA "BG3Access\Play BG3.vbs"
            $lnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "Baldurs Gate 3 (no launcher).lnk"
            $sh = New-Object -ComObject WScript.Shell
            $s = $sh.CreateShortcut($lnk)
            if (Test-Path $play) {
                $s.TargetPath = "wscript.exe"
                # //B for the same reason the watchdog uses it: if this file ever goes missing,
                # the script host's answer is a message box, and a message box in front of
                # somebody who cannot see it is a game that simply never starts.
                $s.Arguments = "//B ""$play"""
                $s.IconLocation = "$exe,0"
                $s.Description = "Starts BG3 directly with speech running, skipping the launcher (Steam must be running)"
            } else {
                $s.TargetPath = $exe
                $s.Description = "Starts BG3 directly, skipping the launcher (Steam must be running)"
            }
            $s.WorkingDirectory = Split-Path $exe
            $s.Save()
            Ok ("Baldurs Gate 3 (no launcher).lnk" + $(if (Test-Path $play) { " -> Play BG3.vbs" }))
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
    # ASCII only in this file: PS 5.1 reads a .ps1 with no BOM as ANSI, so a line quoting what
    # the layer says in a language that is not English would print as mojibake.
    Write-Host "Next:"
    $n = 1
    if (-not $pad) {
        Write-Host "  $n. Plug in a game controller. The layer reads the game's controller"
        Write-Host "     interface, and without a pad there is nothing for it to read."
        $n++
    }
    Write-Host "  $n. Start the game however you like. The Desktop shortcut skips Larian's"
    Write-Host "     launcher, which cannot be read at all, so it is the easiest way in."
    $n++
    Write-Host "  $n. The layer says one short line out loud when it comes up."
    $n++
    Write-Host "  $n. If it stays silent, run status.bat and send what it prints."
    Write-Host ""
    Write-Host "The keys are in PLAYING.md."
    # Said differently depending on what was found, because "plug in a controller" to somebody
    # who already has one is noise, and noise is what a spoken summary can least afford.
    if ($pad) {
        Say "BG3 access installed. Start the game from the Desktop shortcut."
    } else {
        Say ("BG3 access installed, but no game controller was found. Plug one in before you " +
             "start the game, or the layer will have nothing to read.")
    }
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
#
# Both ways out are explicit. Falling off the end of the script leaves $LASTEXITCODE holding
# whatever the last native command in here happened to return - wscript.exe, three files down -
# and the caller reading that as this script's answer is a coin toss dressed as a check.
if ($problems.Count) { exit 1 }
exit 0
