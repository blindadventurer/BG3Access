<#
.SYNOPSIS
    Builds lua/a11y-questdata.lua out of the game's own journal tables.

.DESCRIPTION
    The game keeps its journal as data rather than as text. Mods/GustavDev/Story/Journal/
    inside Gustav.pak holds 167 quests with their steps, 1335 objectives and 540 markers -
    and a marker carries the UUID of the very object the objective is about. The layer never
    had that, so it guessed the object by matching words from the objective sentence against
    whatever the scan happened to see.

    This unpacks three files (plus the Markers folder), joins them, and writes the result as
    a Lua module into lua/, where build-mod.ps1 and push-lua.ps1 pick it up on their own -
    nothing else in the build has to change.

    No text is stored, only localisation handles: the game turns those into strings in its own
    language through Ext.Loca. So the output is pure ASCII and carries no language with it.

    Note for whoever edits this file: keep it ASCII. Windows PowerShell 5.1 reads a BOM-less
    .ps1 as ANSI, and a UTF-8 Cyrillic letter then decodes to bytes that include a quote
    character, which silently ends a string literal in the middle of a word. No script in
    tools/ carries a BOM, so the rule here is English comments and ASCII output.

.PARAMETER GameData
    The Data folder of the installed game.

.PARAMETER Force
    Unpack again even when the cache already holds the journal.

.PARAMETER WithSteps
    Also emit M.steps - every quest's steps in journal order. Off by default, and that is a
    judgement rather than a size cut: it is 348 KB of the 580, and what it would answer -
    "what comes next in this quest" - it answers badly. The rows are authoring order, not
    play order, and alternatives sit side by side in it (LearnedHelm_Laezel,
    LearnedHelm_AltGuide, LearnedHelm_Devourer are three ways through the same beat, not
    three beats). Reading that out would be both unreliable and a spoiler. The switch keeps
    the table one flag away for whoever finds a use for it that survives those two facts.

.EXAMPLE
    powershell -File tools\build-quest-index.ps1
