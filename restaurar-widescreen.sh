#!/usr/bin/env bash
# Linux: undoes 4:3. Usage: ./restaurar-widescreen.sh [-GameDir "/pasta do jogo"]
echo "Restaurando o KOF Final Attack para widescreen (16:9)..."
echo
exec bash "$(dirname "$0")/pwsh.sh" kof-4x3.ps1 -Action restore "$@"
