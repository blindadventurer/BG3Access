# Put the Script Extender in, because "install BG3SE first" is where the first evening ended.
#
# install.ps1 deliberately did not do this, and the reasoning is still written down there: BG3SE
# is a DLL that loads itself into the game, and fetching someone else's binary on a player's
# behalf is not a habit an accessibility mod should be teaching. What that reasoning did not
# account for is who is on the other end of it. A modder reads "the Script Extender is not
# installed", opens a browser, finds a releases page, works out which of the assets is the one,
# unpacks it and drops a DLL next to bg3.exe. Someone who has never installed a mod does not get
# past the second step - and is doing it with a screen reader reading a page of release notes at
# them. For that person the refusal to download did not protect anything; it cost them the mod.
#
# So the download happens here, and everything that made it worth refusing is kept - as things
# said out loud rather than as a thing not done. Which project, which release, which file, how
# big, what it hashes to, and where it is about to be put, all printed and all spoken. It is
# asked for before it happens, the answer defaults to yes so that it costs one key, and -Yes
# skips even that for anyone who has already decided.
#
# Usage: powershell -File install-extender.ps1
#        powershell -File install-extender.ps1 -Yes -Silent
#        powershell -File install-extender.ps1 -Force          replace the one already there
#
# Exit codes: 0 installed, or already there. 1 declined. 2 could not.

param(
    [string]$GameDir = (& (Join-Path $PSScriptRoot "find-game.ps1")),
    [switch]$Yes,               # do not ask
    [switch]$Force,             # replace a DWrite.dll that is already installed
    [switch]$Silent             # print only; do not speak
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$REPO   = "Norbyte/bg3se"
$UA     = @{ "User-Agent" = "BG3Access-installer" }   # the GitHub API refuses a request without one
$speak  = Join-Path $PSScriptRoot "speak.ps1"
$marker = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Script Extender\A11y\extender.json"
$tmp    = $null

function Ok($t)  { Write-Host "   $t" }
function Bad($t) { Write-Host "   ! $t" }
function Say($t) { if ($Silent) { return } ; try { & $speak -Text $t *> $null } catch { } }
function Cleanup { if ($tmp -and (Test-Path $tmp)) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue } }

# Every give-up path goes through here, because two of them are three lines long and the third
# is easy to write without the cleanup or without the sentence spoken - and an installer that
# stops without saying so is indistinguishable, to this mod's players, from one that hung.
function Fail($text, $hint) {
    Bad $text
    if ($hint) { Write-Host "     $hint" }
    Cleanup
    Say "The Script Extender was not installed. See the window."
    exit 2
}

# --- is there anywhere to put it -------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($GameDir) -or -not (Test-Path $GameDir)) {
    Fail "Baldur's Gate 3 was not found" 'Pass it in: -GameDir "D:\Games\Baldurs Gate 3"'
}

$bin = Join-Path $GameDir "bin"
$dll = Join-Path $bin "DWrite.dll"

if ((Test-Path $dll) -and -not $Force) {
    Ok ("already installed: bin\DWrite.dll, {0:yyyy-MM-dd}" -f (Get-Item $dll).LastWriteTime)
    Ok "it updates itself at every launch - nothing to do (-Force replaces it anyway)"
    exit 0
}

# Both of the next two are checked before the download rather than after it. Five megabytes is
# a long time on the connections this is going to run on, and finding out at the end of it that
# the file could never have been written is the kind of failure people stop retrying.

if (Get-Process bg3, bg3_dx11 -ErrorAction SilentlyContinue) {
    Fail "Baldur's Gate 3 is running" "Close the game and run this again - Windows will not replace a DLL the game has loaded."
}

try {
    $probe = Join-Path $bin ".bg3access-write-test"
    [System.IO.File]::WriteAllText($probe, "")
    Remove-Item $probe -Force
} catch {
    Fail "cannot write into $bin" "Right-click install.bat and choose Run as administrator."
}

# --- which file ------------------------------------------------------------------------------

# .NET Framework picks the protocol here and on an untouched Windows 10 that is still TLS 1.0,
# which github.com answers by dropping the connection with no explanation at all. Reads exactly
# like "you have no internet", and is the single most likely way this script fails on a machine
# that is not the one it was written on.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# The progress bar is not cosmetic. PS 5.1 redraws it per chunk, which on a slow disk costs more
# than the transfer does - and every redraw is new text in the console window, which a screen
# reader reads. Five megabytes of it is several minutes of a voice counting.
$ProgressPreference = "SilentlyContinue"

Write-Host "   asking github.com for the current release of $REPO"
try {
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$REPO/releases/latest" -Headers $UA -UseBasicParsing
} catch {
    Fail "could not reach github.com: $_" "Install it by hand instead: https://github.com/$REPO/releases"
}

# Picked by shape, not by name: the one asset per release has been named for its build date
# since 2023 (BG3SE-Updater-20260621.zip), so anything matching on the name would break at the
# next build. The Console variant, where a release has one, is skipped on purpose - it opens a
# second window at launch that takes focus away from the game, which for these players is not a
# debugging aid, it is a game they can no longer hear.
$asset = @($rel.assets | Where-Object { $_.name -like "*.zip" -and $_.name -notlike "*Console*" })[0]
if (-not $asset) {
    Fail "release $($rel.tag_name) has no zip in it" "Install it by hand instead: https://github.com/$REPO/releases"
}

