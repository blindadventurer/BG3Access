# Is there a game controller on this machine?
#
# The layer reads the game's *controller* interface - the screens whose names end in `_c` - and
# BG3 only raises those when it sees a pad. Without one the install is flawless and the game is
# silent, which to the person it happens to is the same thing as broken. The installer used to
# say "plug in a controller" to everybody, having checked nothing; this is what lets it say
# something true instead, and what puts a line about it in status.bat, where the question is
# actually asked - the silence turns up an evening later, not during the install.
#
# XInput first. A slot that answers ERROR_SUCCESS has a pad in it, and that is the one
# authoritative answer for the controllers most people own. It is not the whole truth: a
# DualSense speaks its own protocol and BG3 reaches it through SDL, not XInput. So a miss falls
# through to asking Windows which HID game controllers it knows about, and a miss on both is
# reported as "none found" - never as "you do not have one". A false negative here costs a
# sentence; a false positive costs somebody their evening.
#
# Usage: powershell -File find-controller.ps1        one line per pad, or nothing
#        $pad = & tools\find-controller.ps1          from another script

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# Guarded: Add-Type throws if the type is already defined, and this script can be dot-sourced
# more than once in a session that calls both the installer and the status check.
if (-not ("BG3Pad" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class BG3Pad {
    // XINPUT_STATE is a DWORD packet number followed by a 12-byte XINPUT_GAMEPAD. Nothing here
    // reads it - only the return code matters - so it is passed as bytes rather than described.
    [DllImport("xinput1_4.dll",   EntryPoint = "XInputGetState")] static extern int G14(int i, byte[] s);
    [DllImport("xinput9_1_0.dll", EntryPoint = "XInputGetState")] static extern int G91(int i, byte[] s);

    // 1_4 ships with Windows 8 and later; 9_1_0 has been there since Vista and is the fallback
    // rather than the first choice because it reports a smaller set of buttons. Neither present
    // means no XInput at all, which is worth telling apart from "present and empty".
    public static int Slots() {
        byte[] s = new byte[16];
        int found = 0;
        for (int i = 0; i < 4; i++) {
            int r;
            try { r = G14(i, s); }
            catch { try { r = G91(i, s); } catch { return -1; } }
            if (r == 0) found++;
        }
        return found;
    }
}
"@
}

$hits = @()

$slots = -1
try { $slots = [BG3Pad]::Slots() } catch { }
for ($i = 1; $i -le $slots; $i++) { $hits += "XInput controller $i" }

# Only asked when XInput came up empty: enumerating PnP costs a second or two, and the answer it
# gives is a guess off a device name. A pad that XInput already found is not worth guessing about.
#
# Whole phrases, never the bare word "controller", and that is measured rather than careful.
# This machine reports 37 HID devices, two of which match on "controller": the pad, named
# "HID-compliant game controller", and "HID-compliant system controller", which is the power
# button. Matching the bare word would have answered "a controller is connected" on a machine
# with no pad in it at all - the one direction this check must not be wrong in, since the whole
# point of it is to warn somebody who is about to hear nothing.
$PAD_NAMES = "(?i)game ?pad|game controller|joystick|wireless controller|pro controller|" +
             "dualsense|dualshock|xbox"
if ($hits.Count -eq 0) {
    try {
        foreach ($d in (Get-CimInstance Win32_PnPEntity -Filter "PNPClass='HIDClass'" -ErrorAction Stop)) {
            $n = "" + $d.Name
            if ($n -match $PAD_NAMES) { $hits += $n.Trim() }
        }
    } catch { }
}

# Nothing on stdout when there is nothing found, the same as find-game.ps1: the caller says the
# miss in its own words, which are better than any this file could write not knowing who asked.
$hits | Select-Object -Unique
