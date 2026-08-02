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
# Usage: powershell -File install-speech-service.ps1
#        powershell -File install-speech-service.ps1 -InPlace
#        powershell -File install-speech-service.ps1 -Uninstall

param(
    [switch]$Uninstall,
    [switch]$InPlace
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$srcSpeak = Join-Path $PSScriptRoot "speak.ps1"
$srcPrism = Join-Path $PSScriptRoot "prism.dll"
$installed = Join-Path $env:LOCALAPPDATA "BG3Access"
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

# Stop-Process returns before the process is gone, and the handles it holds outlive it by a
# moment more - so the copy that follows it can still land on a locked file. Two seconds of
# retries rather than one attempt, and the last attempt is left to throw with the real message.
function Copy-WhenFreed($src, $dst) {
    for ($i = 1; $i -le 10; $i++) {
        try { Copy-Item $src $dst -Force ; return } catch { Start-Sleep -Milliseconds 200 }
    }
    Copy-Item $src $dst -Force
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

# Stopped before anything is copied over it, not after.
#
# A running companion has prism.dll loaded, and Windows does not let a loaded DLL be replaced -
# so on any machine where this had already been installed once, the copy below failed with a
# sharing violation and the install reported that it could not set speech up at all. Which is
# every second install, and the exact advice PLAYING.md gives when speech goes quiet: run
# install.bat again. It never showed up here because a first install has nothing running yet.
Stop-Companion

if ($InPlace) {
    $speak = $srcSpeak
} else {
    # Copied, not linked, and the DLL with it: speak.ps1 loads prism.dll from its own folder.
    New-Item -ItemType Directory -Force $installed | Out-Null
    Copy-WhenFreed $srcSpeak (Join-Path $installed "speak.ps1")
    Copy-WhenFreed $srcPrism (Join-Path $installed "prism.dll")
    $speak = Join-Path $installed "speak.ps1"
    Write-Host "companion copied to $installed"
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

# Already stopped, above, before its files were replaced under it - so this only starts one.
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
