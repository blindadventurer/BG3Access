<#
.SYNOPSIS
    Builds lua/a11y-rcdata.lua - the text the game shows when it asks "are you sure".

.DESCRIPTION
    Larian call these ready checks, and they are the only warning the game gives before a step
    that cannot be taken back. The story raises one with

        ReadyCheckGlobal("ReadyCheck_EnterNightsongPrison", "Message_ProgressingWorldState", 1, _Char)

    - an id, and the **message key** whose text the modal shows. Sighted players read that box;
    in the controller interface it is one of the easiest things in the game to walk past, and
    walking past it is how an act's worth of unfinished quests is lost.

    The texts live in Localization/ReadyChecks_Descriptions.lsf (one copy in Shared.pak, one in
    Gustav.pak), plus a couple of keys that sit in the ordinary Misc tables next to them. Both
    are read here, and the Misc rows are filtered by name because those files hold thousands of
    unrelated strings: only ids that speak of a ready check, a region swap or the world state
    are kept.

    What is emitted is a message key -> handle map and nothing else. The layer receives the key
    from Osiris at runtime and turns it into a sentence through Ext.Loca, so this file carries
    no language, exactly like the quest and place indexes.

    Note for whoever edits this file: keep it ASCII. Windows PowerShell 5.1 reads a BOM-less
    .ps1 as ANSI, and a UTF-8 Cyrillic letter then decodes to bytes that include a quote
    character, which silently ends a string literal in the middle of a word.

.PARAMETER GameData
    The Data folder of the installed game.

.PARAMETER Force
    Unpack and convert again even when the cache already holds the files.

.EXAMPLE
    powershell -File tools\build-readycheck-index.ps1
#>
[CmdletBinding()]
param(
    [string] $GameData = "G:\SteamLibrary\steamapps\common\Baldurs Gate 3\Data",
    [string] $Out,
    [switch] $Force
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if (-not $Out) { $Out = Join-Path $root "lua\a11y-rcdata.lua" }

$divine = Join-Path $PSScriptRoot "lslib\Tools\Divine.exe"
$cache  = Join-Path $env:TEMP "bg3access-readychecks"

if (-not (Test-Path $divine)) { throw "no Divine at $divine" }

# ---------------------------------------------------------------- unpack

$paks = @("Shared.pak", "Gustav.pak")
$slices = @("*/Localization/ReadyChecks_Descriptions.lsf", "Mods/*/Localization/*Misc*.lsf")

if ($Force -and (Test-Path $cache)) { Remove-Item $cache -Recurse -Force }
$raw = Join-Path $cache "raw"
if (-not (Test-Path $raw)) {
    Write-Host "unpacking the ready-check tables (takes a moment)..."
    foreach ($p in $paks) {
        $pak = Join-Path $GameData $p
        if (-not (Test-Path $pak)) { throw "no $p at $pak" }
        foreach ($x in $slices) {
            & $divine -g bg3 -a extract-package -s $pak -d $raw -x $x | Out-Null
        }
    }
    if (-not (Test-Path $raw)) { throw "unpack produced nothing" }
} else {
    Write-Host "using the unpacked copy in $cache (re-unpack with -Force)"
}

$lsx = Join-Path $cache "lsx"
if (-not (Test-Path $lsx)) {
    Write-Host "converting lsf to lsx..."
    & $divine -g bg3 -a convert-resources -s $raw -d $lsx -i lsf -o lsx | Out-Null
    if (-not (Test-Path $lsx)) { throw "conversion produced nothing" }
}

# ---------------------------------------------------------------- read

function Clean-Handle($h) {
    if ([string]::IsNullOrEmpty($h)) { return $null }
    if ($h -like "ls::*") { return $null }
    if ($h -notlike "h*") { return $null }
    return $h
}

# Which ids are worth keeping out of a Misc table. The descriptions file is taken whole.
$keep = [regex] 'ReadyCheck|Regionswap|RegionSwap|ProgressingWorldState'

$msg = @{}
$fromDesc = 0
$fromMisc = 0
foreach ($f in Get-ChildItem $lsx -Recurse -Filter *.lsx -File) {
    $isDesc = ($f.Name -like "ReadyChecks_Descriptions*")
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
        if (-not $isDesc -and -not $keep.IsMatch($id)) { continue }
        if ($msg.ContainsKey($id)) { continue }
        $msg[$id] = $h
        if ($isDesc) { $fromDesc++ } else { $fromMisc++ }
    }
}
Write-Host ("  messages {0} (descriptions {1}, misc {2})" -f $msg.Count, $fromDesc, $fromMisc)
if ($msg.Count -eq 0) { throw "no ready-check messages found - the tables moved" }

# ---------------------------------------------------------------- write lua

function Q($s) {
    if ($null -eq $s -or $s -eq "") { return "nil" }
    return '"' + ([string]$s -replace '\\', '\\' -replace '"', '\"') + '"'
}

$sb = New-Object System.Text.StringBuilder
function W([string] $line) { [void] $sb.AppendLine($line) }

$stamp = (Get-Item (Join-Path $GameData "Gustav.pak")).LastWriteTime.ToString("yyyy-MM-dd")
W '-- What the game says when it asks whether you are ready.'
W '--'
W '-- Generated by tools/build-readycheck-index.ps1 - do not edit by hand.'
W ('-- Source: Shared.pak and Gustav.pak of ' + $stamp + ', Localization/ReadyChecks_Descriptions')
W '-- plus the ready-check rows of the Misc tables beside them.'
W '--'
W '-- A ready check is the only warning the game gives before something that cannot be undone.'
W '-- The story names the message; the layer says it. No text here, only handles - the game'
W '-- turns them into sentences in its own language through Ext.Loca.'
W '--'
W '--   M.msg[messageKey] = handle'
W ''
W 'local M = {}'
W ('M.BUILD = "rcdata ' + $stamp + '"')
W ''
W 'M.msg = {'
foreach ($k in ($msg.Keys | Sort-Object)) {
    W ('[' + (Q $k) + ']=' + (Q $msg[$k]) + ',')
}
W '}'
W ''
W 'return M'

$text = $sb.ToString()
if ($text -cmatch '[^\x00-\x7F]') { throw "output is not ASCII - a key or handle carried a non-ASCII character" }

$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($Out, $text, $enc)

$kb = [math]::Round((Get-Item $Out).Length / 1KB, 1)
Write-Host ""
Write-Host ("done: {0} ({1} KB)" -f $Out, $kb)
