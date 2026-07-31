# Send real keyboard input to the game.
#
# Ext.ClientInput.InjectKeyPress does not reach Noesis: with a combo box open and focused
# it left SelectedIndex untouched, and it never raises Ext.Events.KeyInput either (E1), so
# it cannot be used to drive the interface or to test bindings. What the game does honour
# is input that arrives the way a user's does, which is what SendInput produces.
#
# Scancodes rather than virtual keys: BG3 reads the keyboard through raw input, and a
# virtual-key-only event is ignored by that path while the Noesis layer still sees it -
# a difference that shows up as "the menu highlight moves but the game does not".
#
# The window must be foreground (focus-game.ps1) or the events go elsewhere.
#
# ASCII only: PS 5.1 reads .ps1 as ANSI and the Write tool emits UTF-8 without a BOM.
#
# Usage: powershell -File keys.ps1 -Key ESCAPE
#        powershell -File keys.ps1 -Key DOWN -Repeat 3 -DelayMs 120
#        powershell -File keys.ps1 -Keys "DOWN,DOWN,RETURN"

param(
    [string]$Key,
    [string]$Keys,
    [int]$Repeat = 1,
    [int]$DelayMs = 90,
    [int]$HoldMs = 40
)

$ErrorActionPreference = "Stop"

Add-Type @"
using System;
using System.Runtime.InteropServices;

public class Keyb {
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT {
        public ushort wVk; public ushort wScan; public uint dwFlags;
        public uint time; public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT {
        public uint type;
        public KEYBDINPUT ki;
        // The union is as wide as MOUSEINPUT on x64; pad so the marshalled size matches.
        public int pad1; public int pad2;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint n, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint mapType);

    const uint INPUT_KEYBOARD  = 1;
    const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    const uint KEYEVENTF_KEYUP       = 0x0002;
    const uint KEYEVENTF_SCANCODE    = 0x0008;
    const uint MAPVK_VK_TO_VSC = 0;

    public static uint Send(ushort vk, bool extended, bool up) {
        ushort scan = (ushort)MapVirtualKey(vk, MAPVK_VK_TO_VSC);
        uint flags = KEYEVENTF_SCANCODE;
        if (extended) flags |= KEYEVENTF_EXTENDEDKEY;
        if (up) flags |= KEYEVENTF_KEYUP;

        INPUT[] inp = new INPUT[1];
        inp[0].type = INPUT_KEYBOARD;
        inp[0].ki.wVk = 0;                 // ignored when SCANCODE is set
        inp[0].ki.wScan = scan;
        inp[0].ki.dwFlags = flags;
        inp[0].ki.time = 0;
        inp[0].ki.dwExtraInfo = IntPtr.Zero;
        return SendInput(1, inp, Marshal.SizeOf(typeof(INPUT)));
    }
}
"@

# Virtual-key codes. The extended flag matters for the grey navigation block: without it
# the arrows arrive as their numeric-keypad twins.
$VK = @{
    ESCAPE = 0x1B; RETURN = 0x0D; ENTER = 0x0D; SPACE = 0x20; TAB = 0x09
    BACK = 0x08; DELETE = 0x2E; HOME = 0x24; END = 0x23
    LEFT = 0x25; UP = 0x26; RIGHT = 0x27; DOWN = 0x28
    PAGEUP = 0x21; PAGEDOWN = 0x22; INSERT = 0x2D
    F1 = 0x70; F2 = 0x71; F3 = 0x72; F4 = 0x73; F5 = 0x74; F6 = 0x75
    F7 = 0x76; F8 = 0x77; F9 = 0x78; F10 = 0x79; F11 = 0x7A; F12 = 0x7B
    A = 0x41; B = 0x42; C = 0x43; D = 0x44; E = 0x45; F = 0x46; G = 0x47
    H = 0x48; I = 0x49; J = 0x4A; K = 0x4B; L = 0x4C; M = 0x4D; N = 0x4E
    O = 0x4F; P = 0x50; Q = 0x51; R = 0x52; S = 0x53; T = 0x54; U = 0x55
    V = 0x56; W = 0x57; X = 0x58; Y = 0x59; Z = 0x5A
    D0 = 0x30; D1 = 0x31; D2 = 0x32; D3 = 0x33; D4 = 0x34
    D5 = 0x35; D6 = 0x36; D7 = 0x37; D8 = 0x38; D9 = 0x39
}
$EXTENDED = @("LEFT","UP","RIGHT","DOWN","PAGEUP","PAGEDOWN","HOME","END","INSERT","DELETE")

function Press([string]$name) {
    $n = $name.Trim().ToUpper()
    if (-not $VK.ContainsKey($n)) { Write-Error "unknown key: $n" }
    $vk = [uint16]$VK[$n]         # PS has no [ushort] alias
    $ext = $EXTENDED -contains $n
    [void][Keyb]::Send($vk, $ext, $false)
    Start-Sleep -Milliseconds $HoldMs
    [void][Keyb]::Send($vk, $ext, $true)
    "sent $n"
}

$list = @()
if ($Keys) { $list = $Keys.Split(',') }
elseif ($Key) { for ($i = 0; $i -lt $Repeat; $i++) { $list += $Key } }
else { Write-Error "need -Key or -Keys" }

foreach ($k in $list) {
    Press $k
    Start-Sleep -Milliseconds $DelayMs
}
