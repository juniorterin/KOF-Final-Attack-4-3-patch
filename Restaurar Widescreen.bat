@echo off
title KOF Final Attack - Restaurar widescreen
echo Restaurando o KOF Final Attack para widescreen (16:9)...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0kof-4x3.ps1" -Action restore
echo.
pause
