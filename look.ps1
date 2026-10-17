# Lionel's Additions updater: the look. Dot-sourced by update.ps1 and travels in the zip with it (2026-10-16, Lionel:
# "add some cool ascii magic making the updater more stylized minecraft ascii art or something and some cool loading
# animations"; after the first try, a pixel-font title: "looks weird ... i was just thinking like a dirt block with some
# basic ascii art"). A grass block beside the name in plain ASCII letters, a yellow splash line, section marks,
# progress bars like the experience bar, downloads with speed, and an "Advancement Made!" toast at the end.
#
# Only a real console window gets it. With output redirected (test.ps1, a log) or LIONEL_UPDATER_PLAIN set, everything
# here prints plain ASCII or nothing, so the text players and tests read stays as it was. Windows Terminal (and any
# console that takes escape codes) gets Minecraft's own colours; an old console the nearest of its 16.
# This file is ASCII on purpose: Windows PowerShell 5.1 reads a file without a byte order mark as ANSI, so the block
# characters are made from their code points.

$LookFancy = -not $env:LIONEL_UPDATER_PLAIN -and -not [Console]::IsOutputRedirected
if ($LookFancy) { try { $LookFancy = [Console]::WindowWidth -ge 60 } catch { $LookFancy = $false } }
$Blk = @{ Full = [string][char]0x2588; Up = [string][char]0x2580; Down = [string][char]0x2584
          Light = [string][char]0x2591; Mid = [string][char]0x2592; Dark = [string][char]0x2593
          H = [string][char]0x2500; V = [string][char]0x2502; TL = [string][char]0x250C; TR = [string][char]0x2510
          BL = [string][char]0x2514; BR = [string][char]0x2518 }

$LookSplashes = @(
  'Now with Thaumcraft!', 'Also try Terraria!', 'Lionel approved!', 'Contains guns!', 'Pong on the loading screen!',
  'Bosses capped per hit!', "Don't dig straight down!", 'Glory kills!', 'Spore inside!', '540 mods and counting!',
  'Ask Lionel!', 'Gear Weakened II!', 'The Lost City awaits!', 'Free XP bar!', 'Now 100% more Lycanites!'
)

# Escape codes give true colours (Windows Terminal; consoles that take them); otherwise the 16 console colours.
$LookVT = $LookFancy -and [bool]$Host.UI.SupportsVirtualTerminal
$Esc = [char]27

# The side of a grass block, 8 by 8 as in Minecraft's texture: grass hanging over dirt. Keys are case-blind in a
# hashtable, so each shade has its own letter.
$LookBlock = 'GGHGGGHG', 'GHGGHGGG', 'DGDHDLGD', 'DDLDDEDD', 'DEDDDDLD', 'DDDEDDDD', 'LDDDDEDD', 'DDEDLDDE'
$LookRgb = @{ G = '121;192;90'; H = '89;145;55'; D = '134;96;67'; E = '104;74;50'; L = '158;118;84' }
$Look16 = @{ G = 'Green'; H = 'DarkGreen'; D = 'DarkYellow'; E = 'DarkYellow'; L = 'DarkYellow' }

# Text in one of the block's shades.
function Write-Shade([string]$text, [string]$shade, [switch]$NoNewline) {
  if ($LookVT) { Write-Host "$Esc[38;2;$($LookRgb[$shade])m$text$Esc[0m" -NoNewline:$NoNewline }
  else { Write-Host $text -ForegroundColor $Look16[$shade] -NoNewline:$NoNewline }
}

function Write-BlockRow([string]$row) {
  if ($LookVT) {
    $s = ''
    foreach ($c in $row.ToCharArray()) { $s += "$Esc[38;2;$($LookRgb[[string]$c])m" + $Blk.Full + $Blk.Full }
    Write-Host "$s$Esc[0m" -NoNewline
  } else {
    foreach ($c in $row.ToCharArray()) { Write-Host ($Blk.Full + $Blk.Full) -ForegroundColor $Look16[[string]$c] -NoNewline }
  }
}

# The name in figlet's "standard" and "small" fonts (made with pyfiglet).
$LookTitleBig = @(
  ' _     _                  _ _          _       _     _ _ _   _                 ',
  '| |   (_) ___  _ __   ___| ( )___     / \   __| | __| (_) |_(_) ___  _ __  ___ ',
  '| |   | |/ _ \| ''_ \ / _ \ |// __|   / _ \ / _` |/ _` | | __| |/ _ \| ''_ \/ __|',
  '| |___| | (_) | | | |  __/ | \__ \  / ___ \ (_| | (_| | | |_| | (_) | | | \__ \',
  '|_____|_|\___/|_| |_|\___|_| |___/ /_/   \_\__,_|\__,_|_|\__|_|\___/|_| |_|___/'
)
$LookTitleBigSplit = 35   # where "Additions" starts

