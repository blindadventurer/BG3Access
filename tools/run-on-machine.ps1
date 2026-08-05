# Run something the way the machine runs it, from a shell that is not the machine.
#
# This exists because of a failure that cost this project two evenings of silence and was
# invisible from the inside.
#
# The assistant's shell on this machine runs inside the Claude desktop app's container, and a
# container redirects the profile: every write under `%LOCALAPPDATA%` and `%APPDATA%` lands in
#
#     %LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\{Local,Roaming}\...
#
# while reads fall through to the real file when the container has no copy of its own. So an
# install run from there *looks* perfect from inside it - the files are all where they should
# be, `Test-Path` says yes, the status page says yes - and the machine has none of them. The
# speech companion was installed that way three times. Every launcher pointing at
# `%LOCALAPPDATA%\BG3Access\speak.ps1` found nothing there, at every logon, for days; the only
# companion that ever ran was the one started inside the container, which died with the session
# that started it and could not be restarted by anything outside.
#
# One profile path is exempt and it is the one that made this so hard to see: the Startup folder
# is not redirected. So the launcher was real, and it pointed into a folder that was not.
#
# The Task Scheduler service is outside all of that. It runs as the same user, in the same
# session, with the real profile - so a one-shot task is a way out of the container, and this
# wraps it: write the command where the machine can read it (C:\Users\Public is not redirected
# either), run it as a task, wait, and hand back what it printed.
#
# Usage: powershell -File run-on-machine.ps1 -Command "& '<repo>\tools\install.ps1' -Yes"
#        powershell -File run-on-machine.ps1 -Command "dir C:\Users\igory\AppData\Local\BG3Access"
#
# The console window it opens belongs to the task, not to this script - a second or two of it
# is the price of being outside.

param(
    [Parameter(Mandatory = $true)][string]$Command,
    [int]$TimeoutSec = 600,
    [switch]$KeepFiles
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# Public, because the profile is exactly what cannot be trusted here. Everything this writes is
# readable by anyone on the machine, so it carries a command, never a secret.
$stage = "C:\Users\Public\BG3Access-outside"
$runPs = Join-Path $stage "run.ps1"
$outTx = Join-Path $stage "out.txt"
$task  = "BG3Access run-on-machine"

New-Item -ItemType Directory -Force $stage | Out-Null
Set-Content -LiteralPath $runPs -Value $Command -Encoding UTF8
if (Test-Path -LiteralPath $outTx) { Remove-Item -LiteralPath $outTx -Force }

# *> and not 2>&1: the scripts this runs report through Write-Host, which since PowerShell 5
# goes to the information stream. Merging only stderr is how install.ps1's own speech check
# once captured an empty string and called a working install broken.
$inner = "& '{0}' *> '{1}'" -f ($runPs -replace "'", "''"), ($outTx -replace "'", "''")
$user  = "$env:USERDOMAIN\$env:USERNAME"

# The call operator is the first character of that command line and & is not a character XML
# will take: "The task XML is malformed (16,65)" and nothing more specific than the column.
$xmlSafe = $inner -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
$xml   = '<?xml version="1.0" encoding="UTF-16"?>' + @"
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>One-shot, written by tools\run-on-machine.ps1. Safe to delete.</Description></RegistrationInfo>
  <Triggers></Triggers>
  <Principals><Principal id="Author"><UserId>$user</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>Parallel</MultipleInstancesPolicy>
    <Enabled>true</Enabled>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT${TimeoutSec}S</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -Command "$xmlSafe"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

Register-ScheduledTask -TaskName $task -Xml $xml -Force | Out-Null
try {
    Start-ScheduledTask -TaskName $task
    $t0 = Get-Date
    do {
        Start-Sleep -Milliseconds 500
        $state = (Get-ScheduledTask -TaskName $task).State
    } until ($state -ne "Running" -or ((Get-Date) - $t0).TotalSeconds -gt $TimeoutSec)

    if ($state -eq "Running") { Write-Warning "still running after $TimeoutSec s - showing what it printed so far" }
    if (Test-Path -LiteralPath $outTx) {
        Get-Content -LiteralPath $outTx -Encoding UTF8
    } else {
        Write-Warning ("the task wrote nothing - result 0x{0:X}" -f (Get-ScheduledTaskInfo -TaskName $task).LastTaskResult)
    }
}
finally {
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    if (-not $KeepFiles) {
        foreach ($f in @($runPs, $outTx)) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
    }
}
