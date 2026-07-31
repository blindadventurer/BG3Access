# Press keys in the game and report what the layer said.
#
# The whole loop in one step: raise the game window, send real key events, wait for the
# reader to catch up, then print the lines the speech log gained. Without this every probe
# is three calls and the console has to be read for feedback it renders as question marks.
#
# ASCII only: PS 5.1 reads .ps1 as ANSI and the Write tool emits UTF-8 without a BOM.
#
# Usage: powershell -File drive.ps1 -Keys "DOWN,DOWN,RETURN"
#        powershell -File drive.ps1 -Key DOWN -Repeat 8 -DelayMs 400
#        powershell -File drive.ps1 -Wait 3000            say nothing, just watch

param(
    [string]$Key,
    [string]$Keys,
    [int]$Repeat = 1,
    [int]$DelayMs = 450,
    [int]$Wait = 900,
    [int]$Tail = 60,
    [string]$LogFile = (Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Script Extender\A11y\speech-log.txt")
)

$ErrorActionPreference = "Stop"
# console-send.ps1 attaches to the game's console and frees it again, which can leave this
# process without a valid stdout handle for a moment; the encoding is a nicety, not a
# reason to fail the run.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$before = 0
if (Test-Path $LogFile) {
    $before = @(Get-Content $LogFile -Encoding UTF8).Count
}

& (Join-Path $PSScriptRoot "focus-game.ps1") | Out-Null

if ($Key -or $Keys) {
    $args = @{ DelayMs = $DelayMs }
    if ($Keys) { $args.Keys = $Keys } else { $args.Key = $Key; $args.Repeat = $Repeat }
    & (Join-Path $PSScriptRoot "keys.ps1") @args | Out-Null
}

Start-Sleep -Milliseconds $Wait

if (-not (Test-Path $LogFile)) { "no speech log yet"; return }
$all = @(Get-Content $LogFile -Encoding UTF8)
$new = $all[$before..($all.Count - 1)]
if ($all.Count -le $before) { "(nothing said)"; return }
$new | Select-Object -Last $Tail
