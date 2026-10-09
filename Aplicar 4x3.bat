@echo off
title KOF Final Attack - Patch 4:3
echo Convertendo KOF Final Attack para 4:3...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0kof-4x3.ps1" -Action apply %*
echo.
pause
