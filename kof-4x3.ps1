# KOF Final Attack - patch 4:3
# Uso: kof-4x3.ps1 -Action apply|restore|status [-Width 320] [-GameDir pasta]   (padrao 320x240, monitor CRT)
# -GameDir aceita a pasta do jogo (MUGEN) ou uma pasta convertida para Ikemen GO (ver kof-ikemen.ps1).
param(
    [ValidateSet("apply", "restore", "status")]
    [string]$Action = "status",
    [int]$Width = 320,
    [string]$GameDir = "",
    [switch]$CoinOp
)

$ErrorActionPreference = "Stop"
$latin1 = [Text.Encoding]::GetEncoding(28591)

$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = if ($GameDir) { (Resolve-Path -LiteralPath $GameDir).Path.TrimEnd('\', '/') } else { Split-Path -Parent $patchDir }
$ikemen = (Test-Path -LiteralPath (Join-Path $root "Ikemen_GO.exe")) -or (Test-Path -LiteralPath (Join-Path $root "Ikemen_GO_Linux"))
if (-not $ikemen -and -not (Test-Path -LiteralPath (Join-Path $root "Final Attack.exe"))) {
    throw "Nao encontrei 'Final Attack.exe'. Coloque a pasta 'Patch 4x3' dentro da pasta do jogo."
}
$backupDir = if ($GameDir) { Join-Path $root "backup-widescreen" } else { Join-Path $patchDir "backup-widescreen" }
$stateFile = Join-Path $backupDir "estado.txt"

# MUGEN 1.1 always lays out the fight as if the screen were 16:9. A constant camera zoom of (16/9)/(4/3)
# turns that into a true 4:3 crop: stage and characters keep their proportions and their vertical framing.
# Ikemen GO (FightAspect = resolution) lays the fight out at 4:3 and can show more height than the 16:9 frame, so it
# uses the zoom that draws the characters (localcoord 366) one sprite pixel per screen pixel on a 320-wide screen:
# the arcade pixel grid on a CRT.
$zoom = if ($ikemen) { "1.14375" } else { "1.333333" }
# Ikemen draws a stage pixel at zoom*320/localcoord screen pixels; the arcade stage art matches the characters 1:1
# when the stage uses the characters' localcoord width.
$charLocalcoord = 366
# Under zoom, gamewidth/gameheight shrink by the zoom factor while screen-anchored explods are not zoomed.
# Ikemen computes them differently but has screenwidth/screenheight, the unzoomed screen size.
$screenWidth = if ($ikemen) { "screenwidth" } else { "(gamewidth*4/3)" }
$screenHeight = if ($ikemen) { "screenheight" } else { "(gameheight*4/3)" }
# Extra height of a 4:3 screen, measured in the units of screen-anchored explods (16:9 frame = width*9/16).
# Ikemen at 1:1 has the HUD in screen pixels; the arcade keeps it ~10 px above the bottom, clear of CRT overscan.
$hudBottomShift = if ($ikemen) { "($screenHeight - $screenWidth*9/16 - 10)" } else { "($screenHeight - $screenWidth*9/16)" }

function Read-Text([string]$path) { [IO.File]::ReadAllText($path, $latin1) }
function Write-Text([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, $latin1) }
function Rel([string]$path) { ($path.Substring($root.Length + 1) -replace '[\\/]', '\') }

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

# ---------------------------------------------------------------- fight.def, fight.sff (MUGEN)
# fight.def is laid out in the motif localcoord, now 960 wide: the HUD keeps its original size relative to the
# screen height. Centre elements move by -160 and P2 elements by -320; the lifebars lose $lifeCut units so
# everything fits. Their background sprites (face frame + striped bar + half of the timer box, 3x scale) lose
# 42 px of stripes (3 periods of the pattern), so faces and names move by $lifeCut - 160 (towards the centre when positive).
$lifeCut = 126
$lifeSprites = @(@(10, 0), @(10, 1))
$lifeStripes = @(198, 42)
# The single background (10,0) frames the face with room to spare: 11 px of the frame's plain interior go too, so
# the frame stays at the screen edge and the face moves with it. The team background (10,1) has no frame and its
# portraits keep their place, with the longer bar filling the gap next to them.
$frameSprite = @(10, 0)
$frameCut = @(150, 11)
$teamFaceShift = 42
# FightFx sprites (hit sparks, and the stage art drawn by common1.cns explods) are scaled in the same localcoord, so
# their scale shrinks with it to keep their size.
function Get-FxScale { 960 / (960 + 2 * $motifCrop) }

Add-Type -TypeDefinition @"
using System;
using System.IO;
public static class Sff1 {
    static int U16(byte[] b, int o) { return b[o] | (b[o + 1] << 8); }
    static int I32(byte[] b, int o) { return BitConverter.ToInt32(b, o); }
    static void P16(byte[] b, int o, int v) { b[o] = (byte)v; b[o + 1] = (byte)(v >> 8); }
    static void P32(byte[] b, int o, int v) { Array.Copy(BitConverter.GetBytes(v), 0, b, o, 4); }

    // Removes columns [from, from + count) of an 8-bit PCX image, keeping whatever follows the pixels (palette).
    static byte[] CutPcx(byte[] d, int from, int count) {
        if (d[3] != 8 || d[65] != 1) throw new Exception("PCX nao suportado");
        int w = U16(d, 8) - U16(d, 4) + 1, h = U16(d, 10) - U16(d, 6) + 1, bpl = U16(d, 66);
        if (from < 0 || from + count > w) throw new Exception("corte fora do sprite");
        int p = 128;
        byte[][] rows = new byte[h][];
        for (int y = 0; y < h; y++) {
            rows[y] = new byte[bpl];
            for (int x = 0; x < bpl; ) {
                int v = d[p++], run = 1;
                if ((v & 0xC0) == 0xC0) { run = v & 0x3F; v = d[p++]; }
                for (; run > 0; run--, x++) if (x < bpl) rows[y][x] = (byte)v;
            }
        }
        int nw = w - count, nbpl = nw + (nw & 1);
        var o = new MemoryStream();
        byte[] hdr = new byte[128];
        Array.Copy(d, hdr, 128);
        P16(hdr, 8, U16(d, 4) + nw - 1);
        P16(hdr, 66, nbpl);
        o.Write(hdr, 0, 128);
        byte[] row = new byte[nbpl];
        for (int y = 0; y < h; y++) {
            Array.Clear(row, 0, nbpl);
            Array.Copy(rows[y], 0, row, 0, from);
            Array.Copy(rows[y], from + count, row, from, w - from - count);
            for (int i = 0; i < nbpl; ) {
                int run = 1;
                while (i + run < nbpl && row[i + run] == row[i] && run < 63) run++;
                if (run > 1 || (row[i] & 0xC0) == 0xC0) o.WriteByte((byte)(0xC0 | run));
                o.WriteByte(row[i]);
                i += run;
            }
        }
        o.Write(d, p, d.Length - p);
        return o.ToArray();
    }

    // SFF v1: rewrites the subfile list with the columns of sprite group,item cut out; the axis follows the pixels.
    public static byte[] CutColumns(byte[] f, int group, int item, int from, int count) {
        if (f.Length < 512 || f[15] != 1) throw new Exception("SFF v1 esperado");
        int n = I32(f, 20), off = I32(f, 24), prev = -1, found = 0;
        var o = new MemoryStream();
        o.Write(f, 0, off);
        for (int k = 0; k < n && off != 0; k++) {
            int next = I32(f, off), len = I32(f, off + 4);
            byte[] hdr = new byte[32];
            Array.Copy(f, off, hdr, 0, 32);
            byte[] data = new byte[len];
            Array.Copy(f, off + 32, data, 0, len);
            if (len > 0 && U16(hdr, 12) == group && U16(hdr, 14) == item) {
                data = CutPcx(data, from, count);
                short ax = BitConverter.ToInt16(hdr, 8);
                if (from + count <= ax) P16(hdr, 8, ax - count);
                found++;
            }
            int pos = (int)o.Position;
            if (prev >= 0) { byte[] b = o.GetBuffer(); P32(b, prev, pos); }
            P32(hdr, 0, 0);
            P32(hdr, 4, data.Length);
            o.Write(hdr, 0, 32);
            o.Write(data, 0, data.Length);
            prev = pos;
            off = next;
        }
        if (found != 1) throw new Exception("sprite " + group + "," + item + " nao encontrado");
        return o.ToArray();
    }
}
"@

function Convert-FightSff([string]$text) {
    $bytes = $latin1.GetBytes($text)
    foreach ($s in $lifeSprites) { $bytes = [Sff1]::CutColumns($bytes, $s[0], $s[1], $lifeStripes[0], $lifeStripes[1]) }
    $bytes = [Sff1]::CutColumns($bytes, $frameSprite[0], $frameSprite[1], $frameCut[0], $frameCut[1])
    Write-Host "  fight.sff: fundo das barras de vida $($lifeStripes[1] * 3) unidades mais curto, moldura do rosto $($frameCut[1] * 3) mais estreita"
    $latin1.GetString($bytes)
}

function Convert-FightMugen([string]$text) {
    $split = Split-Lines $text
    $lines = $split.lines
    $face = $lifeCut - $motifCrop
    $n = 0
    $fx = $null
    foreach ($s in Get-StageSections $lines) {
        $name = ($s.name -replace '\s+', ' ')
        if ($name -eq "[fightfx]") {
            $fx = Find-Key $lines $s "scale"
            $old = if ($fx) { [double]::Parse($fx.value, $inv) } else { 1 }
            $value = ($old * (Get-FxScale)).ToString($inv)
            if ($fx) { $lines[$fx.i] = "scale = $value" } else { $lines[$s.from] += "$($split.seps[$s.from])scale = $value" }
            $fx = $value
            continue
        }
        for ($i = $s.from + 1; $i -lt $s.to; $i++) {
            $code = ($lines[$i] -replace ';.*$', '').Trim()
            if ($code -notmatch '^(?i)(p(\d)\.(teammate\.)?pos|p(\d)\.range\.x|team(\d)\.pos|pos)\s*=') { continue }
            $player = if ($Matches[2]) { [int]$Matches[2] } elseif ($Matches[4]) { [int]$Matches[4] } elseif ($Matches[5]) { [int]$Matches[5] } else { 0 }
            $teammate = [bool]$Matches[3]
            $left = $player % 2 -eq 1
            if ($topHudShift -and $code -notmatch '^(?i)p\d\.range\.x' -and
                ($name -match '(lifebar|face|name)\]$' -or $name -eq "[time]")) {
                $lines[$i] = Add-ToValues $lines[$i] @(1) (3 * $topHudShift)
            }
            if ($code -match '^(?i)p\d\.range\.x') {
                $lines[$i] = Add-ToValues $lines[$i] @(1) $(if ($left) { $lifeCut } else { -$lifeCut })
            } elseif ($name -match 'lifebar\]$' -or $name -in "[time]", "[round]", "[winicon]") {
                $lines[$i] = Add-ToValues $lines[$i] @(0) (-$motifCrop)
            } elseif ($name -match '(face|name)\]$' -or $name -eq "[combo]") {
                $dx = if ($name -eq "[combo]") { 0 } else { $face }
                if ($name -in "[simul face]", "[turns face]" -and -not $teammate) { $dx += $teamFaceShift }
                if ($name -eq "[face]") { $dx += 3 * $frameCut[1] }
                $lines[$i] = Add-ToValues $lines[$i] @(0) $(if ($left) { $dx } else { -2 * $motifCrop - $dx })
            } else { continue }
            $n++
        }
    }
    if ($ikemen) {
        # Combo digits are 24x37 pixel art. Only scale 3 (1:1, too big) and 1.5 (every other pixel) sample
        # them evenly; other scales drop pixels irregularly and break the stripes. Round-win icons stay at 3.
        # ROUND and FIGHT were authored for the 1280-wide motif, so on 960 they draw a third larger.
        # FIGHT goes to 2 (was 3.5) and each ROUND n to 3.5 (was 5).
        foreach ($s in Get-StageSections $lines) {
            $sec = ($s.name -replace '\s+', ' ')
            for ($i = $s.from + 1; $i -lt $s.to; $i++) {
                $code = ($lines[$i] -replace ';.*$', '')
                if ($sec -eq "[combo]" -and $code -match '1\.6\s*,\s*1\.6') {
                    $lines[$i] = $lines[$i] -replace '1\.6\s*,\s*1\.6', '1.5,1.5'
                } elseif ($sec -eq "[winicon]" -and $code -match '(?i)scale\s*=\s*2\s*,\s*2') {
                    $lines[$i] = $lines[$i] -replace '2\s*,\s*2', '3,3'
                } elseif ($sec -eq "[winicon]" -and $code -match '(?i)counter\.scale\s*=\s*1\s*,\s*1') {
                    $lines[$i] = $lines[$i] -replace '1\s*,\s*1', '3,3'
                } elseif ($sec -eq "[round]" -and $code -match '(?i)fight\.scale\s*=') {
                    $lines[$i] = $lines[$i] -replace '3\.5\s*,\s*3\.5', '2,2'
                } elseif ($sec -eq "[round]" -and $code -match '(?i)round\d\.scale\s*=') {
                    $lines[$i] = $lines[$i] -replace '5\s*,\s*5', '3.5,3.5'
                }
            }
        }
    }
    if ($n -lt 40) { throw "data/fight.def: poucos elementos de HUD encontrados ($n); arquivo diferente do esperado." }
    if ($null -eq $fx) { throw "data/fight.def: secao [FightFx] nao encontrada; arquivo diferente do esperado." }
    Write-Host "  fight.def: HUD em 960x720 ($n posicoes, barras de vida $lifeCut unidades mais curtas, FightFx scale $fx)"
    Join-Lines $split
}

# ---------------------------------------------------------------- system.def (Ikemen)
# Ikemen crops the sides of a 16:9 motif on a 4:3 screen. A 4:3 localcoord of the same width makes it fit the
# width; absolute positions then move down by $shift to stay centred (positions relative to another element are
# left alone).
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
            if ($link -and $link.value -match '^[-+]?0*[1-9]') { continue }
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

# ---------------------------------------------------------------- system.def, select.def (MUGEN)
# MUGEN 1.1 fits a 16:9 motif to the width of a 4:3 screen, centres it and clips its backgrounds to the 16:9 band.
# A 960x720 localcoord keeps the original height instead: the screens fill the 4:3 frame with the original
# vertical layout, 33% bigger, and lose 160 units on each side (background x is relative to the screen centre).
$motifCrop = 160
# The character grid has five blocks of portraits (x 100..1179) with a blank 40-unit column between them, too wide
# for the narrower screen. The grid gets 8-unit columns (each character takes 5: itself and 4 blanks the cursor skips),
# so the gap between blocks shrinks to one 8-unit column: 952 wide, block k moves by -96 - 32k.
$gridBlocks = @(@(100, 300), @(340, 540), @(580, 700), @(740, 940), @(980, 1180))
$gridColumns = 54
$gridSplit = 5
$gridRows = 2..7
$gridGaps = @(11, 17, 21, 27)
$gridLastColumn = 33
# Select backgrounds by action: portrait sheets of a single block, and art spanning the whole grid (drawn once
# per block through a window).
$gridBlockActions = @{ 30 = 0; 31 = 0; 32 = 1; 33 = 1; 34 = 3; 35 = 3; 36 = 4; 37 = 4; 39 = 2; 40 = 1; 41 = 3 }
$gridWideActions = @(2, 4, 7, 8)
# Black cover over the grid during the intro (its bottom edge hides the last portrait row).
$gridCoverActions = @(64)
# Blue and red gradient (static, and its fade-in): the grid frame (action 8) covers its top, by as much as in 16:9
# only if both move together.
$gridGradientSprite = '^133\s*,\s*2\b'
$gridGradientActions = @(133)
$selectFaceScale = "0.8,0.8"
# Ikemen: big portraits in the bottom corners. Their axis is the bottom-left corner of the 111-px-tall sprite (row 110),
# drawn at 0.8 x 960/366 units per pixel (characters use localcoord 366).
$selectFaceBottom = 720 - 0.8 * 960 / 366
# Columns each gap between blocks keeps. Ikemen at 320x240 shows the screen edges on the CRT: there the gap columns go
# away and each block is pushed right by a 6-unit (2 px) cell offset per gap instead, which leaves an 8-unit margin on
# each side, and the grid moves 18 units down.
$gridGapKeep = if ($ikemen) { 0 } else { 1 }
$gridGapOffset = if ($ikemen) { 6 } else { 0 }
$gridTop = if ($ikemen) { 18 } else { 0 }
function Get-GridShift([int]$k) {
    $gap = $gridGapKeep * 40 / $gridSplit + $gridGapOffset
    $left = (960 - 920 - 4 * $gap) / 2 - 100
    $left - (40 - $gap) * $k
}
# New column of an old visible column (5 per old column, minus the columns dropped from each gap before it).
function Get-GridColumn([int]$col) {
    $gridSplit * $col - ($gridSplit - $gridGapKeep) * @($gridGaps | Where-Object { $_ -lt $col }).Count
}

$victoryW = 1280
$victoryH = 960
$victoryTop = 120
$quoteScale = 1.333333
$motifMugenX = @{
    "[title info]"      = @{ "menu.pos" = -160 }
    "[select info]"     = @{ "pos" = (Get-GridShift 0); "title.offset" = -160; "p2.face.offset" = -320; "p1.name.offset" = -160
                             "p2.name.offset" = -160; "stage.pos" = -160; "p2.teammenu.pos" = -320 }
    "[vs screen]"       = @{ "p1.pos" = -160; "p2.pos" = -160; "p1.name.pos" = -160; "p2.name.pos" = -160 }
    "[continue screen]" = @{ "pos" = -160 }
    "[victory screen]"  = @{ "winquote.offset" = -160 }
}

function Convert-MotifMugen([string]$text) {
    $split = Split-Lines $text
    $lines = $split.lines
    $seps = $split.seps
    $n = 0; $road = $false; $blocks = 0; $wide = 0; $quoteAt = $null
    foreach ($s in Get-StageSections $lines) {
        $name = ($s.name -replace '\s+', ' ')
        if ($name -eq "[info]") {
            $lc = Find-Key $lines $s "localcoord"
            if ($lc) { $lines[$lc.i] = "localcoord = 960,720"; $n++ }
            continue
        }
        if ($ikemen -and $name -eq "[title info]") {
            $nlInfo = if ($seps[$s.from]) { $seps[$s.from] } else { "`n" }
            # Ikemen draws the engine footer (version, "press F1", copyright) over the title. Scale 0 hides it.
            $lines[$s.from] += "${nlInfo}footer.title.scale = 0,0${nlInfo}footer.info.scale = 0,0${nlInfo}footer.version.scale = 0,0"
        }
        if ($ikemen -and $name -eq "[vs screen]") {
            # fadein.time 90000 from white holds a white screen before the fight.
            for ($i = $s.from + 1; $i -lt $s.to; $i++) {
                if ($lines[$i] -match '(?i)fadein\.time\s*=\s*90000') { $lines[$i] = $lines[$i] -replace '90000', '0' }
                if ($lines[$i] -match '(?i)fadein\.col\s*=\s*255\s*,\s*255\s*,\s*255') { $lines[$i] = $lines[$i] -replace '255\s*,\s*255\s*,\s*255', '0,0,0' }
            }
        }
        # Ikemen draws the victory screen in its own 1280x960 localcoord: the whole 1280-wide layout scaled to
        # the 4:3 width and centred vertically. Its black clear goes to layer 1, over the stage foreground and
        # explods; the portrait and quote go to layer 2, over the clear and the wipes, and the engine's
        # half-black overlay is turned off.
        if ($ikemen -and $name -eq "[victorybgdef]") {
            $nlV = if ($seps[$s.from]) { $seps[$s.from] } else { "`n" }
            $lines[$s.from] += "${nlV}bgclearcolor = 0,0,0${nlV}bgclearlayerno = 1"
        }
        # Its backgrounds ignore localcoord: they are scaled by 960/1280 instead (x is relative to the centre).
        # The wipes that uncover the quote line by line (actions 1801-1805) grow with the quote around its
        # offset, so each one stays on its line.
        if ($ikemen -and $name -match '^\[victorybg\s') {
            $st = Find-Key $lines $s "start"
            if ($st) {
                $v = @($st.value -split ',' | ForEach-Object { [double]::Parse($_.Trim(), $inv) })
                $k = 960 / $victoryW
                $q = 1
                $act = Find-Key $lines $s "actionno"
                if ($act -and $act.value -match '^180[1-5]$' -and $quoteAt) {
                    $q = $quoteScale
                    $v[0] = ($victoryW / 2 + $v[0] - $quoteAt[0]) * $q + $quoteAt[0] - $victoryW / 2
                    $v[1] = ($v[1] - $quoteAt[1]) * $q + $quoteAt[1]
                }
                $lines[$st.i] = "start = $(($v[0] * $k).ToString($inv)),$(($v[1] * $k + $victoryTop * $k).ToString($inv))"
                $nlV = if ($seps[$st.i]) { $seps[$st.i] } else { "`n" }
                $lines[$st.i] += "${nlV}scalestart = $(($q * $k).ToString($inv)),$(($q * $k).ToString($inv))"
            }
        }
        if ($ikemen -and $name -eq "[victory screen]") {
            $wq = Find-Key $lines $s "winquote\.offset"
            if ($wq) { $quoteAt = @((($wq.value -replace ';.*$', '') -split ',')[0..1] | ForEach-Object { [double]::Parse($_.Trim(), $inv) }) }
            foreach ($key in "p1.offset", "winquote.offset") {
                $k = Find-Key $lines $s ([regex]::Escape($key)); if ($k) { $lines[$k.i] = Add-ToValues $lines[$k.i] @(1) $victoryTop; $n++ }
            }
            foreach ($key in "p1.window", "winquote.window") {
                $k = Find-Key $lines $s ([regex]::Escape($key)); if ($k) { $lines[$k.i] = Add-ToValues $lines[$k.i] @(1, 3) $victoryTop }
            }
            foreach ($key in "p1.layerno", "winquote.layerno") {
                $k = Find-Key $lines $s ([regex]::Escape($key)); if ($k) { $lines[$k.i] = "$key = 2" }
            }
            # "l" is not an Ikemen wrap mode, so the quote ran past its window instead of wrapping.
            $k = Find-Key $lines $s "winquote\.textwrap"; if ($k) { $lines[$k.i] = "winquote.textwrap = w" }
            $nlV = if ($seps[$s.from]) { $seps[$s.from] } else { "`n" }
            # The quote font keeps its size on the 960 motif (a third of a pixel per font pixel).
            $lines[$s.from] += "${nlV}p1.localcoord = $victoryW,$victoryH${nlV}winquote.localcoord = $victoryW,$victoryH" +
                "${nlV}winquote.scale = $quoteScale,$quoteScale${nlV}overlay.alpha = 0,256"
        }
        # Continue texts are scaled 5 on the 960 motif: 5/3 screen px per font pixel, uneven. 3 is 1:1.
        if ($ikemen -and $name -eq "[continue screen]") {
            for ($i = $s.from + 1; $i -lt $s.to; $i++) {
                if ($lines[$i] -match '^(?i)\s*[\w.]*scale\s*=\s*5\s*,\s*5') { $lines[$i] = $lines[$i] -replace '5\s*,\s*5', '3,3' }
            }
        }
        $moves = if ($ikemen -and $name -eq "[victory screen]") { $null } else { $motifMugenX[$name] }
        if ($moves) {
            foreach ($key in $moves.Keys) {
                $k = Find-Key $lines $s ([regex]::Escape($key)); if ($k) { $lines[$k.i] = Add-ToValues $lines[$k.i] @(0) $moves[$key]; $n++ }
            }
        }
        if ($name -eq "[select info]") {
            $cols = Find-Key $lines $s "columns"
            $spacing = Find-Key $lines $s "cell\.spacing"
            $size = Find-Key $lines $s "cell\.size"
            if (-not $cols -or [int]$cols.value -ne $gridColumns -or -not $spacing -or [int]($spacing.value -replace '\s*;.*$', '') -ne 40 -or
                -not $size -or $size.value -notmatch '^0\s*,\s*25\b') { throw "data/system.def: grade de selecao diferente do esperado." }
            $lines[$cols.i] = "columns = $($gridColumns * $gridSplit)"
            if ($gridTop) { $p = Find-Key $lines $s "pos"; if ($p) { $lines[$p.i] = Add-ToValues $lines[$p.i] @(1) $gridTop } }
            $lines[$spacing.i] = "cell.spacing = $(40 / $gridSplit)"
            $lines[$size.i] = "cell.size = 0,$(65 - 40 / $gridSplit)"
            if ($gridGapOffset) {
                $starts = @($gridGaps | ForEach-Object { Get-GridColumn $_ })
                $nl = if ($seps[$size.i]) { $seps[$size.i] } else { "`r`n" }
                for ($c = $starts[0]; $c -lt $gridColumns * $gridSplit; $c++) {
                    $lines[$size.i] += "${nl}cell.$c-*.offset = $($gridGapOffset * @($starts | Where-Object { $_ -le $c }).Count),0"
                }
            }
            foreach ($p in "p1", "p2") {
                $c = Find-Key $lines $s "$p\.cursor\.startcell"
                if ($c) {
                    $col = [int](($c.value -split ',')[1] -replace '[^\d]', '')
                    $lines[$c.i] = Add-ToValues $lines[$c.i] @(1) ((Get-GridColumn $col) - $col)
                }
                $f = Find-Key $lines $s "$p\.face\.scale"; if ($f) { $lines[$f.i] = "$p.face.scale = $selectFaceScale" }
                $o = Find-Key $lines $s "$p\.face\.offset"
                if ($ikemen -and $o) { $lines[$o.i] = "$p.face.offset = $(if ($p -eq 'p1') { 0 } else { 960 }),$($selectFaceBottom.ToString('0.###', $inv))" }
            }
        }
        if (-not $ikemen -and $name -eq "[victory screen]") {
            foreach ($key in "p1.window", "winquote.window") {
                $w = Find-Key $lines $s ([regex]::Escape($key)); if ($w) { $lines[$w.i] = Add-ToValues $lines[$w.i] @(2) (-2 * $motifCrop) }
            }
        }
        $st = Find-Key $lines $s "start"
        if ($name -match '^\[titlebg\s' -and $st -and (Find-Key $lines $s "spriteno").value -match '^9011\s*,\s*4\b') {
            # The title road (sprite 9011,4, bottom 2 px below its axis) ended 26 px above the bottom.
            $y = [double]::Parse(($st.value -split ',')[1].Trim(), $inv)
            $lines[$st.i] = Add-ToValues $lines[$st.i] @(1) (720 - 2 - $y)
            $road = $true
        }
        if ($name -notmatch '^\[selectbg\s' -or -not $st) { continue }
        $spr = Find-Key $lines $s "spriteno"
        if ($gridTop -and $spr -and $spr.value -match $gridGradientSprite) { $lines[$st.i] = Add-ToValues $lines[$st.i] @(1) $gridTop }
        $action = Find-Key $lines $s "actionno"
        if (-not $action) { continue }
        $a = [int]($action.value -replace '[^\d].*$', '')
        if ($gridTop -and ($gridBlockActions.ContainsKey($a) -or $a -in $gridWideActions -or $a -in $gridCoverActions -or
                $a -in $gridGradientActions)) {
            $lines[$st.i] = Add-ToValues $lines[$st.i] @(1) $gridTop
        }
        if ($gridBlockActions.ContainsKey($a)) {
            $lines[$st.i] = Add-ToValues $lines[$st.i] @(0) ((Get-GridShift $gridBlockActions[$a]) + $motifCrop)
            $blocks++
        } elseif ($a -in $gridWideActions) {
            $nl = if ($seps[$s.from]) { $seps[$s.from] } else { "`r`n" }
            $body = New-Object Text.StringBuilder
            for ($k = 0; $k -lt $gridBlocks.Count; $k++) {
                $dx = Get-GridShift $k
                for ($i = $s.from; $i -lt $s.to; $i++) {
                    $line = $lines[$i]
                    if ($i -eq $st.i) {
                        $line = (Add-ToValues $line @(0) ($dx + $motifCrop)) + "${nl}window = $($gridBlocks[$k][0] + $dx),0,$($gridBlocks[$k][1] + $dx - 1),719"
                    }
                    [void]$body.Append($line).Append($(if ($i -eq $s.to - 1) { $seps[$i] } else { $nl }))
                }
            }
            for ($i = $s.from; $i -lt $s.to; $i++) { $lines[$i] = ""; $seps[$i] = "" }
            $lines[$s.from] = $body.ToString()
            $wide++
        }
    }
    if ($n -lt 15 -or -not $road -or $blocks -ne $gridBlockActions.Count -or $wide -lt $gridWideActions.Count) {
        throw "data/system.def: telas diferentes do esperado ($n posicoes, $blocks/$wide fundos da selecao)."
    }
    Write-Host "  system.def: telas em 960x720 ($n posicoes, grade de personagens com espacos menores entre blocos)"
    $text = Join-Lines $split
    if ($ikemen) {
        # The command list (hold Start) sits at y 20 with a 0.4 font, under the lifebars and hard to read.
        $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
        $text += "${nl}${nl}[Pause Menu]${nl}movelist.pos = 10,36${nl}movelist.title.scale = 0.8,0.8${nl}movelist.text.scale = 0.8,0.8${nl}"
        if ($CoinOp) {
            # Attract mode starts at 0 credits. F6 inserts a coin; the attract menu is arcade only.
            $text += "${nl}${nl}[Attract Mode]${nl}enabled = 1${nl}"
        }
    }
    $text
}

# Splits every column in 5 (the entry and 4 blanks); in the visible rows each gap between blocks keeps a single
# column and the dropped blanks go to the end of the row, so every row keeps its length.
function Convert-SelectGrid([string]$text) {
    $split = Split-Lines $text
    $lines = $split.lines
    $entries = @(); $inChars = $false
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $code = ($lines[$i] -replace ';.*$', '').Trim()
        if ($code.StartsWith("[")) { if ($inChars) { break }; $inChars = $code -match '^\[characters\]$'; continue }
        if ($inChars -and $code) { $entries += $i }
    }
    $extra = @{}
    foreach ($row in $gridRows) {
        $base = $row * $gridColumns
        if ($entries.Count -le $base + $gridLastColumn) { throw "data/select.def: grade de personagens diferente do esperado." }
        foreach ($c in $gridGaps) {
            $i = $entries[$base + $c]
            if (($lines[$i] -replace ';.*$', '').Trim() -ne "blank") { throw "data/select.def: espaco entre blocos nao encontrado (linha $($row), coluna $c)." }
            $extra[$i] = $gridGapKeep - 1
        }
        $extra[$entries[$base + $gridLastColumn]] = ($gridSplit - 1) + ($gridSplit - $gridGapKeep) * $gridGaps.Count
    }
    foreach ($i in $entries) {
        $blanks = if ($extra.ContainsKey($i)) { $extra[$i] } else { $gridSplit - 1 }
        if ($blanks -lt 0) { $lines[$i] = ""; $split.seps[$i] = ""; continue }
        $nl = if ($split.seps[$i]) { $split.seps[$i] } else { "`r`n" }
        $lines[$i] += ("${nl}blank" * $blanks)
    }
    Write-Host "  select.def: grade de personagens com espacos menores entre blocos"
    Join-Lines $split
}

# Storyboards in a 370x280 localcoord centre their text on x = 170, which MUGEN shows at the centre of a 16:9 screen;
# on 4:3 the centre is x = 185. Ikemen would scale the 370x280 area down to the screen (320/370: columns and rows
# dropped at 320x240), so there the centre 320x240 is shown 1:1 instead.
function Convert-NarrowStoryboard([string]$text) {
    $split = Split-Lines $text
    $lines = $split.lines
    $sections = @(Get-StageSections $lines)
    $info = $sections | Where-Object { $_.name -eq "[info]" } | Select-Object -First 1
    if (-not $info) { return $null }
    $lc = Find-Key $lines $info "localcoord"
    if (-not $lc -or $lc.value -notmatch '^370\s*,\s*280\b') { return $null }
    $dx = 15; $dy = 0
    if ($ikemen) {
        $lines[$lc.i] = "localcoord = 320, 240 ;4x3 " + $lines[$lc.i].Trim()
        $dx -= (370 - 320) / 2; $dy -= (280 - 240) / 2
    }
    foreach ($s in $sections | Where-Object { $_.name -match '^\[scene\s' }) {
        $p = Find-Key $lines $s "layerall\.pos"
        if ($p) {
            $lines[$p.i] = Add-ToValues $lines[$p.i] @(0) $dx
            if ($dy) { $lines[$p.i] = Add-ToValues $lines[$p.i] @(1) $dy }
        }
        else {
            $nl = if ($split.seps[$s.from]) { $split.seps[$s.from] } else { "`r`n" }
            $lines[$s.from] += "${nl}layerall.pos = $dx,$dy"
        }
    }
    Join-Lines $split
}

# Story text is laid out for a 1280x960 board. On a 320x240 screen that board is drawn at a quarter size, so the
# arcade story font is unreadably small. Ikemen scales a text layer with layerN.font.scale.
function Add-StoryFontScale([string]$text) {
    if ($text -notmatch '(?i)StoryFont') { return $null }
    $split = Split-Lines $text
    $lines = $split.lines
    $n = 0
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -notmatch '^(?i)\s*layer(\d+)\.font\s*=') { continue }
        $key = "layer$($Matches[1]).font.scale"
        $have = $false
        for ($j = $i + 1; $j -lt [Math]::Min($i + 8, $lines.Length); $j++) {
            if ($lines[$j] -match "(?i)^\s*$([regex]::Escape($key))\s*=") { $have = $true; break }
        }
        if ($have) { continue }
        $nl = if ($split.seps[$i]) { $split.seps[$i] } else { "`n" }
        $lines[$i] += "${nl}$key = 2,2"
        $n++
    }
    if (-not $n) { return $null }
    Join-Lines $split
}

# Ikemen gives storyboards without a localcoord the motif localcoord; MUGEN gives them 320x240, which is what they
# are laid out for (e.g. the intro).
function Add-StoryboardLocalcoord([string]$text) {
    if ($text -match '(?im)^[ \t]*localcoord[ \t]*=') { return $null }
    $m = [regex]::Match($text, '(?im)^[ \t]*\[SceneDef\][^\r\n]*(\r?\n)')
    if (-not $m.Success) { return $null }
    $text.Insert($m.Index + $m.Length, "localcoord = 320,240" + $m.Groups[1].Value)
}

# Storyboards wider than 4:3 (e.g. 1080x720) were seen through the 16:9 frame (1280x720 around them), and their
# text runs past the 1080 area. Both engines would show only that area on 4:3; instead the 16:9 area becomes a
# 4:3 localcoord of the same width and every scene moves by the margin around it (layer offsets are relative to
# layerall.pos).
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
            if ($link -and $link.value -match '^[-+]?0*[1-9]') { continue }
            $st = Find-Key $lines $s "start"; if ($st) { $lines[$st.i] = Add-ToValues (Add-ToValues $lines[$st.i] @(0) $dx) @(1) $dy }
            foreach ($key in "window", "maskwindow") {
                $win = Find-Key $lines $s $key; if ($win) { $lines[$win.i] = Add-ToValues (Add-ToValues $lines[$win.i] @(0, 2) $dx) @(1, 3) $dy }
            }
        }
    }
    Add-StoryFrameFill $lines $split.seps $sections $newW $newH
    Join-Lines $split
}

