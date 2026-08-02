@echo off
rem Remove the accessibility layer. Double-click this file.
chcp 65001 >nul
title BG3Access - uninstall
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\uninstall.ps1" %*
echo.
pause
