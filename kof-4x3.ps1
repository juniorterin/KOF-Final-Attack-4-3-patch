# KOF Final Attack - patch 4:3
# Uso: kof-4x3.ps1 -Action apply|restore|status [-Width 320] [-GameDir pasta]   (padrao 320x240, monitor CRT)
# -GameDir aceita a pasta do jogo (MUGEN) ou uma pasta convertida para Ikemen GO (ver kof-ikemen.ps1).
param(
    [ValidateSet("apply", "restore", "status")]
    [string]$Action = "status",
    [int]$Width = 320,
    [string]$GameDir = ""
)

$ErrorActionPreference = "Stop"
$latin1 = [Text.Encoding]::GetEncoding(28591)

$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = if ($GameDir) { (Resolve-Path -LiteralPath $GameDir).Path.TrimEnd('\') } else { Split-Path -Parent $patchDir }
$ikemen = (Test-Path -LiteralPath (Join-Path $root "Ikemen_GO.exe")) -or (Test-Path -LiteralPath (Join-Path $root "Ikemen_GO_Linux"))
if (-not $ikemen -and -not (Test-Path -LiteralPath (Join-Path $root "Final Attack.exe"))) {
    throw "Nao encontrei 'Final Attack.exe'. Coloque a pasta 'Patch 4x3' dentro da pasta do jogo."
}
$backupDir = if ($GameDir) { Join-Path $root "backup-widescreen" } else { Join-Path $patchDir "backup-widescreen" }
$stateFile = Join-Path $backupDir "estado.txt"

# MUGEN 1.1 always lays out the fight as if the screen were 16:9. A constant camera zoom of (16/9)/(4/3)
# turns that into a true 4:3 crop: stage and characters keep their proportions and their vertical framing.
# Ikemen GO (FightAspect = resolution) frames the fight the same way, so the same zoom applies.
$zoom = "1.333333"
# Under zoom, gamewidth/gameheight shrink by the zoom factor while screen-anchored explods are not zoomed.
# Ikemen computes them differently but has screenwidth/screenheight, the unzoomed screen size.
$screenWidth = if ($ikemen) { "screenwidth" } else { "(gamewidth*4/3)" }
$screenHeight = if ($ikemen) { "screenheight" } else { "(gameheight*4/3)" }
# Extra height of a 4:3 screen, measured in the units of screen-anchored explods (16:9 frame = width*9/16).
$hudBottomShift = "($screenHeight - $screenWidth*9/16)"

function Read-Text([string]$path) { [IO.File]::ReadAllText($path, $latin1) }
function Write-Text([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, $latin1) }
function Rel([string]$path) { $path.Substring($root.Length + 1) }

function Assert-GameClosed {
    $exe = [IO.Path]::GetFullPath((Join-Path $root $(if ($ikemen) { "Ikemen_GO.exe" } else { "Final Attack.exe" })))
    $running = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and ([IO.Path]::GetFullPath($_.Path) -eq $exe) } catch { $false }
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

# ---------------------------------------------------------------- save/config.ini (Ikemen)
$ikemenVideoKeys = @("GameWidth", "GameHeight", "WindowWidth", "WindowHeight", "FightAspectWidth", "FightAspectHeight")

function Get-IkemenVideo([string]$text) {
    $values = [ordered]@{}
    foreach ($key in $ikemenVideoKeys) {
        $m = [regex]::Match($text, "(?m)^[ \t]*$key[ \t]*=[ \t]*(-?\d+)")
        if (-not $m.Success) { throw "save/config.ini: $key nao encontrado." }
        $values[$key] = [int]$m.Groups[1].Value
    }
    $values
}

function Set-IkemenVideo([string]$text, $values) {
    foreach ($key in $values.Keys) {
        $text = [regex]::Replace($text, "(?m)^([ \t]*$key[ \t]*=[ \t]*)-?\d+", '${1}' + $values[$key])
    }
    $text
}

# ---------------------------------------------------------------- fight.def
# Round/Fight/KO announcements are positioned from the [Round] "pos"; push them to the 4:3 centre.
function Convert-Fight([string]$text, [int]$shift) {
    $m = [regex]::Match($text, '(?ims)^\[Round\][^\[]*?^([ \t]*pos[ \t]*=[ \t]*)(-?[\d.]+)[ \t]*,[ \t]*(-?[\d.]+)')
    if (-not $m.Success) { throw "data/fight.def: [Round] pos nao encontrado." }
    $y = [double]$m.Groups[3].Value + $shift
    $text = $text.Substring(0, $m.Groups[1].Index) + $m.Groups[1].Value + $m.Groups[2].Value + "," + $y + $text.Substring($m.Groups[3].Index + $m.Groups[3].Length)
    # Without [Info] localcoord Ikemen falls back to the motif localcoord, which the motif conversion changes.
    if ($ikemen -and $text -notmatch '(?im)^[ \t]*\[Info\]') {
        $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
        $text = "[Info]${nl}localcoord = $($motifSize[0]),$($motifSize[1])${nl}${nl}" + $text
    }
    $text
}

# ---------------------------------------------------------------- system.def
# MUGEN 1.1 fits a 16:9 motif to the width of a 4:3 screen, centres it and clips its backgrounds to the 16:9
# band; Ikemen crops its sides instead. A 4:3 localcoord of the same width makes both fit the width and draw on
# the whole screen; absolute positions then move down by $shift to stay centred (positions relative to another
# element are left alone).
$motifAbsolute = @{
    "[title info]"               = @("menu.pos")
    "[select info]"              = @("pos", "title.offset", "p1.face.offset", "p2.face.offset", "p1.name.offset", "p2.name.offset",
                                     "stage.pos", "p1.teammenu.pos", "p2.teammenu.pos")
    "[vs screen]"                = @("p1.pos", "p2.pos", "p1.name.pos", "p2.name.pos", "match.offset")
    "[continue screen]"          = @("pos")
    "[win screen]"               = @("wintext.offset")
    "[survival results screen]"  = @("winstext.offset")
    "[victory screen]"           = @("p1.offset", "p2.offset", "p1.name.offset", "p2.name.offset", "winquote.offset")
}
$motifWindows = @("p1.window", "p2.window", "winquote.window", "window", "maskwindow")

function Convert-Motif([string]$text, [int]$shift) {
    $split = Split-Lines $text
    $lines = $split.lines
    $n = 0; $road = $false
    foreach ($s in Get-StageSections $lines) {
        $name = ($s.name -replace '\s+', ' ')
        if ($name -eq "[info]") {
            $lc = Find-Key $lines $s "localcoord"
            if ($lc) { $lines[$lc.i] = "localcoord = $($motifSize[0]),$($motifSize[0] * 3 / 4)" }
            continue
        }
        $keys = $motifAbsolute[$name]
        $isBg = $name -match '^\[\s*\w*bg\s' -and $name -notmatch 'bgdef'
        if ($isBg) {
            $link = Find-Key $lines $s "positionlink"
            if ($link -and $link.value -match '^1') { continue }
            $keys = @("start")
            # The title road (sprite 9011,4, bottom 2 px below its axis) ended 26 px above the 16:9 bottom;
            # it now reaches the bottom of the 4:3 screen.
            $spr = Find-Key $lines $s "spriteno"
            $st = Find-Key $lines $s "start"
            if ($name -match '^\[titlebg\s' -and $spr -and $spr.value -match '^9011\s*,\s*4\b' -and $st) {
                $y = [double]::Parse(($st.value -split ',')[1].Trim(), $inv)
                $lines[$st.i] = Add-ToValues $lines[$st.i] @(1) ($motifSize[0] * 3 / 4 - 2 - $y)
                $n++; $road = $true
                continue
            }
        }
        foreach ($key in @($keys)) {
            if (-not $key) { continue }
            $k = Find-Key $lines $s ([regex]::Escape($key)); if ($k) { $lines[$k.i] = Add-ToValues $lines[$k.i] @(1) $shift; $n++ }
        }
        foreach ($key in $motifWindows) {
            $w = Find-Key $lines $s ([regex]::Escape($key)); if ($w) { $lines[$w.i] = Add-ToValues $lines[$w.i] @(1, 3) $shift; $n++ }
        }
    }
    if ($n -lt 10 -or -not $road) { throw "data/system.def: poucos elementos de tela encontrados ($n); arquivo diferente do esperado." }
    Write-Host "  system.def: telas ajustadas para 4:3 ($n posicoes centralizadas)"
    Join-Lines $split
}

# Storyboards wider than 4:3 (e.g. 1080x720) were seen through the 16:9 frame (1280x720 around them). Ikemen
# would crop them to 4:3; instead the 16:9 area becomes a 4:3 localcoord of the same width and every scene
# moves by the margin around it (layer offsets are relative to layerall.pos).
function Convert-Storyboard([string]$text) {
    $split = Split-Lines $text
    $lines = $split.lines
    $sections = @(Get-StageSections $lines)
    $info = $sections | Where-Object { $_.name -eq "[info]" } | Select-Object -First 1
    if (-not $info) { return $null }
    $lc = Find-Key $lines $info "localcoord"
    if (-not $lc) { return $null }
    $w, $h = $lc.value -split '\s*,\s*' | ForEach-Object { [int]($_ -replace '[^\d]', '') }
    if ($w * 3 -le $h * 4) { return $null }
    $newW = [int][math]::Round($h * 16 / 9)
    $newH = $newW * 3 / 4
    $dx = ($newW - $w) / 2; $dy = ($newH - $h) / 2
    $lines[$lc.i] = "localcoord = $newW,$newH"
    foreach ($s in $sections) {
        if ($s.name -match '^\[scene\s') {
            $p = Find-Key $lines $s "layerall\.pos"
            if ($p) {
                $lines[$p.i] = Add-ToValues (Add-ToValues $lines[$p.i] @(0) $dx) @(1) $dy
            } else {
                $nl = if ($split.seps[$s.from]) { $split.seps[$s.from] } else { "`r`n" }
                $lines[$s.from] += "${nl}layerall.pos = $dx,$dy"
            }
        } elseif ($s.name -match '^\[\s*\w*bg\s' -and $s.name -notmatch 'bgdef') {
            $link = Find-Key $lines $s "positionlink"
            if ($link -and $link.value -match '^1') { continue }
            $st = Find-Key $lines $s "start"; if ($st) { $lines[$st.i] = Add-ToValues (Add-ToValues $lines[$st.i] @(0) $dx) @(1) $dy }
            foreach ($key in "window", "maskwindow") {
                $win = Find-Key $lines $s $key; if ($win) { $lines[$win.i] = Add-ToValues (Add-ToValues $lines[$win.i] @(0, 2) $dx) @(1, 3) $dy }
            }
        }
    }
    Join-Lines $split
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

# The camera zoom only takes effect after the first tick, so screen explods created on "!time" read the unzoomed
# gamewidth/gameheight and land off-screen. A ModifyExplod right after them repositions them from then on
# (only when the ID is unique in its state, so other explods are not moved).
function Add-ZoomRefresh([string[]]$lines, [string]$nl) {
    $n = 0
    $blocks = @(Get-Blocks $lines)
    $states = @(); $cur = @()
    foreach ($b in $blocks) {
        if ($lines[$b.from] -match '^\s*\[\s*(?i)statedef') { if ($cur.Count) { $states += , $cur }; $cur = @() }
        $b.id = $null; $b.created = $false
        for ($i = $b.from + 1; $i -lt $b.to; $i++) {
            $code = ($lines[$i] -replace ';.*$', '').Trim()
            if ($code -match '^(?i)id\s*=\s*(\d+)$') { $b.id = $Matches[1] }
            elseif ($code -match '^(?i)trigger1\s*=\s*!\s*time$') { $b.created = $true }
        }
        $cur += $b
    }
    if ($cur.Count) { $states += , $cur }
    foreach ($state in $states) {
        foreach ($b in $state) {
            if ($b.type -ne "explod" -or -not $b.created -or -not $b.id -or $b.posIdx -lt 0 -or $b.postype -notin @("left", "right")) { continue }
            $pos = ($lines[$b.posIdx] -replace ';.*$', '').Trim()
            if ($pos -notmatch [regex]::Escape($screenWidth) -and $pos -notmatch [regex]::Escape($screenHeight)) { continue }
            if (@($state | Where-Object { $_.type -eq "explod" -and $_.id -eq $b.id }).Count -gt 1) { continue }
            $lines[$b.to - 1] += "${nl}[State 0, ModifyExplod 4:3]${nl}type = ModifyExplod${nl}trigger1 = time > 0${nl}ID = $($b.id)${nl}postype = $($b.postype)${nl}$pos${nl}"
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
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $refreshed = Add-ZoomRefresh $lines $nl
    if ($refreshed -lt 2) { throw "data/common1.cns: explods de inicio de luta (LEVEL) nao encontrados." }
    $text = Join-Lines $split

    $powerY = 'fvar(39):= 197.5'
    if ($text.IndexOf($powerY) -lt 0) { throw "data/common1.cns: posicao da barra de power nao encontrada." }
    $text = $text.Replace($powerY, "fvar(39):= 197.5 + $hudBottomShift")

    # The MODE SELECT backdrop only covers a 16:9 screen; a second copy underneath fills the extra 4:3 height
    # with its lower black band (the fighters would show through there otherwise).
    $backdrop = [regex]::Match($text, '\[State 0, Striker Setup Top BG\]\r?\n(?:(?!\r?\n\r?\n)[\s\S])*?postype = back[^\r\n]*\r?\n')
    if (-not $backdrop.Success -or $backdrop.Value -notmatch 'anim = f199890') { throw "data/common1.cns: fundo da tela MODE SELECT nao encontrado." }
    $nl = if ($backdrop.Value.Contains("`r`n")) { "`r`n" } else { "`n" }
    $cover = ($backdrop.Value -replace '\]', ' 4:3]' -replace '19990', '19989' -replace 'fvar\(39\)', "fvar(39) + $hudBottomShift" -replace 'sprpriority=95', 'sprpriority=94')
    $text = $text.Insert($backdrop.Index + $backdrop.Length, $nl + $cover)
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
        (Join-Path $root "data\system.def"),
        (Join-Path $root "data\fight.def"),
        (Join-Path $root "data\common1.cns")
    )
    if (-not $ikemen) { $list += Join-Path $root "data\mugen.cfg" }
    if ($ikemen) {
        $list += Get-ChildItem -LiteralPath (Join-Path $root "data") -Filter *.def |
            Select-String -Pattern '^\s*\[SceneDef\]' -List | ForEach-Object { $_.Path }
    }
    $list += Get-ChildItem -LiteralPath (Join-Path $root "stages") -Filter *.def | ForEach-Object { $_.FullName }
    $list += Get-ChildItem -LiteralPath (Join-Path $root "chars") -Recurse -File -Include *.cns, *.st, *.txt |
        Select-String -Pattern 'game(width|height)' -List | ForEach-Object { $_.Path }
    $list
}

function Get-MotifShift {
    $sys = Read-Text (Join-Path $root "data\system.def")
    $m = [regex]::Match($sys, '(?im)^[ \t]*localcoord[ \t]*=[ \t]*(\d+)[ \t]*,[ \t]*(\d+)')
    if (-not $m.Success) { $script:motifSize = @(320, 240); return 0 }
    $w = [int]$m.Groups[1].Value; $h = [int]$m.Groups[2].Value
    $script:motifSize = @($w, $h)
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

    if ($ikemen) {
        $cfgPath = Join-Path $root "save\config.ini"
        if (-not (Test-Path -LiteralPath $cfgPath)) { throw "save/config.ini nao encontrado; rode o Ikemen GO uma vez ou use kof-ikemen.ps1." }
        $origIkemen = Get-IkemenVideo (Read-Text $cfgPath)
        $origSize = @($origIkemen["GameWidth"], $origIkemen["GameHeight"])
    } else {
        $cfgPath = Join-Path $root "data\mugen.cfg"
        $origSize = Get-ConfigSize (Read-Text $cfgPath)
    }
    $shift = Get-MotifShift

    $changes = @{}
    if ($ikemen) {
        $changes[$cfgPath] = Set-IkemenVideo (Read-Text $cfgPath) @{
            GameWidth = $renderW; GameHeight = $renderH; WindowWidth = $Width; WindowHeight = $height
            FightAspectWidth = 0; FightAspectHeight = 0
        }
    }
    foreach ($path in Get-Targets) {
        $text = Read-Text $path
        $rel = Rel $path
        $new = switch -Wildcard ($rel) {
            "data\mugen.cfg"   { Set-VideoMode (Convert-Config $text $renderW $renderH) $Width $height; break }
            "data\system.def"  { Convert-Motif $text $shift; break }
            "data\fight.def"   { Convert-Fight $text $shift; break }
            "data\common1.cns" { Convert-Common $text; break }
            "data\*.def"       { Convert-Storyboard $text; break }
            "stages\*"         { Convert-Stage $text; break }
            "chars\*"          { Convert-CharFile $text; break }
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
        if ($ikemen) { $state += $origIkemen.Keys | ForEach-Object { "ikemen_$_=$($origIkemen[$_])" } }
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
    if ($ikemen) {
        $boards = @($changes.Keys | Where-Object { (Rel $_) -like "data\*.def" -and (Rel $_) -notin @("data\system.def", "data\fight.def") }).Count
        Write-Host "  Storyboards widescreen ajustados: $boards"
        Write-Host "  Ikemen GO: save\config.ini com FightAspect da resolucao (4:3)"
    }
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
        } elseif ($rel -eq "save\config.ini") {
            $values = @{}
            foreach ($v in $state | Where-Object { $_ -like "ikemen_*=*" }) { $kv = $v.Substring(7) -split '=', 2; $values[$kv[0]] = $kv[1] }
            Write-Text $path (Set-IkemenVideo (Read-Text $path) $values)
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
