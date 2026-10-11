#!/usr/bin/env bash
# Shared by the .sh launchers: runs a script of this folder with PowerShell 7 (pwsh). Without pwsh installed,
# a portable copy is downloaded once to downloads/pwsh (no root needed).
# Usage: pwsh.sh <script.ps1> [args...]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version=7.4.6

find_pwsh() {
    if command -v pwsh >/dev/null 2>&1; then command -v pwsh; return; fi
    if [[ -x "$here/downloads/pwsh/pwsh" ]]; then echo "$here/downloads/pwsh/pwsh"; return; fi
    case "$(uname -m)" in
        x86_64 | amd64) arch=x64 ;;
        aarch64 | arm64) arch=arm64 ;;
        armv7l | armhf) arch=arm32 ;;
        *) echo "Arquitetura $(uname -m) sem PowerShell 7. Instale o pwsh e rode de novo." >&2; exit 1 ;;
    esac
    url="https://github.com/PowerShell/PowerShell/releases/download/v$version/powershell-$version-linux-$arch.tar.gz"
    echo "PowerShell 7 nao encontrado. Baixando uma copia portatil ($arch, ~70 MB) para downloads/pwsh..." >&2
    mkdir -p "$here/downloads/pwsh"
    tgz="$here/downloads/powershell-$version-linux-$arch.tar.gz"
    if command -v curl >/dev/null 2>&1; then curl -fL --retry 3 -o "$tgz" "$url" >&2
    elif command -v wget >/dev/null 2>&1; then wget -O "$tgz" "$url" >&2
    else echo "Instale o curl ou o wget (ou o pwsh) e rode de novo." >&2; exit 1; fi
    tar -xzf "$tgz" -C "$here/downloads/pwsh"
    rm -f "$tgz"
    chmod +x "$here/downloads/pwsh/pwsh"
    echo "$here/downloads/pwsh/pwsh"
}

script="$1"; shift
exe="$(find_pwsh)"
# Without libicu (minimal systems, arcade cabinets) pwsh does not start; the scripts need no culture data.
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
exec "$exe" -NoProfile -File "$here/$script" "$@"
