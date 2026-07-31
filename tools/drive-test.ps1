# Run the experiments that only work while the game owns the keyboard.
#
# Injected device events and real pointer moves are both ignored by an unfocused client,
# so this waits for BG3 to come to the foreground, then drives the whole sequence and
# narrates it through the speech bridge - the tester never has to leave the game to read
# anything or type an answer.
#
# Usage: powershell -File drive-test.ps1 [-WaitSeconds 180]

param([int]$WaitSeconds = 180)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$tools  = $PSScriptRoot
$seDir  = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Script Extender\A11y"
$speech = Join-Path $seDir "speech.txt"
$enc    = New-Object System.Text.UTF8Encoding($false)
$seq    = 20000

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class DT {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out P p);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
    [StructLayout(LayoutKind.Sequential)] public struct P { public int X; public int Y; }
    public const uint LEFTDOWN = 0x0002;
    public const uint LEFTUP   = 0x0004;
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
    $h = [DT]::GetForegroundWindow()
    $owner = 0
    [void][DT]::GetWindowThreadProcessId($h, [ref]$owner)
    $p = Get-Process -Id $owner -ErrorAction SilentlyContinue
    if ($p) { return $p.ProcessName } else { return "?" }
}

$game = Get-Process bg3_dx11, bg3 -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $game) { Write-Host "BG3 is not running"; return }

Write-Host "waiting up to $WaitSeconds s for the game to take focus..."
$deadline = (Get-Date).AddSeconds($WaitSeconds)
$focused = $false
while ((Get-Date) -lt $deadline) {
    if ((Get-FgProcess) -match '^bg3') { $focused = $true; break }
    Start-Sleep -Milliseconds 500
}
if (-not $focused) { Write-Host "game never took focus - aborting"; return }

Write-Host "game focused, starting"
Start-Sleep -Milliseconds 800
Say "Игра в фокусе. Начинаю проверку. Ничего не нажимай."
Start-Sleep -Seconds 4

# --- 1. injected device events ------------------------------------------------
Send-Lua 'A11y.hoverReset()'
Send-Lua 'A11y.focusScan()'
Start-Sleep -Seconds 2

Say "Первое. Событие вниз от клавиатуры."
Start-Sleep -Seconds 3
Send-Lua 'A11y.injectEvent(0, 246)'
Start-Sleep -Milliseconds 700
Send-Lua 'A11y.focusScan()'
Start-Sleep -Seconds 2
Copy-Item (Join-Path $seDir "focus_scan.json") (Join-Path $seDir "fs_kbd.json") -Force

Say "Второе. Событие вниз от геймпада."
Start-Sleep -Seconds 3
Send-Lua 'A11y.injectEvent(3, 246)'
Start-Sleep -Milliseconds 700
Send-Lua 'A11y.focusScan()'
Start-Sleep -Seconds 2
Copy-Item (Join-Path $seDir "focus_scan.json") (Join-Path $seDir "fs_pad.json") -Force

Say "Третье. Разрешаю клавиатуру в геймпадном режиме и повторяю."
Start-Sleep -Seconds 4
Send-Lua 'do local im = Ext.ClientInput.GetInputManager() im.ControllerAllowKeyboardMouseInput = true _P("flag set") end'
Start-Sleep -Milliseconds 500
Send-Lua 'A11y.injectEvent(3, 246)'
Start-Sleep -Milliseconds 700
Send-Lua 'A11y.injectEvent(3, 245)'
Start-Sleep -Milliseconds 700
Send-Lua 'A11y.focusScan()'
Start-Sleep -Seconds 2
Copy-Item (Join-Path $seDir "focus_scan.json") (Join-Path $seDir "fs_flag.json") -Force

# --- 2. real pointer ----------------------------------------------------------
Say "Теперь курсор. Я поведу мышь по меню и верну её на место."
Start-Sleep -Seconds 4

$orig = New-Object DT+P
[void][DT]::GetCursorPos([ref]$orig)
Write-Host "original cursor $($orig.X),$($orig.Y)"

$x = $orig.X
for ($y = 300; $y -le 900; $y += 40) {
    [void][DT]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 150
    Send-Lua "A11y.hoverMark($x, $y)"
    Start-Sleep -Milliseconds 100
}
Send-Lua 'A11y.hoverDump()'
Start-Sleep -Seconds 1

# --- 3. a real click on an entry commands cannot reach ------------------------
Say "Последнее. Ищу Параметры и щёлкаю по ним настоящей мышью."
Start-Sleep -Seconds 4
Send-Lua 'A11y.summary("preclick")'
Start-Sleep -Seconds 2

# The hover map above says which y sits on which entry; the click target is resolved
# from it rather than guessed.
$hm = Get-Content (Join-Path $seDir "hover_map.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$target = $null
foreach ($p in $hm.marks.PSObject.Properties) {
    $m = $p.Value
    if (-not $m.hits) { continue }
    $labels = @($m.hits.PSObject.Properties | ForEach-Object { $_.Value })
    if ($labels -contains "Параметры") { $target = $m; break }
}

if ($target) {
    Write-Host "clicking Параметры at $($target.x),$($target.y)"
    [void][DT]::SetCursorPos([int]$target.x, [int]$target.y)
    Start-Sleep -Milliseconds 250
    [DT]::mouse_event([DT]::LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 50
    [DT]::mouse_event([DT]::LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Seconds 2
    Send-Lua 'A11y.summary("postclick")'
    Start-Sleep -Seconds 2
} else {
    Write-Host "Параметры was never hovered during the scan - no click target"
    Say "Параметры не нашлись под курсором, щелчок пропускаю."
    Start-Sleep -Seconds 3
}

[void][DT]::SetCursorPos($orig.X, $orig.Y)
Say "Проверка закончена. Курсор на месте. Можешь возвращаться."
Write-Host "done"
