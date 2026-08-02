# Graft the layer onto a module the game already loads.
#
# Patch 8 will not take the mod the normal way: a pak in %LOCALAPPDATA%\...\Mods\ is not even
# listed among the modules the game knows (AvailableMods stays at the 16 base ones), and the
# entry written into modsettings.lsx is stripped on every launch. The load order belongs to
# the in-game mod manager and nothing outside it is honoured.
#
# But the Script Extender does not need a *mod* - it needs a folder. It reads
# Mods/<Folder>/ScriptExtender/Config.json for every module in the load order, through the
# game's own file system, and that file system mounts loose files under Data\ on top of the
# paks. So the layer is dropped into the folder of a module that is always loaded (GustavX,
# the campaign module every modsettings.lsx lists), and comes up with it.
#
# Nothing of the game is overwritten: the ScriptExtender subfolder does not exist inside
# GustavX.pak, so these are new paths in the merged tree, not replacements. -Uninstall takes
# them away again.
#
# Usage: powershell -File graft-mod.ps1
#        powershell -File graft-mod.ps1 -Uninstall
#        powershell -File graft-mod.ps1 -HostModule Shared  graft onto another module

param(
    [string]$HostModule = "GustavX",
    [string]$GameDir = (& (Join-Path $PSScriptRoot "find-game.ps1")),
    [switch]$Uninstall,
    [switch]$Quiet          # one line instead of the file list - install.ps1 has its own report
)

$ErrorActionPreference = "Stop"
# Guarded: console-send.ps1 frees this process's console handle, and a run that follows it in
# the same session cannot set the encoding - which is no reason to fail.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$root  = Split-Path $PSScriptRoot
$src   = Join-Path $root "BG3Access\Mods\BG3Access\ScriptExtender"
$luaS  = Join-Path $root "lua"
$dst   = Join-Path $GameDir "Data\Mods\$HostModule\ScriptExtender"

if ([string]::IsNullOrWhiteSpace($GameDir)) {
    Write-Error ("Baldur's Gate 3 was not found on this machine - pass -GameDir " +
                 '"<path to Baldurs Gate 3>" (the folder holding bin\bg3.exe)')
}
if (-not (Test-Path $GameDir)) { Write-Error "no game at $GameDir - pass -GameDir" }

if ($Uninstall) {
    if (Test-Path $dst) {
        Remove-Item $dst -Recurse -Force
        Write-Host "removed $dst"
        # Leave Data\Mods\<Host> itself alone only if something else lives there.
        $parent = Split-Path $dst
        if ((Test-Path $parent) -and -not (Get-ChildItem $parent -Force)) {
            Remove-Item $parent -Force
            Write-Host "removed $parent"
        }
    } else {
        Write-Host "nothing grafted at $dst"
    }
    return
}

if (-not (Test-Path $src)) { Write-Error "no mod tree at $src - run build-mod.ps1 first" }

New-Item -ItemType Directory -Force (Join-Path $dst "Lua\A11y") | Out-Null
Copy-Item (Join-Path $src "Config.json") $dst -Force
Copy-Item (Join-Path $src "Lua\Bootstrap*.lua") (Join-Path $dst "Lua") -Force
Copy-Item (Join-Path $luaS "*.lua") (Join-Path $dst "Lua\A11y") -Force

$files = Get-ChildItem $dst -Recurse -File
if ($Quiet) {
    Write-Host ("   {0} files -> Data\Mods\{1}\ScriptExtender" -f $files.Count, $HostModule)
} else {
    Write-Host "grafted onto ${HostModule}:"
    $files | ForEach-Object { "    " + $_.FullName.Substring($GameDir.Length + 1) }
    Write-Host ""
    Write-Host "Restart the game, then run status.bat (or tools\mod-status.ps1)"
}
