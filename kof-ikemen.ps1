# KOF Final Attack - conversao para Ikemen GO em 4:3
# Uso: kof-ikemen.ps1 [-Out pasta] [-Width 320] [-Platform both|windows|linux] [-Windowed] [-Widescreen]
# Cria uma copia do jogo rodando no Ikemen GO; a pasta original do jogo (MUGEN) nao e alterada.
param(
    [string]$Out = "",
    [int]$Width = 320,
    [ValidateSet("both", "windows", "linux")]
    [string]$Platform = "both",
    [switch]$Windowed,
    [switch]$Widescreen,
    [switch]$CoinOp
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$game = Split-Path -Parent $patchDir
if (-not (Test-Path -LiteralPath (Join-Path $game "Final Attack.exe"))) {
    throw "Nao encontrei 'Final Attack.exe'. Coloque a pasta 'Patch 4x3' dentro da pasta do jogo."
}
if (-not $Out) { $Out = Join-Path (Split-Path -Parent $game) "KOF Final Attack Ikemen" }
if ((Test-Path -LiteralPath $Out) -and (Get-ChildItem -LiteralPath $Out -Force | Select-Object -First 1)) {
    throw "A pasta de destino ja existe e nao esta vazia: $Out"
}

$version = "v1.0.0"
$releases = @{
    windows = @{ file = "Ikemen_GO-$version-windows.zip"; sha256 = "9338eaeb68599ceb13b0867819a091ea3f92eba58077e800b4540b7a1f9c3731" }
    linux   = @{ file = "Ikemen_GO-$version-linux.zip"; sha256 = "cc533c1a2ab84d63cbf9126d9dcb3f2dcc1a41c6206f2da419b0c91084f193e4" }
}
$downloads = Join-Path $patchDir "downloads"

function Get-Release([string]$os) {
    $r = $releases[$os]
    $zip = Join-Path $downloads $r.file
    if (-not (Test-Path -LiteralPath $zip)) {
        New-Item -ItemType Directory -Force -Path $downloads | Out-Null
        Write-Host "Baixando $($r.file)..."
        Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/ikemen-engine/Ikemen-GO/releases/download/$version/$($r.file)" -OutFile "$zip.part"
        Move-Item -LiteralPath "$zip.part" -Destination $zip
    }
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $r.sha256) { throw "$($r.file): SHA256 inesperado ($hash). Apague o arquivo em '$downloads' e tente de novo." }
    $zip
}

function Copy-Tree([string]$from, [string]$to) {
    if (Get-Command robocopy -ErrorAction SilentlyContinue) {
        robocopy $from $to /E /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Falha ao copiar '$from' para '$to' (robocopy $LASTEXITCODE)." }
        $global:LASTEXITCODE = 0
        return
    }
    # Without robocopy (Linux, macOS): -LiteralPath does not expand "*", so the items are listed and piped.
    New-Item -ItemType Directory -Force -Path $to | Out-Null
    Get-ChildItem -LiteralPath $from -Force | Copy-Item -Destination $to -Recurse -Force
}

$base = if ($Platform -eq "linux") { "linux" } else { "windows" }
$zips = @{ $base = Get-Release $base }
if ($Platform -eq "both") { $zips["linux"] = Get-Release "linux" }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("kof-ikemen-" + [guid]::NewGuid().ToString("N"))
try {
    Write-Host "Extraindo Ikemen GO $version..."
    foreach ($os in $zips.Keys) { Expand-Archive -LiteralPath $zips[$os] -DestinationPath (Join-Path $tmp $os) }

    # Engine only: the sample characters and stages of the release are left out.
    New-Item -ItemType Directory -Force -Path $Out | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $tmp $base) -Force | Where-Object { $_.Name -notin @("chars", "stages") } | ForEach-Object {
        if ($_.PSIsContainer) { Copy-Tree $_.FullName (Join-Path $Out $_.Name) } else { Copy-Item -LiteralPath $_.FullName -Destination $Out }
    }
    if ($Platform -eq "both") {
        $lx = Join-Path $tmp "linux"
        foreach ($f in "Ikemen_GO_Linux", "Ikemen_GO.command", "Ikemen_GO.desktop", "ikemen-go.png") {
            Copy-Item -LiteralPath (Join-Path $lx $f) -Destination $Out
        }
        Copy-Tree (Join-Path $lx "lib") (Join-Path $Out "lib")
    }
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}

Write-Host "Copiando o jogo (personagens, cenarios, telas, fontes e sons)..."
$content = [ordered]@{ "Chars" = "chars"; "stages" = "stages"; "data" = "data"; "font" = "font"; "sound" = "sound" }
foreach ($dir in $content.Keys) { Copy-Tree (Join-Path $game $dir) (Join-Path $Out $content[$dir]) }
# If the MUGEN 4:3 patch is applied to the game, start from the original widescreen files.
$mugenBackup = Join-Path $patchDir "backup-widescreen"
if (Test-Path -LiteralPath (Join-Path $mugenBackup "estado.txt")) {
    foreach ($dir in "data", "stages", "chars") {
        $b = Join-Path $mugenBackup $dir
        if (Test-Path -LiteralPath $b) { Copy-Tree $b (Join-Path $Out $dir) }
    }
}
# Ikemen prefers common1.cns.zss over common1.cns; the game's HUD lives in its own common1.cns.
Remove-Item -LiteralPath (Join-Path $Out "data\common1.cns.zss") -Force -ErrorAction SilentlyContinue

# Minimal config; Ikemen fills in every other option with its defaults on the first run.
$fullscreen = if ($Windowed) { 0 } else { 1 }
$config = @"
[Config]
Motif             = data/system.def
FirstRun          = 0
WindowTitle       = The King of Fighters: Final Attack

[Video]
GameWidth         = 1024
GameHeight        = 576
WindowWidth       = 0
WindowHeight      = 0
Fullscreen        = $fullscreen
FightAspectWidth  = 0
FightAspectHeight = 0
"@
New-Item -ItemType Directory -Force -Path (Join-Path $Out "save") | Out-Null
[IO.File]::WriteAllText((Join-Path $Out "save\config.ini"), ($config -replace "`r?`n", "`r`n") + "`r`n")

if ($Widescreen) {
    Write-Host "Ikemen GO pronto em widescreen (sem patch 4:3)."
} else {
    $patchArgs = @{ Action = "apply"; Width = $Width; GameDir = $Out }
    if ($CoinOp) { $patchArgs.CoinOp = $true }
    & (Join-Path $patchDir "kof-4x3.ps1") @patchArgs
}
Write-Host ""
Write-Host "Pronto: $Out"
if ($Platform -ne "linux") { Write-Host "  Windows: Ikemen_GO.exe" }
if ($Platform -ne "windows") { Write-Host "  Linux:   chmod +x Ikemen_GO_Linux && ./Ikemen_GO_Linux" }
