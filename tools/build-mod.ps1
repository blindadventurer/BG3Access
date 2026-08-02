# Build the layer into something the game starts by itself, and install it.
#
# Installing does NOT mean a mod in the normal sense. Patch 8 will not take one from outside:
# a pak dropped in %LOCALAPPDATA%\...\Mods is never listed among the modules the game knows
# (AvailableMods stays at the 16 base ones, and the in-game manager does not show it either),
# and an entry written into modsettings.lsx is stripped on the next launch. What works is the
# graft - the layer's ScriptExtender folder placed inside a module the game already loads.
# See graft-mod.ps1 for the mechanism.
#
# The pak is still built on request. It is the artefact for the day the layer is published
# through the in-game manager, and building it proves the mod tree is well-formed.
#
# Usage: powershell -File build-mod.ps1                stage the modules and graft them
#        powershell -File build-mod.ps1 -Pak           also build BG3Access.pak
#        powershell -File build-mod.ps1 -Register      also write the modsettings entry
#        powershell -File build-mod.ps1 -NoGraft       stage only

param(
    [string]$Divine,
    [string]$GameDir = (& (Join-Path $PSScriptRoot "find-game.ps1")),
    [switch]$Pak,
    [switch]$Register,
    [switch]$NoGraft
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$root     = Split-Path $PSScriptRoot
$modRoot  = Join-Path $root "BG3Access"
$modDir   = Join-Path $modRoot "Mods\BG3Access"
$luaDst   = Join-Path $modDir "ScriptExtender\Lua\A11y"
$luaSrc   = Join-Path $root "lua"

$appData  = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3"
$modsDir  = Join-Path $appData "Mods"
$pak      = Join-Path $modsDir "BG3Access.pak"
$settings = Join-Path $appData "PlayerProfiles\Public\modsettings.lsx"

$folder   = "BG3Access"
$uuid     = "0541fc3e-d292-4ff9-b352-9e3ab8b09a82"     # must match meta.lsx
$version  = "36028797018963968"                         # 1.0.0.0 packed into an int64

if (Get-Process bg3_dx11, bg3 -ErrorAction SilentlyContinue) {
    Write-Warning "BG3 is running - the graft only takes effect on the next launch."
}

# --- 1. the layer's own files ------------------------------------------------------------

New-Item -ItemType Directory -Force $luaDst | Out-Null
Copy-Item (Join-Path $luaSrc "*.lua") $luaDst -Force
$copied = (Get-ChildItem $luaDst -Filter *.lua | Measure-Object).Count
Write-Host "staged $copied lua modules -> $luaDst"

# --- 2. the pak, on request ---------------------------------------------------------------

if ($Pak) {
    # tools\lslib first, and it is there for a reason: the Divine bundled with Vortex
    # (LSLib 1.15.4) writes an LSPK **version 16** package for -g bg3, and BG3 reads version
    # 18. A v16 pak is not rejected loudly - the game simply never lists the mod, which looks
    # exactly like the load order being overwritten and cost an evening on that wrong trail.
    if (-not $Divine) {
        $candidates = @(
            (Join-Path $PSScriptRoot "lslib\Tools\Divine.exe"),
            "F:\games\nexus\Vortex\resources\app.asar.unpacked\bundledPlugins\game-baldursgate3\tools\divine.exe",
            "$env:APPDATA\Vortex\resources\app.asar.unpacked\bundledPlugins\game-baldursgate3\tools\divine.exe"
        )
        $Divine = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if (-not $Divine -or -not (Test-Path $Divine)) {
        Write-Error "divine.exe not found - pass -Divine <path> (it ships with LSLib, Vortex and the BG3 Modder's Multitool)"
    }

    New-Item -ItemType Directory -Force $modsDir | Out-Null
    $out = & $Divine -g bg3 -a create-package -s $modRoot -d $pak -l warn 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Error "divine failed: $out" }

    $fs = [System.IO.File]::OpenRead($pak)
    $head = New-Object byte[] 8
    $fs.Read($head, 0, 8) | Out-Null
    $fs.Dispose()
    $magic = [System.Text.Encoding]::ASCII.GetString($head, 0, 4)
    $pakVersion = [BitConverter]::ToUInt32($head, 4)
    if ($magic -ne "LSPK" -or $pakVersion -ne 18) {
        Write-Error ("$Divine wrote an LSPK v$pakVersion package; BG3 needs v18. " +
                     "Use another Divine build - tools\lslib\Tools\Divine.exe is known good.")
    }

    $size = [math]::Round((Get-Item $pak).Length / 1KB, 1)
    Write-Host "packed -> $pak  (LSPK v$pakVersion, $size KB)"
}

# --- 3. the install that actually works ----------------------------------------------------

if (-not $NoGraft) {
    & (Join-Path $PSScriptRoot "graft-mod.ps1") -GameDir $GameDir
}

# --- 4. the load order, on request ----------------------------------------------------------

# Off by default because it does nothing: the game rewrites modsettings.lsx at startup from
# its own list and drops anything it did not put there. Kept for the day that changes, and
# because it is the first thing anyone will try again.
if ($Register) {
    if (-not (Test-Path $settings)) { Write-Error "no modsettings.lsx at $settings" }

    $backup = "$settings.bak-a11y"
    if (-not (Test-Path $backup)) {
        Copy-Item $settings $backup
        Write-Host "backed up modsettings.lsx -> $backup"
    }

    [xml]$doc = Get-Content $settings -Raw -Encoding UTF8

    $modsNode = $doc.SelectSingleNode("//node[@id='Mods']/children")
    if (-not $modsNode) {
        $holder = $doc.SelectSingleNode("//node[@id='Mods']")
        if (-not $holder) { Write-Error "modsettings.lsx has no Mods node - restore it from $backup" }
        $modsNode = $doc.CreateElement("children")
        $holder.AppendChild($modsNode) | Out-Null
    }

    $existing = $modsNode.SelectSingleNode("node[@id='ModuleShortDesc'][attribute[@id='Folder'][@value='$folder']]")
    if ($existing) {
        Write-Host "modsettings.lsx already lists $folder"
    } else {
        $entry = $doc.CreateElement("node")
        $entry.SetAttribute("id", "ModuleShortDesc")
        # Attribute set copied from what the game writes for GustavX: UUID as `guid` and a
        # PublishHandle, which the Patch 8 format has and the old one has no notion of.
        $attrs = [ordered]@{
            Folder        = @("LSString", $folder)
            MD5           = @("LSString", "")
            Name          = @("LSString", $folder)
            PublishHandle = @("uint64",   "0")
            UUID          = @("guid",     $uuid)
            Version64     = @("int64",    $version)
        }
        foreach ($k in $attrs.Keys) {
            $a = $doc.CreateElement("attribute")
            $a.SetAttribute("id", $k)
            $a.SetAttribute("type", $attrs[$k][0])
            $a.SetAttribute("value", $attrs[$k][1])
            $entry.AppendChild($a) | Out-Null
        }
        $modsNode.AppendChild($entry) | Out-Null

        # No BOM: that is how the game writes this file.
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $w = New-Object System.Xml.XmlTextWriter($settings, $utf8)
        $w.Formatting = [System.Xml.Formatting]::Indented
        $w.Indentation = 4
        try { $doc.WriteTo($w) } finally { $w.Close() }
        Write-Host "added $folder to modsettings.lsx (the game will most likely strip it)"
    }
}

Write-Host ""
Write-Host "Restart the game, then check it took:"
Write-Host "    powershell -File tools\mod-status.ps1"
