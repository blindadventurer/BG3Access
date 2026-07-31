# Find a widget on screen by hovering the real pointer over it and asking the game.
#
# The Script Extender injects no mouse input and Noesis exposes no absolute geometry -
# ActualWidth on a caption node reads 0 - so where to click cannot be computed. It can be
# measured: move the OS pointer, ask the tree which element reports IsMouseOver, repeat.
# One probe costs a console round trip, so a sweep is a coarse grid rather than a search.
#
# The pointer is restored to where the user left it before the script returns.
#
# ASCII only: PS 5.1 reads .ps1 as ANSI and the Write tool emits UTF-8 without a BOM.
#
# Usage: powershell -File hover-sweep.ps1 -X 200 -Y0 400 -Y1 1000 -Step 25
#        powershell -File hover-sweep.ps1 -Rect            just print the window box
#        powershell -File hover-sweep.ps1 -Points "200,500;400,600"

param(
    [int]$X = -1,
    [int]$Y0 = 0,
    [int]$Y1 = 0,
    [int]$Step = 25,
    [string]$Points,
    [switch]$Rect,
    [int]$SettleMs = 220,
    [string]$Flush = "sweep",
    [string]$Probe = "Ms.mark('{TAG}')"
)

$ErrorActionPreference = "Stop"

Add-Type @"
using System;
using System.Runtime.InteropServices;

public class Win {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out PT p);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RC r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RC r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref PT p);

    [StructLayout(LayoutKind.Sequential)] public struct PT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RC { public int L, T, R, B; }
}
"@

$proc = Get-Process bg3_dx11, bg3 -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) { Write-Error "BG3 is not running" }
$hwnd = $proc.MainWindowHandle

$wr = New-Object Win+RC
[void][Win]::GetWindowRect($hwnd, [ref]$wr)
$cr = New-Object Win+RC
[void][Win]::GetClientRect($hwnd, [ref]$cr)
$org = New-Object Win+PT
[void][Win]::ClientToScreen($hwnd, [ref]$org)

"window  : $($wr.L),$($wr.T) .. $($wr.R),$($wr.B)"
"client  : $($cr.R) x $($cr.B) at screen $($org.X),$($org.Y)"
if ($Rect) { return }

$send = Join-Path $PSScriptRoot "console-send.ps1"

$saved = New-Object Win+PT
[void][Win]::GetCursorPos([ref]$saved)

$probes = @()
if ($Points) {
    foreach ($p in $Points.Split(';')) {
        $xy = $p.Split(',')
        $probes += ,@([int]$xy[0], [int]$xy[1])
    }
} else {
    if ($X -lt 0) { Write-Error "need -X with -Y0/-Y1, or -Points" }
    for ($y = $Y0; $y -le $Y1; $y += $Step) { $probes += ,@($X, $y) }
}

"probing $($probes.Count) points"
foreach ($p in $probes) {
    # Client coordinates in, screen coordinates out: the game reasons in its own 1920x1080
    # space and the window may be offset or the desktop scaled.
    $sx = $org.X + $p[0]
    $sy = $org.Y + $p[1]
    [void][Win]::SetCursorPos($sx, $sy)
    Start-Sleep -Milliseconds $SettleMs
    & $send -Line $Probe.Replace("{TAG}", "$($p[0])_$($p[1])") -DelayMs 20
    Start-Sleep -Milliseconds 90
}

# One file for the whole sweep: the per-probe warnings SE logs on GetAllProperties bury
# anything printed to the console long before a sweep of this length ends.
& $send -Line "Ms.flush('$Flush')" -DelayMs 20
Start-Sleep -Milliseconds 400

[void][Win]::SetCursorPos($saved.X, $saved.Y)
"pointer restored to $($saved.X),$($saved.Y); results in $Flush.json"
