﻿# Can the existing Noesis keyboard focus be moved?
#
# What we know: BG3 keeps a real keyboard focus (IsFocused / IsKeyboardFocused) while its
# window is active, injected keys do reach the game (ESCAPE raised UICancel and closed a
# panel), and nothing in mouse-and-keyboard mode ever moves that focus. Noesis has its own
# Tab traversal at framework level, independent of Larian's bindings - if that is alive,
# focus movement, highlight, sound and activation are all the game's own code.
#
# Every step is spoken, so the tester can stay in the game and just listen.
#
# Usage: powershell -File drive-focus.ps1 [-WaitSeconds 240]

param([int]$WaitSeconds = 240)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$tools  = $PSScriptRoot
$seDir  = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Script Extender\A11y"
$speech = Join-Path $seDir "speech.txt"
$enc    = New-Object System.Text.UTF8Encoding($false)
$seq    = 30000

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class FG {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
}
"@

function Say($text) {
    $script:seq++
    [System.IO.File]::WriteAllText($speech, "$($script:seq)|1|$text", $enc)
    Write-Host "SAY: $text"
}
function Send-Lua($line) {
    & (Join-Path $tools "console-send.ps1") -Line $line
    Write-Host "LUA: $line"
}
function Get-FgProcess {
    $h = [FG]::GetForegroundWindow()
    $owner = 0
    [void][FG]::GetWindowThreadProcessId($h, [ref]$owner)
    $p = Get-Process -Id $owner -ErrorAction SilentlyContinue
    if ($p) { return $p.ProcessName } else { return "?" }
}

if (-not (Get-Process bg3_dx11, bg3 -ErrorAction SilentlyContinue)) {
    Write-Host "BG3 is not running"; return
}

Write-Host "waiting up to $WaitSeconds s for game focus..."
$deadline = (Get-Date).AddSeconds($WaitSeconds)
$ok = $false
while ((Get-Date) -lt $deadline) {
    if ((Get-FgProcess) -match '^bg3') { $ok = $true; break }
    Start-Sleep -Milliseconds 500
}
if (-not $ok) { Write-Host "game never took focus - aborting"; return }

Write-Host "game focused"
Start-Sleep -Milliseconds 900
Say "Начинаю. Ничего не нажимай, я буду называть, где фокус."
Start-Sleep -Seconds 5

Send-Lua 'A11y.focusSay("start")'
Start-Sleep -Seconds 4

# Noesis-level traversal first: this needs no Larian binding at all.
foreach ($n in 1, 2) {
    Send-Lua 'Ext.ClientInput.InjectKeyPress("TAB", 0)'
    Start-Sleep -Milliseconds 600
    Send-Lua "A11y.focusSay(`"tab$n`")"
    Start-Sleep -Seconds 4
}

Send-Lua 'do local ok,e = pcall(function() return Ext.ClientInput.InjectKeyPress("TAB", "LShift") end) _P("shifttab ok="..tostring(ok).." e="..tostring(e)) end'
Start-Sleep -Milliseconds 600
Send-Lua 'A11y.focusSay("shifttab")'
Start-Sleep -Seconds 4

# Then the arrow, to confirm from our side what the tester already reported by hand.
Send-Lua 'Ext.ClientInput.InjectKeyPress("DOWN", 0)'
Start-Sleep -Milliseconds 600
Send-Lua 'A11y.focusSay("down")'
Start-Sleep -Seconds 4

# And the engine-level event queue, now that AllowDeviceEvents is known to gate it.
Send-Lua 'A11y.armInjection()'
Start-Sleep -Milliseconds 400
Send-Lua 'A11y.injectEvent(0, 246)'
Start-Sleep -Milliseconds 800
Send-Lua 'A11y.focusSay("evdown")'
Start-Sleep -Seconds 4

Send-Lua 'A11y.injectEvent(3, 246)'
Start-Sleep -Milliseconds 800
Send-Lua 'A11y.focusSay("evpad")'
Start-Sleep -Seconds 4

Say "Проверка закончена, возвращайся."
Write-Host "done"
