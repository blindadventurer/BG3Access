# Make the speech companion come up with the machine, and come back when it dies.
#
# The game cannot talk to a screen reader from Lua - it writes utterances into a bridge file
# and something outside has to pick them up (port P5). That something is speak.ps1 -Watch,
# and until now it was started by hand next to every play session, which is exactly the kind
# of step that turns "the mod is silent" into a mystery. Here it goes into the user's Startup
# folder instead: it costs a 1 Hz process check while the game is closed and wakes into the
# 10 ms poll when the game appears.
#
# No admin rights and no console window: a .vbs is the one launcher that starts a PowerShell
# loop with nothing flashing on the screen, so all three launchers written here are .vbs and
# the scheduled task below runs one of them rather than powershell.exe directly.
#
# The launcher holds an absolute path to speak.ps1, so the companion is copied somewhere it can
# keep pointing at. A player unpacks a ZIP into Downloads, installs, plays for a month and then
# tidies Downloads out - and at the next logon speech is gone with no error anywhere, because
# the thing that would have reported it is the thing that did not start. The copy lives in
# %LOCALAPPDATA%\BG3Access, which nothing else has a reason to clean up. -InPlace keeps the old
# behaviour, pointing at the working copy, which is what a development machine wants.
#
# Three moments can start it, and it took two separate silences to find all three:
#
#   Startup      logon, and nowhere else.
#   Play BG3     the Desktop shortcut, which is one way in among several.
#   the watchdog  every minute, from the Task Scheduler service, whatever killed the last one.
#
# Usage: powershell -File install-speech-service.ps1
#        powershell -File install-speech-service.ps1 -GameExe "...\bin\bg3_dx11.exe"
#        powershell -File install-speech-service.ps1 -InPlace
#        powershell -File install-speech-service.ps1 -NoWatchdog
#        powershell -File install-speech-service.ps1 -Uninstall

param(
    [switch]$Uninstall,
    [switch]$InPlace,
    [string]$GameExe,       # write a play launcher that starts the companion, then this
    [switch]$NoWatchdog     # do not register the scheduled task that restarts a dead companion
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$srcSpeak = Join-Path $PSScriptRoot "speak.ps1"
$srcPrism = Join-Path $PSScriptRoot "prism.dll"
$installed = Join-Path $env:LOCALAPPDATA "BG3Access"
$startup = [Environment]::GetFolderPath("Startup")
$vbs     = Join-Path $startup "BG3 Access Speech.vbs"
$ensure  = Join-Path $installed "Ensure Speech.vbs"
$start   = Join-Path $installed "Start Speech.vbs"
$play    = Join-Path $installed "Play BG3.vbs"
$log     = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Script Extender\A11y\speech-companion.log"
$taskName = "BG3Access Speech"

# How a running companion is recognised, everywhere: by the shape of the command line that
# starts one, and not by the two words being in it somewhere.
#
# "*speak.ps1*-Watch*" was the old test and it is too loose to be safe. Any process whose command
# line merely mentions both - a diagnostic asking whether a companion is running, most obviously -
# answers yes to it. Which is not hypothetical: the first live test of the watchdog failed
# because the process asking "did it come back?" was itself what the launcher found and mistook
# for a companion, so it started nothing, twice, and reported the machine mute. A false yes is
# the one answer nothing downstream can recover from; a false no costs one PowerShell that finds
# the mutex taken and leaves.
#
#     & 'C:\...\speak.ps1' -Watch *>> '...'      the launchers
#     powershell -File ...\speak.ps1 -Watch      by hand
$COMPANION = 'speak\.ps1[''" ] -Watch'

function Stop-Companion {
    $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
             Where-Object { $_.CommandLine -match $COMPANION }
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

# The watchdog. A per-user task, so no administrator and no stored password: Windows lets an
# ordinary account register a task that runs as itself, which was the objection that kept this
# out for two months and turns out not to apply.
# The watchdog, and the one thing here that does not depend on the player doing anything.
#
# Both .vbs launchers are events: log in, or start the game from that one shortcut. Neither is a
# check that keeps being made. Measured on this machine on 2026-08-05: up for nine days, so
# Startup had fired exactly once; the companion was killed some time during the day - no crash
# report, no PowerShell shutdown record, so killed rather than exited - and the evening's session
# was started from Steam rather than from the shortcut. The layer ran perfectly for an hour and a
# half and wrote every line into the bridge, and nothing was reading it. status.bat is what found
# it, an hour and a half late.
#
# A watchdog cannot itself be a process, because whatever killed the companion can kill that too.
# The Task Scheduler service is already running on every Windows machine and is nobody's child -
# so the companion goes there: at logon, on unlock, and on a trigger that repeats every minute
# for as long as the machine is on.
#
# The action does not *check on* the companion, it *is* the companion - "Start Speech.vbs" waits
# on it, so the task instance and the companion share one lifetime. That is what makes the repeat
# trigger enough on its own: while it lives, every minute's trigger is refused (IgnoreNew) and
# costs nothing; the moment it dies the instance ends and the next minute starts another. There
# is no state to keep and nothing that has to notice a death.
#
# Two settings are load-bearing and neither is obvious:
#
#   ExecutionTimeLimit PT0S   no limit. The default is three days, and a task meant to run for as
#                             long as the machine is on has to say so, or the companion is killed
#                             every 72 hours and speech is gone until the minute after.
#   wscript //B               batch mode: no dialogs, ever. Without it a script host that cannot
#                             find its file puts up a message box and waits for somebody to click
#                             OK, the instance never ends, and IgnoreNew refuses every run after
#                             it. Not hypothetical: that is how this machine spent an hour with a
#                             wedged watchdog and a dialog nobody could see, while status.bat
#                             reported the task as Running.
#
# Registered from XML rather than New-ScheduledTask*: a repetition that never ends is expressed by
# leaving Duration out, and the cmdlets have no way to say that ([TimeSpan]::MaxValue is rejected
# by the service as out of range, PT99999999D).
#
# Not fatal when it fails. A machine with the Task Scheduler service off, or a policy against user
# tasks, still has the two launchers - which is where all of this was yesterday.
function Install-Watchdog {
    if ($NoWatchdog) { Write-Host "watchdog skipped (-NoWatchdog)"; return $false }
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Runs the BG3 accessibility speech companion, and starts it again within a minute if it stops. Written by BG3Access; remove it with uninstall.bat.</Description>
    <URI>\$taskName</URI>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger><Enabled>true</Enabled><UserId>$user</UserId></LogonTrigger>
    <SessionStateChangeTrigger><Enabled>true</Enabled><UserId>$user</UserId><StateChange>SessionUnlock</StateChange></SessionStateChangeTrigger>
    <TimeTrigger>
      <Enabled>true</Enabled>
      <StartBoundary>2025-01-01T00:00:00</StartBoundary>
      <Repetition><Interval>PT1M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$user</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <DisallowStartOnRemoteAppSession>false</DisallowStartOnRemoteAppSession>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>wscript.exe</Command>
      <Arguments>//B "$start"</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    try {
        Register-ScheduledTask -TaskName $taskName -Xml $xml -Force -ErrorAction Stop | Out-Null
        Write-Host "watchdog installed - '$taskName', checked every minute"
        return $true
    } catch {
        Write-Warning "the watchdog could not be registered: $($_.Exception.Message)"
        Write-Warning "    speech will still start at logon, but nothing will notice if it stops"
        return $false
    }
}

function Remove-Watchdog {
    try {
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-Host "removed scheduled task '$taskName'"
            return
        }
    } catch { }
    Write-Host "no scheduled task '$taskName'"
}

