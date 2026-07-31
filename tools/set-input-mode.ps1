# Put the game's control scheme to Controller, without a human at the pad.
#
# Not needed to play any more: at the default Auto the game raises the controller interface
# by itself the moment the pad is touched, and that is all the layer needs (measured -
# ControllerMode stays 0 and the _c screens are up). This script is for the other case: no pad
# in hand, driving the game from the keyboard, which only the Controller setting allows.
#
# The setting does not survive a restart, is read-only through the Script Extender, and
# writing the options combo's SelectedIndex moves the widget without applying anything. What
# does apply it is the screen's own path: click the entry, click the drop-down, click the
# item, leave with a real Escape.
#
# Every step is checked before the next one is taken. Clicking blind through an options
# screen is how a setting nobody asked about ends up changed.
#
# ASCII only: PS 5.1 reads .ps1 as ANSI and the Write tool emits UTF-8 without a BOM.
#
# Usage: powershell -File set-input-mode.ps1
#        powershell -File set-input-mode.ps1 -Check      report the mode and stop

param(
    [switch]$Check,
    # Screen positions of the mouse-mode main menu and options row, measured by hover probe
    # at 1920x1080 fullscreen (hover-sweep.ps1). Verified before use, never trusted.
    [int[]]$OptionsEntry = @(300, 770),
    [int[]]$ComboButton  = @(975, 447),
    [int[]]$ControllerItem = @(800, 560)
)

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$a11y = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Script Extender\A11y"

function Send-Line([string]$line) { & (Join-Path $here "console-send.ps1") -Line $line | Out-Null }
function Raise { & (Join-Path $here "focus-game.ps1") | Out-Null }
function Click([int[]]$p) {
    & (Join-Path $here "mouse.ps1") -X $p[0] -Y $p[1] | Out-Null
    Start-Sleep -Milliseconds 350
    & (Join-Path $here "mouse.ps1") -X $p[0] -Y $p[1] -Click | Out-Null
}

# Ask the game where it is. The answer goes to a file: the SE console drowns in property
# warnings on any screen this size.
function Get-State([string]$tag) {
    $f = Join-Path $a11y "state_$tag.json"
    if (Test-Path $f) { Remove-Item $f -Force }
    Send-Line "Mods.BG3Access.Ms.state('$tag')"
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 250
        if (Test-Path $f) { return (Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json) }
    }
    return $null
}

if (-not (Get-Process bg3_dx11, bg3 -ErrorAction SilentlyContinue)) { Write-Error "BG3 is not running" }

# The layer itself is already up - the game starts it. Only the hit-test module is missing,
# and it has to be loaded into the mod's table rather than the console's globals, or it will
# not find A11y and Pad.
& (Join-Path $here "push-lua.ps1") -Name a11y-mouse -Dev Ms -NoReload | Out-Null
Start-Sleep -Milliseconds 900

# Nothing is replaced any more, so the reader keeps running throughout; kept as a no-op hook
# so the flow below reads the same as it did.
function Restore-Reader { }

Raise
$s = Get-State "check"
if ($null -eq $s) { Write-Error "no answer from the game - is the client Lua context up?" }
"mode=$($s.mode) screen=$($s.screen)"
if ($Check) { Restore-Reader; return }
if ($s.mode -eq "2") { Restore-Reader; "already Controller - nothing to do"; return }

# Retried: the first click after a fresh launch is regularly eaten while the menu is still
# settling, and one lost click looks exactly like a wrong coordinate.
$s = $null
for ($try = 1; $try -le 3; $try++) {
    Raise
    Click $OptionsEntry
    Start-Sleep -Milliseconds 1800
    $s = Get-State "options"
    if ($s.screen -eq "GameOptions") { break }
    "options did not open (screen=$($s.screen)), retry $try"
    Start-Sleep -Milliseconds 1200
}
if ($s.screen -ne "GameOptions") {
    Write-Error "options did not open (screen=$($s.screen)); re-measure with hover-sweep.ps1"
}

Raise
Click $ComboButton
Start-Sleep -Milliseconds 1200
$s = Get-State "combo"
if ($s.comboOpen -ne "True" -and $s.comboOpen -ne "true") {
    Write-Error "the input-mode drop-down did not open (row=$($s.row))"
}

# The item lives in a Noesis popup outside the screen widget, so it is confirmed by asking
# the whole tree what the pointer is on - not by trusting the coordinate.
Raise
& (Join-Path $here "mouse.ps1") -X $ControllerItem[0] -Y $ControllerItem[1] | Out-Null
Start-Sleep -Milliseconds 500
$s = Get-State "item"
"pointer is on: $($s.under) <$($s.underCls)>  isController=$($s.isController)"
if ($s.isController -ne "True" -and $s.isController -ne "true") {
    Write-Error "the pointer is not on the Controller item; re-measure with hover-sweep.ps1"
}

& (Join-Path $here "mouse.ps1") -X $ControllerItem[0] -Y $ControllerItem[1] -Click | Out-Null
Start-Sleep -Milliseconds 1200

# Leaving the screen is what applies it; the click alone only moves SelectedIndex.
Raise
& (Join-Path $here "keys.ps1") -Key ESCAPE | Out-Null
Start-Sleep -Milliseconds 2000

$s = Get-State "final"
Restore-Reader
"mode=$($s.mode) screen=$($s.screen)"
if ($s.mode -eq "2") { "control scheme is Controller" }
else { Write-Error "still ControllerMode=$($s.mode) - not applied" }
