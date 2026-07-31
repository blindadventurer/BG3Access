# Is the layer actually up? Answered without the game window and without the SE console.
#
# Four things have to be true and each fails silently on its own: the layer is grafted onto a
# loaded module, the client bootstrap ran, the game is running it, and something is turning
# the speech bridge into speech. Each line below is one of them.
#
# Usage: powershell -File mod-status.ps1

param(
    [string]$HostModule = "GustavX",
    [string]$GameDir = "G:\SteamLibrary\steamapps\common\Baldurs Gate 3"
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$appData = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3"
$a11y    = Join-Path $appData "Script Extender\A11y"
$boot    = Join-Path $a11y "boot.json"
$bridge  = Join-Path $a11y "speech.txt"
$graft   = Join-Path $GameDir "Data\Mods\$HostModule\ScriptExtender"

function Line($label, $ok, $detail) {
    $mark = if ($ok) { "OK  " } else { "--  " }
    Write-Host ("{0}{1,-22}{2}" -f $mark, $label, $detail)
}

# 1. game
$game = Get-Process bg3_dx11, bg3 -ErrorAction SilentlyContinue
Line "game" ([bool]$game) $(if ($game) { "running, pid $($game[0].Id)" } else { "not running" })

# 2. the install itself. Not a pak and not a modsettings entry - Patch 8 keeps neither (see
#    graft-mod.ps1); the layer lives in the ScriptExtender folder of a module already loaded.
if (Test-Path (Join-Path $graft "Config.json")) {
    $files = Get-ChildItem $graft -Recurse -File
    $newest = ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
    Line "graft onto $HostModule" $true ("{0} files, newest {1:yyyy-MM-dd HH:mm}" -f $files.Count, $newest)
} else {
    Line "graft onto $HostModule" $false "missing - run tools\graft-mod.ps1"
}

# 3. what the bootstrap wrote the last time the client state was built. That happens at launch
#    and again after every save load, so a stale timestamp here means it did not come back.
if (Test-Path $boot) {
    $b = Get-Content $boot -Raw -Encoding UTF8 | ConvertFrom-Json
    $age = [int]((Get-Date) - (Get-Item $boot).LastWriteTime).TotalSeconds
    Line "bootstrap" ($b.state -eq "running") ("state=$($b.state) modules=$($b.modules -join ' ') " +
        "controllerMode=$($b.controllerMode) SE=v$($b.extender) ${age}s ago")
    if ($b.error) { Write-Host "    error: $($b.error)" }
} else {
    Line "bootstrap" $false "no boot.json - the client bootstrap never ran"
}

# 4. speech companion
$watch = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
         Where-Object { $_.CommandLine -like "*speak.ps1*-Watch*" }
Line "speech companion" ([bool]$watch) $(if ($watch) { "running, pid $($watch[0].ProcessId)" } else { "not running - run tools\install-speech-service.ps1" })

if (Test-Path $bridge) {
    $raw = (Get-Content $bridge -Raw -Encoding UTF8)
    $parts = $raw.Split('|', 3)
    $age = [int]((Get-Date) - (Get-Item $bridge).LastWriteTime).TotalSeconds
    Line "last spoken" $true ("#{0} ({1}s ago) {2}" -f $parts[0], $age, ($parts[2] -replace "\r?\n", " / "))
} else {
    Line "last spoken" $false "the layer has said nothing yet"
}
