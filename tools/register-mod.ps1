# Turn a .pak sitting in Mods\ into a module the game actually loads.
#
# There are two separate questions and for two months this project conflated them, which is how
# "Patch 8 refuses mods from outside its manager" became a settled fact that was never true.
#
#   1. Does the game KNOW the module?   -> Ext.Mod.GetModManager().AvailableMods
#      This is decided by meta.lsx. A meta in the pre-Patch-7 format is unreadable, and an
#      unreadable module is not reported, not logged and not complained about - it is absent.
#      Measured 2026-08-07: with the old meta, AvailableMods held 16 base modules; with a
#      Patch 8 meta and nothing else changed, 18, ours among them.
#
#   2. Does the game LOAD it?           -> modsettings.lsx
#      Only what is listed there is loaded. Dropping a pak in Mods\ does not enable it; the
#      in-game manager writes that file when the player switches a mod on, and a mod that never
#      appeared in the manager (question 1) could never be switched on there either.
#
# So this script answers 2, and refuses to try when 1 is not satisfied - because an entry whose
# module the game cannot find is silently deleted at startup, which is exactly what was once
# read as the game stripping our load order.
#
# It writes into %LOCALAPPDATA%, so from an agent shell it must be run through
# tools\run-on-machine.ps1 or the edit lands in a container and the game never sees it.
#
# Usage: powershell -File register-mod.ps1 -List
#        powershell -File register-mod.ps1 -Pak BG3AccessDiag.pak
#        powershell -File register-mod.ps1 -Pak BG3AccessDiag.pak -Remove
#        powershell -File register-mod.ps1 -Meta path\to\meta.lsx      (no Divine needed)
#
# -Meta exists for the installer a player runs. Reading the identity out of a pak needs Divine,
# which is 30 MB of LSLib and PhysX and has no business in a release; but the release already
# carries the mod's own meta.lsx, and that is the same source of truth the pak was built from.
# So the identity always comes from a meta - never from constants copied into a second file that
# can drift from it.

param(
    [string]$Pak,
    [string]$Meta,
    [string]$Install,       # a .pak anywhere on disk: copy it into Mods\ and switch it on
    [switch]$Remove,
    [switch]$List,
    [string]$Divine
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$appData  = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3"
$modsDir  = Join-Path $appData "Mods"
$settings = Join-Path $appData "PlayerProfiles\Public\modsettings.lsx"

if (-not (Test-Path $settings)) { Write-Error "no modsettings.lsx at $settings" }

# --- reading the load order ------------------------------------------------------------------

function Get-Entries {
    [xml]$doc = Get-Content $settings -Raw -Encoding UTF8
    $doc.SelectNodes("//node[@id='ModuleShortDesc']")
}

if ($List) {
    Write-Host "enabled in modsettings.lsx:"
    foreach ($e in (Get-Entries)) {
        $n = $e.SelectSingleNode("attribute[@id='Name']").value
        $f = $e.SelectSingleNode("attribute[@id='Folder']").value
        Write-Host ("   {0,-40} [{1}]" -f $n, $f)
    }
    Write-Host ""
    Write-Host "paks present in Mods\:"
    Get-ChildItem $modsDir -Filter *.pak -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host ("   {0,-50} {1:N0} KB" -f $_.Name, ($_.Length / 1KB))
    }
    Write-Host ""
    Write-Host "A pak listed below but not above is installed and switched off."
    return
}

# --- installing one from outside ---------------------------------------------------------------

# The copy is here rather than left to the player because the two halves have to agree: an entry
# in modsettings.lsx naming a module whose pak is not in Mods\ is the exact state the game
# silently repairs by deleting the entry, and that repair is indistinguishable from the game
# refusing the mod. So the file lands first, and only then is it read and switched on.
if ($Install) {
    if (-not (Test-Path $Install)) { Write-Error "no pak at $Install" }
    if (Get-Process bg3, bg3_dx11 -ErrorAction SilentlyContinue) {
        Write-Error ("Baldur's Gate 3 is running. It holds every pak in Mods\ open while it " +
                     "runs - switched on or not - so nothing can be copied in until it quits.")
    }
    New-Item -ItemType Directory -Force $modsDir | Out-Null
    $leaf = Split-Path $Install -Leaf
    Copy-Item $Install (Join-Path $modsDir $leaf) -Force
    Write-Host ("copied -> Mods\{0}  ({1:N0} KB)" -f $leaf, ((Get-Item $Install).Length / 1KB))
    $Pak = $leaf
}

