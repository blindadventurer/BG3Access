# Which window currently owns the keyboard?
#
# The Script Extender opens its own console window, and it can take focus at
# startup — in which case the game receives no key events and the accessibility
# layer looks broken for a reason that has nothing to do with the layer. This
# reports the truth without needing to look at the screen.

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public class Fg {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr h, StringBuilder buf, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

    public static string Title(IntPtr h) {
        var sb = new StringBuilder(512);
        GetWindowTextW(h, sb, sb.Capacity);
        return sb.ToString();
    }
}
"@

$h = [Fg]::GetForegroundWindow()
$owner = 0                      # not $pid — that one is read-only in PowerShell
[void][Fg]::GetWindowThreadProcessId($h, [ref]$owner)
$proc = Get-Process -Id $owner -ErrorAction SilentlyContinue

[PSCustomObject]@{
    Process = if ($proc) { $proc.ProcessName } else { "?" }
    Pid     = $owner
    Title   = [Fg]::Title($h)
} | Format-List
