@echo off
rem Is the layer actually up? Double-click this file, and send what it prints when it is not.
rem
rem Six lines, each one of the six things that can be wrong on its own and silently: no game
rem found, no Script Extender, game not running, layer not installed, layer installed but never
rem started, nothing turning its speech into speech.
chcp 65001 >nul
title BG3Access - status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\mod-status.ps1" %*
echo.
pause
