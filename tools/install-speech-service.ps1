# Make the speech companion come up with the machine.
#
# The game cannot talk to a screen reader from Lua - it writes utterances into a bridge file
# and something outside has to pick them up (port P5). That something is speak.ps1 -Watch,
# and until now it was started by hand next to every play session, which is exactly the kind
# of step that turns "the mod is silent" into a mystery. Here it goes into the user's Startup
# folder instead: it costs a 1 Hz process check while the game is closed and wakes into the
# 10 ms poll when the game appears.
#
# No admin rights and no scheduled task: a .vbs in Startup is the one launcher that starts
# a PowerShell loop with no console window flashing on the screen at every logon.
#
# The launcher holds an absolute path to speak.ps1, so the companion is copied somewhere it can
# keep pointing at. A player unpacks a ZIP into Downloads, installs, plays for a month and then
# tidies Downloads out - and at the next logon speech is gone with no error anywhere, because
# the thing that would have reported it is the thing that did not start. The copy lives in
# %LOCALAPPDATA%\BG3Access, which nothing else has a reason to clean up. -InPlace keeps the old
# behaviour, pointing at the working copy, which is what a development machine wants.
#
# Startup is not the only moment that matters, and it took a week of silence to notice. It fires
# at logon and nowhere else, so a companion that dies mid-session stays dead until the next one -
# and nothing reports it, because the thing that would have reported it is the thing that is
# gone. -GameExe writes a second launcher, "Play BG3.vbs", which brings the companion up if it
# is missing and then starts the game; that is what the Desktop shortcut points at.
#
# Usage: powershell -File install-speech-service.ps1
#        powershell -File install-speech-service.ps1 -GameExe "...\bin\bg3_dx11.exe"
#        powershell -File install-speech-service.ps1 -InPlace
#        powershell -File install-speech-service.ps1 -Uninstall

param(
    [switch]$Uninstall,
    [switch]$InPlace,
    [string]$GameExe        # write a play launcher that starts the companion, then this
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$srcSpeak = Join-Path $PSScriptRoot "speak.ps1"
$srcPrism = Join-Path $PSScriptRoot "prism.dll"
$installed = Join-Path $env:LOCALAPPDATA "BG3Access"
$startup = [Environment]::GetFolderPath("Startup")
$vbs     = Join-Path $startup "BG3 Access Speech.vbs"
$play    = Join-Path $installed "Play BG3.vbs"
$log     = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Script Extender\A11y\speech-companion.log"

function Stop-Companion {
    $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
             Where-Object { $_.CommandLine -like "*speak.ps1*-Watch*" }
    foreach ($p in $procs) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host "stopped companion pid $($p.ProcessId)"
    }
}

# Stop-Process returns before the process is gone, and the handles it holds outlive it by a
# moment more - so the copy that follows it can still land on a locked file. Two seconds of
# retries rather than one attempt, and the last attempt is left to throw with the real message.
function Copy-WhenFreed($src, $dst) {
    for ($i = 1; $i -le 10; $i++) {
        try { Copy-Item $src $dst -Force ; return } catch { Start-Sleep -Milliseconds 200 }
    }
    Copy-Item $src $dst -Force
}

# Byte-for-byte the same file already in place? Then there is nothing to copy, and nothing to
# stop the companion for. This is the whole difference between "run install.bat again" being a
# safe thing to advise and it being the thing that turns speech off.
function Test-SameFile($src, $dst) {
    if (-not (Test-Path $dst)) { return $false }
    if ((Get-Item $src).Length -ne (Get-Item $dst).Length) { return $false }
    return (Get-FileHash $src -Algorithm SHA256).Hash -eq (Get-FileHash $dst -Algorithm SHA256).Hash
}

if ($Uninstall) {
    Stop-Companion
    if (Test-Path $vbs) { Remove-Item $vbs -Force; Write-Host "removed $vbs" }
    else { Write-Host "nothing installed at $vbs" }
    # Only ever written by this script, so it goes whole. The bridge file and the log live
    # elsewhere, under the Script Extender - uninstall.ps1 deals with those, by name.
    if (Test-Path $installed) { Remove-Item $installed -Recurse -Force; Write-Host "removed $installed" }
    return
}

if (-not (Test-Path $srcSpeak)) { Write-Error "speak.ps1 not found at $srcSpeak" }
if (-not (Test-Path $srcPrism)) {
    Write-Error "prism.dll not found next to speak.ps1 - the companion would have nothing to speak with"
}

# Where the launcher is going to point. Decided before anything is moved, so that building the
# launcher - pure string work, which cannot fail halfway - happens before the part that can.
# Copied, not linked, and the DLL with it: speak.ps1 loads prism.dll from its own folder.
$speak = if ($InPlace) { $srcSpeak } else { Join-Path $installed "speak.ps1" }

New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null

