# Is the layer actually up? Answered without the game window and without the SE console.
#
# Everything here fails silently on its own: the game has to be found and carry the Script
# Extender, a pad has to be plugged in for BG3 to raise the interface the layer reads, the
# layer has to be installed AND switched on - two separate facts - the client bootstrap has to
# have run,
# something has to be turning the speech bridge into speech, and something has to be watching
# that that thing is still there at all. One line each, and the failing
# one names its own fix - this page is what a player is asked for when it has gone quiet, so
# a line that only says "no" is half an answer.
#
# Usage: powershell -File mod-status.ps1

param(
    [string]$HostModule = "GustavX",
    [string]$GameDir = (& (Join-Path $PSScriptRoot "find-game.ps1"))
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$appData = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3"
$a11y    = Join-Path $appData "Script Extender\A11y"
$boot    = Join-Path $a11y "boot.json"
$bridge  = Join-Path $a11y "speech.txt"
$graft   = if ($GameDir) { Join-Path $GameDir "Data\Mods\$HostModule\ScriptExtender" } else { $null }

function Line($label, $ok, $detail) {
    $mark = if ($ok) { "OK  " } else { "--  " }
    Write-Host ("{0}{1,-22}{2}" -f $mark, $label, $detail)
}

# 0. the two things that are not the layer's doing at all, and that it cannot work without.
#    Both fail silently: no game found means every path below is guesswork, and a missing
#    DWrite.dll means the game starts perfectly and runs no mod code whatsoever.
Line "game folder" ([bool]$GameDir) $(if ($GameDir) { $GameDir } else { "not found - pass -GameDir" })
if ($GameDir) {
    $se = Join-Path $GameDir "bin\DWrite.dll"
    Line "script extender" (Test-Path $se) $(if (Test-Path $se) {
        "bin\DWrite.dll, {0:yyyy-MM-dd}" -f (Get-Item $se).LastWriteTime
    } else { "missing - run install.bat, it offers to fetch it" })
}

# 0b. the pad. Not the layer's doing either, and the one prerequisite that fails while
#     everything else on this page says OK: BG3 raises its controller interface only when it
#     sees a pad, and that interface is the whole of what the layer reads. "It installed fine
#     and the game says nothing" is this line, most of the time.
$pad = $null
try { $pad = @(& (Join-Path $PSScriptRoot "find-controller.ps1")) } catch { }
Line "controller" ([bool]$pad) $(if ($pad) { $pad[0] } else {
    "none found - plug one in; without it the layer has nothing to read" })

# 1. game
$game = Get-Process bg3_dx11, bg3 -ErrorAction SilentlyContinue
Line "game" ([bool]$game) $(if ($game) { "running, pid $($game[0].Id)" } else { "not running" })

# 2. the install itself, by either route - and they are exclusive, so this reports which one is
#    in use rather than assuming. As a mod: a pak in Mods\ AND an entry in modsettings.lsx,
#    because the two are separate facts and "installed but switched off" is a real state a
#    player can be in and cannot see. As a graft: the ScriptExtender folder inside a loaded
#    module, which needs no mod at all.
#
#    This used to check the graft alone and call anything else "missing - run install.bat",
#    which after the move to a real mod meant telling a player with a working layer that they
#    had no install. A status page that is wrong is worse than one that is absent.
$pakFile  = Join-Path $appData "Mods\BG3Access.pak"
$settings = Join-Path $appData "PlayerProfiles\Public\modsettings.lsx"
$enabled  = $false
if (Test-Path $settings) {
    try {
        [xml]$ms = Get-Content $settings -Raw -Encoding UTF8
        $enabled = $null -ne $ms.SelectSingleNode(
            "//node[@id='ModuleShortDesc'][attribute[@id='Folder'][@value='BG3Access']]")
    } catch { }
}
$grafted = $graft -and (Test-Path (Join-Path $graft "Config.json"))

if (Test-Path $pakFile) {
    $pk = Get-Item $pakFile
    if ($enabled) {
        Line "installed as a mod" $true ("Mods\BG3Access.pak, {0:N0} KB, {1:yyyy-MM-dd HH:mm}" -f ($pk.Length / 1KB), $pk.LastWriteTime)
    } else {
        Line "installed as a mod" $false ("the pak is there but switched off - " +
            "powershell -File tools\register-mod.ps1 -Pak BG3Access.pak")
    }
} elseif ($grafted) {
    $files = Get-ChildItem $graft -Recurse -File
    $newest = ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
    Line "grafted onto $HostModule" $true ("{0} files, newest {1:yyyy-MM-dd HH:mm}" -f $files.Count, $newest)
} else {
    Line "install" $false "neither a pak nor a graft found - run install.bat"
}

# Both at once is not a worse install, it is a broken one: the extender is handed the same
# ModTable twice. Silence here would leave the player with a layer that behaves oddly for a
# reason nothing on this page mentions.
if ((Test-Path $pakFile) -and $grafted) {
    Line "CONFLICT" $false ("both the pak and the graft are installed - they declare the same " +
        "ModTable. Remove one: tools\graft-mod.ps1 -Uninstall")
}

# 3. what the bootstrap wrote the last time the client state was built. That happens at launch
#    and again after every save load, so a stale timestamp here means it did not come back.
if (Test-Path $boot) {
    $b = Get-Content $boot -Raw -Encoding UTF8 | ConvertFrom-Json
    $age = [int]((Get-Date) - (Get-Item $boot).LastWriteTime).TotalSeconds
    Line "bootstrap" ($b.state -eq "running") ("state=$($b.state) modules=$($b.modules -join ' ') " +
        "controllerMode=$($b.controllerMode) SE=v$($b.extender) ${age}s ago")
    if ($b.error) { Write-Host "    error: $($b.error)" }
    # Which language the layer speaks, and where that came from. The first thing a report from
    # somebody playing in a language nobody here has heard needs to establish.
    if ($b.lang) {
        $why = if ($b.langForced) { "A11y\lang.txt" } else { "game=$($b.gameLanguage)" }
        Line "language" $true "$($b.lang) ($why)"
    }
} else {
    Line "bootstrap" $false "no boot.json - the client bootstrap never ran"
}

# 4. speech companion
# Matched on the shape of a launcher's command line, not on the two words appearing anywhere in
# it - see install-speech-service.ps1, where the same expression decides whether to start one.
# A status page that says "running" because it found itself is worse than no status page.
$watch = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
         Where-Object { $_.CommandLine -match 'speak\.ps1[''" ] -Watch' }
# The path matters as much as the pid. The launcher in Startup holds an absolute path to a copy
# of speak.ps1, so "running" can mean a copy other than the one you have been editing.
$watchFrom = $null
if ($watch) {
    $m = [regex]::Match($watch[0].CommandLine, "'([^']*speak\.ps1)'")
    if ($m.Success) { $watchFrom = $m.Groups[1].Value }
}
Line "speech companion" ([bool]$watch) $(if ($watch) {
    "running, pid $($watch[0].ProcessId)" + $(if ($watchFrom) { " <- $watchFrom" })
} else { "not running - run install.bat" })

# 5. and the thing that is supposed to make the line above impossible to see.
#
# The companion is started by events - logon, and the Desktop shortcut - and this is the only
# check that keeps being made after them. A machine that has been on for a week has had one
# logon; a session started from Steam went through neither. So when this line says no, the line
# above it is one killed process away from being no for the rest of the evening, and nothing
# would say so. It is worth its own line for the same reason the controller is: it is the
# difference between "silent once" and "silent until somebody notices".
$task = $null
try { $task = Get-ScheduledTask -TaskName "BG3Access Speech" -ErrorAction SilentlyContinue } catch { }
if ($task) {
    # Running is the healthy state, and that is not the usual reading of the word: the task does
    # not check on the companion, it runs it, so an instance in progress *is* the companion. Ready
    # means the last one has ended and the next minute has not come round yet - which is fine for
    # a moment and a problem if the line above still says nothing is running.
    $detail = switch ($task.State) {
        "Running"  { "running the companion; if it dies, the next minute starts another" }
        "Ready"    { "installed, between runs - it starts a companion within a minute" }
        "Disabled" { "DISABLED - nothing will start speech; enable it or run install.bat" }
        default    { "$($task.State)" }
    }
    Line "watchdog" ($task.State -ne "Disabled") $detail
} else {
    Line "watchdog" $false "not installed - run install.bat; nothing will restart a dead companion"
}

if (Test-Path $bridge) {
    $raw = (Get-Content $bridge -Raw -Encoding UTF8)
    $parts = $raw.Split('|', 3)
    $age = [int]((Get-Date) - (Get-Item $bridge).LastWriteTime).TotalSeconds
    Line "last spoken" $true ("#{0} ({1}s ago) {2}" -f $parts[0], $age, ($parts[2] -replace "\r?\n", " / "))
} else {
    Line "last spoken" $false "the layer has said nothing yet"
}
