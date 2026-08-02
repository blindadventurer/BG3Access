# Push a Lua module from lua\ into a running game and reload the layer in one step.
#
# The layer now starts with the game (tools\graft-mod.ps1), and its modules are read from
# <Script Extender>\A11y\ when they are there - which is exactly where this script writes.
# So a push is: copy the file, then ask the running layer to re-read it. No repacking, no
# restart, and nothing is left half-swapped, because the reload stops the old reader before
# building the new one.
#
# Everything lives in the mod's own table, not in the console's globals: `Ms = load(...)()`
# typed at the console would build a second copy that cannot see A11y or Pad (its `_G` is a
# different table). Hence the Mods.BG3Access prefix everywhere below, and -Dev for the
# modules that are not part of the layer proper.
#
# Usage: powershell -File push-lua.ps1                        push every module, reload
#        powershell -File push-lua.ps1 -Name a11y-pad         push one, reload
#        powershell -File push-lua.ps1 -Name a11y-mouse -Dev Ms
#        powershell -File push-lua.ps1 -Call 'Pad.status()'   run something after the reload

param(
    [string]$Name = "",
    [string]$Dev = "",
    [string]$Call = "",
    [switch]$NoReload
)

$ErrorActionPreference = "Stop"
# console-send.ps1 attaches to the game's console and frees it again, which leaves this
# process without a console handle - so a second push in the same session cannot set the
# encoding, and must not die trying.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$MOD = "Mods.BG3Access"

$srcDir = Join-Path (Split-Path $PSScriptRoot) "lua"
$seDir  = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Script Extender"
$dstDir = Join-Path $seDir "A11y"
New-Item -ItemType Directory -Force $dstDir | Out-Null

$files = if ($Name) { @(Join-Path $srcDir "$Name.lua") } else { Get-ChildItem $srcDir -Filter *.lua | ForEach-Object { $_.FullName } }
foreach ($f in $files) {
    if (-not (Test-Path $f)) { Write-Error "no such module: $f" }
    Copy-Item $f $dstDir -Force
    Write-Host "pushed $(Split-Path $f -Leaf)"
}

if (-not (Get-Process bg3_dx11, bg3 -ErrorAction SilentlyContinue)) {
    Write-Host "BG3 is not running - files staged, nothing sent to the console."
    return
}

$send = Join-Path $PSScriptRoot "console-send.ps1"
# The console starts in the server context and swallows its first line (session 1 rule), so
# the context is asserted twice before anything that matters is sent.
& $send -Line "client" | Out-Null
Start-Sleep -Milliseconds 300
& $send -Line "client" | Out-Null
Start-Sleep -Milliseconds 300

$lines = @()
if (-not $NoReload) { $lines += "$MOD.A11yBoot.reload()" }
if ($Dev) {
    if (-not $Name) { Write-Error "-Dev needs -Name (which module to load)" }
    $lines += "$MOD.A11yBoot.loadDev(`"$Name`", `"$Dev`")"
}
if ($Call) { $lines += "$MOD.$Call" }

foreach ($l in $lines) {
    & $send -Line $l | Out-Null
    Write-Host "  > $l"
    Start-Sleep -Milliseconds 400
}

# The server half is not part of A11yBoot.reload(): BootstrapServer reads a11y-nav-server.lua
# once, when the session loads, and the client's reload cannot reach across. So a push that
# touched it left the old copy running - the file on disk was new, the character still would
# not stop, and nothing said which half was which. It is re-read here, in its own context,
# exactly the way its own header documents.
if (-not $NoReload -and (-not $Name -or $Name -eq "a11y-nav-server")) {
    $serverLines = @(
        'NavSrv = load(Ext.IO.LoadFile("A11y/a11y-nav-server.lua"))()',
        'NavSrv.listen()'
    )
    & $send -Line "server" | Out-Null
    Start-Sleep -Milliseconds 300
    foreach ($l in $serverLines) {
        & $send -Line $l | Out-Null
        Write-Host "  server > $l"
        Start-Sleep -Milliseconds 400
    }
    # Left in the client context, because that is where everything else is typed.
    & $send -Line "client" | Out-Null
    Start-Sleep -Milliseconds 300
}
