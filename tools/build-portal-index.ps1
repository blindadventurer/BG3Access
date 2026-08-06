<#
.SYNOPSIS
    Builds lua/a11y-portaldata.lua out of the game's own navigation portals.

.DESCRIPTION
    A BG3 level is not one walkable surface. It is a handful of disjoint navigation regions -
    the open world, the Underdark, each cellar, each temple wing - and the game stores every
    link between them:

      Levels/<lvl>/Ai/navigationPortals.lsf
        Portal: Source (fvec3), Target (fvec3), Region (guid), TargetRegion (guid)

    Which is exactly the thing the layer was missing and could not have guessed. Interiors in
    this game are placed hundreds of metres away from the building they belong to: the druids'
    inner chambers of the Emerald Grove sit at -440,-4 while the grove itself is at 213,476.
    A straight line to one is a straight line into nothing, and the scanner had no way to know
    that - it measured, correctly, a distance no character can walk.

    Checked before this was written, against the level's own objects: **121 of the 125 portals
    of WLD_Main_A have a named object within six metres of their Source** - S_DOOR_
    GoblinCaveTortureExit, DOOR_GEN_Hatch_Wood_A, S_PLA_Cellar_LadderUp,
    S_HAG_HagLair_PortalToTeaHouse, S_UND_FairyRings_Main_MushroomRing. So a portal is not an
    AI abstraction; it is the door, the hatch, the ladder or the mushroom ring a player uses.

    And checked the other way, against the place table: labelling every named place of
    WLD_Main_A by the region of its nearest portal endpoint reproduces the geography exactly.
    Sixteen places come out as one region - grove, goblin camp, forest, road, swamp, ruins,
    everything you can walk between on the surface. Seven come out as the Underdark. Four as
    the hag's lair, four as Grymforge, four as the druids' chambers, and the temple's three
    wings as three regions of their own. That is the map, and nothing in it had to be guessed.

    Only the regions are stored here, not the Connection tables: those hold a cost the engine
    uses for its own hierarchical pathfinder, and measurement says it is not a distance in any
    sense the layer could use (correlation with the real distance between the portals it links:
    0.09).

    ASCII output, like the other generated tables - see build-quest-index.ps1 for why.

.PARAMETER GameData
    The Data folder of the installed game.

.PARAMETER Force
    Unpack and convert again even when the cache already holds the files.

.EXAMPLE
    powershell -File tools\build-portal-index.ps1