# -Command rather than -File so PowerShell does the redirect itself: wrapping it in cmd just
# to get one would mean a second layer of quoting for no gain. Single quotes inside keep the
# only double quotes in the string the outer pair, which VBS then wants doubled.
#
# The log is truncated at every logon on purpose - it is a diagnostic for the session in
# progress, not a history; the transcript of what was actually spoken is speech-log.txt.
#
# Both paths get their apostrophes doubled first: the log sits under "Baldur's Gate 3", and
# a lone apostrophe closes the PowerShell string it is quoted in - the first build of this
# launcher died on exactly that, silently, because the window it would have complained in is
# hidden by design.
$inner  = "& '{0}' -Watch *> '{1}'" -f ($speak -replace "'", "''"), ($log -replace "'", "''")
$cmd    = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ""$inner"""
$vbsCmd = $cmd -replace '"', '""'

$body = @"
' Starts the BG3 accessibility speech companion, hidden, at logon.
' Written by tools\install-speech-service.ps1 - edit that, not this.
Set sh = CreateObject("WScript.Shell")
sh.Run "$vbsCmd", 0, False
"@

# The second place a companion can come from, and the reason it needed one.
#
# Startup fires at logon and nowhere else. A machine that has not been logged off in a week has
# had exactly one chance to start the companion, and if that one was cut short - an install that
# did not reach its last line, anything at all that killed the process - the game comes up every
# evening after that, writes every line it has to say into the bridge, and there is nobody on
# the other end. Nothing anywhere says so, and the player this is for cannot see silence.
#
# So the other moment it matters gets a launcher too: starting the game. That is what the
# Desktop shortcut points at now - the companion if it is missing, then the game.
#
# Appended to the log rather than truncating it: this one runs while a session may already be
# under way, and the log of the companion that is actually working is the diagnostic.
$playBody = $null
if (-not [string]::IsNullOrWhiteSpace($GameExe)) {
    if (-not (Test-Path $GameExe)) { Write-Error "no game executable at $GameExe" }
    $gameDirBin = Split-Path $GameExe

$playInner = "& '{0}' -Watch *>> '{1}'" -f ($speak -replace "'", "''"), ($log -replace "'", "''")
$playCmd   = ("powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ""$playInner""") -replace '"', '""'

# Asking first is only to keep that log intact. Starting a second companion is harmless in
# itself - speak.ps1 takes a mutex and the loser leaves without reading the bridge - so if WMI
# is unavailable this falls through to starting one, which is the right way round to be wrong.
$playBody = @"
' Starts Baldur's Gate 3, with something listening to it.
' Written by tools\install-speech-service.ps1 - edit that, not this.
Set sh = CreateObject("WScript.Shell")

alive = False
On Error Resume Next
Set wmi = GetObject("winmgmts:\\.\root\cimv2")
If Err.Number = 0 Then
  Set procs = wmi.ExecQuery("SELECT CommandLine FROM Win32_Process WHERE Name = 'powershell.exe' OR Name = 'pwsh.exe'")
  For Each p In procs
    If Not IsNull(p.CommandLine) Then
      If InStr(p.CommandLine, "speak.ps1") > 0 And InStr(p.CommandLine, "-Watch") > 0 Then alive = True
    End If
  Next
End If
Err.Clear
On Error Goto 0

If Not alive Then sh.Run "$playCmd", 0, False

sh.CurrentDirectory = "$gameDirBin"
sh.Run """$GameExe""", 1, False
"@
}

# Nothing above this line has touched the running companion, and that is the fix.
#
# It has to be stopped to replace the files under it - a running companion holds prism.dll
# open and Windows will not let a loaded DLL be overwritten, which is a real constraint and
# was found the hard way. What that argument left out is that on the re-install PLAYING.md
# actually advises - "if speech goes quiet, run install.bat again" - the bytes already in
# place are identical and there is nothing to replace at all. Stopping for it anyway opened a
# window forty lines wide in which the machine has no speech, and an install that does not
# reach its last line leaves it that way.
#
# Which is exactly how this machine went quiet: a test run of the setup exe was cut short
# inside that window, and the launcher in Startup only fires at logon - eight days earlier.
# The game came up every evening after that, wrote every line it had to say into the bridge
# file, and there was nobody on the other end of it. Nothing anywhere said so.
#
# So the copy is skipped when the files match, the stop happens only for a copy that is really
# going to happen, and the restart sits in a finally: the one state this script must never
# exit in is silence.
$stopped = $false
try {
    if (-not $InPlace) {
        New-Item -ItemType Directory -Force $installed | Out-Null
        $dstPrism = Join-Path $installed "prism.dll"
        if ((Test-SameFile $srcSpeak $speak) -and (Test-SameFile $srcPrism $dstPrism)) {
            Write-Host "companion already current in $installed"
        } else {
            Stop-Companion
            $stopped = $true
            Copy-WhenFreed $srcSpeak $speak
            Copy-WhenFreed $srcPrism $dstPrism
            Write-Host "companion copied to $installed"
        }
    }

    Set-Content -Path $vbs -Value $body -Encoding ASCII
    Write-Host "installed $vbs"

    if ($playBody) {
        New-Item -ItemType Directory -Force $installed | Out-Null
        Set-Content -Path $play -Value $playBody -Encoding ASCII
        Write-Host "installed $play"
    }
}
finally {
    # Back to back, and last. The stop is what keeps it to one companion rather than two, and
    # it finds nothing when the copy above has already done it - so on the common re-install
    # the gap between having speech and having it back is these two lines and nothing else.
    #
    # An old launcher is started in preference to none: it points at a speak.ps1 that worked
    # yesterday, which beats leaving the machine mute over a file that failed to be written.
    if (Test-Path $vbs) {
        Stop-Companion
        & wscript.exe $vbs
    } elseif ($stopped) {
        Write-Warning "no launcher was written and the companion is stopped - this machine has no speech"
        Write-Warning "    powershell -File `"$speak`" -Watch"
    }
}
Start-Sleep -Milliseconds 1500

$running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
           Where-Object { $_.CommandLine -like "*speak.ps1*-Watch*" }
if ($running) {
    Write-Host "companion running, pid $($running[0].ProcessId)"
    Write-Host "log: $log"
} else {
    Write-Warning "companion did not come up - run it in the foreground to see why:"
    Write-Warning "    powershell -File `"$speak`" -Watch"
}
