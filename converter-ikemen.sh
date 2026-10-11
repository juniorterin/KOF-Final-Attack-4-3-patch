#!/usr/bin/env bash
# Linux: builds the Ikemen GO 4:3 copy of the game. Usage: ./converter-ikemen.sh [-Out pasta] [-Platform linux] [-CoinOp]
echo "Criando uma copia do KOF Final Attack no Ikemen GO em 4:3..."
echo
exec bash "$(dirname "$0")/pwsh.sh" kof-ikemen.ps1 "$@"