if ($Uninstall) {
    Stop-Companion
    Remove-Watchdog
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
New-Item -ItemType Directory -Force $installed | Out-Null

# -Command rather than -File so PowerShell does the redirect itself: wrapping it in cmd just
# to get one would mean a second layer of quoting for no gain. Single quotes inside keep the
# only double quotes in the string the outer pair, which VBS then wants doubled.
#
# Appended, never truncated. Every launcher writes to the same log and two of them can fire
# within a second of each other; a truncating redirect meeting a handle another PowerShell
# already holds fails to open at all, and a redirect that cannot open kills the process before
# its first line runs - silently, because the place the complaint would go is the thing that
# failed. Rotation happens in the launcher below instead, where nothing is holding the file.
#
# Both paths get their apostrophes doubled first: the log sits under "Baldur's Gate 3", and
# a lone apostrophe closes the PowerShell string it is quoted in - the first build of this
# launcher died on exactly that, silently, because the window it would have complained in is
# hidden by design.
$inner  = "& '{0}' -Watch *>> '{1}'" -f ($speak -replace "'", "''"), ($log -replace "'", "''")
$cmd    = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ""$inner"""
$vbsCmd = $cmd -replace '"', '""'

# One body, three launchers.
#
# Every one of them wants the same two things first - is a companion already running, and is
# the log big enough to throw away - and they used to want them in two slightly different
# spellings, which is how the Startup one ended up truncating a log the other one was appending
# to. $tail is the only thing that differs: for the play launcher it starts the game.
#
# Asking whether one is running is only to keep the log readable. Starting a second companion is
# harmless in itself - speak.ps1 takes a mutex and the loser leaves without reading the bridge -
# so if WMI is unavailable this falls through to starting one, which is the right way round to
# be wrong.
function New-LauncherBody([string]$what, [string]$tail, [string]$wait = "False") {
@"
' $what
' Written by tools\install-speech-service.ps1 - edit that, not this.
Set sh = CreateObject("WScript.Shell")

alive = False
On Error Resume Next
Set rx = New RegExp
rx.Pattern = "speak\.ps1[""' ] -Watch"
Set wmi = GetObject("winmgmts:\\.\root\cimv2")
If Err.Number = 0 Then
  Set procs = wmi.ExecQuery("SELECT CommandLine FROM Win32_Process WHERE Name = 'powershell.exe' OR Name = 'pwsh.exe'")
  For Each p In procs
    If Not IsNull(p.CommandLine) Then
      If rx.Test(p.CommandLine) Then alive = True
    End If
  Next
End If
Err.Clear
On Error Goto 0

If Not alive Then
  ' Nobody is holding the log at this point, which is the only moment it is safe to drop.
  On Error Resume Next
  Set fso = CreateObject("Scripting.FileSystemObject")
  If fso.FileExists("$log") Then
    If fso.GetFile("$log").Size > 4194304 Then fso.DeleteFile "$log", True
  End If
  Err.Clear
  On Error Goto 0
  sh.Run "$vbsCmd", 0, $wait
End If
$tail
"@
}

# The play launcher, and the reason it exists.
#
# Startup fires at logon and nowhere else. A machine that has not been logged off in a week has
# had exactly one chance to start the companion, and if that one was cut short - an install that
# did not reach its last line, anything at all that killed the process - the game comes up every
# evening after that, writes every line it has to say into the bridge, and there is nobody on
# the other end. Nothing anywhere says so, and the player this is for cannot see silence.
#
# So the other moment it matters gets a launcher too: starting the game. That is what the
# Desktop shortcut points at - the companion if it is missing, then the game.
$playBody = $null
if (-not [string]::IsNullOrWhiteSpace($GameExe)) {
    if (-not (Test-Path $GameExe)) { Write-Error "no game executable at $GameExe" }
    $gameDirBin = Split-Path $GameExe
    $playBody = New-LauncherBody "Starts Baldur's Gate 3, with something listening to it." @"

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

    Set-Content -Path $ensure -Value (New-LauncherBody "Starts the BG3 accessibility speech companion if nothing is listening." "") -Encoding ASCII
    Write-Host "installed $ensure"

    # The same launcher, waiting instead of returning - and the difference is the whole reason
    # the watchdog works.
    #
    # A scheduled task owns the processes its action starts. Measured here on 2026-08-05: with a
    # launcher that returned straight away, every minute's run started a companion and the
    # companion went down with the task instance that had started it - five of them in the log,
    # each one alive for as long as its wscript and no longer. Waiting turns that inside out: the
    # companion *is* the task instance, it lives as long as the task says it may (unlimited), and
    # when it dies the instance ends and the next minute's trigger starts another. Nothing has to
    # notice a death for it to be repaired.
    Set-Content -Path $start -Value (New-LauncherBody "Runs the BG3 accessibility speech companion as a scheduled task." "" "True") -Encoding ASCII
    Write-Host "installed $start"

    Set-Content -Path $vbs -Value (New-LauncherBody "Starts the BG3 accessibility speech companion, hidden, at logon." "") -Encoding ASCII
    Write-Host "installed $vbs"

    if ($playBody) {
        Set-Content -Path $play -Value $playBody -Encoding ASCII
        Write-Host "installed $play"
    }

    # Inside the try, and before the finally that starts speech, because which of the two ways to
    # start a companion is the right one depends on whether this succeeded.
    $watchdog = Install-Watchdog
}
finally {
    # Last, and always. On the common re-install nothing above stopped anything, a companion is
    # still running, and the launcher looks, sees it, and leaves it alone - so the gap between
    # having speech and having it back is zero rather than forty lines.
    #
    # The wait is not a courtesy. Stop-Process returns before the process is gone, and the
    # launcher now decides by looking for one: run it too early and it finds the corpse of the
    # companion this script just killed, concludes there is nothing to do, and leaves the
    # machine mute for a minute - or forever, on a machine where the watchdog would not
    # register. Polled rather than slept, so it costs nothing when the kill was clean.
    #
    # An old launcher is started in preference to none: it points at a speak.ps1 that worked
    # yesterday, which beats leaving the machine mute over a file that failed to be written.
    if ($stopped) {
        for ($i = 1; $i -le 30; $i++) {
            $left = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
                    Where-Object { $_.CommandLine -match $COMPANION }
            if (-not $left) { break }
            Start-Sleep -Milliseconds 100
        }
    }
    # Through the task when there is one, and not merely because it is tidier: a companion this
    # script starts itself is this script's child, and a child outlives its parent only as long as
    # nothing is holding the two of them together. Started from an installer running inside a
    # container or under another scheduled task, it dies when that ends - which is precisely how
    # the companion kept vanishing here without a single line in any log. Started by the watchdog,
    # it belongs to the Task Scheduler service and to nothing else.
    $launched = $false
    if ($watchdog) {
        try { Start-ScheduledTask -TaskName $taskName -ErrorAction Stop ; $launched = $true } catch { }
    }
    if (-not $launched) {
        $launcher = @($ensure, $vbs) | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($launcher) {
            & wscript.exe $launcher
        } elseif ($stopped) {
            Write-Warning "no launcher was written and the companion is stopped - this machine has no speech"
            Write-Warning "    powershell -File `"$speak`" -Watch"
        }
    }
}

Start-Sleep -Milliseconds 2500

$running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
           Where-Object { $_.CommandLine -match $COMPANION }
if ($running) {
    Write-Host "companion running, pid $($running[0].ProcessId)"
    Write-Host "log: $log"
} else {
    Write-Warning "companion did not come up - run it in the foreground to see why:"
    Write-Warning "    powershell -File `"$speak`" -Watch"
}
