# Move and click the real mouse pointer.
#
# The Script Extender exposes no mouse injection at all (InjectMouseButton and friends
# are nil), and Noesis hit-testing follows the real OS pointer - writing the picking
# helper's WindowCursorPos only aims world picking. So anything that needs the game to
# genuinely hover or click a widget has to come from outside the game.
#
# ASCII only: the Write tool emits UTF-8 without a BOM and PS 5.1 reads .ps1 as ANSI,
# which turns a dash into a stray string delimiter.
#
# Usage: powershell -File mouse.ps1 -Get
#        powershell -File mouse.ps1 -X 960 -Y 500
#        powershell -File mouse.ps1 -X 960 -Y 500 -Click
#        powershell -File mouse.ps1 -Restore 960,540

param(
    [int]$X = -1,
    [int]$Y = -1,
    [switch]$Click,
    [switch]$Get,
    [int[]]$Restore
)

$ErrorActionPreference = "Stop"

Add-Type @"
using System;
using System.Runtime.InteropServices;

public class Mouse {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);

    public const uint LEFTDOWN = 0x0002;
    public const uint LEFTUP   = 0x0004;

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }
}
"@

function Get-Pos {
    $p = New-Object Mouse+POINT
    [void][Mouse]::GetCursorPos([ref]$p)
    return $p
}

if ($Get) {
    $p = Get-Pos
    "$($p.X),$($p.Y)"
    return
}

if ($Restore) {
    [void][Mouse]::SetCursorPos($Restore[0], $Restore[1])
    "restored to $($Restore[0]),$($Restore[1])"
    return
}

if ($X -lt 0 -or $Y -lt 0) { Write-Error "need -X and -Y (or -Get / -Restore)" }

[void][Mouse]::SetCursorPos($X, $Y)

if ($Click) {
    # A real button press through the OS, so the game handles it exactly as a user click.
    [Mouse]::mouse_event([Mouse]::LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 40
    [Mouse]::mouse_event([Mouse]::LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
}

$p = Get-Pos
"at $($p.X),$($p.Y)$(if ($Click) { ' clicked' })"
