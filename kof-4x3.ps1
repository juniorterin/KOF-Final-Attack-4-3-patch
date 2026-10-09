# KOF Final Attack - patch 4:3
# Uso: kof-4x3.ps1 -Action apply|restore|status [-Width 320]   (padrao 320x240, monitor CRT)
param(
    [ValidateSet("apply", "restore", "status")]
    [string]$Action = "status",
    [int]$Width = 320
)

$ErrorActionPreference = "Stop"
$latin1 = [Text.Encoding]::GetEncoding(28591)

$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $patchDir
if (-not (Test-Path -LiteralPath (Join-Path $root "Final Attack.exe"))) {
    throw "Nao encontrei 'Final Attack.exe'. Coloque a pasta 'Patch 4x3' dentro da pasta do jogo."
}
$backupDir = Join-Path $patchDir "backup-widescreen"
$stateFile = Join-Path $backupDir "estado.txt"

# MUGEN 1.1 always lays out the fight as if the screen were 16:9. A constant camera zoom of (16/9)/(4/3)
# turns that into a true 4:3 crop: stage and characters keep their proportions and their vertical framing.
$zoom = "1.333333"
# Under zoom, gamewidth/gameheight shrink by the zoom factor while screen-anchored explods are not zoomed.
$screenWidth = "(gamewidth*4/3)"
$screenHeight = "(gameheight*4/3)"
# Extra height of a 4:3 screen, measured in the units of screen-anchored explods (16:9 frame = width*9/16).
$hudBottomShift = "($screenHeight - $screenWidth*9/16)"

function Read-Text([string]$path) { [IO.File]::ReadAllText($path, $latin1) }
function Write-Text([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, $latin1) }
function Rel([string]$path) { $path.Substring($root.Length + 1) }

function Assert-GameClosed {
    $running = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and ([IO.Path]::GetFullPath($_.Path) -eq [IO.Path]::GetFullPath((Join-Path $root "Final Attack.exe"))) } catch { $false }
    }
    if ($running) { throw "Feche o jogo antes de aplicar ou restaurar o patch." }
}

# ---------------------------------------------------------------- mugen.cfg
function Convert-Config([string]$text, [int]$w, [int]$h) {
    $wRe = '(?m)^([ \t]*GameWidth[ \t]*=[ \t]*)\d+'
    $hRe = '(?m)^([ \t]*GameHeight[ \t]*=[ \t]*)\d+'
    if (-not [regex]::IsMatch($text, $wRe) -or -not [regex]::IsMatch($text, $hRe)) {
        throw "data/mugen.cfg: linhas GameWidth/GameHeight ativas nao encontradas."
    }
    $text = [regex]::Replace($text, $wRe, '${1}' + $w)
    [regex]::Replace($text, $hRe, '${1}' + $h)
}

# [Video] Width/Height set the real video mode (e.g. 320x240 on a CRT) while GameWidth/GameHeight stay at the
# render size. Lines added by the patch end with $videoMark; original active lines are disabled with $videoMark prefix.
$videoMark = ";4x3"

function Set-VideoMode([string]$text, [int]$w, [int]$h) {
    $m = [regex]::Match($text, '(?im)^[ \t]*\[Video\][^\r\n]*(\r?\n)')
    if (-not $m.Success) { throw "data/mugen.cfg: secao [Video] nao encontrada." }
    $nl = $m.Groups[1].Value
    $end = [regex]::Match($text.Substring($m.Index + $m.Length), '(?m)^[ \t]*\[')
    $bodyEnd = if ($end.Success) { $m.Index + $m.Length + $end.Index } else { $text.Length }
    $body = $text.Substring($m.Index + $m.Length, $bodyEnd - $m.Index - $m.Length)
    $body = [regex]::Replace($body, '(?im)^([ \t]*(Width|Height)[ \t]*=)', "$videoMark`$1")
    $body = "Width = $w $videoMark${nl}Height = $h $videoMark$nl" + $body
    $text.Substring(0, $m.Index + $m.Length) + $body + $text.Substring($bodyEnd)
}

function Reset-VideoMode([string]$text) {
    $text = [regex]::Replace($text, "(?m)^[^\r\n]*[ \t]$videoMark\r?\n", "")
    [regex]::Replace($text, "(?m)^$videoMark", "")
}