#>
[CmdletBinding()]
param(
    [string] $GameData = "G:\SteamLibrary\steamapps\common\Baldurs Gate 3\Data",
    [string] $Out,
    [switch] $Force
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if (-not $Out) { $Out = Join-Path $root "lua\a11y-portaldata.lua" }

$divine = Join-Path $PSScriptRoot "lslib\Tools\Divine.exe"
$pak    = Join-Path $GameData "Gustav.pak"
$cache  = Join-Path $env:TEMP "bg3access-portals"

if (-not (Test-Path $divine)) { throw "no Divine at $divine" }
if (-not (Test-Path $pak))    { throw "no Gustav.pak at $pak" }

if ($Force -and (Test-Path $cache)) { Remove-Item $cache -Recurse -Force }
$raw = Join-Path $cache "raw"
$lsx = Join-Path $cache "lsx"
if (-not (Test-Path (Join-Path $raw "Mods"))) {
    Write-Host "unpacking the navigation portals out of Gustav.pak..."
    & $divine -g bg3 -a extract-package -s $pak -d $raw -x "Mods/*/Levels/*/Ai/navigationPortals.lsf" | Out-Null
    if (-not (Test-Path (Join-Path $raw "Mods"))) { throw "unpack produced nothing" }
} else {
    Write-Host "using the unpacked copy in $cache (re-unpack with -Force)"
}
if (-not (Test-Path $lsx)) {
    Write-Host "converting lsf to lsx..."
    & $divine -g bg3 -a convert-resources -s (Join-Path $raw "Mods") -d $lsx -i lsf -o lsx | Out-Null
    if (-not (Test-Path $lsx)) { throw "conversion produced nothing" }
}

# ---------------------------------------------------------------- pick one file per level
#
# Four levels are defined by two mods at once, and only WLD_Main_A differs in substance:
# Gustav has 140 portals, GustavDev 125, sharing 121. The nineteen Gustav-only ones are older
# geometry - short hops around the hag's illusion, which the released version reworked - so
# this takes the last mod in load order rather than the union. A portal the game no longer has
# is a door the layer would send somebody to and they would find a wall.

$prio = @{ "Honour" = 4; "GustavX" = 3; "GustavDev" = 2; "Gustav" = 1 }
$pick = @{}
foreach ($f in Get-ChildItem $lsx -Recurse -Filter navigationPortals.lsx -File) {
    $parts = $f.FullName -split '\\'
    $i = [array]::IndexOf($parts, "Levels")
    if ($i -lt 1) { continue }
    $mod = $parts[$i - 1]
    $lvl = $parts[$i + 1]
    $p = 0
    if ($prio.ContainsKey($mod)) { $p = $prio[$mod] }
    if (-not $pick.ContainsKey($lvl) -or $p -gt $pick[$lvl].prio) {
        $pick[$lvl] = [pscustomobject]@{ prio = $p; mod = $mod; path = $f.FullName }
    }
}
Write-Host ("  levels with portals: {0}" -f $pick.Count)

# ---------------------------------------------------------------- read

$levels = @{}
$total = 0; $selfLinks = 0
foreach ($lvl in ($pick.Keys | Sort-Object)) {
    $doc = New-Object System.Xml.XmlDocument
    $doc.Load($pick[$lvl].path)

    $rows = New-Object System.Collections.ArrayList
    $regionId = @{}
    foreach ($n in $doc.SelectNodes("//node[@id='Portal']")) {
        $a = @{}
        foreach ($x in $n.SelectNodes("attribute")) { $a[$x.GetAttribute("id")] = $x.GetAttribute("value") }
        if (-not $a.ContainsKey("Source") -or -not $a.ContainsKey("Target")) { continue }
        $s = $a["Source"] -split ' '
        $t = $a["Target"] -split ' '
        foreach ($g in @($a["Region"], $a["TargetRegion"])) {
            if ($g -and -not $regionId.ContainsKey($g)) { $regionId[$g] = $regionId.Count + 1 }
        }
        $sr = 0; if ($a["Region"])       { $sr = $regionId[$a["Region"]] }
        $tr = 0; if ($a["TargetRegion"]) { $tr = $regionId[$a["TargetRegion"]] }
        if ($sr -eq $tr) { $selfLinks++ }
        [void] $rows.Add([pscustomobject]@{
            sx = [double]$s[0]; sy = [double]$s[1]; sz = [double]$s[2]
            tx = [double]$t[0]; ty = [double]$t[1]; tz = [double]$t[2]
            sr = $sr; tr = $tr
        })
    }
    if ($rows.Count -gt 0) {
        $levels[$lvl] = [pscustomobject]@{ rows = $rows; regions = $regionId.Count }
        $total += $rows.Count
    }
}
Write-Host ("  portals {0} in {1} levels, of them linking a region to itself {2}" -f
            $total, $levels.Count, $selfLinks)

# A check worth having in the output rather than in a comment: how much of the world is only
# reachable through a portal. A level whose portals all link one region to itself has no
# islands, and the routing this feeds would never fire there.
$islanded = 0
foreach ($k in $levels.Keys) { if ($levels[$k].regions -gt 1) { $islanded++ } }
Write-Host ("  levels with more than one navigation region: {0}" -f $islanded)

# ---------------------------------------------------------------- write lua

function Q($s) {
    if ($null -eq $s -or $s -eq "") { return "nil" }
    return '"' + ([string]$s -replace '\\', '\\' -replace '"', '\"') + '"'
}
function N($v) { return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:0.#}", $v) }

$sb = New-Object System.Text.StringBuilder
function W([string] $line) { [void] $sb.AppendLine($line) }

$stamp = (Get-Item $pak).LastWriteTime.ToString("yyyy-MM-dd")
W '-- The links between the walkable islands of a level: the doors, hatches, ladders and rings'
W '-- that are the only way from one to another.'
W '--'
W '-- Generated by tools/build-portal-index.ps1 - do not edit by hand.'
W ('-- Source: Gustav.pak of ' + $stamp + ', Levels/<lvl>/Ai/navigationPortals.lsf.')
W '--'
W '-- A level is not one surface. Interiors are placed hundreds of metres from the building they'
W '-- belong to, so a straight line to one is a straight line into nothing - which is what the'
W '-- scanner used to measure, correctly and uselessly. A portal is where that line is allowed to'
W '-- jump: stand at Source, use what is standing there, arrive at Target.'
W '--'
W '--   M.pt[levelName] = { { sx, sy, sz, tx, ty, tz, srcRegion, dstRegion }, ... }'
W '--'
W '-- The regions are small integers, unique within a level and meaningless across levels. Two'
W '-- points in the same region can be walked between; two points in different regions cannot,'
W '-- and the portals are the whole of what joins them.'
W ''
W 'local M = {}'
W ('M.BUILD = "portaldata ' + $stamp + '"')
W ''

W 'M.pt = {'
foreach ($lvl in ($levels.Keys | Sort-Object)) {
    $rows = @()
    foreach ($r in $levels[$lvl].rows) {
        $rows += ('{' + (N $r.sx) + ',' + (N $r.sy) + ',' + (N $r.sz) + ',' +
                        (N $r.tx) + ',' + (N $r.ty) + ',' + (N $r.tz) + ',' +
                        $r.sr + ',' + $r.tr + '}')
    }
    W ('[' + (Q $lvl) + ']={' + ($rows -join ',') + '},')
}
W '}'
W ''
W 'return M'

$text = $sb.ToString()
if ($text -cmatch '[^\x00-\x7F]') { throw "output is not ASCII - a level name carried a non-ASCII character" }

$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($Out, $text, $enc)

$kb = [math]::Round((Get-Item $Out).Length / 1KB)
Write-Host ""
Write-Host ("done: {0} ({1} KB)" -f $Out, $kb)