$mb = [math]::Round($asset.size / 1MB, 1)
Write-Host ""
Write-Host "   The Script Extender is missing. Without it the game starts perfectly and"
Write-Host "   runs no mod code at all - this layer included."
Write-Host ""
Write-Host "     project:  $REPO (Norbyte, the author of the Script Extender)"
Write-Host "     release:  $($rel.tag_name)"
Write-Host "     file:     $($asset.name), $mb MB"
Write-Host "     from:     $($asset.browser_download_url)"
Write-Host "     into:     $dll"
Write-Host ""

if (-not $Yes) {
    Say ("The Script Extender is missing, and nothing runs without it. May I download it " +
         "from the official project on github, about $mb megabytes? Press enter for yes.")
    # Enter is yes - the point of the prompt is that it costs one key - and so is anything else
    # that means yes to the people this layer speaks to: U+0434 and U+0434 U+0430, the Cyrillic
    # "d" and "da". Built from code points rather than typed, because PS 5.1 reads a .ps1 with
    # no BOM as ANSI and the letters written out would arrive here as two other letters.
    $d = [char]0x434
    $yes = "^(y|yes|$d|$d" + [char]0x430 + ")$"
    $answer = ((Read-Host "   Download and install it? [Y/n]") + "").Trim()
    if ($answer -and $answer -notmatch $yes) {
        Ok "not downloaded - nothing was changed"
        Write-Host "     To do it yourself: https://github.com/$REPO/releases - the zip holds one"
        Write-Host "     DWrite.dll, and it goes into $bin"
        Say "Nothing was downloaded. The layer will not run until the Script Extender is installed."
        exit 1
    }
}

# --- fetch it --------------------------------------------------------------------------------

$tmp = Join-Path $env:TEMP ("BG3Access-se-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $tmp | Out-Null
$zip = Join-Path $tmp $asset.name

Say "Downloading the Script Extender."
Write-Host "   downloading..."
try {
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -Headers $UA -UseBasicParsing
} catch {
    Fail "the download failed: $_" "Install it by hand instead: https://github.com/$REPO/releases"
}

# The size is the one thing GitHub told us in advance, so it is the one thing that can be
# checked against something other than the download itself. A truncated file is otherwise a
# perfectly good zip right up to the point where the game refuses to start.
$got = (Get-Item $zip).Length
if ($got -ne $asset.size) {
    Fail "downloaded $got bytes, expected $($asset.size) - the transfer was cut short" "Run install.bat again."
}

# Printed rather than compared. Norbyte publishes no hash to compare against, so this is not a
# verification; it is the fingerprint of what actually landed on this machine, which is the only
# way a "my antivirus ate it" or "this build breaks X" report can name the same file twice.
$sha = (Get-FileHash $zip -Algorithm SHA256).Hash
Ok "$got bytes, sha256 $sha"

Add-Type -AssemblyName System.IO.Compression.FileSystem
$staged = Join-Path $tmp "DWrite.dll"
$archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
try {
    $entries = @($archive.Entries)
    foreach ($e in $entries) { Write-Host "     in the archive: $($e.FullName) ($($e.Length) bytes)" }

    # Found by basename and extracted to a path of our own making - never to the one written in
    # the archive. There is exactly one file in there today and this costs nothing today; what
    # it buys is that a zip which one day contains ..\..\something cannot put it anywhere.
    $hit = @($entries | Where-Object { [System.IO.Path]::GetFileName($_.FullName) -ieq "DWrite.dll" })
    if ($hit.Count -ne 1) {
        Fail "expected one DWrite.dll inside $($asset.name), found $($hit.Count)" "Install it by hand instead: https://github.com/$REPO/releases"
    }
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($hit[0], $staged, $true)
    $want = $hit[0].Length
} finally { $archive.Dispose() }

# --- put it in -------------------------------------------------------------------------------

if (Test-Path $dll) {
    Copy-Item $dll "$dll.bak-a11y" -Force
    Ok "kept the old bin\DWrite.dll as DWrite.dll.bak-a11y"
}

try {
    Copy-Item $staged $dll -Force
} catch {
    Fail "could not write $dll : $_" "Close the game and any antivirus prompt, then run install.bat again."
}

# Antivirus is the reason this is checked rather than assumed. A DLL that loads itself into
# another process is what a proxy loader looks like from the outside, and more than one scanner
# quarantines this one between the copy and the next line - silently, leaving an install that
# reported success and a game that runs no mod code.
if (-not (Test-Path $dll)) {
    Fail "bin\DWrite.dll is not there after copying it" "An antivirus most likely removed it. Allow it and run install.bat again."
}
$now = (Get-Item $dll).Length
if ($now -ne $want) {
    Fail "bin\DWrite.dll is $now bytes, expected $want" "Run install.bat again."
}
Ok "installed bin\DWrite.dll, $now bytes"

# What was put there, and by whom.
#
# uninstall.ps1 reads this to tell an extender this installer fetched from one the player had
# before - a distinction it cannot make from the file itself, and the difference between taking
# back what we added and quietly breaking every other mod on the machine. It lives with boot.json
# rather than in %LOCALAPPDATA%\BG3Access, which the speech companion's uninstall deletes whole.
$record = [ordered]@{
    installedBy = "BG3Access"
    when        = (Get-Date).ToString("s")
    repo        = $REPO
    release     = $rel.tag_name
    asset       = $asset.name
    url         = $asset.browser_download_url
    sha256      = $sha
    target      = $dll
}
try {
    New-Item -ItemType Directory -Force (Split-Path $marker) | Out-Null
    [System.IO.File]::WriteAllText($marker, ($record | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
} catch { }

Cleanup
Ok "the Script Extender updates itself from here on - this file is its updater"
Say "The Script Extender is installed."
exit 0