#>
[CmdletBinding()]
param(
    [string] $GameData = "G:\SteamLibrary\steamapps\common\Baldurs Gate 3\Data",
    [string] $Out,
    [switch] $Force,
    [switch] $WithSteps
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if (-not $Out) { $Out = Join-Path $root "lua\a11y-questdata.lua" }

$divine = Join-Path $PSScriptRoot "lslib\Tools\Divine.exe"
$pak    = Join-Path $GameData "Gustav.pak"
$cache  = Join-Path $env:TEMP "bg3access-journal"
$jdir   = Join-Path $cache "Mods\GustavDev\Story\Journal"

if (-not (Test-Path $divine)) { throw "no Divine at $divine" }
if (-not (Test-Path $pak))    { throw "no Gustav.pak at $pak" }

# ---------------------------------------------------------------- unpack

if ($Force -and (Test-Path $cache)) { Remove-Item $cache -Recurse -Force }
if (-not (Test-Path (Join-Path $jdir "quest_prototypes.lsx"))) {
    Write-Host "unpacking the journal out of Gustav.pak (takes a minute)..."
    & $divine -g bg3 -a extract-package -s $pak -d $cache -x "Mods/GustavDev/Story/Journal/*" | Out-Null
    if (-not (Test-Path (Join-Path $jdir "quest_prototypes.lsx"))) { throw "unpack produced no quest_prototypes.lsx" }
} else {
    Write-Host "using the unpacked copy in $cache (re-unpack with -Force)"
}

# ---------------------------------------------------------------- read lsx
#
# The format is regular: a node carries its own attributes as direct children and nests other
# nodes inside <children>. So one level of XPath is enough - a deep search would pick up the
# MapKey of a nested object instead of the node's own, which is exactly the trap that made the
# first pass over the level files return the level name for every object.

function Read-Lsx([string] $path) {
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $false
    $doc.Load($path)
    return $doc
}

function Get-Attrs($node) {
    $h = @{}
    foreach ($a in $node.SelectNodes("attribute")) {
        $id = $a.GetAttribute("id")
        if ($a.HasAttribute("value"))      { $h[$id] = $a.GetAttribute("value") }
        elseif ($a.HasAttribute("handle")) { $h[$id] = $a.GetAttribute("handle") }
    }
    return $h
}

# The game writes an "unknown string" handle where a translation is missing; it is no use here.
function Clean-Handle($h) {
    if ([string]::IsNullOrEmpty($h)) { return $null }
    if ($h -like "ls::*") { return $null }
    if ($h -notlike "h*") { return $null }
    return $h
}

Write-Host "reading quest_prototypes.lsx..."
$qdoc = Read-Lsx (Join-Path $jdir "quest_prototypes.lsx")

$quests = @{}          # questID -> @{ title; category; steps }
$stepCount = 0
foreach ($qn in $qdoc.SelectNodes("//node[@id='Quest']")) {
    $q = Get-Attrs $qn
    $qid = $q["QuestID"]
    if ([string]::IsNullOrEmpty($qid)) { continue }
    $steps = New-Object System.Collections.ArrayList
    foreach ($sn in $qn.SelectNodes("children/node[@id='QuestStep']")) {
        $s = Get-Attrs $sn
        $sid = $s["ID"]
        if ([string]::IsNullOrEmpty($sid)) { continue }
        [void] $steps.Add([pscustomobject]@{
            id   = $sid
            desc = Clean-Handle $s["Description"]
            obj  = $s["Objective"]
        })
        $stepCount++
    }
    $quests[$qid] = [pscustomobject]@{
        title    = Clean-Handle $q["QuestTitle"]
        category = $q["CategoryID"]
        steps    = $steps
    }
}
Write-Host ("  quests {0}, steps {1}" -f $quests.Count, $stepCount)

# The game's own answer to "is this the main story or not".
#
# questcategory_prototypes.lsx is fourteen rows: the sections of the journal, each with the
# priority it is sorted by. MainQuest is 10, PersonalStory 9, then the geographic ones
# descending to Companions at 1. That number is the only ordering of quests the game itself
# states, so it is the one the layer sorts targets by - anything else would be a scale invented
# here. The name is a handle like everything else, which means the layer says the category in
# the player's own language without a word of it being written into the mod.
Write-Host "reading questcategory_prototypes.lsx..."
$cats = @{}            # categoryID -> @{ prio; name }
$cdoc = Read-Lsx (Join-Path $jdir "questcategory_prototypes.lsx")
foreach ($cn in $cdoc.SelectNodes("//node[@id='QuestCategory']")) {
    $c = Get-Attrs $cn
    $cid = $c["CategoryID"]
    if ([string]::IsNullOrEmpty($cid)) { continue }
    $p = 0
    [void][int]::TryParse([string]$c["SortingPriority"], [ref] $p)
    $cats[$cid] = [pscustomobject]@{
        prio = $p
        name = Clean-Handle $c["Description"]
    }
}
Write-Host ("  categories {0}" -f $cats.Count)

Write-Host "reading objective_prototypes.lsx..."
$odoc = Read-Lsx (Join-Path $jdir "objective_prototypes.lsx")

$objs = @{}            # objectiveID -> @{ quest; desc; markers }
$byHandle = @{}        # objective description handle -> objectiveID
foreach ($on in $odoc.SelectNodes("//node[@id='Objective']")) {
    $o = Get-Attrs $on
    $oid = $o["ObjectiveID"]
    if ([string]::IsNullOrEmpty($oid)) { continue }
    $mk = New-Object System.Collections.ArrayList
    foreach ($mn in $on.SelectNodes("children/node[@id='Markers']")) {
        $m = Get-Attrs $mn
        if (-not [string]::IsNullOrEmpty($m["Markers"])) { [void] $mk.Add($m["Markers"]) }
    }
    $desc = Clean-Handle $o["Description"]
    $objs[$oid] = [pscustomobject]@{
        quest   = $o["QuestID"]
        desc    = $desc
        markers = $mk
    }
    if ($desc -and -not $byHandle.ContainsKey($desc)) { $byHandle[$desc] = $oid }
}
Write-Host ("  objectives {0}, of them with text {1}" -f $objs.Count, $byHandle.Count)

Write-Host "reading markers..."
$marks = @{}           # markerID -> @( @{level;type;uuid;label} )
$mfiles = Get-ChildItem (Join-Path $jdir "Markers") -Filter *.lsx -File
foreach ($f in $mfiles) {
    $mdoc = Read-Lsx $f.FullName
    foreach ($mn in $mdoc.SelectNodes("//node[@id='Marker']")) {
        $m = Get-Attrs $mn
        $mid  = $m["MarkerID"]
        $uuid = $m["MarkerTargetObjectUUID"]
        if ([string]::IsNullOrEmpty($mid) -or [string]::IsNullOrEmpty($uuid)) { continue }
        if (-not $marks.ContainsKey($mid)) { $marks[$mid] = New-Object System.Collections.ArrayList }
        [void] $marks[$mid].Add([pscustomobject]@{
            level = $m["MarkerLevel"]
            type  = $m["MarkerTargetObjectType"]
            uuid  = $uuid
            label = Clean-Handle $m["DisplayText"]
        })
    }
}
$mpoints = 0
foreach ($k in $marks.Keys) { $mpoints += $marks[$k].Count }
Write-Host ("  markers {0} in {1} points" -f $marks.Count, $mpoints)

# How many objectives actually reach a place. That number is the whole point of the table.
$reach = 0
foreach ($oid in $objs.Keys) {
    foreach ($mid in $objs[$oid].markers) { if ($marks.ContainsKey($mid)) { $reach++; break } }
}
Write-Host ("  objectives that lead to a point: {0} of {1}" -f $reach, $objs.Count)

# ---------------------------------------------------------------- write lua

# Untyped on purpose: a [string] parameter turns $null into "", and an empty string in the
# table is not the same as a missing one - the load-time reverse index would happily key
# itself on "" and hand back an arbitrary objective for anything that had no handle.
function Q($s) {
    if ($null -eq $s -or $s -eq "") { return "nil" }
    return '"' + ([string]$s -replace '\\', '\\' -replace '"', '\"') + '"'
}

$sb = New-Object System.Text.StringBuilder
function W([string] $line) { [void] $sb.AppendLine($line) }

$stamp = (Get-Item $pak).LastWriteTime.ToString("yyyy-MM-dd")
W '-- The game journal as a table: objectives, steps, and the places they send you to.'
W '--'
W '-- Generated by tools/build-quest-index.ps1 - do not edit by hand.'
W ('-- Source: Gustav.pak of ' + $stamp + ', Mods/GustavDev/Story/Journal/.')
W '--'
W '-- No text here, only localisation handles: the game itself turns them into strings, in the'
W '-- language it is being played in, through Ext.Loca. So this file is ASCII and carries no'
W '-- language of its own.'
W '--'
W '--   M.obj[objectiveID] = { questID, descHandle, markerID... }'
W '--   M.mk[markerID]     = { { level, type, uuid, labelHandle }, ... }'
W '--   M.q[questID]       = { titleHandle, categoryID }'
W '--   M.cat[categoryID]  = { sortingPriority, nameHandle }  -- the journal own sections'
W '--   M.oh[descHandle]   = objectiveID   -- built at load: the objective a journal line is'
if ($WithSteps) {
W '--   M.steps[questID]   = { { stepID, descHandle, objectiveID }, ... }  -- journal order'
W '--   M.sh[descHandle]   = { questID, stepID, objectiveID }  -- built at load'
}
W ''
W 'local M = {}'
W ('M.BUILD = "questdata ' + $stamp + '"')
W ''

W 'M.obj = {'
foreach ($oid in ($objs.Keys | Sort-Object)) {
    $o = $objs[$oid]
    $parts = @((Q $o.quest), (Q $o.desc))
    foreach ($mid in $o.markers) { $parts += (Q $mid) }
    W ('[' + (Q $oid) + ']={' + ($parts -join ',') + '},')
}
W '}'
W ''

W 'M.mk = {'
foreach ($mid in ($marks.Keys | Sort-Object)) {
    $pts = @()
    foreach ($p in $marks[$mid]) {
        $pts += ('{' + (Q $p.level) + ',' + (Q $p.type) + ',' + (Q $p.uuid) + ',' + (Q $p.label) + '}')
    }
    W ('[' + (Q $mid) + ']={' + ($pts -join ',') + '},')
}
W '}'
W ''

W 'M.q = {'
foreach ($qid in ($quests.Keys | Sort-Object)) {
    W ('[' + (Q $qid) + ']={' + (Q $quests[$qid].title) + ',' + (Q $quests[$qid].category) + '},')
}
W '}'
W ''

W 'M.cat = {'
foreach ($cid in ($cats.Keys | Sort-Object)) {
    W ('[' + (Q $cid) + ']={' + $cats[$cid].prio + ',' + (Q $cats[$cid].name) + '},')
}
W '}'
W ''

if ($WithSteps) {
W 'M.steps = {'
foreach ($qid in ($quests.Keys | Sort-Object)) {
    $rows = @()
    foreach ($s in $quests[$qid].steps) {
        $rows += ('{' + (Q $s.id) + ',' + (Q $s.desc) + ',' + (Q $s.obj) + '}')
    }
    if ($rows.Count -gt 0) { W ('[' + (Q $qid) + ']={' + ($rows -join ',') + '},') }
}
W '}'
W ''
}

W '--- The reverse turns, built at load rather than shipped.'
W '---'
W '--- Writing the same facts out again would have cost 90 KB for M.oh alone, and one pass over'
W '--- a table this size is not measurable next to loading the file at all.'
W 'M.oh = {}'
W 'for oid, row in pairs(M.obj) do'
W '    local h = row[2]'
W '    if h ~= nil and M.oh[h] == nil then M.oh[h] = oid end'
W 'end'
W ''
if ($WithSteps) {
W 'M.sh = {}'
W 'for qid, rows in pairs(M.steps) do'
W '    for i = 1, #rows do'
W '        local r = rows[i]'
W '        if r[2] ~= nil and M.sh[r[2]] == nil then M.sh[r[2]] = { qid, r[1], r[3] } end'
W '    end'
W 'end'
W ''
}
W 'return M'

$text = $sb.ToString()
if ($text -cmatch '[^\x00-\x7F]') { throw "output is not ASCII - a handle or id carried a non-ASCII character" }

$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($Out, $text, $enc)

$kb = [math]::Round((Get-Item $Out).Length / 1KB)
Write-Host ""
Write-Host ("done: {0} ({1} KB)" -f $Out, $kb)