function Get-ConfigSize([string]$text) {
    $w = [regex]::Matches($text, '(?m)^[ \t]*GameWidth[ \t]*=[ \t]*(\d+)')
    $h = [regex]::Matches($text, '(?m)^[ \t]*GameHeight[ \t]*=[ \t]*(\d+)')
    if ($w.Count -eq 0 -or $h.Count -eq 0) { throw "data/mugen.cfg: GameWidth/GameHeight nao encontrados." }
    @([int]$w[$w.Count - 1].Groups[1].Value, [int]$h[$h.Count - 1].Groups[1].Value)
}

# ---------------------------------------------------------------- fight.def
# Round/Fight/KO announcements are positioned from the [Round] "pos"; push them to the 4:3 centre.
function Convert-Fight([string]$text, [int]$shift) {
    $m = [regex]::Match($text, '(?ims)^\[Round\][^\[]*?^([ \t]*pos[ \t]*=[ \t]*)(-?[\d.]+)[ \t]*,[ \t]*(-?[\d.]+)')
    if (-not $m.Success) { throw "data/fight.def: [Round] pos nao encontrado." }
    $y = [double]$m.Groups[3].Value + $shift
    $text.Substring(0, $m.Groups[1].Index) + $m.Groups[1].Value + $m.Groups[2].Value + "," + $y + $text.Substring($m.Groups[3].Index + $m.Groups[3].Length)
}

# ---------------------------------------------------------------- common1.cns
# Splits "x , y" at the top-level comma (ignores commas inside parentheses).
function Split-Pos([string]$v) {
    $depth = 0
    for ($i = 0; $i -lt $v.Length; $i++) {
        $c = $v[$i]
        if ($c -eq '(') { $depth++ } elseif ($c -eq ')') { $depth-- }
        elseif ($c -eq ',' -and $depth -eq 0) { return @($v.Substring(0, $i), $v.Substring($i + 1)) }
    }
    $null
}

# Lines without terminators plus the original terminators, so files keep their exact line endings.
function Split-Lines([string]$text) {
    $parts = [regex]::Split($text, '(\r?\n)')
    $lines = New-Object string[] (($parts.Length + 1) / 2)
    $seps = New-Object string[] $lines.Length
    for ($i = 0; $i -lt $parts.Length; $i++) { if ($i % 2 -eq 0) { $lines[$i / 2] = $parts[$i] } else { $seps[($i - 1) / 2] = $parts[$i] } }
    @{ lines = $lines; seps = $seps }
}

function Join-Lines($split) {
    $sb = New-Object Text.StringBuilder
    for ($i = 0; $i -lt $split.lines.Length; $i++) { [void]$sb.Append($split.lines[$i]).Append($split.seps[$i]) }
    $sb.ToString()
}

# State controllers of a .cns split by "[" headers, with the parameters that matter for screen anchoring.
function Get-Blocks([string[]]$lines) {
    $blocks = @()
    $current = $null
    for ($i = 0; $i -le $lines.Length; $i++) {
        if ($i -lt $lines.Length -and -not $lines[$i].TrimStart().StartsWith("[")) {
            if ($current) {
                $code = ($lines[$i] -replace ';.*$', '').Trim()
                if ($code -match '^(?i)type\s*=\s*(\S+)') { $current.type = $Matches[1].ToLower() }
                elseif ($code -match '^(?i)postype\s*=\s*(\S+)') { $current.postype = $Matches[1].ToLower() }
                elseif ($code -match '^(?i)pos\s*=') { $current.posIdx = $i }
            }
            continue
        }
        if ($current) { $current.to = $i; $blocks += $current }
        if ($i -lt $lines.Length) { $current = @{ from = $i; to = $lines.Length; type = $null; postype = $null; posIdx = -1 } }
    }
    $blocks
}

function Test-ScreenBlock($b, [string[]]$types) { $b.type -in $types -and $b.postype -in @("left", "right") }

# Screen-anchored explods that use gamewidth/gameheight get the unzoomed screen size back.
function Convert-ScreenSize([string[]]$lines) {
    $n = 0
    foreach ($b in Get-Blocks $lines) {
        if (-not (Test-ScreenBlock $b @("explod", "modifyexplod"))) { continue }
        for ($i = $b.from + 1; $i -lt $b.to; $i++) {
            $line = $lines[$i]
            $semi = $line.IndexOf(';')
            $code = if ($semi -ge 0) { $line.Substring(0, $semi) } else { $line }
            if ($code -notmatch '(?i)\bgame(width|height)\b' -or $code -match '^\s*(?i)trigger') { continue }
            $code = [regex]::Replace($code, '(?i)\bgamewidth\b', $screenWidth)
            $code = [regex]::Replace($code, '(?i)\bgameheight\b', $screenHeight)
            $lines[$i] = $code + $(if ($semi -ge 0) { $line.Substring($semi) } else { "" })
            $n++
        }
    }
    $n
}

