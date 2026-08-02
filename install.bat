@echo off
rem Install the accessibility layer. Double-click this file.
rem
rem It exists because Windows will not run a .ps1 by double-click at all, and the command line
rem it wants instead - powershell -NoProfile -ExecutionPolicy Bypass -File ... - is a sentence
rem that has to be typed correctly before anything can be heard. -ExecutionPolicy Bypass is the
rem load-bearing part: a fresh Windows refuses to run any script without it, and the refusal is
rem four lines of red text that read like the mod is broken.
rem
rem The window is left open at the end on purpose - what it printed is the whole report.
chcp 65001 >nul
title BG3Access - install
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install.ps1" %*
echo.
pause
