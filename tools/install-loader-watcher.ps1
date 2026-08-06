# Keep the native-plugin loader running, so plugins load without the player catching a ten-second
# window by hand.
#
# Native BG3 plugins are DLLs injected into the running game. YABG3NML ships two ways to do it:
#
#   bg3_injector.exe   one shot, run *after* the game starts - and its own instructions say
#                      plugins expect to be there at process startup, so "as soon as possible",
#                      within about ten seconds.
#   bg3_watcher.exe    the same thing left running: it waits for the game to appear and injects
#                      the moment it does.
#
# For this project the injector is not an option. The player is blind; the ten seconds after the
# game starts are the ten seconds when the launcher, the splash and the main menu are all fighting
# for focus, and "alt-tab to a second program and press Enter on it in time, every session" is
# exactly the kind of step that turns into a silence nobody can diagnose. The watcher makes it
# nobody's job.
#
# It goes in the Task Scheduler rather than the Startup folder, for the reason
# install-speech-service.ps1 learnt the hard way: Startup fires at logon and nowhere else, and
# this machine had been up for nine days. Same three moments, same shape:
#
#   logon, unlock, and a trigger repeating every minute for as long as the machine is on.
#
# The task action *is* the watcher rather than a check on it - the instance and the process share
# one lifetime, so while it lives every minute's trigger is refused (IgnoreNew) and costs nothing,
# and the minute after it dies starts another. No state, nothing that has to notice a death.
#
# Two settings are load-bearing and neither is obvious:
#
#   ExecutionTimeLimit PT0S   no limit. The default is three days, and a task meant to run for as
#                             long as the machine is on has to say so.
#   WorkingDirectory          the watcher loads loader.dll from beside itself; started from
#                             somewhere else it finds nothing and injects nothing.
#
# bg3_watcher.exe is a GUI-subsystem binary, so it runs with no console window and needs no shim -
# checked, not assumed. It asks for no elevation either (no requestedExecutionLevel in its
# manifest), which is what makes a per-user task with LeastPrivilege enough: no administrator, no
# stored password.
#
# Usage: powershell -File install-loader-watcher.ps1
#        powershell -File install-loader-watcher.ps1 -WatcherExe "...\bin\NativeModLoader\bg3_watcher.exe"
#        powershell -File install-loader-watcher.ps1 -Uninstall
#
# Run it through run-on-machine.ps1 if you are calling it from inside the assistant's container -
# the task itself is registered with the service and would be real either way, but the checks
# below read files, and those lie in there. See assistant-shell-profile-redirect.

param(
    [string]$WatcherExe,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$taskName = "BG3Access Native Loader"

function Stop-Watcher {
    Get-Process -Name "bg3_watcher" -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        Write-Host "stopped watcher pid $($_.Id)"
    }
}

if ($Uninstall) {
    try {
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-Host "removed scheduled task '$taskName'"
        } else {
            Write-Host "no scheduled task '$taskName'"
        }
    } catch { Write-Warning "could not remove the task: $($_.Exception.Message)" }
    Stop-Watcher
    Write-Host "the loader and the plugins are left where they are - this only stops them being started"
    return
}

# Where the watcher is. The loader was put in <game>\bin\NativeModLoader by hand; find the game
# the way the rest of the toolkit does rather than hard-coding a drive letter.
if (-not $WatcherExe) {
    $roots = @()
    $findGame = Join-Path $PSScriptRoot "find-game.ps1"
    if (Test-Path $findGame) {
        try { $roots += (& $findGame) | Where-Object { $_ } } catch { }
    }
    $roots += @(
        "G:\SteamLibrary\steamapps\common\Baldurs Gate 3",
        "C:\Program Files (x86)\Steam\steamapps\common\Baldurs Gate 3"
    )
    foreach ($r in $roots) {
        $c = Join-Path $r "bin\NativeModLoader\bg3_watcher.exe"
        if (Test-Path $c) { $WatcherExe = $c; break }
    }
}

if (-not $WatcherExe -or -not (Test-Path $WatcherExe)) {
    Write-Error ("bg3_watcher.exe not found. Install Yet Another BG3 Native Mod Loader into " +
                 "<game>\bin\NativeModLoader\ first, or pass -WatcherExe.")
}

$watcherDir = Split-Path $WatcherExe
if (-not (Test-Path (Join-Path $watcherDir "loader.dll"))) {
    Write-Error "loader.dll is not beside $WatcherExe - the watcher would inject nothing"
}

# What it will actually load. Not fatal - an empty Plugins folder is a legitimate state, it just
# means nothing happens - but silence with a reason beats silence.
$plugins = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Plugins"
$dlls = @()
if (Test-Path $plugins) { $dlls = @(Get-ChildItem $plugins -Filter *.dll -File -ErrorAction SilentlyContinue) }
if ($dlls.Count -eq 0) {
    Write-Warning "no plugin DLLs in $plugins - the watcher will run and inject nothing"
} else {
    Write-Host "plugins it will inject:"
    $dlls | ForEach-Object { Write-Host ("    {0}  ({1:N0} bytes)" -f $_.Name, $_.Length) }
}

$user = "$env:USERDOMAIN\$env:USERNAME"
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Runs the BG3 native mod loader's watcher, so plugins are injected when the game starts without anyone having to run a tool in time. Written by BG3Access; remove it with install-loader-watcher.ps1 -Uninstall.</Description>
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
      <Command>$WatcherExe</Command>
      <WorkingDirectory>$watcherDir</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

Register-ScheduledTask -TaskName $taskName -Xml $xml -Force -ErrorAction Stop | Out-Null
Write-Host "registered '$taskName' -> $WatcherExe"

# Don't wait for the next logon to find out whether it works. Start it now and look for the
# process, because a task that registers and then fails to start is the failure this project
# keeps meeting.
Stop-Watcher
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 3

$p = Get-Process -Name "bg3_watcher" -ErrorAction SilentlyContinue
$t = Get-ScheduledTask -TaskName $taskName
if ($p) {
    Write-Host ("running: bg3_watcher pid {0}, task state {1}" -f $p.Id, $t.State)
} else {
    Write-Warning "the task is registered but no bg3_watcher process appeared - task state $($t.State)"
    (Get-ScheduledTaskInfo -TaskName $taskName) | Format-List LastRunTime, LastTaskResult, NumberOfMissedRuns | Out-String | Write-Host
}
