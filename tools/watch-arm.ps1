# Keep a watcher probe alive across a save load, for as long as somebody is playing.
#
# Loading a save wipes the client Lua state and every dev module with it, which is exactly
# the moment a probe meant to catch things that happen *while playing* is needed. Nothing on
# the game side can survive that - BootstrapClient is re-run by the extender and rebuilds the
# layer, but it knows nothing about probes - so the re-arming has to come from outside.
#
# The probe writes a heartbeat file about once a second. This watches that file's age: gone
# or stale means the state was rebuilt (or the probe threw), and the load lines are sent
# again. Re-arming is idempotent - start() stops first, and the log is read back off disk -
# so a needless re-arm costs two console lines and loses nothing.
#
# Nothing here takes window focus: console-send.ps1 writes into the game console's input
# buffer, so the player keeps playing while this runs.
#
# ASCII only: PS 5.1 reads .ps1 as ANSI and the Write tool emits UTF-8 without a BOM.
#
# Usage: powershell -File watch-arm.ps1
#        powershell -File watch-arm.ps1 -Probe probe-appear -Global W -Minutes 180

param(
    [string]$Probe   = "probe-appear",
    [string]$Global  = "W",
    [string]$Beat    = "appear_beat.txt",
    [int]$Minutes    = 120,
    [int]$StaleSecs  = 30,
    [int]$PollSecs   = 10
)

$ErrorActionPreference = "Stop"

$root  = Split-Path $PSScriptRoot
$send  = Join-Path $PSScriptRoot "console-send.ps1"
$seDir = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Script Extender\A11y"
$beat  = Join-Path $seDir $Beat
$src   = Join-Path $root "probes\$Probe.lua"

if (-not (Test-Path $src)) { Write-Error "no such probe: $src" }
New-Item -ItemType Directory -Force $seDir | Out-Null
Copy-Item $src $seDir -Force
Write-Host "staged $Probe.lua -> $seDir"

function Send-Arm {
    # The epoch second is handed to the probe so its log lines carry wall-clock time; the
    # extender offers a monotonic counter and no calendar.
    $epoch = [int][double]::Parse((Get-Date -UFormat %s))
    & $send -Line "client" | Out-Null
    Start-Sleep -Milliseconds 300
    & $send -Line "Mods.BG3Access.A11yBoot.loadDev(`"$Probe`", `"$Global`")" | Out-Null
    Start-Sleep -Milliseconds 400
    & $send -Line "Mods.BG3Access.$Global.start($epoch)" | Out-Null
    Write-Host "$(Get-Date -Format 'HH:mm:ss') armed $Probe as $Global"
}

$deadline = (Get-Date).AddMinutes($Minutes)
$armed = $false

while ((Get-Date) -lt $deadline) {
    $game = Get-Process bg3_dx11, bg3 -ErrorAction SilentlyContinue
    if (-not $game) {
        if ($armed) { Write-Host "$(Get-Date -Format 'HH:mm:ss') game closed - waiting" }
        $armed = $false
        Start-Sleep -Seconds $PollSecs
        continue
    }

    $stale = $true
    if (Test-Path $beat) {
        $age = ((Get-Date) - (Get-Item $beat).LastWriteTime).TotalSeconds
        $stale = ($age -gt $StaleSecs)
    }

    if ($stale) {
        # Clear it first, so the next poll measures a heartbeat this arming produced rather
        # than the stale file that triggered it.
        if (Test-Path $beat) { Remove-Item $beat -Force -ErrorAction SilentlyContinue }
        Send-Arm
        $armed = $true
    }

    Start-Sleep -Seconds $PollSecs
}

Write-Host "watch-arm finished after $Minutes minutes"