# The story scenes on a white clear colour are framed by sprite 5,0 (black bands around a transparent window,
# 806 px tall), shorter than the 4:3 view: the white clear colour would show above and below it. Two background
# copies of the frame, clipped by windows to those strips, extend its black bands to the screen edges.
$storyFrame = @{ sprite = "5,0"; axisY = 607; height = 806; band = 140 }

function Add-StoryFrameFill([string[]]$lines, [string[]]$seps, $sections, [int]$w, [int]$h) {
    $frameActions = @()
    foreach ($s in $sections | Where-Object { $_.name -match '^\[begin action\s+(\d+)\]$' }) {
        $a = [int]($s.name -replace '[^\d]', '')
        for ($i = $s.from + 1; $i -lt $s.to; $i++) {
            $code = ($lines[$i] -replace ';.*$', '').Trim()
            if (-not $code) { continue }
            if ($code -match "^$([regex]::Escape($storyFrame.sprite) -replace ',', '\s*,\s*')\s*,") { $frameActions += $a }
            break
        }
    }
    $n = 0
    foreach ($s in $sections | Where-Object { $_.name -match '^\[scene\s' }) {
        $clear = Find-Key $lines $s "clearcolor"
        if (-not $clear -or $clear.value -match '^0\s*,\s*0\s*,\s*0\b') { continue }
        $all = Find-Key $lines $s "layerall\.pos"
        if (-not $all) { continue }
        $layer = $null
        for ($i = $s.from + 1; $i -lt $s.to; $i++) {
            if (($lines[$i] -replace ';.*$', '') -match '^\s*(?i)layer(\d+)\.anim\s*=\s*(\d+)' -and [int]$Matches[2] -in $frameActions) { $layer = $Matches[1]; break }
        }
        if ($null -eq $layer) { continue }
        $off = Find-Key $lines $s "layer$layer\.offset"
        $ax, $ay = ($all.value -split ',') | ForEach-Object { [double]::Parse($_.Trim(), $inv) }
        $ox, $oy = if ($off) { ($off.value -split ',') | ForEach-Object { [double]::Parse(($_ -replace ';.*$', '').Trim(), $inv) } } else { 0, 0 }
        $x = $ax + $ox - $w / 2; $y = $ay + $oy
        $top = $y - $storyFrame.axisY; $bottom = $top + $storyFrame.height
        if ($top -le 0 -and $bottom -ge $h) { continue }
        if ($top -gt $storyFrame.band -or $h - $bottom -gt $storyFrame.band) { throw "Storyboard: moldura da cena menor que o esperado." }
        $name = "Fill43s$n"
        $nl = if ($seps[$s.from]) { $seps[$s.from] } else { "`r`n" }
        $lines[$all.i] += "${nl}bg.name = $name"
        $last = $lines.Length - 1
        $lines[$last] += "$nl$nl[${name}Def]$nl$nl" +
            "[$name top]${nl}type = normal${nl}spriteno = $($storyFrame.sprite)${nl}start = $x,$($y - $top)${nl}window = 0,0,$($w - 1),$($top + 2)$nl$nl" +
            "[$name bottom]${nl}type = normal${nl}spriteno = $($storyFrame.sprite)${nl}start = $x,$($y + $h - $bottom)${nl}window = 0,$($bottom - 2),$($w - 1),$($h - 1)$nl"
        $n++
    }
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

# Ikemen at 320x240 draws screen-anchored FightFx sprites at 7/8 (2.625 / 3), which drops pixel columns of the small
# pixel-font sprites. The power gauge (the Statedef that sets fvar(39), plus the MAX mode pieces at y 188), the
# difficulty LEVEL and the characters' VS names (anim 7997, 4x pixel art at .25) get 8/7 on top of their scale, i.e. 1:1.
$hudScale = "1.142857"
# Ikemen at 320x240 shows the top edge on the CRT: the top HUD (lifebars, faces, names, time, score) moves down
# by this many screen pixels.
$topHudShift = if ($ikemen) { 6 } else { 0 }
# The middle of the 8 px LEVEL sits on the gauges' bottom edge.
$levelLift = 11.15
function Add-HudScale([string[]]$lines, [string]$nl) {
    $n = 0
    $gauges = @{}
    $statedef = -1
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -match '^\s*\[\s*(?i)statedef') { $statedef = $i }
        elseif ($lines[$i] -match 'fvar\(39\):=\s*197\.5') { $gauges[$statedef] = $true }
    }
    $inGauge = $false
    foreach ($b in Get-Blocks $lines) {
        if ($lines[$b.from] -match '^\s*\[\s*(?i)statedef') { $inGauge = $gauges.ContainsKey($b.from); continue }
        if ($b.type -notin @("explod", "modifyexplod")) { continue }
        $pos = if ($b.posIdx -ge 0) { ($lines[$b.posIdx] -replace ';.*$', '') } else { "" }
        $max = $b.type -eq "explod" -and $pos -match '188\s*\+\s*\(screenheight'
        $level = $b.type -eq "explod" -and $pos -match '\(screenwidth\*\.5\),\(screenheight\)'
        $vsNames = $b.type -eq "explod" -and
            @($lines[($b.from + 1)..($b.to - 1)] | Where-Object { $_ -match '^\s*(?i)anim\s*=\s*7997\b' }).Count -gt 0
        if (-not ($inGauge -or $max -or $level -or $vsNames)) { continue }
        $found = $false
        for ($i = $b.from + 1; $i -lt $b.to; $i++) {
            $code = ($lines[$i] -replace ';.*$', '')
            if ($code -notmatch '^(?i)\s*scale\s*=(.*)$') { continue }
            $parts = Split-Pos $Matches[1]
            if (-not $parts) { continue }
            $lines[$i] = "scale = ($($parts[0].Trim()))*$hudScale,($($parts[1].Trim()))*$hudScale"
            $found = $true; $n++
        }
        if (-not $found -and $b.type -eq "explod" -and $b.posIdx -ge 0) {
            $lines[$b.posIdx] += "${nl}scale = $hudScale,$hudScale"
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
    if ($ikemen) {
        $scaled = Add-HudScale $lines $nl
        if ($scaled -lt 20) { throw "data/common1.cns: explods do medidor de power nao encontrados ($scaled)." }
    }
    $refreshed = Add-ZoomRefresh $lines $nl
    if ($refreshed -lt 2) { throw "data/common1.cns: explods de inicio de luta (LEVEL) nao encontrados." }
    $text = Join-Lines $split

    if (-not $ikemen) {
        # Score digits follow the ends of the lifebars, which moved with the bigger HUD (see Convert-FightMugen).
        $score = 'ifelse( teamside=1 , 46.5 , 280.0 )'
        $count = ([regex]::Matches($text, [regex]::Escape($score))).Count
        if ($count -lt 10) { throw "data/common1.cns: posicao da pontuacao nao encontrada." }
        $text = $text.Replace($score, 'ifelse( teamside=1 , 65 , 261.5 )')
    }

    if ($topHudShift) {
        $scoreY = [regex]'(ifelse\( teamside=1 , 46\.5 , 280\.0 \)[^,\r\n]*, )-2\.5'
        if ($scoreY.Matches($text).Count -lt 10) { throw "data/common1.cns: altura da pontuacao nao encontrada." }
        $dy = [math]::Round($topHudShift * $charLocalcoord / 320, 2).ToString($inv)
        $text = $scoreY.Replace($text, "`${1}(-2.5 + $dy)")
    }

    if ($ikemen) {
        # The VS names, 1:1 and so taller, move up 4 px to clear the LEVEL below them.
        $vsY = 'pos = screenwidth/2,180 + '
        if (([regex]::Matches($text, [regex]::Escape($vsY))).Count -ne 1) { throw "data/common1.cns: posicao dos nomes do VS nao encontrada." }
        $text = $text.Replace($vsY, 'pos = screenwidth/2,175.43 + ')

        # The difficulty LEVEL sits on the screen bottom itself; same margin as the rest of the bottom HUD.
        $level = 'pos = (screenwidth*.5),(screenheight)'
        if (([regex]::Matches($text, [regex]::Escape($level))).Count -ne 2) { throw "data/common1.cns: posicao do LEVEL nao encontrada." }
        $text = $text.Replace($level, "pos = (screenwidth*.5),(screenheight - $levelLift)")

        # WINNER graphics are drawn at scale 1 in the 960 localcoord, so a 45 px word is 15 px on screen.
        $winner = [regex]::Replace($text, '(anim = Fifelse\(\(teamside = 2\),80(?:21,8020|23,8024)\)\r?\npostype = left\r?\npos = 160, 60\r?\n)scale = 1,1', '${1}scale = 2,2')
        if ($winner -eq $text) { throw "data/common1.cns: anuncio de vencedor nao encontrado." }
        $text = $winner

        # The 1994 USA referee is bound to the bottom of the screen for one tick, which on 4:3 is below the
        # floor (on the logo). Leave him at y = -10, just above the floor, and draw every FightFx pose 1:1.
        # The stand poses are f1583/f1587; the walk poses are f1584-f1589. Scaling only the stand ones makes
        # him change size when he moves.
        $eol = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
        $doll = [regex]::Replace($text, '(?m)^trigger1 = time = 1(\r?\ntime = 1\r?\nfacing = 0\r?\npos = 0,-30)\r?$', 'trigger1 = 0${1}')
        if ($doll -eq $text) { throw "data/common1.cns: juiz do 1994 EUA nao encontrado." }
        $text = $doll
        $dollScale = [regex]::Replace($text, '(?m)^(anim = f158[3-9])\r?$', ('${1}' + $eol + "scale = $hudScale,$hudScale"))
        if (([regex]::Matches($dollScale, "(?m)^anim = f158[3-9]\r?\nscale = $hudScale,$hudScale")).Count -ne 13) { throw "data/common1.cns: animacoes do juiz do 1994 EUA nao encontradas." }
        $text = $dollScale

        # The 1996 Fatal Fury picture is drawn by these explods at the feet line, and sits a few pixels
        # under the top of the screen. Lift only the picture, 5 screen px (one unit is one pixel there).
        $script:ffLift = 0
        $ff = [regex]::Replace($text, '(?m)^\[State [^\r\n]*\r?\n(?:(?!\[)[^\r\n]*\r?\n)*', {
                param($m)
                $b = $m.Value
                if ($b -notmatch '(?m)^trigger(all|1) = StageVar\(info\.name\) = "   \("') { return $b }
                $script:ffLift++
                [regex]::Replace($b, '(?m)^(postype = [^\r\n]*)', ('${1}' + $eol + 'pos = 0,-5'), 1)
            })
        if ($script:ffLift -ne 20) { throw "data/common1.cns: arte do 1996 Fatal Fury nao encontrada ($script:ffLift)." }
        $text = $ff

        # The 2000 Egypt sky ends up to 25 lines under the top of the screen. A copy of it 30 px higher, behind
        # everything, fills the top (the sky is an even haze there).
        $script:egLift = 0
        $eg = [regex]::Replace($text, '(?m)^\[State [^\r\n]*;Sky[^\r\n]*\r?\n(?:(?!\[)[^\r\n]*\r?\n)*', {
                param($m)
                $b = $m.Value
                if ($b -notmatch '(?m)^trigger(all|1) = StageVar\(info\.name\) = "   A"') { return $b }
                $script:egLift++
                $copy = [regex]::Replace($b, '(?m)^(postype = [^\r\n]*)', ('${1}' + $eol + 'pos = 0,-30'), 1)
                $copy = [regex]::Replace($copy, '(?m)^sprpriority = -?\d+', 'sprpriority = -9990', 1)
                $b + ($copy -replace '^(\[State [^\]\r\n]*)\]', '${1} 4:3]')
            })
        if ($script:egLift -ne 5) { throw "data/common1.cns: ceu do 2000 Egypt nao encontrado ($script:egLift)." }
        $text = $eg

        # The 1998 USA sky (parallax, explod 1066) ends 16 lines under the top (the station sky of round 2, F1164,
        # 37). Same fix, with its own ID and parallax 40 px higher.
        $script:usLift = 0
        $us = [regex]::Replace($text, '(?m)^\[State [^\r\n]*;Sky[^\r\n]*\r?\n(?:(?!\[)[^\r\n]*\r?\n)*', {
                param($m)
                $b = $m.Value
                if ($b -notmatch '(?m)^trigger(all|1) = StageVar\(info\.name\) = "   O"') { return $b }
                $script:usLift++
                $copy = [regex]::Replace($b, '(?m)^id = 1066\b', 'id = 19066', 1)
                $copy = [regex]::Replace($copy, '(?m)^sprpriority = -?\d+', 'sprpriority = -9990', 1)
                $b + ($copy -replace '^(\[State [^\]\r\n]*)\]', '${1} 4:3]')
            })
        $sky = [regex]::Match($us, '\[State 0, ModifyExplod\]\r?\ntype = ModifyExplod\r?\n;;parallax explod\r?\ntrigger1 = numexplod\(1066\)\r?\n(?:(?!\[)[^\r\n]*\r?\n)*')
        if ($script:usLift -ne 2 -or -not $sky.Success) { throw "data/common1.cns: ceu do 1998 USA nao encontrado ($script:usLift)." }
        $skyCopy = $sky.Value -replace '\(1066\)', '(19066)' -replace 'ID = 1066', 'ID = 19066' -replace '-70', '-110' -replace '(?m)^anim = 1066\r?\n', ''
        $text = $us.Insert($sky.Index + $sky.Length, $skyCopy)

        # Every parallax sky is explod 1066 with its own picture. MUGEN ignores anim in ModifyExplod; Ikemen applies
        # it and shows the 1996 Fatal Fury "day" sky (F1066) in its other rounds and in the other stages.
        # Its later skies (F1073, F1078) lack the -12 axis of F1066 and leave 8 black lines on top of a 4:3 screen.
        # The sky moves at 1/3 of the camera speed, between screen pixels: round it to whole pixels.
        $skyMod = [regex]'(?m)^(?:anim = 1066\r?\n)?(postype = left\r?\n)pos = \(\(0 \+ fvar\(0\)\) - fvar\(2\) / 3 \),\( \((-70|-110) \+ fvar\(1\)\) - fvar\(3\) / 3 \)'
        if ($skyMod.Matches($text).Count -ne 2) { throw "data/common1.cns: paralaxe dos ceus nao encontrada." }
        $px = "(screenwidth/$Width.0)"
        $text = $skyMod.Replace($text, { param($m)
                $y = $m.Groups[2].Value
                if ($y -eq "-70") { $y += ' - 12*(StageVar(info.name) = "   (" && !(roundno = 1))' }
                $m.Groups[1].Value + "pos = floor((fvar(0) - fvar(2)/3)/$px + .5)*$px," +
                "floor(($y + fvar(1) - fvar(3)/3)/$px + .5)*$px"
            })

        # The stage art helper stands at the bottom of the screen on its first tick, and its explods hang from it.
        # On Ikemen the camera is not settled on that tick (it differs between Arcade and Practice), so the picture
        # lands up to ~80 px low. Use the bottom of the screen with the camera at rest: the floor is drawn 32 px
        # above zoffset in a 240-line screen, one unit per pixel.
        $anchor = 'y = floor(pos Y-screenpos Y)+gameheight+5'
        if (([regex]::Matches($text, [regex]::Escape($anchor))).Count -ne 1) { throw "data/common1.cns: posicao do helper da arte dos cenarios nao encontrada." }
        $text = $text.Replace($anchor, 'y = 277 - StageVar(stageinfo.zoffset)')
        # The parallax skies measure the camera from the helper's screen height on tick 1, which was the bottom
        # of the screen by construction; keep that value instead of the unsettled one.
        $skyRef = [regex]::Match($text, '(trigger1 = time = 1\r?\nfv = 1\s*\r?\nvalue = )screenpos y')
        if (-not $skyRef.Success) { throw "data/common1.cns: referencia do ceu dos cenarios nao encontrada." }
        $text = $text.Remove($skyRef.Index, $skyRef.Length).Insert($skyRef.Index, $skyRef.Groups[1].Value + 'gameheight + 5')

        # The VS names (helper 7997) hold the intro for 210 ticks from the round start, so they show under the MODE
        # SELECT screen (helper 199999) and are half gone when it closes. Start their clock and picture after it.
        # The button that closes MODE SELECT also skips the intro on Ikemen (VS and ROUND); not while they hold it.
        $vs = [regex]::Match($text, '(?s)\[Statedef 7997\].*?(?=\[Statedef )')
        $vsMenu = '!(root,numhelper(199999)) && !(enemy,numhelper(199999))'
        $vsText = [regex]::Replace($vs.Value, '(type = Varadd\r?\n)trigger1 = 1(\r?\nv = 0\r?\nvalue = 1)', "`${1}trigger1 = $vsMenu`${2}", 1)
        $vsText = [regex]::Replace($vsText, '(type = Explod\r?\n)trigger1 = !time(\r?\nremovetime = -1)', '${1}trigger1 = var(0) = 1${2}', 1)
        $vsText = [regex]::Replace($vsText, '(flag = intro\r?\nflag2 = nobardisplay)(\r?\n)', '${1}${2}flag3 = roundnotskip${2}', 1)
        if (-not $vs.Success -or ([regex]::Matches($vsText, [regex]::Escape($vsMenu) + '|trigger1 = var\(0\) = 1\r?\nremovetime|flag3 = roundnotskip')).Count -ne 3) { throw "data/common1.cns: nomes do VS nao encontrados." }
        $text = $text.Remove($vs.Index, $vs.Length).Insert($vs.Index, $vsText)

        # The stage art helper picks each round's picture with var(39) := roundno, but characters whose code writes
        # var(39) on their helpers (Kyo, Amanda, Lee...) change it and the picture goes missing or wrong. Ask roundno.
        $rounds = [regex]::Replace($text, '(?m)^(trigger(?:all|\d+) = )var\(39\)', '${1}roundno')
        if (([regex]::Matches($rounds, '(?m)^trigger(?:all|\d+) = roundno')).Count -lt 500) { throw "data/common1.cns: gatilhos de round da arte dos cenarios nao encontrados." }
        $text = $rounds

        # MUGEN draws an explod behind the older ones of the same sprpriority; Ikemen draws it in front. The stage
        # art explods are made in a row at the same priority (sky last), so on Ikemen the sky covers the stage.
        # Break the ties in MUGEN's order: each explod goes one below the previous one of its stage and priority.
        $script:artTies = @{}
        $script:artRanks = @{}
        $art = [regex]::Replace($text, '(?m)^\[State [^\r\n]*\r?\n(?:(?!\[)[^\r\n]*\r?\n)*', {
                param($m)
                $b = $m.Value
                $st = [regex]::Match($b, '(?m)^trigger(?:all|1) = StageVar\(info\.name\) = "([^"]*)"')
                $pr = [regex]::Match($b, '(?m)^sprpriority = (-?\d+)')
                if (-not $st.Success -or -not $pr.Success -or $b -notmatch '(?mi)^type = Explod') { return $b }
                $p = [int]$pr.Groups[1].Value
                $key = "$($st.Groups[1].Value)|$p"
                $k = [int]$script:artTies[$key]
                $script:artTies[$key] = $k + 1
                if (-not $script:artRanks.ContainsKey($st.Groups[1].Value)) { $script:artRanks[$st.Groups[1].Value] = @{} }
                $script:artRanks[$st.Groups[1].Value][$p] = $k
                if ($k -eq 0) { return $b }
                $b.Remove($pr.Index, $pr.Length).Insert($pr.Index, "sprpriority = $($p - $k)")
            })
        foreach ($stage in $script:artRanks.Keys) {
            $ps = @($script:artRanks[$stage].Keys | Sort-Object)
            for ($i = 1; $i -lt $ps.Count; $i++) {
                if ($ps[$i] - $script:artRanks[$stage][$ps[$i]] -le $ps[$i - 1]) { throw "data/common1.cns: prioridades da arte do cenario '$stage' se cruzam." }
            }
        }
        if ($script:artTies.Count -lt 20) { throw "data/common1.cns: explods de arte de cenario nao encontrados." }
        $text = $art
    }

    $powerY = 'fvar(39):= 197.5'
    if ($text.IndexOf($powerY) -lt 0) { throw "data/common1.cns: posicao da barra de power nao encontrada." }
    $text = $text.Replace($powerY, "fvar(39):= 197.5 + $hudBottomShift")

    # The MODE SELECT backdrop only covers a 16:9 screen; a second copy underneath fills the extra 4:3 height
    # with its lower black band (the fighters would show through there otherwise). It goes down the whole extra
    # height, not the HUD's (10 px short of the bottom on Ikemen).
    $backdrop = [regex]::Match($text, '\[State 0, Striker Setup Top BG\]\r?\n(?:(?!\r?\n\r?\n)[\s\S])*?postype = back[^\r\n]*\r?\n')
    if (-not $backdrop.Success -or $backdrop.Value -notmatch 'anim = f199890') { throw "data/common1.cns: fundo da tela MODE SELECT nao encontrado." }
    $nl = if ($backdrop.Value.Contains("`r`n")) { "`r`n" } else { "`n" }
    $cover = ($backdrop.Value -replace '\]', ' 4:3]' -replace '19990', '19989' -replace 'fvar\(39\)', "fvar(39) + ($screenHeight - $screenWidth*9/16)" -replace 'sprpriority=95', 'sprpriority=94')
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

# Starting y of the BG element with the given id; a nonzero positionlink places an element relative to the one before it.
function Get-BgY([string[]]$lines, $sections, [string]$id) {
    $prev = 0.0
    foreach ($s in $sections | Where-Object { $_.name -match '^\[\s*bg(?!\s*def|\s*ctrl)' }) {
        $st = Find-Key $lines $s "start"
        $y = 0.0
        if ($st) { $parts = $st.value -split ','; if ($parts.Length -gt 1) { [void][double]::TryParse($parts[1].Trim(), [Globalization.NumberStyles]::Float, $inv, [ref]$y) } }
        $link = Find-Key $lines $s "positionlink"
        if ($link -and $link.value -match '^[-+]?0*[1-9]') { $y += $prev }
        $bid = Find-Key $lines $s "id"
        if ($bid -and $bid.value.Trim() -eq $id) { return $y }
        $prev = $y
    }
    $null
}

# Constant camera zoom; the zoom pivots on the floor line, so floor and background are translated down by zoffset/3
# (only 1.x stages with a fixed floor need it). Camera bounds grow by localcoord/8 so the whole stage stays reachable.
# Screen rows below the art on stages whose art ends closer to the floor; their floor goes down by that much.
$floorDrop = @{
    "kofxi-boss2" = 7
    "1999-airport" = 11; "1999-china_town" = 11; "kof2k-temple" = 19
    "svc_boss" = 9; "1996-boss_team" = 9
    "1995-korea_team" = 8; "2003-pyramids" = 7
    "1994-japan" = 5
    "1994-china" = 4; "1999-sewer" = 4; "1994-rugal" = 4
    "kf2k3_skynoah" = 4; "kf2k3_kagurastage" = 4; "kf2k3_cave" = 4
    "1995-psychic_soldier" = 4; "1995-women_team" = 4; "1995-ikari_team" = 1; "kof2k1-zero" = 4
    "1994-brazil" = 22; "1994-england" = 3; "1994-italy" = 4; "1994-korea" = 4; "1994-mexico" = 3; "1994-usa" = 4
    "1995-fatal_fury" = 4; "1995-hero_team" = 4; "1996-women_team" = 4; "1996-ikari_team" = 1
    "1997-bali_stage" = 3; "1997-monaco_stage" = 4; "1998-korea_dock" = 4; "1998-middle_east" = 4
    "1999-museum" = 4; "1999-sewer_elivator" = 4; "2000-hero" = 1; "2000-harbour" = 4; "2000-korea" = 4
    "2001-brazil" = 4; "2001-china" = 4; "2001-italy" = 4; "2001-japan" = 4; "2001-korea" = 4
    "2001-mexico" = 4; "2001-usa" = 1; "2002-cambodia" = 4; "2003-japan" = 4; "2003-china" = 4
    "2003-lokomotive" = 4; "kof95-saisyu" = 4; "kof96-goenitzstage" = 4; "kof97-orochichris" = 4
    "kof97-orochishermie" = 4; "kof97-orochiyashiro" = 4; "kof97orochi" = 4; "kof99-krizalid" = 2
    "kof2k1-igniz" = 4; "kof2k2rugal" = 4
}
# Screen pixels the picture (not the floor) goes up on retargeted stages; one stage unit is one pixel there.
$artLift = @{ "1994-brazil" = 8 }
# Screen pixels the foreground layers (layerno 1) go down, where they end above the bottom of the screen.
$frontDrop = @{ "1998-china_lake" = 8 }

function Convert-Stage([string]$text, [string]$name) {
    $split = Split-Lines $text
    $lines = $split.lines
    $sections = @(Get-StageSections $lines)
    $infos = @($sections | Where-Object { $_.name -eq "[stageinfo]" })
    $cameras = @($sections | Where-Object { $_.name -eq "[camera]" })
    if (-not $infos.Count -or -not $cameras.Count) { return $null }

    $localcoord = $null; $zoffset = $null; $linked = $false; $linkId = $null
    foreach ($s in $infos) {
        $lc = Find-Key $lines $s "localcoord"
        if ($lc -and $null -eq $localcoord) { $localcoord = [int](($lc.value -split ',')[0]) }
        $z = Find-Key $lines $s "zoffset"
        if ($z -and $null -eq $zoffset) { $zoffset = [double]::Parse($z.value, $inv) }
        $zl = Find-Key $lines $s "zoffsetlink"
        if ($zl) { $linked = $true; $linkId = $zl.value.Trim() }
    }
    $shift = if ($localcoord -and -not $linked -and $null -ne $zoffset) { [math]::Round($zoffset / 3) } else { 0 }
    $bound = [math]::Round($(if ($localcoord) { $localcoord } else { 320 }) / 8)
    # With zoffsetlink the floor is zoffset below the linked layer, so the layer shift places the art and the
    # zoffset change places the feet.
    $oldWidth = if ($localcoord) { $localcoord } else { 320 }
    $retarget = $ikemen -and $oldWidth -le 400
    # The art is shifted so it reaches the bottom of the 240 lines. The feet sit 2.5 screen px below that
    # edge (half of the previous 5 px drop). Raising the floor with the art opens a gap. Ikemen draws the
    # floor 32 px above zoffset, and the floor moves 5 screen rows per 8 units of zoffset, so 2.5 rows are
    # 4 units. Only zoffset moves the feet.
    $artZ = 248
    if ($floorDrop.ContainsKey($name)) { $artZ += [math]::Ceiling($floorDrop[$name] * 1.6) }
    $footZ = $artZ + 4
    # Retargeted stages show 320 units across instead of localcoord/zoom, so the bounds grow only by what the
    # widescreen view showed beyond that.
    if ($retarget) { $bound = [math]::Max(0, [math]::Floor($oldWidth / 2 - 160)) }
    # The select thumbnail is the stage name, drawn centered in stage.fnt, where a space is 185 units wide.
    # The other 94 stages use five spaces and a trailing space, which puts the glyph in the box. Mexico is
    # only "\", so its picture sits 370 units to the left. The glyph art is retargeted in the font below.
    if ($ikemen -and $name -eq "1994-mexico") {
        $renamed = $false
        for ($i = 0; $i -lt $lines.Length; $i++) {
            if ($lines[$i] -match '^\s*name\s*=\s*"\\"\s*$') { $lines[$i] = 'name = "     \ "'; $renamed = $true; break }
        }
        if (-not $renamed) { throw "1994-mexico: nome do cenario nao encontrado" }
    }
    $footDelta = $null
    if ($retarget -and $null -ne $zoffset) {
        if (-not $linked) {
            $shift = $artZ - $zoffset
            $footDelta = $footZ - $zoffset
        } else {
            $linkY = Get-BgY $lines $sections $linkId
            if ($null -ne $linkY) { $shift = $artZ - ($zoffset + $linkY); $footDelta = $footZ - $artZ }
        }
    }

    foreach ($s in $sections) {
        if ($s.name -eq "[camera]") {
            $bl = Find-Key $lines $s "boundleft"; if ($bl) { $lines[$bl.i] = Add-ToValues $lines[$bl.i] @(0) (-$bound) }
            $br = Find-Key $lines $s "boundright"; if ($br) { $lines[$br.i] = Add-ToValues $lines[$br.i] @(0) $bound }
            # The art is drawn for the shorter 16:9 frame; at 1:1 on 4:3 a camera going up on jumps shows the black
            # above it, and the parallax skies (1/3 speed) part from the ground.
            if ($retarget) { $bh = Find-Key $lines $s "boundhigh"; if ($bh) { $lines[$bh.i] = "boundhigh = 0 ;4x3 " + $lines[$bh.i].Trim() } }
            foreach ($key in "zoomout", "zoomin", "startzoom") {
                $old = Find-Key $lines $s $key
                if ($old) { $lines[$old.i] = ";" + $lines[$old.i] }
            }
            $nl = if ($split.seps[$s.from]) { $split.seps[$s.from] } else { "`r`n" }
            $lines[$s.from] += "${nl}zoomout = $zoom${nl}zoomin = $zoom"
        } elseif ($s.name -eq "[stageinfo]") {
            $z = Find-Key $lines $s "zoffset"
            if ($z -and $null -ne $footDelta) { $lines[$z.i] = Add-ToValues $lines[$z.i] @(0) $footDelta }
            elseif ($z -and $shift -and -not $linked) { $lines[$z.i] = Add-ToValues $lines[$z.i] @(0) $shift }
            if ($retarget -and $s -eq $infos[0]) {
                $lc = Find-Key $lines $s "localcoord"
                $height = if ($lc) { [int](($lc.value -split ',')[1].Trim()) } else { 240 }
                $new = "localcoord = $charLocalcoord, $([math]::Round($height * $charLocalcoord / $oldWidth))"
                if ($lc) { $lines[$lc.i] = $new + " ;4x3 " + $lines[$lc.i].Trim() }
                else { $nl = if ($split.seps[$s.from]) { $split.seps[$s.from] } else { "`r`n" }; $lines[$s.from] += "$nl$new" }
            }
        } elseif ($s.name -match '^\[\s*bg(?!\s*def|\s*ctrl)') {
            $zd = Find-Key $lines $s "zoomdelta"; if ($zd) { $lines[$zd.i] = ($lines[$zd.i] -replace '=\s*[-\d.]+', '= 1') }
            # The 1995 layers are enlarged 5-20% to fill the widescreen frame. At a fractional scale the
            # doubled pixel columns move as the camera scrolls, so draw them 1:1.
            # Women's back wall (the 1.2 layers) is then shorter and narrower than the screen: it goes up under the
            # front, and scrolls slower so its edges stay off screen at the camera bounds.
            $wallLift = 0
            if ($retarget -and $name -like "1995-*") {
                $sc = Find-Key $lines $s "scalestart"
                if ($sc) {
                    $dl = Find-Key $lines $s "delta"
                    if ($name -eq "1995-women_team" -and $sc.value -match '^1\.2\b' -and $dl -and $dl.value -match '^\.65\s*,') {
                        $wallLift = 4
                        $lines[$dl.i] = "delta = .55,.8 ;4x3 " + $lines[$dl.i].Trim()
                    }
                    # Ikari's desert (240 lines, 1.1 from the top) then ends 30 lines short of the bottom, behind
                    # the gaps of the bridge. It goes down; the sky layer behind it stays.
                    if ($name -eq "1995-ikari_team" -and $dl -and $dl.value -match '^\.2857\s*,') { $wallLift = -30 }
                    $lines[$sc.i] = "scalestart = 1,1 ;4x3 " + $lines[$sc.i].Trim()
                }
            }
            $link = Find-Key $lines $s "positionlink"
            $bgShift = $shift - $wallLift
            # Some 1994 pictures sit a few pixels under the top of the screen. Lift only the picture.
            if ($retarget -and $artLift.ContainsKey($name)) { $bgShift -= $artLift[$name] }
            if ($retarget -and $frontDrop.ContainsKey($name)) {
                $ln = Find-Key $lines $s "layerno"
                if ($ln -and $ln.value -match '^1\b') { $bgShift += $frontDrop[$name] }
            }
            if (-not $bgShift -or ($link -and $link.value -match '^[-+]?0*[1-9]')) { continue }
            $st = Find-Key $lines $s "start"; if ($st) { $lines[$st.i] = Add-ToValues $lines[$st.i] @(1) $bgShift }
            foreach ($key in "window", "maskwindow") {
                $w = Find-Key $lines $s $key; if ($w) { $lines[$w.i] = Add-ToValues $lines[$w.i] @(1, 3) $bgShift }
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
    $list += (Join-Path $root "data\select.def"), (Join-Path $root "data\fight.sff")
    if (-not $ikemen) { $list += (Join-Path $root "data\mugen.cfg") }
    $list += Get-ChildItem -LiteralPath (Join-Path $root "data") -Filter *.def |
        Select-String -Pattern '^\s*\[SceneDef\]' -List | ForEach-Object { $_.Path }
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
    # modes are rendered at 960x720 and scaled down by the engine. Ikemen renders the video mode directly, which keeps
    # sprites sharp instead of filtering a 960x720 frame down.
    $renderW = if ($ikemen) { $Width } else { [math]::Max($Width, 960) }
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
            "data\system.def"  { Convert-MotifMugen $text; break }
            "data\select.def"  { Convert-SelectGrid $text; break }
            "data\fight.def"   { Convert-FightMugen $text; break }
            "data\fight.sff"   { Convert-FightSff $text; break }
            "data\common1.cns" { Convert-Common $text; break }
            "data\*.def"       {
                $board = if ($ikemen) { Add-StoryboardLocalcoord $text }
                if ($null -eq $board) { $board = Convert-NarrowStoryboard $text }
                if ($null -eq $board) { $board = Convert-Storyboard $text }
                if ($ikemen) {
                    $scaled = Add-StoryFontScale $(if ($board) { $board } else { $text })
                    if ($scaled) { $board = $scaled }
                }
                $board; break
            }
            "stages\*"         { Convert-Stage $text ([IO.Path]::GetFileNameWithoutExtension($rel)); break }
            "chars\*"          { Convert-CharFile $text; break }
        }
        if ($new -and $new -ne $text) { $changes[$path] = $new }
    }
    if ($ikemen) {
        # "\" and "S" both pointed at the USA thumbnail. The Mexico art sits 183 px further along, unmapped.
        $fontPath = Join-Path $root "font\stage.fnt"
        $font = Read-Text $fontPath
        $glyph = $font.Replace('\ 16465 185 ; 1994 Mexico', '\ 17607 185 ; 1994 Mexico')
        if ($glyph -eq $font) { throw "stage.fnt: miniatura do Mexico nao encontrada" }
        $changes[$fontPath] = $glyph
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
