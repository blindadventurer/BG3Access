<#
.SYNOPSIS
    Builds lua/a11y-placedata.lua out of the game's own map of named places.

.DESCRIPTION
    The game knows every place in it by name and by shape, and none of that was reaching the
    player. Three tables inside Gustav.pak hold it:

      Story/RawFiles/Goals/*.txt        DB_Subregion(trigger, "DEN_DruidGrove_SUB", ...)
                                        DB_WaypointInfo(act, "WAYP_GOB_Temple", shrine, trigger)
      Localization/*Subregions*.lsf     "DEN_DruidGrove_SUB"  -> a translated handle
      Localization/Waypointshrines*.lsf "WAYP_GOB_Temple"     -> a translated handle
      Localization/Levels.lsf           "WLD_Main_A"          -> a translated handle
      Levels/<lvl>/Triggers/_merged.lsf the trigger itself: where it stands and what shape it is
      Globals/<lvl>/Items/_merged.lsf   the waypoint shrine, which is an item, not a trigger

    A subregion trigger is a polygon (Points, relative to its own Position, plus a Height), a
    box (Extents, half sizes, turned by RotationQuat), or a bare point. All three come out of
    here as one thing: a closed ring of absolute XZ points and a vertical band. That is what
    lets the layer answer "which place am I standing in" without asking the engine anything.

    Verified offline against a second, independent table: of the 40 fast-travel shrines, 34
    fall inside a subregion of their own level and every one of those lands somewhere that
    makes sense - WAYP_GOB_Temple inside the goblin camp, WAYP_UND_Duergar inside Grymforge,
    WAYP_WYR_Rivington inside Rivington. The six that fall outside are shrines placed on the
    approach to a place rather than in it.

    No text is stored, only localisation handles: the game turns those into strings in its own
    language through Ext.Loca. So the output is pure ASCII and carries no language with it -
    the same rule build-quest-index.ps1 follows.

    Note for whoever edits this file: keep it ASCII. Windows PowerShell 5.1 reads a BOM-less
    .ps1 as ANSI, and a UTF-8 Cyrillic letter then decodes to bytes that include a quote
    character, which silently ends a string literal in the middle of a word.

.PARAMETER GameData
    The Data folder of the installed game.

.PARAMETER Force
    Unpack and convert again even when the cache already holds the files.

.EXAMPLE
    powershell -File tools\build-place-index.ps1
#>
[CmdletBinding()]
param(
    [string] $GameData = "G:\SteamLibrary\steamapps\common\Baldurs Gate 3\Data",
    [string] $Out,
    [switch] $Force
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if (-not $Out) { $Out = Join-Path $root "lua\a11y-placedata.lua" }

$divine = Join-Path $PSScriptRoot "lslib\Tools\Divine.exe"
$pak    = Join-Path $GameData "Gustav.pak"
$cache  = Join-Path $env:TEMP "bg3access-places"

if (-not (Test-Path $divine)) { throw "no Divine at $divine" }
if (-not (Test-Path $pak))    { throw "no Gustav.pak at $pak" }

# ---------------------------------------------------------------- unpack
#
# Four slices, and no more: the goals are the only place the names of places are joined to the
# triggers that hold them, the localisation files are the only place those names are handles,
# and the level triggers plus the level globals are the only places the shapes live. Everything
# else in the 13 GB pak is scenery, sound and geometry.

$slices = @(
    @{ x = "Mods/*/Story/RawFiles/Goals/*.txt";        probe = "goals" },
    @{ x = "Mods/*/Localization/*.lsf";                probe = "loca"  },
    @{ x = "Mods/*/Levels/*/Triggers/_merged.lsf";     probe = "lv"    },
    @{ x = "Mods/*/Globals/*/*/_merged.lsf";           probe = "gl"    }
)

if ($Force -and (Test-Path $cache)) { Remove-Item $cache -Recurse -Force }
$raw = Join-Path $cache "raw"
if (-not (Test-Path (Join-Path $raw "Mods"))) {
    Write-Host "unpacking the place tables out of Gustav.pak (takes a minute)..."
    foreach ($s in $slices) {
        & $divine -g bg3 -a extract-package -s $pak -d $raw -x $s.x | Out-Null
    }
    if (-not (Test-Path (Join-Path $raw "Mods"))) { throw "unpack produced nothing" }
} else {
    Write-Host "using the unpacked copy in $cache (re-unpack with -Force)"
}

