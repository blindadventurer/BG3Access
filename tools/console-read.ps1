# Read the tail of the BG3 Script Extender console.
#
# console-send.ps1 pushes Lua in but says nothing about the result, so a Lua error
# used to be invisible from outside. This attaches to the same console and reads its
# screen buffer directly, which is the only feedback channel that needs no file I/O
# from the game side.
#
# ASCII only on purpose: the Write tool emits UTF-8 without a BOM and PS 5.1 reads
# .ps1 as ANSI, which turns any dash or quote into a stray string delimiter.
#
# Usage: powershell -File console-read.ps1 -Lines 40

param([int]$Lines = 40)

$ErrorActionPreference = "Stop"

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)]
public struct SMALL_RECT { public short Left, Top, Right, Bottom; }

[StructLayout(LayoutKind.Sequential)]
public struct CONSOLE_SCREEN_BUFFER_INFO {
    public int    dwSize;              // COORD packed as two shorts
    public int    dwCursorPosition;
    public ushort wAttributes;
    public SMALL_RECT srWindow;
    public int    dwMaximumWindowSize;
}

public class ConOut {
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sec,
                                           uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CONSOLE_SCREEN_BUFFER_INFO i);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool ReadConsoleOutputCharacterW(IntPtr h, StringBuilder buf, uint len,
                                                          int coord, out uint read);

    public static short Lo(int packed) { return (short)(packed & 0xFFFF); }
    public static short Hi(int packed) { return (short)((packed >> 16) & 0xFFFF); }
    public static int Coord(short x, short y) { return (y << 16) | (x & 0xFFFF); }
}
"@

$proc = Get-Process bg3_dx11, bg3 -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) { Write-Error "BG3 is not running" }

$null = [ConOut]::FreeConsole()
if (-not [ConOut]::AttachConsole([uint32]$proc.Id)) {
    Write-Error "AttachConsole failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
}

$access        = [uint32]3221225472    # GENERIC_READ | GENERIC_WRITE as decimal, see console-send.ps1
$FILE_SHARE_RW = [uint32]3
$OPEN_EXISTING = [uint32]3
$h = [ConOut]::CreateFile("CONOUT$", $access, $FILE_SHARE_RW,
                          [IntPtr]::Zero, $OPEN_EXISTING, [uint32]0, [IntPtr]::Zero)
if ($h -eq [IntPtr]::Zero -or $h -eq (New-Object IntPtr -1)) {
    [void][ConOut]::FreeConsole()
    Write-Error "CreateFile(CONOUT$) failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
}

$info = New-Object CONSOLE_SCREEN_BUFFER_INFO
if (-not [ConOut]::GetConsoleScreenBufferInfo($h, [ref]$info)) {
    [void][ConOut]::CloseHandle($h); [void][ConOut]::FreeConsole()
    Write-Error "GetConsoleScreenBufferInfo failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
}

$width  = [ConOut]::Lo($info.dwSize)
$curY   = [ConOut]::Hi($info.dwCursorPosition)
$first  = [Math]::Max(0, $curY - $Lines + 1)

$out = New-Object System.Collections.Generic.List[string]
for ($y = $first; $y -le $curY; $y++) {
    $sb = New-Object System.Text.StringBuilder ($width + 1)
    $read = 0
    $coord = [ConOut]::Coord(0, [int16]$y)   # PS has no [short] alias
    if ([ConOut]::ReadConsoleOutputCharacterW($h, $sb, [uint32]$width, $coord, [ref]$read)) {
        $out.Add($sb.ToString(0, [int]$read).TrimEnd())
    }
}

[void][ConOut]::CloseHandle($h)
[void][ConOut]::FreeConsole()

# Drop the run of blank lines below the last real output.
$text = ($out -join "`n").TrimEnd()
if ($text) { $text } else { "<console buffer empty>" }