if (-not $Pak -and -not $Meta) {
    Write-Error "pass -Install <path>, -Pak <name.pak>, -Meta <meta.lsx> or -List"
}

# --- what the module says it is -----------------------------------------------------------------

$metaXml  = $null
$metaFrom = $null

if ($Meta) {
    if (-not (Test-Path $Meta)) { Write-Error "no meta.lsx at $Meta" }
    $metaXml  = [xml](Get-Content $Meta -Raw -Encoding UTF8)
    $metaFrom = $Meta
} else {
    $pakPath = $Pak
    if (-not (Test-Path $pakPath)) { $pakPath = Join-Path $modsDir $Pak }
    if (-not (Test-Path $pakPath)) { Write-Error "no pak at $Pak or $pakPath" }

    if (-not $Divine) { $Divine = Join-Path $PSScriptRoot "lslib\Tools\Divine.exe" }
    if (-not (Test-Path $Divine)) {
        Write-Error ("divine.exe not found at $Divine - reading a pak needs it. If you are " +
                     "installing this layer, pass -Meta <the shipped meta.lsx> instead.")
    }

    # Divine is checked by what it produced, never by $LASTEXITCODE: `list-package` prints a
    # perfectly good listing and still exits non-zero, and `2>&1` on a native command in PS 5.1
    # wraps its stderr in ErrorRecords that trip $ErrorActionPreference = "Stop". Together those
    # two killed this script before its first line of output, which from outside looked exactly
    # like the task having run and done nothing.
    $listing = & $Divine -g bg3 -a list-package -s $pakPath

    # The listing is "<path>\t<size>\t<flags>" per line; the meta is the only file named meta.lsx
    # directly under Mods/<Folder>/.
    $metaPath = $null
    foreach ($line in $listing) {
        $p = ([string]$line -split "`t")[0]
        if ($p -match "^Mods/[^/]+/meta\.lsx$") { $metaPath = $p; break }
    }
    if (-not $metaPath) {
        Write-Error "$pakPath has no Mods/<Folder>/meta.lsx - it is not a mod package"
    }

    $tmp = Join-Path $env:TEMP ("bg3-meta-" + [guid]::NewGuid().ToString("N") + ".lsx")
    & $Divine -g bg3 -a extract-single-file -s $pakPath -f $metaPath -d $tmp | Out-Null
    if (-not (Test-Path $tmp)) { Write-Error "could not extract $metaPath from $pakPath" }

    $metaXml  = [xml](Get-Content $tmp -Raw -Encoding UTF8)
    $metaFrom = $pakPath
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

$info = $metaXml.SelectSingleNode("//node[@id='ModuleInfo']")
if (-not $info) { Write-Error "$metaFrom has no ModuleInfo node" }
function MetaAttr($id) {
    $a = $info.SelectSingleNode("attribute[@id='$id']")
    if ($a) { return $a.value }
    return $null
}

# Presence, not value. Half the attributes that decide whether a meta is Patch 8-shaped are
# legitimately empty - StartupLevelName, PhotoBooth, MD5 - and `-not ""` is true in PowerShell,
# so testing the value rejected a correctly packaged mod and blamed its packaging for it.
function MetaHas($id) {
    return $null -ne $info.SelectSingleNode("attribute[@id='$id']")
}

$folder  = MetaAttr "Folder"
$name    = MetaAttr "Name"
$uuid    = MetaAttr "UUID"
$version = MetaAttr "Version64"
$md5     = MetaAttr "MD5"
$handle  = MetaAttr "PublishHandle"

if (-not $folder -or -not $uuid) { Write-Error "$metaFrom names no Folder/UUID" }

# The gate, and it is narrower than it was - corrected 2026-08-08 by a mod that would have
# failed it and works.
#
# The first version refused anything without `PublishHandle`, on the reasoning that our own
# module lacked it and was invisible. Then a current Nexus mod turned up - "Carry Weight
# Increased 9000", built for Patch 8 - whose meta declares format 4.0.0.49, carries no
# PublishHandle, no FileSize and no Version64, and uses `Version` (int32) where Patch 8 modules
# use `Version64`. All of that is the old shape, and none of it stops the game.
#
# What it does have, and what our broken module did not, is `PublishVersion` **inside**
# `ModuleInfo` rather than beside it. That is the one difference the evidence actually supports,
# so it is the only thing refused here. Everything else is noted and let through: a check that
# blocks a working mod is worse than no check, because it sends its author looking for a fault
# that is not there.
if ($null -eq $info.SelectSingleNode("children/node[@id='PublishVersion']")) {
    Write-Error ("$name has PublishVersion outside ModuleInfo. Patch 8 nests it inside, cannot " +
                 "parse the module otherwise, and says nothing about it: the mod will never " +
                 "appear in AvailableMods and this entry would be deleted at the next launch. " +
                 "The mod needs repackaging, not registering.")
}
if (-not (MetaHas "PublishHandle")) {
    Write-Host "  note: no PublishHandle - the pre-Patch-7 shape. Not fatal; PublishHandle 0 is written."
}
if (-not $version) { $version = "36028797018963968" }
if ($null -eq $md5) { $md5 = "" }
if ($null -eq $handle) { $handle = "0" }

Write-Host ("module: {0}  folder {1}  uuid {2}" -f $name, $folder, $uuid)

# --- writing the load order --------------------------------------------------------------------

$backup = "$settings.bak-a11y"
if (-not (Test-Path $backup)) {
    Copy-Item $settings $backup
    Write-Host "backed up modsettings.lsx -> $backup"
}

[xml]$doc = Get-Content $settings -Raw -Encoding UTF8
$modsNode = $doc.SelectSingleNode("//node[@id='Mods']/children")
if (-not $modsNode) { Write-Error "modsettings.lsx has no Mods/children node - restore $backup" }

$existing = $modsNode.SelectSingleNode(
    "node[@id='ModuleShortDesc'][attribute[@id='Folder'][@value='$folder']]")

if ($Remove) {
    if (-not $existing) { Write-Host "$name was not enabled - nothing to do"; return }
    $modsNode.RemoveChild($existing) | Out-Null
    Write-Host "removed $name from the load order"
} else {
    if ($existing) { Write-Host "$name is already enabled"; return }
    $entry = $doc.CreateElement("node")
    $entry.SetAttribute("id", "ModuleShortDesc")
    # Attribute set and types copied from what the game itself writes: UUID as `guid` here even
    # though meta.lsx calls the same value a FixedString.
    $attrs = [ordered]@{
        Folder        = @("LSString", $folder)
        MD5           = @("LSString", $md5)
        Name          = @("LSString", $name)
        PublishHandle = @("uint64",   $handle)
        UUID          = @("guid",     $uuid)
        Version64     = @("int64",    $version)
    }
    foreach ($k in $attrs.Keys) {
        $a = $doc.CreateElement("attribute")
        $a.SetAttribute("id", $k)
        $a.SetAttribute("type", $attrs[$k][0])
        $a.SetAttribute("value", [string]$attrs[$k][1])
        $entry.AppendChild($a) | Out-Null
    }
    $modsNode.AppendChild($entry) | Out-Null
    Write-Host "enabled $name"
}

# No BOM: that is how the game writes this file.
$utf8 = New-Object System.Text.UTF8Encoding($false)
$w = New-Object System.Xml.XmlTextWriter($settings, $utf8)
$w.Formatting = [System.Xml.Formatting]::Indented
$w.Indentation = 4
try { $doc.WriteTo($w) } finally { $w.Close() }

Write-Host ""
Write-Host "Restart the game. If the entry is gone afterwards, the game could not find the"
Write-Host "module the entry names - which is a packaging problem, not a load-order one."
