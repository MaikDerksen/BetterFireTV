@echo off
rem BetterFireTV - Hintergrund. Startet tool\start.ps1 (Windows PowerShell).
chcp 65001 >nul
title BetterFireTV - Hintergrund
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& ([ScriptBlock]::Create([IO.File]::ReadAllText('%~dp0tool\start.ps1'))) -Root '%~dp0.' -Modus hintergrund"