# Screen-anchored HUD pieces near the bottom of the 16:9 frame (y 150..230) are moved to the bottom of the 4:3 screen.
function Convert-Common([string]$text) {
    $split = Split-Lines $text
    $lines = $split.lines
    $sized = Convert-ScreenSize $lines
    $counter = @{ n = 0 }
    $flush = {
        param($b)
        $posIdx = $b.posIdx
        if ($posIdx -lt 0 -or -not (Test-ScreenBlock $b @("explod", "modifyexplod", "helper"))) { return }
        $line = $lines[$posIdx]
        $semi = $line.IndexOf(';')
        $code = if ($semi -ge 0) { $line.Substring(0, $semi) } else { $line }
        $tail = if ($semi -ge 0) { $line.Substring($semi) } else { "" }
        $eq = $code.IndexOf('=')
        $parts = Split-Pos $code.Substring($eq + 1)
        if (-not $parts) { return }
        $y = 0.0
        if (-not [double]::TryParse($parts[1].Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$y)) { return }
        if ($y -lt 150 -or $y -gt 230) { return }
        $lines[$posIdx] = $code.Substring(0, $eq + 1) + $parts[0] + "," + $parts[1].TrimEnd() + " + " + $hudBottomShift + $tail
        $counter.n++
    }
    foreach ($b in Get-Blocks $lines) { & $flush $b }
    $text = Join-Lines $split

    $powerY = 'fvar(39):= 197.5'
    if ($text.IndexOf($powerY) -lt 0) { throw "data/common1.cns: posicao da barra de power nao encontrada." }
    $text = $text.Replace($powerY, "fvar(39):= 197.5 + $hudBottomShift")
    if ($counter.n -lt 10 -or $sized -lt 10) { throw "data/common1.cns: poucos elementos de HUD encontrados ($($counter.n)/$sized); arquivo diferente do esperado." }
    Write-Host "  common1.cns: $($counter.n + 1) elementos de HUD ancorados na base da tela, $sized compensados para o zoom"
    $text
}

# Characters' own screen effects (super backgrounds, cut-ins) centred with gamewidth/gameheight.
function Convert-CharFile([string]$text) {
    $split = Split-Lines $text
    if ((Convert-ScreenSize $split.lines) -eq 0) { return $null }
    Join-Lines $split
}

# ---------------------------------------------------------------- stages
$inv = [Globalization.CultureInfo]::InvariantCulture

# Adds $delta to the comma-separated numeric values at $indexes of a "key = a, b, ..." line.
function Add-ToValues([string]$line, [int[]]$indexes, [double]$delta) {
    $semi = $line.IndexOf(';')
    $code = if ($semi -ge 0) { $line.Substring(0, $semi) } else { $line }
    $tail = if ($semi -ge 0) { $line.Substring($semi) } else { "" }
    $eq = $code.IndexOf('=')
    $values = $code.Substring($eq + 1).Split(',')
    foreach ($k in $indexes) {
        $v = 0.0
        if ($k -ge $values.Length -or -not [double]::TryParse($values[$k].Trim(), [Globalization.NumberStyles]::Float, $inv, [ref]$v)) { continue }
        $values[$k] = " " + ($v + $delta).ToString($inv)
    }
    $code.Substring(0, $eq + 1) + ($values -join ",") + $tail
}

function Get-StageSections([string[]]$lines) {
    $sections = @()
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $code = ($lines[$i] -replace ';.*$', '').Trim()
        if (-not $code.StartsWith("[")) { continue }
        if ($sections.Count) { $sections[-1].to = $i }
        $sections += @{ name = $code.ToLower(); from = $i; to = $lines.Length }
    }
    $sections
}

function Find-Key([string[]]$lines, $section, [string]$key) {
    for ($i = $section.from + 1; $i -lt $section.to; $i++) {
        if (($lines[$i] -replace ';.*$', '') -match "^\s*(?i)$key\s*=\s*(\S.*?)\s*$") { return @{ i = $i; value = $Matches[1] } }
    }
    $null
}

