# Bring the BG3 window to the front and give it the keyboard.
#
# An unfocused game processes no input and plays no sound (session 1 rule), so every
# probe that involves hover, injected keys or audio has to start here. SetForegroundWindow
# alone is refused by Windows when the calling process did not produce the last input,
# so the thread input queues are attached first - the standard workaround.
#
# ASCII only: PS 5.1 reads .ps1 as ANSI and the Write tool emits UTF-8 without a BOM.
#
# Usage: powershell -File focus-game.ps1

$ErrorActionPreference = "Stop"

Add-Type @"
using System;
using System.Runtime.InteropServices;

public class Fore {
    public delegate bool EnumProc(IntPtr h, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder buf, int n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();

    public const int SW_RESTORE = 9;

    // Not MainWindowHandle. The Script Extender's debug console belongs to the same
    // process, and once it has been to the front Windows starts reporting *it* as the main
    // window - after which focus-game raises the console, every key goes to the console,
    // and the game looks like it stopped responding to input.
    public static IntPtr FindGame(int pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr lp) {
            uint owner;
            GetWindowThreadProcessId(h, out owner);
            if (owner != (uint)pid || !IsWindowVisible(h)) return true;
            var sb = new System.Text.StringBuilder(512);
            GetWindowTextW(h, sb, sb.Capacity);
            string t = sb.ToString();
            if (t.StartsWith("Baldur")) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

    public static bool Raise(IntPtr target) {
        uint me  = GetCurrentThreadId();
        uint him = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
        uint mine = GetWindowThreadProcessId(target, IntPtr.Zero);
        AttachThreadInput(me, him, true);
        AttachThreadInput(mine, him, true);
        ShowWindow(target, SW_RESTORE);
        BringWindowToTop(target);
        bool ok = SetForegroundWindow(target);
        AttachThreadInput(mine, him, false);
        AttachThreadInput(me, him, false);
        return ok;
    }
}
"@

$proc = Get-Process bg3_dx11, bg3 -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) { Write-Error "BG3 is not running" }

$hwnd = [Fore]::FindGame($proc.Id)
if ($hwnd -eq [IntPtr]::Zero) { Write-Error "no window titled 'Baldur...' in process $($proc.Id)" }

$ok = [Fore]::Raise($hwnd)
Start-Sleep -Milliseconds 250

$fg = [Fore]::GetForegroundWindow()
if ($fg -eq $hwnd) { "game is foreground" }
else { "raise returned $ok but foreground is still someone else" }
