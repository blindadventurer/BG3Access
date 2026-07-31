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
# Usage: powershell -File install-speech-service.ps1
#        powershell -File install-speech-service.ps1 -Uninstall

param(
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$speak   = Join-Path $PSScriptRoot "speak.ps1"
$startup = [Environment]::GetFolderPath("Startup")
$vbs     = Join-Path $startup "BG3 Access Speech.vbs"
$log     = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Script Extender\A11y\speech-companion.log"

function Stop-Companion {
    $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
             Where-Object { $_.CommandLine -like "*speak.ps1*-Watch*" }
    foreach ($p in $procs) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host "stopped companion pid $($p.ProcessId)"
    }
}

if ($Uninstall) {
    Stop-Companion
    if (Test-Path $vbs) { Remove-Item $vbs -Force; Write-Host "removed $vbs" }
    else { Write-Host "nothing installed at $vbs" }
    return
}

if (-not (Test-Path $speak)) { Write-Error "speak.ps1 not found at $speak" }
if (-not (Test-Path (Join-Path $PSScriptRoot "prism.dll"))) {
    Write-Error "prism.dll not found next to speak.ps1 - the companion would have nothing to speak with"
}

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

Set-Content -Path $vbs -Value $body -Encoding ASCII
Write-Host "installed $vbs"

Stop-Companion
& wscript.exe $vbs
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
