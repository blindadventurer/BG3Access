# Build the layer into something the game starts by itself, and install it.
#
# CORRECTED 2026-08-07. What stood here was: "Patch 8 will not take a mod from outside - a pak
# in %LOCALAPPDATA%\...\Mods is never listed, and a modsettings.lsx entry is stripped on the
# next launch." That is wrong, and it sent the whole project down the graft road.
#
# Patch 8 takes external paks. Measured by finding one in that very folder: a mod.io add-on
# ("Extra encounters and Minibosses") sitting beside our BG3AccessDiag.pak - the add-on listed
# in modsettings.lsx and loading, ours ignored, both LSPK v18, same folder, same launch. The
# game was not refusing outside mods. It was refusing OUR module, because meta.lsx was written
# in the pre-Patch-7 format: PublishVersion and Scripts as siblings of ModuleInfo instead of its
# children, no PublishHandle, no FileSize, StartLevelName for StartupLevelName, empty
# Dependencies. A module whose meta will not parse is never listed and never explains itself,
# which is indistinguishable from being refused. See BG3Access\Mods\BG3Access\meta.lsx.
#
# The graft still works and is still installed - it is what the layer runs from today, and it
# stays until the pak route is proven in a launch. But it was a workaround for a bug of ours.
#
# Usage: powershell -File build-mod.ps1                stage the modules and graft them
#        powershell -File build-mod.ps1 -Pak           build dist\BG3Access.pak and the probe
#        powershell -File build-mod.ps1 -Pak -InstallPak   run as a real mod, drop the graft
#        powershell -File build-mod.ps1 -Register      also write the modsettings entry
#        powershell -File build-mod.ps1 -NoGraft       stage only

