#!/usr/bin/env bash
# Linux: applies 4:3. Usage: ./aplicar-4x3.sh [-GameDir "/pasta do jogo"] [-Width 320] [-CoinOp]
echo "Convertendo KOF Final Attack para 4:3..."
echo
exec bash "$(dirname "$0")/pwsh.sh" kof-4x3.ps1 -Action apply "$@"