$LookTitleSmall = @(
  ' _    _              _ _        _      _    _ _ _   _             ',
  '| |  (_)___ _ _  ___| ( )___   /_\  __| |__| (_) |_(_)___ _ _  ___',
  '| |__| / _ \ '' \/ -_) |/(_-<  / _ \/ _` / _` | |  _| / _ \ '' \(_-<',
  '|____|_\___/_||_\___|_| /__/ /_/ \_\__,_\__,_|_|\__|_\___/_||_/__/'
)
$LookTitleSmallSplit = 29   # where "Additions" starts

# The title screen: the grass block, the name beside it ("Lionel's" grass green, "Additions" white), what this is,
# and a splash typed out in yellow. A narrow window gets the small letters, a very narrow one no block.
function Show-Banner {
  if (-not $LookFancy) { Write-Host "Lionel's Additions updater"; return }
  try { Clear-Host } catch { }
  $width = [Console]::WindowWidth
  $rnd = New-Object Random
  if ($width -ge 100) { $title = $LookTitleBig; $split = $LookTitleBigSplit } else { $title = $LookTitleSmall; $split = $LookTitleSmallSplit }
  $block = $width -ge 2 + 16 + 3 + $title[0].Length + 1
  $sub = 'All the Mods 10  *  the updater for Lionel''s server'
  $splash = $LookSplashes[$rnd.Next($LookSplashes.Count)]
  $top = [Math]::Max(0, [int]((8 - $title.Count - 3) / 2))
  Write-Host ''
  for ($y = 0; $y -lt 8; $y++) {
    Write-Host '  ' -NoNewline
    if ($block) { Write-BlockRow $LookBlock[$y]; Write-Host '   ' -NoNewline }
    $t = $y - $top
    if ($t -ge 0 -and $t -lt $title.Count) {
      Write-Shade $title[$t].Substring(0, $split) 'G' -NoNewline
      Write-Host $title[$t].Substring($split) -ForegroundColor White
    } elseif ($t -eq $title.Count + 1) {
      Write-Host $sub -ForegroundColor DarkGray
    } elseif ($t -eq $title.Count + 2) {
      Write-Host (' ' * [Math]::Max(0, $title[0].Length - $splash.Length - 2)) -NoNewline
      foreach ($ch in $splash.ToCharArray()) { Write-Host $ch -ForegroundColor Yellow -NoNewline; Start-Sleep -Milliseconds 15 }
      Write-Host ''
    } else { Write-Host '' }
    Start-Sleep -Milliseconds 25
  }
  Write-Host ''
}

# A heading before each part of the run: a grass pixel, then the title.
function Write-Section([string]$title) {
  Clear-LookLine
  if (-not $LookFancy) { Write-Host "`n== $title =="; return }
  Write-Host "`n  " -NoNewline
  Write-BlockRow 'G'
  Write-Host " $title" -ForegroundColor White
}

# One file the update added (+), changed (~) or removed (-). Plain: exactly the line it always was.
function Write-Change([string]$sign, [string]$text) {
  Clear-LookLine
  if (-not $LookFancy) { Write-Host "  $sign $text"; return }
  $color = switch ($sign) { '+' { 'Green' } '~' { 'Yellow' } '-' { 'Red' } default { 'Gray' } }
  Write-Host "  $sign " -ForegroundColor $color -NoNewline
  Write-Host $text -ForegroundColor Gray
}

# The progress line, redrawn in place: a block being mined (the spinner), the label, an experience bar with its
# level-green percentage, and a detail. A fraction below 0 means "unknown": a short bar runs back and forth instead.
$LookBar = @{ Active = $false; Last = -1000; Frame = 0; Watch = [Diagnostics.Stopwatch]::StartNew() }
function Show-LookBar([string]$label, [double]$fraction, [string]$detail = '', [switch]$Force) {
  if (-not $LookFancy) { return }
  $now = $LookBar.Watch.ElapsedMilliseconds
  if (-not $Force -and $now - $LookBar.Last -lt 80) { return }
  $LookBar.Last = $now; $LookBar.Frame++
  $width = [Console]::WindowWidth
  $barW = [Math]::Max(10, [Math]::Min(32, $width - $label.Length - $detail.Length - 18))
  $mine = @(@($Blk.Light, 'DarkGray'), @($Blk.Mid, 'Gray'), @($Blk.Dark, 'Gray'), @($Blk.Full, 'White'), @('*', 'Yellow'))
  $f = $mine[[int]($LookBar.Frame / 2) % $mine.Count]
  $line = 4 + $label.Length + 1
  Write-Host "`r  " -NoNewline
  Write-Host $f[0] -ForegroundColor $f[1] -NoNewline
  Write-Host " $label " -ForegroundColor White -NoNewline
  if ($fraction -ge 0) {
    $fill = [int][Math]::Floor($barW * [Math]::Min(1, $fraction))
    Write-Host ($Blk.Full * $fill) -ForegroundColor Green -NoNewline
    Write-Host ($Blk.Light * ($barW - $fill)) -ForegroundColor DarkGray -NoNewline
    $pct = ' {0,3}%' -f [int][Math]::Floor(100 * [Math]::Min(1, $fraction))
    Write-Host $pct -ForegroundColor Green -NoNewline
    $line += $barW + $pct.Length
  } else {
    $run = 5; $span = $barW - $run; $p = $LookBar.Frame % (2 * $span); if ($p -gt $span) { $p = 2 * $span - $p }
    Write-Host ($Blk.Light * $p) -ForegroundColor DarkGray -NoNewline
    Write-Host ($Blk.Full * $run) -ForegroundColor Green -NoNewline
    Write-Host ($Blk.Light * ($barW - $run - $p)) -ForegroundColor DarkGray -NoNewline
    $line += $barW
  }
  if ($detail) { Write-Host "  $detail" -ForegroundColor DarkGray -NoNewline; $line += 2 + $detail.Length }
  if ($line -lt $width - 1) { Write-Host (' ' * ($width - 1 - $line)) -NoNewline }
  $LookBar.Active = $true
}

