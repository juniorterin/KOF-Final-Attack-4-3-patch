@echo off
title KOF Final Attack - Ikemen GO 4:3
echo Criando uma copia do KOF Final Attack no Ikemen GO em 4:3...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0kof-ikemen.ps1" %*
echo.
pause
