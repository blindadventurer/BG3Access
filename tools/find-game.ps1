# Where is Baldur's Gate 3 on this machine?
#
# Every script here used to carry `G:\SteamLibrary\steamapps\common\Baldurs Gate 3` as its
# default, which is true on exactly one computer. For anyone else the first command of the
# install printed "no game at G:\..." and there was nothing in the message saying that the
# path is a guess and can simply be passed in. So the guess is made properly instead, and
# the scripts take their default from here.
#
# Order is by how much the source knows: an explicit override, then Steam's own library
# index, then GOG's registry entry, then the handful of paths people actually use. Every
# candidate has to prove itself the same way - bin\bg3.exe - because a leftover folder from
# an uninstalled copy looks exactly like an install until you look inside it.
#
# Usage: powershell -File find-game.ps1              print the path, or nothing
#        powershell -File find-game.ps1 -All         every install found, not just the first
#        $dir = & tools\find-game.ps1                from another script

param(
    [switch]$All
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$STEAM_APPID = "1086940"

function Test-GameDir($dir) {
    if ([string]::IsNullOrWhiteSpace($dir)) { return $false }
    return (Test-Path (Join-Path $dir "bin\bg3.exe")) -or
           (Test-Path (Join-Path $dir "bin\bg3_dx11.exe"))
}

function Get-SteamRoot {
    # HKCU first: it is written by the Steam the user actually runs, and on a machine with
    # both a per-user and a machine-wide install the HKLM one can point at the other.
    foreach ($k in @(
        @{ Path = "HKCU:\Software\Valve\Steam";               Name = "SteamPath" },
        @{ Path = "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam";   Name = "InstallPath" },
        @{ Path = "HKLM:\SOFTWARE\Valve\Steam";               Name = "InstallPath" }
    )) {
        try {
            $v = (Get-ItemProperty -Path $k.Path -Name $k.Name -ErrorAction Stop).($k.Name)
            # HKCU holds it with forward slashes and in lower case - a valid path, but not one
            # to print at a person, so it is normalised before it goes anywhere.
            if ($v) { return [System.IO.Path]::GetFullPath($v.Replace("/", "\")) }
        } catch { }
    }
    return $null
}

function Get-SteamLibraries($steamRoot) {
    $out = @()
    if (-not $steamRoot) { return $out }
    $out += (Join-Path $steamRoot "steamapps")

    # libraryfolders.vdf is Valve's own list of every drive a game may live on. It is a small
    # nested-quote format and nothing here needs to understand it: the "path" values are the
    # only thing being asked for, and a regex over them is both shorter and harder to break
    # than a parser for a format that changes between Steam versions.
    $vdf = Join-Path $steamRoot "steamapps\libraryfolders.vdf"
    if (Test-Path $vdf) {
        $raw = Get-Content $vdf -Raw -Encoding UTF8
        foreach ($m in [regex]::Matches($raw, '"path"\s+"([^"]+)"')) {
            # The file escapes its backslashes; a literal C:\\Program Files does not exist.
            $p = $m.Groups[1].Value -replace '\\\\', '\'
            $out += (Join-Path $p "steamapps")
        }
    }
    return $out | Select-Object -Unique
}

function Get-SteamCandidates {
    $found = @()
    foreach ($apps in (Get-SteamLibraries (Get-SteamRoot))) {
        if (-not (Test-Path $apps)) { continue }

        # The manifest is the authoritative answer for "is the game in this library", and it
        # carries the folder name, which is not always "Baldurs Gate 3" - a library moved off
        # a backup, or a non-English Steam, can spell it otherwise.
        $manifest = Join-Path $apps "appmanifest_$STEAM_APPID.acf"
        if (Test-Path $manifest) {
            $raw = Get-Content $manifest -Raw -Encoding UTF8
            $m = [regex]::Match($raw, '"installdir"\s+"([^"]+)"')
            if ($m.Success) { $found += (Join-Path $apps ("common\" + $m.Groups[1].Value)) }
        }
        $found += (Join-Path $apps "common\Baldurs Gate 3")
    }
    return $found
}

function Get-GogCandidates {
    $found = @()
    foreach ($root in @("HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games", "HKLM:\SOFTWARE\GOG.com\Games")) {
        if (-not (Test-Path $root)) { continue }
        foreach ($key in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            try {
                $p = Get-ItemProperty $key.PSPath -ErrorAction Stop
                if ($p.gameName -like "*Baldur*Gate*3*" -and $p.path) { $found += $p.path }
            } catch { }
        }
    }
    return $found
}

function Get-PlainCandidates {
    # What is left when neither store will say: the layouts people set up by hand. Cheap to
    # test - a Test-Path on a drive that is not there costs nothing - and it covers the case
    # of a game copied onto a second drive without Steam knowing about it.
    $found = @(
        "C:\Program Files (x86)\Steam\steamapps\common\Baldurs Gate 3",
        "C:\Program Files\Steam\steamapps\common\Baldurs Gate 3",
        "C:\GOG Games\Baldurs Gate 3",
        "C:\Games\Baldurs Gate 3"
    )
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        $r = $d.Root
        $found += (Join-Path $r "SteamLibrary\steamapps\common\Baldurs Gate 3")
        $found += (Join-Path $r "Steam\steamapps\common\Baldurs Gate 3")
        $found += (Join-Path $r "Games\Baldurs Gate 3")
        $found += (Join-Path $r "GOG Games\Baldurs Gate 3")
    }
    return $found
}

$candidates = @()
if ($env:BG3_DIR) { $candidates += $env:BG3_DIR }
$candidates += Get-SteamCandidates
$candidates += Get-GogCandidates
$candidates += Get-PlainCandidates

$hits = @()
foreach ($c in $candidates) {
    if (-not (Test-GameDir $c)) { continue }
    $full = [System.IO.Path]::GetFullPath($c).TrimEnd("\")
    if ($hits -notcontains $full) { $hits += $full }
    if (-not $All) { break }
}

# Nothing on stdout when there is nothing to say. A caller taking this as a default gets an
# empty string and reports the miss in its own words, which are better than any this script
# could write without knowing what it was being asked for.
$hits
