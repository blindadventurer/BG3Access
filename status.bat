@echo off
rem Is the layer actually up? Double-click this file, and send what it prints when it is not.
rem
rem One line each for the things that can be wrong on their own and silently: no game found, no
rem Script Extender, no controller, layer not installed, layer installed but never started,
rem nothing turning its speech into speech, and nothing watching that that keeps running.
chcp 65001 >nul
title BG3Access - status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\mod-status.ps1" %*
echo.
pause