# Constant camera zoom; the zoom pivots on the floor line, so floor and background are translated down by zoffset/3
# (only 1.x stages with a fixed floor need it). Camera bounds grow by localcoord/8 so the whole stage stays reachable.
function Convert-Stage([string]$text) {
    $split = Split-Lines $text
    $lines = $split.lines
    $sections = @(Get-StageSections $lines)
    $infos = @($sections | Where-Object { $_.name -eq "[stageinfo]" })
    $cameras = @($sections | Where-Object { $_.name -eq "[camera]" })
    if (-not $infos.Count -or -not $cameras.Count) { return $null }

    $localcoord = $null; $zoffset = $null; $linked = $false
    foreach ($s in $infos) {
        $lc = Find-Key $lines $s "localcoord"
        if ($lc -and $null -eq $localcoord) { $localcoord = [int](($lc.value -split ',')[0]) }
        $z = Find-Key $lines $s "zoffset"
        if ($z -and $null -eq $zoffset) { $zoffset = [double]::Parse($z.value, $inv) }
        if (Find-Key $lines $s "zoffsetlink") { $linked = $true }
    }
    $shift = if ($localcoord -and -not $linked -and $null -ne $zoffset) { [math]::Round($zoffset / 3) } else { 0 }
    $bound = [math]::Round($(if ($localcoord) { $localcoord } else { 320 }) / 8)

    foreach ($s in $sections) {
        if ($s.name -eq "[camera]") {
            $bl = Find-Key $lines $s "boundleft"; if ($bl) { $lines[$bl.i] = Add-ToValues $lines[$bl.i] @(0) (-$bound) }
            $br = Find-Key $lines $s "boundright"; if ($br) { $lines[$br.i] = Add-ToValues $lines[$br.i] @(0) $bound }
            foreach ($key in "zoomout", "zoomin", "startzoom") {
                $old = Find-Key $lines $s $key
                if ($old) { $lines[$old.i] = ";" + $lines[$old.i] }
            }
            $nl = if ($split.seps[$s.from]) { $split.seps[$s.from] } else { "`r`n" }
            $lines[$s.from] += "${nl}zoomout = $zoom${nl}zoomin = $zoom"
        } elseif ($s.name -eq "[stageinfo]") {
            $z = Find-Key $lines $s "zoffset"; if ($z -and $shift) { $lines[$z.i] = Add-ToValues $lines[$z.i] @(0) $shift }
        } elseif ($s.name -match '^\[\s*bg(?!\s*def|\s*ctrl)') {
            $zd = Find-Key $lines $s "zoomdelta"; if ($zd) { $lines[$zd.i] = ($lines[$zd.i] -replace '=\s*[-\d.]+', '= 1') }
            $link = Find-Key $lines $s "positionlink"
            if (-not $shift -or ($link -and $link.value -match '^1')) { continue }
            $st = Find-Key $lines $s "start"; if ($st) { $lines[$st.i] = Add-ToValues $lines[$st.i] @(1) $shift }
            foreach ($key in "window", "maskwindow") {
                $w = Find-Key $lines $s $key; if ($w) { $lines[$w.i] = Add-ToValues $lines[$w.i] @(1, 3) $shift }
            }
        }
    }
    Join-Lines $split
}

# ---------------------------------------------------------------- actions
function Get-Targets {
    $list = @(
        (Join-Path $root "data\mugen.cfg"),
        (Join-Path $root "data\fight.def"),
        (Join-Path $root "data\common1.cns")
    )
    $list += Get-ChildItem -LiteralPath (Join-Path $root "stages") -Filter *.def | ForEach-Object { $_.FullName }
    $list += Get-ChildItem -LiteralPath (Join-Path $root "chars") -Recurse -File -Include *.cns, *.st, *.txt |
        Select-String -Pattern 'game(width|height)' -List | ForEach-Object { $_.Path }
    $list
}

function Get-MotifShift {
    $sys = Read-Text (Join-Path $root "data\system.def")
    $m = [regex]::Match($sys, '(?im)^[ \t]*localcoord[ \t]*=[ \t]*(\d+)[ \t]*,[ \t]*(\d+)')
    if (-not $m.Success) { return 0 }
    $w = [int]$m.Groups[1].Value; $h = [int]$m.Groups[2].Value
    [int](($w * 3 / 4 - $h) / 2)
}

