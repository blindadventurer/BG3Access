# Speech companion for the BG3 accessibility layer — port P5.
#
# The game cannot talk to a screen reader from Lua, so it writes what should be
# spoken into a bridge file (measured at 0.49 ms median, probe E6) and this
# process picks it up and hands it to prism.dll, which talks to NVDA/JAWS itself.
#
# Usage: powershell -File speak.ps1 -Text 'проверка'      one-shot, prints backend
#        powershell -File speak.ps1 -Watch                companion loop
#
# The companion loop is what tools\install-speech-service.ps1 puts in Startup: it is the half
# of the mod that cannot live inside the game, so it has to come up with the machine and wait
# for the game rather than be started by hand next to it.
#
# Bridge format, one file rewritten per utterance:
#     <seq>|<0|1 interrupt>|<text>
# seq is a monotonic counter from the game side; text may contain newlines.

param(
    [string]$Text,
    [switch]$Watch,
    [string]$BridgeFile = (Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Script Extender\A11y\speech.txt"),
    [int]$PollMs = 10
)

$ErrorActionPreference = "Stop"

# Spoken text is Russian; without this the log written by a redirected stdout comes
# out as mojibake and every debugging session starts with a false alarm.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class Prism {
    // Values taken from prism.h v0.16.7. Note these do NOT match the enum in
    // jerian-access/src/JerianAccess/Speech/PrismNative.cs, which is from an older
    // prism — anything comparing against those names there mislabels the code.
    public enum Err : int {
        Ok = 0, NotInitialized = 1, InvalidParam = 2, NotImplemented = 3,
        NoVoices = 4, VoiceNotFound = 5, SpeakFailure = 6, MemoryFailure = 7,
        RangeOutOfBounds = 8, Internal = 9, NotSpeaking = 10, NotPaused = 11,
        AlreadyPaused = 12, InvalidUtf8 = 13, InvalidOperation = 14,
        AlreadyInitialized = 15, BackendNotAvailable = 16, Unknown = 17,
        InvalidAudioFormat = 18, InternalBackendLimitExceeded = 19,
        BackendEnteredUndefinedState = 20,
    }

    const ulong FeatSupportsOutput = 1UL << 5;

    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr LoadLibraryW(string path);

    [DllImport("prism", EntryPoint = "prism_init")]
    static extern IntPtr NInit(IntPtr cfg);
    [DllImport("prism", EntryPoint = "prism_shutdown")]
    static extern void NShutdown(IntPtr ctx);
    [DllImport("prism", EntryPoint = "prism_registry_create_best")]
    static extern IntPtr NCreateBest(IntPtr ctx);
    [DllImport("prism", EntryPoint = "prism_backend_initialize")]
    static extern Err NBackendInit(IntPtr b);
    [DllImport("prism", EntryPoint = "prism_backend_free")]
    static extern void NBackendFree(IntPtr b);
    [DllImport("prism", EntryPoint = "prism_backend_get_features")]
    static extern ulong NFeatures(IntPtr b);
    [DllImport("prism", EntryPoint = "prism_backend_name")]
    static extern IntPtr NName(IntPtr b);
    [DllImport("prism", EntryPoint = "prism_backend_speak")]
    static extern Err NSpeak(IntPtr b, byte[] utf8, [MarshalAs(UnmanagedType.I1)] bool interrupt);
    [DllImport("prism", EntryPoint = "prism_backend_output")]
    static extern Err NOutput(IntPtr b, byte[] utf8, [MarshalAs(UnmanagedType.I1)] bool interrupt);
    [DllImport("prism", EntryPoint = "prism_backend_stop")]
    static extern Err NStop(IntPtr b);

    static IntPtr _ctx, _backend;
    static ulong _features;

    public static string BackendName;

    // Preloading by full path puts "prism.dll" in the loader's module list, so the
    // DllImport("prism") entries above bind to it without touching PATH.
    public static string Open(string dllPath) {
        if (LoadLibraryW(dllPath) == IntPtr.Zero)
            return "LoadLibrary failed: " + Marshal.GetLastWin32Error();

        _ctx = NInit(IntPtr.Zero);
        if (_ctx == IntPtr.Zero) return "prism_init returned NULL";

        _backend = NCreateBest(_ctx);
        if (_backend == IntPtr.Zero) { Close(); return "no usable backend on this machine"; }

        // create_best may already have initialized it; only a real failure matters.
        Err e = NBackendInit(_backend);
        if (e != Err.Ok && e != Err.AlreadyInitialized) { Close(); return "backend_initialize -> " + e; }

        _features = NFeatures(_backend);
        BackendName = Utf8FromPtr(NName(_backend));
        return null;
    }

    public static string Say(string text, bool interrupt) {
        if (_backend == IntPtr.Zero) return "not open";
        byte[] u = Utf8(text);
        // output drives speech and braille together where the backend has it.
        if ((_features & FeatSupportsOutput) != 0) {
            Err e = NOutput(_backend, u, interrupt);
            if (e == Err.Ok) return null;
            if (e != Err.NotImplemented) return "output -> " + e;
        }
        Err s = NSpeak(_backend, u, interrupt);
        return s == Err.Ok ? null : "speak -> " + s;
    }

    public static void Close() {
        if (_backend != IntPtr.Zero) { try { NStop(_backend); } catch {} NBackendFree(_backend); _backend = IntPtr.Zero; }
        if (_ctx != IntPtr.Zero) { NShutdown(_ctx); _ctx = IntPtr.Zero; }
        _features = 0;
    }

    static byte[] Utf8(string s) {
        int n = Encoding.UTF8.GetByteCount(s);
        byte[] buf = new byte[n + 1];               // native side wants NUL-terminated
        Encoding.UTF8.GetBytes(s, 0, s.Length, buf, 0);
        return buf;
    }

    static string Utf8FromPtr(IntPtr p) {
        if (p == IntPtr.Zero) return null;
        int n = 0;
        while (Marshal.ReadByte(p, n) != 0) n++;
        byte[] b = new byte[n];
        Marshal.Copy(p, b, 0, n);
        return Encoding.UTF8.GetString(b);
    }
}
"@

