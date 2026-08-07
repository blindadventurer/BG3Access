<#
.SYNOPSIS
    Compares each translation table against the English the layer actually says.

.DESCRIPTION
    Every sentence the layer speaks is written in English inside `T"..."` and translated on the
    way out by lua/a11y-<code>.lua. Nothing enforces that the two stay in step: a new line added
    to a11y-pad.lua is simply spoken in English on a Russian game, silently, and a line deleted
    leaves a translation behind that no longer matches anything.

    This names both halves of that drift. Missing keys are what a player in that language hears
    in English; stale keys are dead weight, and usually the sign that a sentence was reworded
    rather than removed.

    It is a report, not a gate: an untranslated string is a working layer, and there is no build
    step to fail. Run it before a release.

    Also checked, because it is the one mistake that cannot be seen by reading either file: a
    format string whose translation carries different placeholders (`%d`, `%s`, `%.0f`) crashes
    string.format at the moment it is spoken.

.PARAMETER Lang
    Which language table to check. Defaults to all of them.

.EXAMPLE
    powershell -File tools\check-lang.ps1
#>
[CmdletBinding()]
param([string] $Lang)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$luaDir = Join-Path $root "lua"

# --- the English the source says --------------------------------------------------

$said = [ordered]@{}
foreach ($f in Get-ChildItem (Join-Path $luaDir "a11y-*.lua")) {
    if ($f.Name -match '^a11y-(ru|lang|.*data)\.lua$') { continue }
    $text = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
    foreach ($m in [regex]::Matches($text, 'T"((?:[^"\\]|\\.)*)"')) {
        $s = $m.Groups[1].Value -replace '\\"', '"' -replace '\\\\', '\'
        if (-not $said.Contains($s)) { $said[$s] = $f.Name }
    }
}
# The bootstraps say one line of their own.
foreach ($f in Get-ChildItem (Join-Path $root "BG3Access\Mods\BG3Access\ScriptExtender\Lua\Bootstrap*.lua")) {
    $text = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
    foreach ($m in [regex]::Matches($text, 'local hello = "([^"]*)"')) {
        if (-not $said.Contains($m.Groups[1].Value)) { $said[$m.Groups[1].Value] = $f.Name }
    }
}
Write-Host ("English strings in the source: {0}" -f $said.Count)

# --- what each table translates ---------------------------------------------------

function Get-Placeholders([string] $s) {
    ([regex]::Matches($s, '%[-+ #0-9.]*[dsfqxi]') | ForEach-Object { $_.Value }) -join ","
}

$tables = Get-ChildItem (Join-Path $luaDir "a11y-*.lua") |
          Where-Object { $_.Name -match '^a11y-([a-z]{2})\.lua$' -and $_.Name -ne 'a11y-lang.lua' }
if ($Lang) { $tables = $tables | Where-Object { $_.Name -eq "a11y-$Lang.lua" } }
if (-not $tables) { Write-Host "no translation tables found"; exit 0 }

$bad = 0
foreach ($t in $tables) {
    $code = [regex]::Match($t.Name, '^a11y-([a-z]{2})\.lua$').Groups[1].Value
    $text = [IO.File]::ReadAllText($t.FullName, [Text.Encoding]::UTF8)
    $keys = @{}
    foreach ($m in [regex]::Matches($text, '\[\s*"((?:[^"\\]|\\.)*)"\s*\]\s*=\s*"((?:[^"\\]|\\.)*)"')) {
        $k = $m.Groups[1].Value -replace '\\"', '"' -replace '\\\\', '\'
        $v = $m.Groups[2].Value -replace '\\"', '"' -replace '\\\\', '\'
        $keys[$k] = $v
    }

    $missing = @($said.Keys | Where-Object { -not $keys.ContainsKey($_) })
    $stale   = @($keys.Keys | Where-Object { -not $said.Contains($_) })
    $slots   = @()
    foreach ($k in $keys.Keys) {
        if ((Get-Placeholders $k) -ne (Get-Placeholders $keys[$k])) { $slots += $k }
    }

    Write-Host ""
    Write-Host ("=== {0} ({1} translated) ===" -f $t.Name, $keys.Count) -ForegroundColor Cyan
    if ($missing.Count -eq 0 -and $stale.Count -eq 0 -and $slots.Count -eq 0) {
        Write-Host "in step with the source" -ForegroundColor Green
        continue
    }
    if ($slots.Count -gt 0) {
        $bad++
        Write-Host ("PLACEHOLDERS DIFFER ({0}) - these crash when spoken:" -f $slots.Count) -ForegroundColor Red
        $slots | Sort-Object | ForEach-Object { "    `"$_`"  ->  `"$($keys[$_])`"" }
    }
    if ($missing.Count -gt 0) {
        Write-Host ("said in English ({0}):" -f $missing.Count) -ForegroundColor Yellow
        $missing | Sort-Object | ForEach-Object { "    `"$_`"" }
    }
    if ($stale.Count -gt 0) {
        Write-Host ("translated but never said ({0}):" -f $stale.Count) -ForegroundColor DarkYellow
        $stale | Sort-Object | ForEach-Object { "    `"$_`"" }
    }
}
exit $bad