param(
    [string]$Divine,
    [string]$GameDir = (& (Join-Path $PSScriptRoot "find-game.ps1")),
    [switch]$Pak,
    [switch]$InstallPak,
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

# The probe module. It carries its own ModTable, so it can be installed as a real mod while the
# layer is still running from the graft - which is what makes it safe to test the meta format
# without a launch in which the player might have no accessibility at all.
$diagRoot = Join-Path $root "BG3AccessDiag"

$appData  = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3"
$modsDir  = Join-Path $appData "Mods"
# $pakPath and not $pak: PowerShell variable names are case-insensitive, so `$pak` is the same
# variable as the `[switch]$Pak` parameter above - assigning a string to it threw
# "Cannot convert value System.String to type SwitchParameter" at line 37 and the script died
# before it staged anything. It had done that since the switch was added, which is why the
# graft has only ever been run through graft-mod.ps1 directly.
#
# The layer's pak is built into dist\ and NOT into Mods\, and that is deliberate: the graft
# declares `"ModTable": "BG3Access"` from inside GustavX's folder, and so does this pak. Install
# both and the extender is handed the same mod table twice - two bootstraps, or an error, and
# either way the player finds out by launching into a game with no accessibility. The two
# routes are exclusive, so -InstallPak is the switch that swaps one for the other, and nothing
# else ever puts this file in Mods\.
$pakPath  = Join-Path $root "dist\BG3Access.pak"
# The probe builds into dist\ too, and not into Mods\ where it used to. Packaging a release
# calls this script, and a build step that installs a diagnostic mod into the player's game as
# a side effect is a build step that undoes a tidy-up nobody asked it to touch. Installing it is
# a deliberate act now: copy it into Mods\ and register-mod.ps1 -Pak BG3AccessDiag.pak.
$diagPak  = Join-Path $root "dist\BG3AccessDiag.pak"
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

    # Pack one module tree and refuse to ship anything the game is known to ignore.
    #
    # Two silent invisibilities are checked here, because both cost this project weeks and
    # neither produces a word from the game: an LSPK v16 package, and a meta.lsx in the format
    # that predates Patch 7. The pak header check was already here; the meta check is new, and
    # it exists because "the module is simply never listed" is the same symptom for both.
    function Pack-Module([string]$srcRoot, [string]$dstPak) {
        $meta = Get-ChildItem (Join-Path $srcRoot "Mods") -Recurse -Filter "meta.lsx" |
                Select-Object -First 1
        if (-not $meta) { Write-Error "no meta.lsx under $srcRoot" }
        [xml]$mx = Get-Content $meta.FullName -Raw -Encoding UTF8

        $info = $mx.SelectSingleNode("//node[@id='ModuleInfo']")
        if (-not $info) { Write-Error "$($meta.FullName): no ModuleInfo node" }
        foreach ($need in @("PublishHandle", "StartupLevelName", "FileSize")) {
            if (-not $info.SelectSingleNode("attribute[@id='$need']")) {
                Write-Error ("$($meta.FullName): ModuleInfo has no $need - this is the " +
                             "pre-Patch-7 meta format and the game will never list the module")
            }
        }
        # The one that actually broke us: these belong inside ModuleInfo, not beside it.
        if (-not $info.SelectSingleNode("children/node[@id='PublishVersion']")) {
            Write-Error ("$($meta.FullName): PublishVersion is not a child of ModuleInfo - " +
                         "Patch 8 nests it there, and a module it cannot parse is never listed")
        }

        $out = & $Divine -g bg3 -a create-package -s $srcRoot -d $dstPak -l warn 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Error "divine failed: $out" }

        $fs = [System.IO.File]::OpenRead($dstPak)
        $head = New-Object byte[] 8
        $fs.Read($head, 0, 8) | Out-Null
        $fs.Dispose()
        $magic = [System.Text.Encoding]::ASCII.GetString($head, 0, 4)
        $pakVersion = [BitConverter]::ToUInt32($head, 4)
        if ($magic -ne "LSPK" -or $pakVersion -ne 18) {
            Write-Error ("$Divine wrote an LSPK v$pakVersion package; BG3 needs v18. " +
                         "Use another Divine build - tools\lslib\Tools\Divine.exe is known good.")
        }

        $size = [math]::Round((Get-Item $dstPak).Length / 1KB, 1)
        Write-Host "packed -> $dstPak  (LSPK v$pakVersion, $size KB)"
    }

    New-Item -ItemType Directory -Force (Split-Path $pakPath) | Out-Null
    Pack-Module $modRoot  $pakPath

    # Non-fatal on purpose: the probe is a development aid, and losing it must not cost the
    # layer's own pak, which was built a line ago.
    try {
        Pack-Module $diagRoot $diagPak
    } catch {
        Write-Warning ("could not build the probe at ${diagPak}: " + $_.Exception.Message)
    }
}

# --- 2b. the swap: stop being a graft, start being a mod -------------------------------------

# Only ever both at once by mistake - see the note on $pakPath. So this takes the graft away in
# the same breath as it installs the pak, and it refuses to guess: without -Pak there is no
# freshly built pak to install, and installing a stale one is how a fixed bug comes back.
if ($InstallPak) {
    if (-not $Pak) { Write-Error "-InstallPak needs -Pak: nothing was built to install" }
    & (Join-Path $PSScriptRoot "graft-mod.ps1") -GameDir $GameDir -Uninstall
    Copy-Item $pakPath (Join-Path $modsDir "BG3Access.pak") -Force
    Write-Host "installed -> $(Join-Path $modsDir 'BG3Access.pak')  (graft removed)"
    Write-Host ""
    Write-Host "This is the launch where the layer either comes up as a mod or does not come up"
    Write-Host "at all. To go back: powershell -File tools\graft-mod.ps1"
}

# --- 3. the install that actually works ----------------------------------------------------

if (-not $NoGraft -and -not $InstallPak) {
    & (Join-Path $PSScriptRoot "graft-mod.ps1") -GameDir $GameDir
}

# --- 4. the load order, on request ----------------------------------------------------------

# Off by default, and the reason recorded here was wrong. "The game rewrites modsettings.lsx
# from its own list and drops anything it did not put there" described the symptom of a module
# the game could not parse: it dropped the entry because it could not find the module the entry
# named. With a Patch 8 meta the entry has a module to point at, so this may now be the ordinary
# way to set a load order - untested, which is why it is still a switch and still off.
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