# Rubs the progress line out before anything else is printed.
function Clear-LookLine {
  if (-not $LookBar.Active) { return }
  Write-Host ("`r" + (' ' * ([Console]::WindowWidth - 1)) + "`r") -NoNewline
  $LookBar.Active = $false
}

# A download, with curl as always. In a console the bar shows how far, how big and how fast (read from the progress
# meter curl writes to its error output); otherwise curl's own output, as before. True when it succeeded.
function Invoke-Download([string]$url, [string]$file, [string]$label, [switch]$QuietPlain) {
  $curl = "$env:SystemRoot\System32\curl.exe"
  if (-not $LookFancy) {
    if ($QuietPlain) { & $curl -L --fail -s -o $file $url } else { & $curl -L --fail --progress-bar -o $file $url }
    return -not $LASTEXITCODE
  }
  $meter = "$file.meter"
  $p = Start-Process -FilePath $curl -ArgumentList "-L --fail -o `"$file`" `"$url`"" -NoNewWindow -PassThru -RedirectStandardError $meter
  $null = $p.Handle   # Windows PowerShell only keeps the exit code of a process whose handle was asked for
  $unit = { param($s) $s -replace 'k$', ' kB' -replace 'M$', ' MB' -replace 'G$', ' GB' }
  while (-not $p.HasExited) {
    $frac = -1; $detail = ''
    try {
      $fs = [IO.File]::Open($meter, 'Open', 'Read', 'ReadWrite')
      $n = [Math]::Min(400, $fs.Length); [void]$fs.Seek(-$n, 'End'); $buf = New-Object byte[] $n; [void]$fs.Read($buf, 0, $n); $fs.Close()
      foreach ($seg in @([Text.Encoding]::ASCII.GetString($buf) -split "[`r`n]" | Where-Object { $_.Trim() }) | Select-Object -Last 2) {
        $f = -split $seg
        if ($f.Count -ge 7 -and $f[0] -match '^\d+$' -and $f[1] -match '^[\d.]+[kMG]?$') {
          if ($f[1] -ne '0') { $frac = [int]$f[0] / 100; $detail = "$(& $unit $f[3]) of $(& $unit $f[1])  $(& $unit $f[6])/s" }
          else { $detail = "$(& $unit $f[3])  $(& $unit $f[6])/s" }
        }
      }
    } catch { }
    if (-not $detail -and (Test-Path -LiteralPath $file)) { $detail = '{0:N1} MB' -f ((Get-Item -LiteralPath $file).Length / 1MB) }
    Show-LookBar $label $frac $detail
    Start-Sleep -Milliseconds 100
  }
  $p.WaitForExit()
  $ok = $p.ExitCode -eq 0
  if ($ok) { Show-LookBar $label 1 'done' -Force; Start-Sleep -Milliseconds 250 }
  Clear-LookLine
  if ($ok) { Write-Host '  ' -NoNewline; Write-Host $Blk.Full -ForegroundColor Green -NoNewline; Write-Host " $label" -ForegroundColor Gray }
  Remove-Item -LiteralPath $meter -Force -ErrorAction SilentlyContinue
  $ok
}

# The end: Minecraft's advancement toast, with a grass block for its icon.
function Show-Toast([string]$title, [string]$text) {
  if (-not $LookFancy) { return }
  $inner = [Math]::Max($title.Length, $text.Length) + 9
  Write-Host ''
  Write-Host ('  ' + $Blk.TL + ($Blk.H * $inner) + $Blk.TR) -ForegroundColor Gray
  Write-Host ('  ' + $Blk.V + ' ') -ForegroundColor Gray -NoNewline
  Write-BlockRow 'GH' 
  Write-Host '  ' -NoNewline; Write-Host $title.PadRight($inner - 7) -ForegroundColor Yellow -NoNewline
  Write-Host $Blk.V -ForegroundColor Gray
  Write-Host ('  ' + $Blk.V + ' ') -ForegroundColor Gray -NoNewline
  Write-BlockRow 'DL' 
  Write-Host '  ' -NoNewline; Write-Host $text.PadRight($inner - 7) -ForegroundColor White -NoNewline
  Write-Host $Blk.V -ForegroundColor Gray
  Write-Host ('  ' + $Blk.BL + ($Blk.H * $inner) + $Blk.BR) -ForegroundColor Gray
}
