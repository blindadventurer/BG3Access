@echo off
rem The inside of BG3Access-Setup.exe. Nobody runs this file by hand; it is what the
rem self-extracting installer runs once it has unpacked itself into a temp folder.
rem
rem Everything it does is what a person would otherwise do in Explorer: put the folder
rem somewhere it will still be there next month, and start the installer inside it. The
rem window it runs in is the report - a screen reader reads a console as it prints - so
rem nothing here is hidden, and it closes itself only when there was nothing to say.

chcp 65001 >nul
title BG3Access - setup

rem 64-bit PowerShell, explicitly, and this is load-bearing rather than tidy. The IExpress
rem stub is a 32-bit program, so a plain "powershell" started from here is the 32-bit one -
rem which cannot load prism.dll, the 64-bit DLL every spoken word in this mod goes through.
rem Sysnative is the door out of WOW64 and only exists when we are inside it.
set PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe

set TARGET=%LOCALAPPDATA%\Programs\BG3Access

echo BG3Access
echo ------------------------------------------------------------
echo.
echo   Unpacking into %TARGET%

rem Emptied first, not merged into: a file dropped in a later version would otherwise sit
rem there being run by whatever still names it. Quoted with single quotes on the PowerShell
rem side because %~dp0 is a temp path, and somebody's user folder has a space in it.
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $t=$env:LOCALAPPDATA+'\Programs\BG3Access'; if (Test-Path $t) { Remove-Item $t -Recurse -Force }; New-Item -ItemType Directory -Force $t | Out-Null; Add-Type -AssemblyName System.IO.Compression.FileSystem; [System.IO.Compression.ZipFile]::ExtractToDirectory('%~dp0BG3Access.zip', $t)"
if errorlevel 1 goto unpackfailed

rem The archive carries one folder named for the version, so it is found rather than spelled.
set APP=
for /d %%d in ("%TARGET%\BG3Access-*") do set APP=%%d
if not defined APP goto unpackfailed

rem The window is the report, and the window is also gone the moment it closes.
rem
rem PLAYING.md asks for what it printed when something goes wrong, which is a reasonable thing
rem to ask of someone who can see it scroll past and an unreasonable thing to ask of everybody
rem this installer is for. So the same text goes to a file as well, next to the other things a
rem bug report wants - speech-log.txt and speech-companion.log are in that same folder.
rem
rem Through environment variables rather than into the command line: this path contains
rem "Baldur's Gate 3", and a lone apostrophe ends the PowerShell string it would sit in.
rem Tee-Object rather than a plain redirect, because a redirect would take the console output
rem away, and the console output is the half a screen reader can actually read as it happens.
set INSTALLER=%APP%\tools\install.ps1
set LOG=%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\A11y\install-log.txt

echo.
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "New-Item -ItemType Directory -Force (Split-Path $env:LOG) | Out-Null; & $env:INSTALLER -Yes *>&1 | Tee-Object -FilePath $env:LOG; exit $LASTEXITCODE"
if errorlevel 1 goto notready

echo.
echo   Done. This window closes by itself.
timeout /t 20 >nul
exit /b 0

:notready
echo.
echo   Something above needs attention - it is written out in full, and said out loud.
echo   Nothing else was left half done.
echo.
echo   All of it was also written to
echo   %LOG%
echo   Send that file to https://github.com/blindadventurer/BG3Access/issues
echo.
pause
exit /b 1

:unpackfailed
echo.
echo   ! could not unpack into %TARGET%
echo   Nothing was installed. Send this window to
echo   https://github.com/blindadventurer/BG3Access/issues
echo.
pause
exit /b 2