function Invoke-Apply {
    if (Test-Path -LiteralPath $stateFile) { Write-Host "O patch 4:3 ja esta aplicado."; return }
    if ($Width % 4 -ne 0) { throw "A largura precisa ser multipla de 4 (ex.: 640, 800, 960, 1024, 1280)." }
    $height = $Width * 3 / 4
    # MUGEN 1.1 misplaces 4:3 storyboards (logo/intro) when rendering below ~960 px wide, so small video
    # modes are rendered at 960x720 and scaled down by the engine.
    $renderW = [math]::Max($Width, 960)
    $renderH = $renderW * 3 / 4

    $cfgPath = Join-Path $root "data\mugen.cfg"
    $origSize = Get-ConfigSize (Read-Text $cfgPath)
    $shift = Get-MotifShift

    $changes = @{}
    foreach ($path in Get-Targets) {
        $text = Read-Text $path
        $rel = Rel $path
        $new = switch -Wildcard ($rel) {
            "data\mugen.cfg"   { Set-VideoMode (Convert-Config $text $renderW $renderH) $Width $height }
            "data\fight.def"   { Convert-Fight $text $shift }
            "data\common1.cns" { Convert-Common $text }
            "stages\*"         { Convert-Stage $text }
            "chars\*"          { Convert-CharFile $text }
        }
        if ($new -and $new -ne $text) { $changes[$path] = $new }
    }

    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $written = @()
    try {
        foreach ($path in $changes.Keys) {
            $dest = Join-Path $backupDir (Rel $path)
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
            Copy-Item -LiteralPath $path -Destination $dest -Force
        }
        foreach ($path in $changes.Keys) {
            Write-Text $path $changes[$path]
            $written += $path
        }
        $state = @("resolucao_original=$($origSize[0])x$($origSize[1])") + ($changes.Keys | ForEach-Object { "arquivo=" + (Rel $_) })
        [IO.File]::WriteAllLines($stateFile, $state)
    } catch {
        foreach ($path in $written) { Copy-Item -LiteralPath (Join-Path $backupDir (Rel $path)) -Destination $path -Force }
        throw
    }

    $stages = @($changes.Keys | Where-Object { (Rel $_) -like "stages\*" }).Count
    $chars = @($changes.Keys | Where-Object { (Rel $_) -like "chars\*" }).Count
    Write-Host "Patch 4:3 aplicado."
    Write-Host ("  Resolucao de video: {0}x{1} (renderizado em {2}x{3}; original {4}x{5})" -f $Width, $height, $renderW, $renderH, $origSize[0], $origSize[1])
    Write-Host "  Cenarios ajustados (zoom 4:3): $stages"
    Write-Host "  Arquivos de personagens com efeitos de tela ajustados: $chars"
    Write-Host "  HUD de luta e anuncios reposicionados (fight.def, common1.cns)"
    Write-Host "  Backup dos originais: $(Rel $backupDir)"
}

function Invoke-Restore {
    if (-not (Test-Path -LiteralPath $stateFile)) { Write-Host "O patch 4:3 nao esta aplicado; nada a restaurar."; return }
    $state = [IO.File]::ReadAllLines($stateFile)
    $orig = ($state | Where-Object { $_ -like "resolucao_original=*" }) -replace '^resolucao_original=', ''
    $ow, $oh = $orig -split 'x'
    foreach ($line in $state | Where-Object { $_ -like "arquivo=*" }) {
        $rel = $line.Substring(8)
        $path = Join-Path $root $rel
        if ($rel -eq "data\mugen.cfg") {
            # Only the resolution is reverted so options saved by the game meanwhile are kept.
            Write-Text $path (Reset-VideoMode (Convert-Config (Read-Text $path) ([int]$ow) ([int]$oh)))
        } else {
            Copy-Item -LiteralPath (Join-Path $backupDir $rel) -Destination $path -Force
        }
    }
    Remove-Item -LiteralPath $backupDir -Recurse -Force
    Write-Host "Widescreen original restaurado (${ow}x${oh})."
}

switch ($Action) {
    "status" {
        if (Test-Path -LiteralPath $stateFile) { Write-Host "Patch 4:3: APLICADO" } else { Write-Host "Patch 4:3: nao aplicado (widescreen original)" }
    }
    "apply" { Assert-GameClosed; Invoke-Apply }
    "restore" { Assert-GameClosed; Invoke-Restore }
}