$lsx = Join-Path $cache "lsx"
if (-not (Test-Path $lsx)) {
    Write-Host "converting lsf to lsx..."
    & $divine -g bg3 -a convert-resources -s (Join-Path $raw "Mods") -d $lsx -i lsf -o lsx | Out-Null
    if (-not (Test-Path $lsx)) { throw "conversion produced nothing" }
}

# ---------------------------------------------------------------- goals
#
# The two facts the story files carry. A line starting with NOT is a savegame patch taking an
# old row away rather than adding one, and a line starting with // is a comment; both would
# otherwise put places in the table that the game does not have.

$UUID = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$reSub  = [regex] ('DB_Subregion\s*\(\s*(?:\(TRIGGER\)\s*)?\w*?(' + $UUID + ')\s*,\s*"([^"]+)"')
$reWayp = [regex] ('DB_WaypointInfo\s*\(\s*"([^"]*)"\s*,\s*"([^"]+)"\s*,\s*(?:\(ITEM\)\s*)?\w*?(' +
                   $UUID + ')\s*,\s*(?:\(TRIGGER\)\s*)?\w*?(' + $UUID + ')')

$subOf = @{}          # trigger uuid -> subregion id
$waypoints = New-Object System.Collections.ArrayList
foreach ($f in Get-ChildItem (Join-Path $raw "Mods") -Recurse -Filter *.txt -File) {
    if ($f.FullName -notmatch 'RawFiles\\Goals') { continue }
    foreach ($line in [System.IO.File]::ReadAllLines($f.FullName)) {
        $s = $line.Trim()
        if ($s.Length -eq 0 -or $s.StartsWith("//") -or $s.StartsWith("NOT ")) { continue }
        $m = $reSub.Match($s)
        if ($m.Success) {
            $k = $m.Groups[1].Value.ToLower()
            if (-not $subOf.ContainsKey($k)) { $subOf[$k] = $m.Groups[2].Value }
        }
        $m = $reWayp.Match($s)
        if ($m.Success) {
            [void] $waypoints.Add([pscustomobject]@{
                id     = $m.Groups[2].Value
                shrine = $m.Groups[3].Value.ToLower()
                trig   = $m.Groups[4].Value.ToLower()
            })
        }
    }
}
Write-Host ("  subregion triggers {0}, waypoints {1}" -f $subOf.Count, $waypoints.Count)

# ---------------------------------------------------------------- names
#
# One flat id -> handle map over every localisation file, because the ids are unique across
# them and which file a place happens to be declared in is an accident of which act shipped it.

function Clean-Handle($h) {
    if ([string]::IsNullOrEmpty($h)) { return $null }
    if ($h -like "ls::*") { return $null }
    if ($h -notlike "h*") { return $null }
    return $h
}

$handle = @{}
$levelName = @{}
foreach ($f in Get-ChildItem $lsx -Recurse -Filter *.lsx -File) {
    if ($f.FullName -notmatch '\\Localization\\') { continue }
    $isLevels = ($f.Name -eq "Levels.lsx")
    $doc = New-Object System.Xml.XmlDocument
    $doc.Load($f.FullName)
    foreach ($n in $doc.SelectNodes("//node[@id='TranslatedStringKey']")) {
        $id = $null; $h = $null
        foreach ($a in $n.SelectNodes("attribute")) {
            switch ($a.GetAttribute("id")) {
                "UUID"    { $id = $a.GetAttribute("value") }
                "Content" { $h  = $a.GetAttribute("handle") }
            }
        }
        $h = Clean-Handle $h
        if (-not $id -or -not $h) { continue }
        if (-not $handle.ContainsKey($id)) { $handle[$id] = $h }
        # Levels.lsf is the one file whose ids are level names, which is how the layer can say
        # where you are before it knows anything else about the place.
        if ($isLevels -and -not $levelName.ContainsKey($id)) { $levelName[$id] = $h }
    }
}
Write-Host ("  named ids {0}, of them levels {1}" -f $handle.Count, $levelName.Count)

# ---------------------------------------------------------------- triggers
#
# Streamed rather than loaded: WLD_Main_A alone is 20 MB of XML and 4394 objects, and all but a
# handful of them are cameras, sound zones and combat areas. So the outer XML of each object is
# read as a string, its MapKey picked out with one regex, and only the objects actually wanted
# are handed to an XML parser.

