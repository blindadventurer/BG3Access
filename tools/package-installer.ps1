# Build the one file a person downloads, clicks, and waits through.
#
# The ZIP and the one-liner both still ask something of whoever is installing: unpack this,
# find that, or paste a line of PowerShell into a box. Both are reasonable and both lose people.
# What does not lose anyone is a file called BG3Access-Setup.exe that you double-click.
#
# It is built with IExpress, which has shipped in every Windows since 98 and is already on the
# machine - no toolchain to install, nothing third-party in the build. The exe is a cabinet
# holding the release ZIP and sfx-setup.bat: it unpacks itself into a temp folder, asks once
# whether to go ahead, runs the batch, and cleans up after itself.
#
# The one thing it cannot do is be signed. An unsigned exe downloaded from the internet gets
# SmartScreen's "Windows protected your PC", which hides its Run anyway button behind a More
# info link - two steps, and the second one is not obvious with a screen reader either. That is
# the honest cost of the exe over the ZIP, it is written down in PLAYING.md, and the only real
# fix is a code-signing certificate.
#
# Usage: powershell -File package-installer.ps1 -Version 0.3.0
#
# Expects dist\BG3Access-<Version>.zip to exist - run package-release.ps1 first.

param(
    [string]$Version = "0.1.0",
    [string]$OutDir  = (Join-Path (Split-Path $PSScriptRoot) "dist")
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$zip = Join-Path $OutDir "BG3Access-$Version.zip"

# Deliberately not BG3Access-Setup-0.3.0.exe. GitHub serves the assets of the newest release
# under /releases/latest/download/<name>, so a name with no version in it is a link that keeps
# working - which is the difference between a page in PLAYING.md that says "download the setup"
# and one that has to be edited, and re-read by everyone who bookmarked it, at every release.
# The version is in the installer's own window and in the folder it installs into.
$exe = Join-Path $OutDir "BG3Access-Setup.exe"
if (-not (Test-Path $zip)) {
    Write-Error "no $zip - run package-release.ps1 -Version $Version first"
}

# Built somewhere with no spaces in the path, and not in the repository.
#
# IExpress takes its paths from an .SED file it parses itself, and its parser is old enough to
# split them on whitespace: a build directory named "baldur access" ends the run with an error
# that names a file called "baldur". The repository is going to sit in a folder with a space in
# it on somebody's machine sooner or later, so the build simply never happens there.
$stage = Join-Path $env:TEMP "bg3access-sfx"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null

Copy-Item $zip (Join-Path $stage "BG3Access.zip") -Force
Copy-Item (Join-Path $PSScriptRoot "sfx-setup.bat") (Join-Path $stage "setup.bat") -Force

$stageExe = Join-Path $stage "BG3Access-Setup.exe"
$sed      = Join-Path $stage "BG3Access.sed"

# The prompt is the consent screen for the whole install, and it is the only thing anyone is
# asked. It says the two things that are actually being agreed to - files into the game folder,
# and a download from somebody else's project - because after this the installer runs with -Yes
# and will not stop to ask again.
#
# ASCII, and English, on purpose. The .SED is read in the machine's ANSI codepage, so Russian
# written here renders as mojibake on any Windows whose codepage is not 1251 - which includes
# the machine of the first person abroad who tries this.
$prompt = "Install BG3Access, screen reader support for Baldur's Gate 3? " +
          "Close the game first. It installs as an ordinary mod and, if the Script Extender is " +
          "missing, downloads it from that project. " +
          "Nothing is replaced and uninstall.bat undoes it."

# RUN THIS SCRIPT DIRECTLY. It does not work from a scheduled task.
#
# Measured 2026-08-08: through tools\run-on-machine.ps1 - which runs a command as a one-shot
# task to escape an agent shell's redirected profile - iexpress reads the .SED, writes its .DDF
# beside it, produces no exe, prints nothing and exits 0. The same command in an ordinary
# console builds it first time. Whatever iexpress wants from its session, a task does not give
# it, and it does not say so.
#
# Worth writing down because the silence is identical to every other way this fails: a missing
# source file, a path with a space in it, a .SED with a BOM. An hour went into shortening the
# install prompt on a theory about string limits before the environment was suspected at all.

# Three things about the command below, each of which cost a build to find out, and all three
# fail the same way: the package extracts itself, runs nothing, deletes its temp folder and
# exits 0 in about a second. There is no log anywhere and the exit code is success.
#
#   .\setup.bat, not setup.bat. cmd can see the file - `type setup.bat` prints it, and it is
#   in the working directory, which is the extraction folder - but a bare name as a *command*
#   is not found there. Whatever sets that (NoDefaultCurrentDirectoryInExePath is the usual
#   suspect), the explicit .\ is immune to it and costs nothing. Measured across five forms:
#   `setup.bat`, `call setup.bat` and a renamed `setup.cmd` all did nothing; `.\setup.bat` ran.
#
#   cmd.exe /c, and not the .bat on its own. IExpress resolves a packaged file to its full path
#   and then runs a .bat through Command.com, which has not existed on 64-bit Windows for
#   twenty years. That one at least says so - "cannot create process <Command.com /c ...>,
#   the system cannot find the file specified" - in a modal box behind the installer window.
#
#   The quiet commands are the same command and not left empty as the wizard leaves them.
#   `/Q:A` does not mean "do the same thing without prompting" - it means "run QuietInstCmd
#   instead of AppLaunched", so an empty one is a package that installs nothing, quietly.
$body = @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=1
HideExtractAnimation=1
UseLongFileName=1
InsideCompressed=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=%InstallPrompt%
DisplayLicense=%DisplayLicense%
FinishMessage=%FinishMessage%
TargetName=%TargetName%
FriendlyName=%FriendlyName%
AppLaunched=%AppLaunched%
PostInstallCmd=%PostInstallCmd%
AdminQuietInstCmd=%AdminQuietInstCmd%
UserQuietInstCmd=%UserQuietInstCmd%
SourceFiles=SourceFiles
[Strings]
InstallPrompt=$prompt
DisplayLicense=
FinishMessage=
TargetName=$stageExe
FriendlyName=BG3Access $Version
AppLaunched=cmd.exe /c .\setup.bat
PostInstallCmd=<None>
AdminQuietInstCmd=cmd.exe /c .\setup.bat
UserQuietInstCmd=cmd.exe /c .\setup.bat
FILE0="setup.bat"
FILE1="BG3Access.zip"
[SourceFiles]
SourceFiles0=$stage
[SourceFiles0]
%FILE0%=
%FILE1%=
"@

# ANSI, not UTF-8: this is what IExpress reads it as, and a BOM at the top is enough to make it
# fail to find [Version] at all.
[System.IO.File]::WriteAllText($sed, $body, [System.Text.Encoding]::Default)

Write-Host "building $exe"
& "$env:SystemRoot\System32\iexpress.exe" /N /Q $sed | Out-Null
if (-not (Test-Path $stageExe)) { Write-Error "iexpress produced nothing - see $sed" }

New-Item -ItemType Directory -Force $OutDir | Out-Null
Copy-Item $stageExe $exe -Force
Remove-Item $stage -Recurse -Force

$size = [math]::Round((Get-Item $exe).Length / 1KB, 1)
Write-Host "$exe  ($size KB)"
Write-Host ""
Write-Host "Publish it alongside the ZIP:"
Write-Host "    gh release upload v$Version `"$exe`""
Write-Host "Then it is downloadable, for good, from"
Write-Host "    https://github.com/blindadventurer/BG3Access/releases/latest/download/BG3Access-Setup.exe"