$dll = Join-Path $PSScriptRoot "prism.dll"
if (-not (Test-Path $dll)) { Write-Error "prism.dll not found next to this script" }

function Open-Prism {
    $err = [Prism]::Open($dll)
    if ($err) { Write-Host "! prism: $err"; return $false }
    Write-Host "backend: $([Prism]::BackendName)"
    return $true
}

# Share the handle: ReadAllText takes an exclusive-ish lock, and at a 10 ms poll it regularly
# collided with the game's write, which then failed outright ("Could not open file for
# writing") and the utterance was lost with no sign of it on this side.
function Read-Bridge {
    if (-not (Test-Path $BridgeFile)) { return $null }
    $raw = $null
    try {
        $fs = [System.IO.File]::Open($BridgeFile,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        try {
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
            $raw = $sr.ReadToEnd()
        } finally { $fs.Dispose() }
    } catch {
        return $null     # half-written file: the game rewrites it whole, retry next tick
    }
    $parts = $raw.Split([char]'|', 3)
    if ($parts.Count -ne 3) { return $null }
    return ,$parts
}

try {
    if ($Text -or -not $Watch) {
        if (-not (Open-Prism)) { exit 1 }
        if ($Text) {
            $e = [Prism]::Say($Text, $true)
            if ($e) { Write-Error "prism: $e" }
            Write-Host "spoken: $Text"
        }
    }

    if ($Watch) {
        # One companion, and no way to have two.
        #
        # There are three places a companion can now be started from - the launcher in Startup,
        # an install, and the shortcut that starts the game - and two of them can fire within a
        # second of each other. Two processes polling the same bridge means every line spoken
        # twice, which is a worse failure than either of the ones they guard against. A mutex is
        # the only check here that cannot race: whoever creates it is the companion, and anyone
        # who finds it taken says so and leaves.
        #
        # An abandoned mutex is the previous companion having been killed rather than having
        # released it - which is exactly the state this machine was found in, and it means the
        # job is vacant.
        $mutex = New-Object System.Threading.Mutex($false, "Local\BG3AccessSpeechCompanion")
        $mine  = $false
        try { $mine = $mutex.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] { $mine = $true }
        if (-not $mine) {
            Write-Host "another companion is already running - leaving it to it"
            exit 0
        }

        New-Item -ItemType Directory -Force (Split-Path $BridgeFile) | Out-Null
        Write-Host "watching: $BridgeFile  (poll ${PollMs} ms while the game runs, Ctrl+C to stop)"

        # This loop is meant to sit in the user's session from logon to shutdown, so it does
        # nothing at all while the game is closed: no file reads, and a poll a thousand times
        # slower. The process list is what it watches instead, and only once a second - at the
        # 10 ms speech poll, enumerating processes would cost more than everything else here.
        $lastSeq   = ""
        $gameWas   = $false
        $open      = $false
        $nextProbe = [datetime]::MinValue

        while ($true) {
            $now = Get-Date
            if ($now -ge $nextProbe) {
                $nextProbe = $now.AddSeconds(1)
                $gameNow = [bool](Get-Process bg3_dx11, bg3 -ErrorAction SilentlyContinue)

                if ($gameNow -ne $gameWas) {
                    [Prism]::Close()
                    $open = $false
                    if ($gameNow) {
                        # The backend is chosen here rather than at logon on purpose: the
                        # screen reader is usually started after the machine comes up, and a
                        # backend picked before NVDA exists stays SAPI for the whole session.
                        # Whatever the bridge holds right now is the tail of the last session,
                        # so it is remembered, not spoken.
                        $p = Read-Bridge
                        if ($p) { $lastSeq = $p[0] }
                        Write-Host "game up"
                    } else {
                        Write-Host "game gone - idle"
                    }
                    $gameWas = $gameNow
                }
                if ($gameNow -and -not $open) { $open = Open-Prism }
            }

            if ($gameWas -and $open) {
                $parts = Read-Bridge
                if ($parts -and $parts[0] -ne $lastSeq) {
                    $lastSeq = $parts[0]
                    $interrupt = $parts[1].Trim() -ne "0"
                    $body = $parts[2].Trim()
                    if ($body) {
                        $e = [Prism]::Say($body, $interrupt)
                        if ($e) { Write-Host "! $e" }
                        Write-Host "[$lastSeq] $body"
                    }
                }
            }

            if ($gameWas) { Start-Sleep -Milliseconds $PollMs } else { Start-Sleep -Milliseconds 1000 }
        }
    }
}
finally {
    [Prism]::Close()
    if ($mutex) { try { $mutex.ReleaseMutex() } catch { } ; $mutex.Dispose() }
}