$want = @{}
foreach ($k in $subOf.Keys) { $want[$k] = $true }
foreach ($w in $waypoints)  { $want[$w.shrine] = $true; $want[$w.trig] = $true }

$reKey = [regex] '<attribute id="MapKey" type="FixedString" value="([^"]+)"'
$found = @{}

function Read-Objects([string] $path) {
    $set = New-Object System.Xml.XmlReaderSettings
    $set.IgnoreWhitespace = $true
    $set.IgnoreComments = $true
    $rd = [System.Xml.XmlReader]::Create($path, $set)
    try {
        # ReadOuterXml already leaves the reader on the node *after* the one it swallowed, so
        # calling Read() again would step over it. With two GameObjects side by side - which is
        # what a level file is - that reads every other object and silently loses half the
        # level. Hence the flag rather than a plain while(Read()).
        $advanced = $true
        while ($true) {
            if (-not $advanced) { if (-not $rd.Read()) { break } }
            $advanced = $false
            if ($rd.EOF) { break }
            if ($rd.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
            if ($rd.Name -ne "node") { continue }
            if ($rd.GetAttribute("id") -ne "GameObjects") { continue }
            $xml = $rd.ReadOuterXml()
            $advanced = $true
            $m = $reKey.Match($xml)
            if (-not $m.Success) { continue }
            $key = $m.Groups[1].Value.ToLower()
            if (-not $want.ContainsKey($key)) { continue }
            # Keep the richest copy: a level is assembled from several mods and the same
            # trigger can appear in more than one of them, sometimes without its polygon.
            $doc = New-Object System.Xml.XmlDocument
            $doc.LoadXml($xml)
            $node = $doc.DocumentElement

            $attrs = @{}
            foreach ($a in $node.SelectNodes("attribute")) {
                $attrs[$a.GetAttribute("id")] = $a.GetAttribute("value")
            }
            $pos = $null; $rot = $null
            $t = $node.SelectSingleNode("children/node[@id='Transform']")
            if ($t) {
                foreach ($a in $t.SelectNodes("attribute")) {
                    switch ($a.GetAttribute("id")) {
                        "Position"     { $pos = $a.GetAttribute("value") -split ' ' }
                        "RotationQuat" { $rot = $a.GetAttribute("value") -split ' ' }
                    }
                }
            }
            $pts = New-Object System.Collections.ArrayList
            foreach ($p in $node.SelectNodes("children/node[@id='Points']/attribute[@id='Object']")) {
                $v = $p.GetAttribute("value") -split ' '
                [void] $pts.Add(@([double]$v[0], [double]$v[1]))
            }
            if ($pos -eq $null) { continue }

            $rec = [pscustomobject]@{
                level  = $attrs["LevelName"]
                name   = $attrs["Name"]
                x      = [double]$pos[0]; y = [double]$pos[1]; z = [double]$pos[2]
                rot    = $rot
                pts    = $pts
                height = $(if ($attrs.ContainsKey("Height")) { [double]$attrs["Height"] } else { $null })
                ext    = $(if ($attrs.ContainsKey("Extents")) { $attrs["Extents"] -split ' ' } else { $null })
            }
            $old = $found[$key]
            if ($old -eq $null -or $pts.Count -gt $old.pts.Count) { $found[$key] = $rec }
        }
    } finally { $rd.Close() }
}

$files = @(Get-ChildItem $lsx -Recurse -Filter _merged.lsx -File |
           Where-Object { $_.FullName -match '\\(Triggers|Items|Characters)\\' })
Write-Host ("  reading {0} level files..." -f $files.Count)
$i = 0
foreach ($f in $files) {
    $i++
    if ($i % 100 -eq 0) { Write-Host ("    {0}/{1}" -f $i, $files.Count) }
    Read-Objects $f.FullName
}
Write-Host ("  triggers resolved {0} of {1}" -f $found.Count, $want.Count)

# ---------------------------------------------------------------- shapes
#
# Three shapes in, one out. The ring is absolute XZ, so the Lua side does a plain
# point-in-polygon and never has to know which of the three a place was authored as.

function Ring($r) {
    $out = New-Object System.Collections.ArrayList
    if ($r.pts.Count -ge 3) {
        # Every element of an array literal is parenthesised on purpose: in PowerShell the comma
        # binds tighter than the plus, so @($a + $b, $c + $d) is read as $a + ($b, $c) + $d and
        # dies with an op_Addition error a long way from the line that caused it.
        foreach ($p in $r.pts) { [void] $out.Add(@(($r.x + $p[0]), ($r.z + $p[1]))) }
        $y0 = $r.y
        $y1 = $r.y + $(if ($r.height) { $r.height } else { 0 })
        return @{ ring = $out; y0 = $y0; y1 = $y1 }
    }
    if ($r.ext -ne $null) {
        $ex = [double]$r.ext[0]; $ey = [double]$r.ext[1]; $ez = [double]$r.ext[2]
        # Yaw out of the quaternion, so a room built at an angle is still that room.
        $qx = 0.0; $qy = 0.0; $qz = 0.0; $qw = 1.0
        if ($r.rot -ne $null) {
            $qx = [double]$r.rot[0]; $qy = [double]$r.rot[1]
            $qz = [double]$r.rot[2]; $qw = [double]$r.rot[3]
        }
        $yaw = [Math]::Atan2(2 * ($qw * $qy + $qx * $qz), 1 - 2 * ($qy * $qy + $qz * $qz))
        $cosy = [Math]::Cos($yaw); $siny = [Math]::Sin($yaw)
        $ox = [double] $r.x; $oz = [double] $r.z
        $signx = @(-1.0, 1.0, 1.0, -1.0)
        $signz = @(-1.0, -1.0, 1.0, 1.0)
        for ($k = 0; $k -lt 4; $k++) {
            $cx = $signx[$k] * $ex
            $cz = $signz[$k] * $ez
            [void] $out.Add(@(($ox + $cx * $cosy + $cz * $siny), ($oz - $cx * $siny + $cz * $cosy)))
        }
        return @{ ring = $out; y0 = $r.y - $ey; y1 = $r.y + $ey }
    }
    # A bare point. It still answers "where is it" and "how far"; it just cannot answer
    # "am I inside it", and the layer is told so by the empty ring.
    return @{ ring = $out; y0 = $r.y - 4; y1 = $r.y + 4 }
}

$subs = @{}       # level -> list of rows
$noName = 0; $noTrigger = 0
foreach ($u in ($subOf.Keys | Sort-Object)) {
    $r = $found[$u]
    if ($r -eq $null) { $noTrigger++; continue }
    $sid = $subOf[$u]
    $h = $handle[$sid]
    if (-not $h) { $noName++ }
    $sh = Ring $r
    $lvl = $r.level
    if (-not $subs.ContainsKey($lvl)) { $subs[$lvl] = New-Object System.Collections.ArrayList }
    [void] $subs[$lvl].Add([pscustomobject]@{
        id = $sid; handle = $h; x = $r.x; y = $r.y; z = $r.z
        y0 = $sh.y0; y1 = $sh.y1; ring = $sh.ring
    })
}

$waps = @{}
$noWayp = 0
foreach ($w in $waypoints) {
    $r = $found[$w.shrine]
    if ($r -eq $null) { $r = $found[$w.trig] }
    if ($r -eq $null) { $noWayp++; continue }
    $lvl = $r.level
    if (-not $waps.ContainsKey($lvl)) { $waps[$lvl] = New-Object System.Collections.ArrayList }
    [void] $waps[$lvl].Add([pscustomobject]@{
        id = $w.id; handle = $handle[$w.id]; uuid = $w.shrine
        x = $r.x; y = $r.y; z = $r.z
    })
}

$nsub = 0; foreach ($k in $subs.Keys) { $nsub += $subs[$k].Count }
$nwap = 0; foreach ($k in $waps.Keys) { $nwap += $waps[$k].Count }
Write-Host ("  places {0} in {1} levels (no trigger {2}, no name {3})" -f $nsub, $subs.Count, $noTrigger, $noName)
Write-Host ("  waypoints {0} in {1} levels (no place {2})" -f $nwap, $waps.Count, $noWayp)

# A check that costs nothing and catches a broken join: the waypoints are a second, independent
# table, so how many of them land inside a subregion of their own level says whether the shapes
# came out right. Measured when this was written: 34 of 40.
function InRing($x, $z, $ring) {
    $inside = $false
    $n = $ring.Count
    if ($n -lt 3) { return $false }
    $j = $n - 1
    for ($i = 0; $i -lt $n; $i++) {
        $xi = $ring[$i][0]; $zi = $ring[$i][1]
        $xj = $ring[$j][0]; $zj = $ring[$j][1]
        if ((($zi -gt $z) -ne ($zj -gt $z)) -and
            ($x -lt (($xj - $xi) * ($z - $zi) / ($zj - $zi) + $xi))) { $inside = -not $inside }
        $j = $i
    }
    return $inside
}
$hit = 0
foreach ($lvl in $waps.Keys) {
    foreach ($w in $waps[$lvl]) {
        foreach ($s in $subs[$lvl]) {
            if (InRing $w.x $w.z $s.ring) { $hit++; break }
        }
    }
}
Write-Host ("  self-check: {0} of {1} waypoints fall inside a place of their own level" -f $hit, $nwap)

# ---------------------------------------------------------------- write lua

function Q($s) {
    if ($null -eq $s -or $s -eq "") { return "nil" }
    return '"' + ([string]$s -replace '\\', '\\' -replace '"', '\"') + '"'
}
function N($v) { return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:0.#}", $v) }

$sb = New-Object System.Text.StringBuilder
function W([string] $line) { [void] $sb.AppendLine($line) }

$stamp = (Get-Item $pak).LastWriteTime.ToString("yyyy-MM-dd")
W '-- The places of the game as a table: what each one is called, where it is, and what shape.'
W '--'
W '-- Generated by tools/build-place-index.ps1 - do not edit by hand.'
W ('-- Source: Gustav.pak of ' + $stamp + ' - the Subregion and Waypoint tables of the story,')
W '-- joined to the triggers that hold their shapes.'
W '--'
W '-- No text here, only localisation handles: the game itself turns them into strings, in the'
W '-- language it is being played in, through Ext.Loca. So this file is ASCII and carries no'
W '-- language of its own.'
W '--'
W '--   M.lvl[levelName]  = titleHandle                     -- what the level itself is called'
W '--   M.sub[levelName]  = { { id, handle, x, y, z, y0, y1, {x,z, x,z, ...} }, ... }'
W '--   M.wp[levelName]   = { { id, handle, uuid, x, y, z }, ... }'
W '--'
W '-- The ring is absolute XZ and closed implicitly; it is empty for the few places authored as'
W '-- a bare point, which can be measured to but not stood inside. y0..y1 is the vertical band,'
W '-- and it is what keeps a cellar from answering for the room above it.'
W ''
W 'local M = {}'
W ('M.BUILD = "placedata ' + $stamp + '"')
W ''

W 'M.lvl = {'
foreach ($id in ($levelName.Keys | Sort-Object)) {
    W ('[' + (Q $id) + ']=' + (Q $levelName[$id]) + ',')
}
W '}'
W ''

W 'M.sub = {'
foreach ($lvl in ($subs.Keys | Sort-Object)) {
    $rows = @()
    foreach ($s in ($subs[$lvl] | Sort-Object id)) {
        $ring = @()
        foreach ($p in $s.ring) { $ring += (N $p[0]); $ring += (N $p[1]) }
        $rows += ('{' + (Q $s.id) + ',' + (Q $s.handle) + ',' +
                  (N $s.x) + ',' + (N $s.y) + ',' + (N $s.z) + ',' +
                  (N $s.y0) + ',' + (N $s.y1) + ',{' + ($ring -join ',') + '}}')
    }
    W ('[' + (Q $lvl) + ']={' + ($rows -join ',') + '},')
}
W '}'
W ''

W 'M.wp = {'
foreach ($lvl in ($waps.Keys | Sort-Object)) {
    $rows = @()
    foreach ($w in ($waps[$lvl] | Sort-Object id)) {
        $rows += ('{' + (Q $w.id) + ',' + (Q $w.handle) + ',' + (Q $w.uuid) + ',' +
                  (N $w.x) + ',' + (N $w.y) + ',' + (N $w.z) + '}')
    }
    W ('[' + (Q $lvl) + ']={' + ($rows -join ',') + '},')
}
W '}'
W ''
W 'return M'

$text = $sb.ToString()
if ($text -cmatch '[^\x00-\x7F]') { throw "output is not ASCII - an id or handle carried a non-ASCII character" }

$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($Out, $text, $enc)

$kb = [math]::Round((Get-Item $Out).Length / 1KB)
Write-Host ""
Write-Host ("done: {0} ({1} KB)" -f $Out, $kb)
