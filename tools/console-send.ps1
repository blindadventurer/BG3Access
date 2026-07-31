# Feed lines into the BG3 Script Extender debug console of a running game.
#
# The console is a real Win32 console owned by the game process, so we attach to
# it and push synthetic key events into its input buffer. No window focus needed,
# nothing is typed into whatever the user is actually doing.
#
# Usage: powershell -File console-send.ps1 -File lines.txt
#        powershell -File console-send.ps1 -Line '_P("hi")'

param(
    [string]$File,
    [string]$Line,
    [int]$DelayMs = 60
)

$ErrorActionPreference = "Stop"

Add-Type @"
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Explicit)]
public struct INPUT_RECORD {
    [FieldOffset(0)] public ushort EventType;
    [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
}

[StructLayout(LayoutKind.Sequential)]
public struct KEY_EVENT_RECORD {
    [MarshalAs(UnmanagedType.Bool)] public bool bKeyDown;
    public ushort wRepeatCount;
    public ushort wVirtualKeyCode;
    public ushort wVirtualScanCode;
    public char UnicodeChar;
    public uint dwControlKeyState;
}

public class ConIn {
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sec,
                                           uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool WriteConsoleInput(IntPtr h, INPUT_RECORD[] buf, uint len, out uint written);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
}
"@

$proc = Get-Process bg3_dx11, bg3 -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) { Write-Error "BG3 is not running" }

$lines = @()
if ($File) { $lines = Get-Content -Path $File -Encoding UTF8 }
if ($Line) { $lines += $Line }
if ($lines.Count -eq 0) { Write-Error "nothing to send" }

# The console input buffer is ANSI: anything non-ASCII arrives as '?' and a Lua string
# literal containing it dies with "unfinished string near <eof>". Fail loudly instead of
# sending a line that cannot parse. Russian text belongs inside the .lua file, which is
# read as UTF-8 by Ext.IO.LoadFile.
foreach ($l in $lines) {
    if ($l -match '[^\x00-\x7F]') {
        Write-Error "non-ASCII in console line (would be mangled to '?'): $l"
    }
}

$null = [ConIn]::FreeConsole()
if (-not [ConIn]::AttachConsole([uint32]$proc.Id)) {
    Write-Error "AttachConsole failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
}

# GENERIC_READ | GENERIC_WRITE — written as a decimal literal because PS 5.1
# parses 0x80000000 as a negative Int32.
$access        = [uint32]3221225472
$FILE_SHARE_RW = [uint32]3
$OPEN_EXISTING = [uint32]3
$hIn = [ConIn]::CreateFile("CONIN$", $access, $FILE_SHARE_RW,
                           [IntPtr]::Zero, $OPEN_EXISTING, [uint32]0, [IntPtr]::Zero)
if ($hIn -eq [IntPtr]::Zero -or $hIn -eq (New-Object IntPtr -1)) {
    [void][ConIn]::FreeConsole()
    Write-Error "CreateFile(CONIN$) failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
}

function Send-Char([char]$c, [uint16]$vk) {
    $recs = New-Object INPUT_RECORD[] 2
    for ($i = 0; $i -lt 2; $i++) {
        $r = New-Object INPUT_RECORD
        $r.EventType = 1
        $k = New-Object KEY_EVENT_RECORD
        $k.bKeyDown = ($i -eq 0)
        $k.wRepeatCount = 1
        $k.wVirtualKeyCode = $vk
        $k.wVirtualScanCode = 0
        $k.UnicodeChar = $c
        $k.dwControlKeyState = 0
        $r.KeyEvent = $k
        $recs[$i] = $r
    }
    $written = 0
    [void][ConIn]::WriteConsoleInput($hIn, $recs, 2, [ref]$written)
}

foreach ($l in $lines) {
    foreach ($ch in $l.ToCharArray()) { Send-Char $ch 0 }
    Send-Char ([char]13) 13
    Start-Sleep -Milliseconds $DelayMs
}

[void][ConIn]::CloseHandle($hIn)
[void][ConIn]::FreeConsole()
