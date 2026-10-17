# Lionel's Additions updater: the logic. Travels inside the update zip, so it can change with every update.
# Run by "Update Lionel's Additions.bat" from the folder the zip was unpacked into. Works on Windows PowerShell 5.1.
#
# Layout next to this file:
#   overwrite\    files made to match exactly (mods, kubejs, resourcepacks, the title and loading screens under config\fancymenu)
#   if-missing\   files copied only when the player does not have them (config defaults)
#   delete.txt    pack files to remove, one relative path per line
#   version.txt   label shown to the player
param([string]$Target = $env:LIONEL_UPDATER_TARGET)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot

# The look (banner, section marks, progress bars, the toast at the end): look.ps1, beside this file in the zip.
. (Join-Path $src 'look.ps1')
Show-Banner

function Fail($message) { Clear-LookLine; Write-Host "`n$message" -ForegroundColor Red; exit 1 }

# Players' own settings. Never written, whatever the zip contains. Keybinds live in options.txt.
$protected = '^(options.*\.txt|servers\.dat.*|saves/|journeymap/|shaderpacks/|screenshots/|config/[^/]*keybind)'

# A relative path from the zip or a list file, checked before it is used against the player's folder.
function Resolve-Safe([string]$rel) {
  $rel = $rel.Trim().Replace('\', '/')
  if (-not $rel -or $rel -match '(^|/)\.\.(/|$)' -or $rel -match '^/' -or $rel -match ':') { throw "Unsafe path refused: $rel" }
  if ($rel -match $protected) { throw "Refusing to touch a player settings file: $rel" }
  if ($rel -match '\*.*/') { throw "A * may only stand in a file name: $rel" }
  if ($rel -match '^(mods|config|kubejs|resourcepacks|defaultconfigs|logs|crash-reports|\.)/*$') { throw "Refusing to act on a whole pack folder: $rel" }
  Join-Path $Target $rel.Replace('/', '\')
}

function Get-Files([string]$root) {
  if (-not (Test-Path -LiteralPath $root)) { return @() }
  $full = (Resolve-Path -LiteralPath $root).Path.TrimEnd('\')
  @(Get-ChildItem -LiteralPath $full -Recurse -File | ForEach-Object { $_.FullName.Substring($full.Length + 1).Replace('\', '/') })
}

function Same-File([string]$a, [string]$b) {
  (Get-Item -LiteralPath $a).Length -eq (Get-Item -LiteralPath $b).Length -and
    (Get-FileHash -LiteralPath $a -Algorithm SHA1).Hash -eq (Get-FileHash -LiteralPath $b -Algorithm SHA1).Hash
}

function Copy-To([string]$from, [string]$to) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
  Copy-Item -LiteralPath $from -Destination $to -Force
}

function Test-Pack([string]$p) {
  if (-not $p) { return $false }
  $bcc = Join-Path $p 'config\bcc-common.toml'
  (Test-Path -LiteralPath (Join-Path $p 'mods')) -and (Test-Path -LiteralPath $bcc) -and
    [bool](Select-String -LiteralPath $bcc -Pattern 'All the Mods 10' -Quiet)
}

# 1. Which launcher, update or fresh install, and which ATM10 folder (2026-10-16, Lionel: "have it prompt atlauncher or
#    modrinth, don't assume. then have it prompt either the update, or install the whole modpack entirely").
$stateDir = Join-Path $env:APPDATA 'lionels-updater'
$savedPath = Join-Path $stateDir 'path.txt'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$remembered = if (Test-Path -LiteralPath $savedPath) { (Get-Content -LiteralPath $savedPath -TotalCount 1).Trim() } else { '' }
# The whole pack for a fresh install: lionels-atm10-full.mrpack in Lionel's Drive folder (make_full_pack.py), a
# Modrinth pack file, which both launchers import. Empty id: a fresh install is not offered yet.
$fullPackId = '1WRkfq006ANIYAVzx9xawV1-zWi5Rv3H_'   # lionels-atm10-full.mrpack, shared "Anyone with the link" (2026-10-16)
$fullPackUrl = if ($env:LIONEL_UPDATER_FULL_URL -eq 'none') { '' } elseif ($env:LIONEL_UPDATER_FULL_URL) { $env:LIONEL_UPDATER_FULL_URL }   # test.ps1: none = not uploaded
  elseif ($fullPackId) { "https://drive.usercontent.google.com/download?id=$fullPackId&export=download&confirm=t" } else { '' }
# ATM10 instances in the usual launcher folders (2026-10-16, Lionel: "see if you can find the atlauncher or modrinth
# installation and find the profile that way"). Each launcher keeps its instances in one folder; Prism and MultiMC put
# the game one level down. The Modrinth app may live anywhere (Lionel's: D:\Games\Modrinth), and that folder is only
# written in its app.db, so drive paths are read out of that file's bytes and kept if they have a profiles folder.
function Find-Packs {
  $roots = New-Object System.Collections.ArrayList
  # Directory.Exists never throws (a mapped network drive that is gone answers false, not an error). Only local
  # fixed drives are looked at: a sleeping network drive could hold the search up for seconds.
  $local = @{}
  foreach ($di in [IO.DriveInfo]::GetDrives()) { if ($di.DriveType -eq 'Fixed') { $local[$di.Name.Substring(0, 1).ToUpper()] = $true } }
  $isDir = { param($dir) $dir -and $dir -match '^[A-Za-z]:\\' -and $local[$dir.Substring(0, 1).ToUpper()] -and [IO.Directory]::Exists($dir) }
  $add = { param($dir, $kind) if (& $isDir $dir) { [void]$roots.Add(@($dir, $kind)) } }
  foreach ($m in "$env:APPDATA\ModrinthApp", "$env:APPDATA\com.modrinth.theseus") { & $add "$m\profiles" 'Modrinth' }
  $probed = @{}
  foreach ($db in "$env:APPDATA\ModrinthApp\app.db", "$env:APPDATA\ModrinthApp\app.db-wal") {
    if (-not [IO.File]::Exists($db)) { continue }
    try { $text = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($db)) } catch { continue }
    foreach ($hit in [regex]::Matches($text, '[A-Za-z]:\\[^\x00-\x1f"<>|*?]{1,200}')) {
      $p = [regex]::Replace($hit.Value, '\\+', '\')   # JSON text in the file doubles its backslashes
      while ($p.Length -gt 3) {
        $key = $p.ToLowerInvariant()
        if ($probed[$key]) { break }
        $probed[$key] = $true
        if (& $isDir "$p\profiles") { & $add "$p\profiles" 'Modrinth'; break }
        $p = [IO.Path]::GetDirectoryName($p)
        if (-not $p) { break }
      }
    }
  }
  foreach ($a in "$env:APPDATA\ATLauncher", "$env:LOCALAPPDATA\Programs\ATLauncher", "$env:USERPROFILE\ATLauncher",
                 "$env:USERPROFILE\Documents\ATLauncher", "$env:USERPROFILE\Desktop\ATLauncher", "$env:USERPROFILE\Downloads\ATLauncher") {
    & $add "$a\instances" 'ATLauncher'
  }
  foreach ($c in "$env:USERPROFILE\curseforge\minecraft\Instances", "$env:USERPROFILE\Documents\curseforge\minecraft\Instances") { & $add $c 'CurseForge' }
  & $add "$env:APPDATA\PrismLauncher\instances" 'Prism'
  & $add "$env:APPDATA\gdlauncher_carbon\data\instances" 'GDLauncher'
  # test.ps1 sets LIONEL_UPDATER_NO_DRIVE_SCAN so a real pack on this PC is never offered to it
  $drives = if ($env:LIONEL_UPDATER_NO_DRIVE_SCAN) { @() } else { @(Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Z]:\\$' } | ForEach-Object { $_.Root }) }
  foreach ($d in $drives) {
    foreach ($sub in 'Games\Modrinth\profiles', 'Modrinth\profiles', 'Games\ATLauncher\instances', 'ATLauncher\instances',
                     'Games\curseforge\minecraft\Instances', 'curseforge\minecraft\Instances') {
      & $add (Join-Path $d $sub) ($(if ($sub -match 'Modrinth') { 'Modrinth' } elseif ($sub -match 'ATL') { 'ATLauncher' } else { 'CurseForge' }))
    }
  }
  $found = New-Object System.Collections.ArrayList
  $seen = @{}
  foreach ($r in $roots) {
    foreach ($inst in @(Get-ChildItem -LiteralPath $r[0] -Directory -ErrorAction SilentlyContinue)) {
      foreach ($p in $inst.FullName, "$($inst.FullName)\minecraft", "$($inst.FullName)\.minecraft", "$($inst.FullName)\instance") {
        $key = $p.ToLowerInvariant()
        if (-not $seen[$key] -and (Test-Pack $p)) { $seen[$key] = $true; [void]$found.Add(@($p, $r[1])) }
      }
    }
  }
  , $found
}

function Clean-Path([string]$p) { if (-not $p) { return '' }; $p.Trim().Trim('"').Trim().TrimEnd('\') }

# The instances Find-Packs found in the chosen launcher only.
function Find-LauncherPacks {
  $mine = New-Object System.Collections.ArrayList
  foreach ($p in (Find-Packs)) { if ($p[1] -eq $Launcher) { [void]$mine.Add($p) } }
  , $mine
}

# Asked every run; Enter repeats last time's answer. LIONEL_UPDATER_LAUNCHER and _MODE answer for test.ps1.
$launcherSeen = Join-Path $stateDir 'launcher.txt'
$lastLauncher = if (Test-Path -LiteralPath $launcherSeen) { (Get-Content -LiteralPath $launcherSeen -TotalCount 1).Trim() } else { '' }
$Launcher = $env:LIONEL_UPDATER_LAUNCHER
while ($Launcher -notin 'ATLauncher', 'Modrinth') {
  Write-Host "`nWhich launcher do you play ATM10 in?"
  Write-Host '  1) ATLauncher'
  Write-Host '  2) Modrinth app'
  $hint = if ($lastLauncher -in 'ATLauncher', 'Modrinth') { " (Enter: $lastLauncher, as last time)" } else { '' }
  Write-Host "Type 1 or 2 and press Enter$hint, or Q to stop: " -NoNewline
  $answer = Clean-Path ([Console]::ReadLine())
  if (-not $answer -and $hint) { $Launcher = $lastLauncher }
  elseif ($answer -eq '1') { $Launcher = 'ATLauncher' }
  elseif ($answer -eq '2') { $Launcher = 'Modrinth' }
  elseif (-not $answer -or $answer -ieq 'Q') { Fail 'No launcher chosen. Nothing was changed.' }
  else { Write-Host "'$answer' is not 1 or 2." -ForegroundColor Yellow }
}
Set-Content -LiteralPath $launcherSeen -Value $Launcher -Encoding UTF8

# 1a. The launcher itself, installed for the player when it is missing (2026-10-16, Lionel: "add an option to download
#     modrinth/atlauncher if not installed, include authentication login instructions"). Signing in cannot be done from
#     here: both launchers keep their own Microsoft sign-in, so the player is walked through it (Show-SignIn).
#     LIONEL_UPDATER_LAUNCHER_EXE (test.ps1) names the only place looked at.
$exeName = if ($Launcher -eq 'Modrinth') { 'Modrinth App.exe' } else { 'ATLauncher.exe' }
function Find-LauncherExe {
  if ($env:LIONEL_UPDATER_LAUNCHER_EXE) { if (Test-Path -LiteralPath $env:LIONEL_UPDATER_LAUNCHER_EXE) { return $env:LIONEL_UPDATER_LAUNCHER_EXE }; return '' }
  # Where each setup puts it (both install for the current user only), then the Windows list of installed programs.
  $dirs = if ($Launcher -eq 'Modrinth') { "$env:LOCALAPPDATA\Modrinth App", "$env:ProgramFiles\Modrinth App" }
          else { "$env:APPDATA\ATLauncher", "$env:LOCALAPPDATA\Programs\ATLauncher", "$env:USERPROFILE\ATLauncher",
                 "$env:USERPROFILE\Documents\ATLauncher", "$env:USERPROFILE\Desktop\ATLauncher", "$env:USERPROFILE\Downloads\ATLauncher" }
  foreach ($d in $dirs) { if ([IO.File]::Exists("$d\$exeName")) { return "$d\$exeName" } }
  $match = if ($Launcher -eq 'Modrinth') { '^Modrinth App' } else { '^ATLauncher' }
  foreach ($key in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                   'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') {
    foreach ($e in @(Get-ItemProperty -Path $key -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $match })) {
      $candidates = @()
      if ($e.InstallLocation) { $candidates += Join-Path $e.InstallLocation.Trim('"') $exeName }
      if ($e.DisplayIcon) { $candidates += ($e.DisplayIcon -replace ',\s*-?\d+$', '').Trim('"') }
      foreach ($c in $candidates) { if ($c -match '\.exe$' -and [IO.File]::Exists($c)) { return $c } }
    }
  }
  ''
}

function Test-LauncherRunning {
  $proc = if ($Launcher -eq 'Modrinth') { 'Modrinth App' } else { 'ATLauncher' }
  [bool](Get-Process -Name $proc -ErrorAction SilentlyContinue)
}

# Starts the launcher unless it is already open. LIONEL_UPDATER_NO_START (test.ps1): starts nothing.
function Start-Launcher([string]$exe) {
  if ($env:LIONEL_UPDATER_NO_START -or -not $exe -or (Test-LauncherRunning)) { return }
  try { Start-Process -FilePath $exe } catch { Write-Host "  (Could not start ${Launcher}: open it yourself.)" -ForegroundColor Yellow }
}

# Downloads the launcher's official Windows setup and runs it with its window showing; returns the installed exe.
function Install-Launcher {
  $work = Split-Path -Parent $src
  $setup = Join-Path $work "$Launcher-setup.exe"
  if ($Launcher -eq 'Modrinth') { $page = 'https://modrinth.com/app'; $size = 'about 25 MB' }
  else { $page = 'https://atlauncher.com/downloads'; $size = 'about 3 MB, plus the Java it installs' }
  $url = $env:LIONEL_UPDATER_LAUNCHER_INSTALLER_URL
  if (-not $url) {
    if ($Launcher -eq 'Modrinth') {
      # The app's own update list names the current setup.
      try { $url = @((Invoke-RestMethod -UseBasicParsing 'https://launcher-files.modrinth.com/updates.json').platforms.'windows-x86_64'.install_urls)[0] } catch { $url = '' }
    } else { $url = 'https://atlauncher.com/download/exe-setup' }   # the site's "Windows Setup (Recommended)"
  }
  $ok = $false
  if ($url) {
    Write-Host "`nDownloading $Launcher ($size)..."
    $ok = (Invoke-Download $url $setup "$Launcher setup") -and (Test-Path -LiteralPath $setup) -and (Get-Item -LiteralPath $setup).Length -gt 1MB
    if ($ok) { $head = New-Object byte[] 2; $fs = [IO.File]::OpenRead($setup); [void]$fs.Read($head, 0, 2); $fs.Close(); $ok = $head[0] -eq 0x4D -and $head[1] -eq 0x5A }
    # Modrinth signs its setup; ATLauncher does not (its site warns about SmartScreen), so it gets the checks above only.
    if ($ok -and $Launcher -eq 'Modrinth') {
      $sig = Get-AuthenticodeSignature -LiteralPath $setup
      $ok = $sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match 'O="?Rinth, Inc\.'
      if (-not $ok) { Write-Host 'The download is not signed by Modrinth, so it was not run.' -ForegroundColor Yellow }
    }
  }
  if ($ok) {
    Write-Host "`nThe $Launcher installer is opening. Click through it: the choices it offers are fine as they are." -ForegroundColor Cyan
    if ($Launcher -eq 'ATLauncher') { Write-Host '  If Windows says "Windows protected your PC": click "More info", then "Run anyway".' }
    Write-Host '  This window waits until the installer has finished.'
    if ($env:LIONEL_UPDATER_NO_START) {   # test.ps1: stands in for the installer, putting the exe where it is looked for
      Copy-To $setup $env:LIONEL_UPDATER_LAUNCHER_EXE
    } else {
      # Waits for the installer only: Start-Process -Wait would also wait for the launcher it may start at the end.
      try { (Start-Process -FilePath $setup -PassThru).WaitForExit() } catch { Write-Host "The installer did not start: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
  } else {
    Write-Host "`n$Launcher could not be downloaded here. Its download page is opening in your browser:" -ForegroundColor Yellow
    Write-Host "  $page"
    Write-Host '  Download the Windows version, run it, and come back here when it has finished.'
    if (-not $env:LIONEL_UPDATER_NO_START) { try { Start-Process $page } catch { } }
  }
  if (Test-Path -LiteralPath $setup) { Remove-Item -LiteralPath $setup -Force -ErrorAction SilentlyContinue }
  while (-not ($exe = Find-LauncherExe)) {
    Write-Host "`n$Launcher is not installed yet. Press Enter when its installer has finished, paste the folder you installed it in, or Q to stop: " -NoNewline
    $raw = [Console]::ReadLine()
    $answer = Clean-Path $raw
    if ($null -eq $raw -or $answer -ieq 'Q') { Fail "Stopped. Install $Launcher ($page), then run the updater again. Nothing was changed." }
    if ($answer -and [IO.File]::Exists("$answer\$exeName")) { return "$answer\$exeName" }
    if ($answer) { Write-Host "There is no $exeName in $answer" -ForegroundColor Yellow }
  }
  Write-Host "$Launcher is installed." -ForegroundColor Green
  $exe
}

# Signing in happens in the launcher (Microsoft's sign-in, opened by it). Shown before a fresh install's import.
function Show-SignIn([string]$exe) {
  Start-Launcher $exe
  Write-Host "`nSign in to Minecraft in $Launcher first (it is open, or opening):" -ForegroundColor Cyan
  if ($Launcher -eq 'ATLauncher') {
    Write-Host '  1. Click the "Accounts" tab on the right.'
    Write-Host '  2. Click "Login with Microsoft". A page opens in your web browser.'
    Write-Host '  3. Sign in there with the Microsoft account that owns Minecraft: Java Edition, then go back to ATLauncher.'
    Write-Host '  4. Your Minecraft name shows at the bottom right: done. (ATLauncher will not install a pack before this.)'
  } else {
    Write-Host '  1. Click the account button in the bottom left corner ("Sign in" / a player head), then "Add account" or "Sign in".'
    Write-Host '  2. Sign in in the window that opens, with the Microsoft account that owns Minecraft: Java Edition.'
    Write-Host '  3. Your Minecraft name shows there: done.'
    Write-Host '  A Modrinth account is something else: your Minecraft sign-in is not it, and Lionel''s pack does not need one.'
    Write-Host '  If the app offers to make or sign in to a Modrinth account, you can skip it.'
  }
  Write-Host "`nPress Enter here when you are signed in (or Q to stop): " -NoNewline
  if ((Clean-Path ([Console]::ReadLine())) -ieq 'Q') { Fail 'Stopped. Nothing was changed.' }
}

$launcherExe = Find-LauncherExe
$justInstalled = $false
while (-not $launcherExe) {
  Write-Host "`n$Launcher does not seem to be installed on this PC."
  Write-Host "  1) Install $Launcher now, then the whole pack in it"
  Write-Host "  2) It is installed, carry on"
  Write-Host 'Type 1 or 2 and press Enter, or Q to stop: ' -NoNewline
  $answer = Clean-Path ([Console]::ReadLine())
  if ($answer -eq '2') { break }
  elseif ($answer -eq '1') {
    # Without the whole pack there is nothing to put in a new launcher.
    if (-not $fullPackUrl) { Fail 'A fresh install is not available yet: Lionel has not uploaded the whole pack. Ask him. Nothing was changed.' }
    $launcherExe = Install-Launcher; $justInstalled = $true
  }
  elseif (-not $answer -or $answer -ieq 'Q') { Fail 'Stopped. Nothing was changed.' }
  else { Write-Host "'$answer' is not 1 or 2." -ForegroundColor Yellow }
}

$Mode = $env:LIONEL_UPDATER_MODE
if (-not $Mode -and $Target) { $Mode = 'update' }   # LIONEL_UPDATER_TARGET (test.ps1) names a pack to update
if ($justInstalled) { $Mode = 'fresh'; Write-Host "`n$Launcher is new on this PC, so the whole pack goes in it as a new instance." }
while ($Mode -notin 'update', 'fresh') {
  Write-Host "`nWhat would you like to do?"
  Write-Host "  1) Update the ATM10 you already have in $Launcher"
  Write-Host "  2) Install the whole pack fresh, as a new $Launcher instance (about 2.7 GB to download)"
  Write-Host 'Type 1 or 2 and press Enter (Enter alone: 1), or Q to stop: ' -NoNewline
  $answer = Clean-Path ([Console]::ReadLine())
  if (-not $answer -or $answer -eq '1') { $Mode = 'update' }
  elseif ($answer -eq '2') { $Mode = 'fresh' }
  elseif ($answer -ieq 'Q') { Fail 'Stopped. Nothing was changed.' }
  else { Write-Host "'$answer' is not 1 or 2." -ForegroundColor Yellow }
}

# A fresh install: the whole pack is downloaded, the player imports it into the launcher (neither launcher can be told
# to from outside), and the instance that appears is then updated and set up like any other.
function Install-Fresh {
  if (-not $fullPackUrl) { Fail 'A fresh install is not available yet: Lionel has not uploaded the whole pack. Ask him. Nothing was changed.' }
  $work = Split-Path -Parent $src
  $packFile = Join-Path $work 'Lionels-ATM10.mrpack'
  $free = (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $work).Path))).AvailableFreeSpace
  if ($free -lt 3500MB) { Fail ("Not enough free space for the whole pack in $work`: {0:N0} MB free, about 3,500 MB needed.`nFree some space and run the updater again. Nothing was changed." -f ($free / 1MB)) }
  Write-Host "`nDownloading the whole pack (about 2.7 GB; this takes a while)..."
  $ok = (Invoke-Download $fullPackUrl $packFile 'The whole pack') -and (Test-Path -LiteralPath $packFile)
  if ($ok) { $head = New-Object byte[] 2; $fs = [IO.File]::OpenRead($packFile); [void]$fs.Read($head, 0, 2); $fs.Close(); $ok = $head[0] -eq 0x50 -and $head[1] -eq 0x4B }
  if (-not $ok) { Fail 'The pack could not be downloaded. Check your internet connection and free space, and try again. Nothing was changed.' }
  $before = @{}
  foreach ($p in (Find-LauncherPacks)) { $before[$p[0].ToLowerInvariant()] = $true }
  Write-Host "`nDownloaded."
  Show-SignIn $launcherExe
  Write-Host "`nNow import it into $Launcher (the file's path is copied: you only paste it):" -ForegroundColor Cyan
  if ($Launcher -eq 'ATLauncher') {
    Write-Host '  1. Open ATLauncher.'
    Write-Host '  2. Go to its "Import" tab and click "Browse".'
    Write-Host '  3. Click in the "File name" box, press Ctrl+V, press Enter, then click "Import".'
    Write-Host '  4. Wait until ATLauncher has finished installing it (it downloads Minecraft and NeoForge too: a few minutes).'
  } else {
    Write-Host '  1. Open the Modrinth app.'
    Write-Host '  2. Click the + (Create new instance) on the left, then "From file".'
    Write-Host '  3. Choose the file: click in the "File name" box, press Ctrl+V, press Enter.'
    Write-Host '  4. Wait until the Modrinth app has finished installing it (a few minutes).'
  }
  Write-Host "  The file: $packFile"
  Write-Host '  Keep this window open meanwhile: the file is deleted when the updater finishes.'
  if (-not $env:LIONEL_UPDATER_NO_CLIPBOARD) { try { Set-Clipboard -Value $packFile } catch { } }
  while ($true) {
    Write-Host "`nWhen the import has finished, press Enter here (or paste the new instance's folder, or Q to stop): " -NoNewline
    $raw = [Console]::ReadLine()
    $answer = Clean-Path $raw
    if ($answer -ieq 'Q') { Fail 'Stopped. Your launcher may already have the new instance: run the updater again and choose Update for it.' }
    if ($env:LIONEL_UPDATER_IMPORT_TO) {   # test.ps1: does what the launcher's import does with the pack's files
      $tmp = Join-Path $work 'import-sim'
      [IO.Compression.ZipFile]::ExtractToDirectory($packFile, $tmp)
      New-Item -ItemType Directory -Force (Split-Path -Parent $env:LIONEL_UPDATER_IMPORT_TO) | Out-Null
      Move-Item -LiteralPath (Join-Path $tmp 'overrides') $env:LIONEL_UPDATER_IMPORT_TO
      Remove-Item -LiteralPath $tmp -Recurse -Force
    }
    if ($answer) {
      foreach ($p in $answer, "$answer\minecraft", "$answer\.minecraft") { if (Test-Pack $p) { return $p } }
      Write-Host "That folder is not an All the Mods 10 instance: $answer" -ForegroundColor Yellow
      continue
    }
    $new = New-Object System.Collections.ArrayList
    foreach ($p in (Find-LauncherPacks)) { if (-not $before[$p[0].ToLowerInvariant()]) { [void]$new.Add($p[0]) } }
    if ($new.Count -eq 1) { return $new[0] }
    if ($new.Count -gt 1) {
      for ($i = 0; $i -lt $new.Count; $i++) { Write-Host ('  {0}) {1}' -f ($i + 1), $new[$i]) }
      Write-Host 'More than one new ATM10 instance. Type the number of the one just imported: ' -NoNewline
      $n = Clean-Path ([Console]::ReadLine())
      if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $new.Count) { return $new[[int]$n - 1] }
      continue
    }
    if ($null -eq $raw) { Fail 'No new ATM10 instance found. Run the updater again once the import has finished, and choose Update.' }
    Write-Host "No new ATM10 instance in $Launcher yet. Is the import finished? If it is somewhere unusual, paste its folder." -ForegroundColor Yellow
  }
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
if ($Mode -eq 'fresh') { $Target = Install-Fresh }

if (-not (Test-Pack $Target)) {
  Write-Host "`nLooking for ATM10 in $Launcher..."
  $packs = Find-LauncherPacks
  # Last time's folder first, and Enter picks it (or the only one found).
  $default = ''
  for ($i = 0; $i -lt $packs.Count; $i++) {
    if ($remembered -and $packs[$i][0] -ieq $remembered) { $hit = $packs[$i]; $packs.RemoveAt($i); $packs.Insert(0, $hit); $default = $remembered; break }
  }
  if (-not $default -and $packs.Count -eq 1) { $default = $packs[0][0] }
}
while (-not (Test-Pack $Target)) {
  Write-Host ''
  if ($packs.Count) {
    Write-Host 'Which one is the ATM10 you play on Lionel''s server?'
    for ($i = 0; $i -lt $packs.Count; $i++) { Write-Host ('  {0}) {1}{2}' -f ($i + 1), $packs[$i][0], $(if ($packs[$i][0] -eq $default) { '   (Enter)' } else { '' })) }
  } else {
    Write-Host "No ATM10 instance found in $Launcher's usual folders."
  }
  Write-Host '  Or paste the folder''s path (the one containing "mods" and "config"), B to browse for it, Q to stop.'
  Write-Host 'Your choice: ' -NoNewline
  $answer = Clean-Path ([Console]::ReadLine())
  if (-not $answer -and $default) { $Target = $default; continue }
  if (-not $answer -or $answer -ieq 'Q') { Fail 'No folder chosen. Nothing was changed.' }
  if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $packs.Count) { $Target = $packs[[int]$answer - 1][0]; continue }
  if ($answer -ieq 'B') {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Choose your All the Mods 10 folder (the one containing "mods" and "config")'
    $dialog.ShowNewFolderButton = $false
    # Owned by an invisible always-on-top window: without an owner the picker can open behind this console window,
    # and the updater looks frozen (Lionel, 2026-10-16: "the updater gets cooked when I type in B for browse").
    $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false; Width = 0; Height = 0; StartPosition = 'CenterScreen' }
    Write-Host '  (A folder window opened. Pick the folder there and click OK.)'
    try { $picked = $dialog.ShowDialog($owner) } finally { $owner.Dispose() }
    if ($picked -eq 'OK') { $answer = $dialog.SelectedPath } else { continue }
  }
  if (Test-Pack $answer) { $Target = $answer }
  elseif (Test-Pack "$answer\minecraft") { $Target = "$answer\minecraft" }
  elseif (Test-Pack "$answer\.minecraft") { $Target = "$answer\.minecraft" }
  else { Write-Host "That folder is not an All the Mods 10 instance: $answer" -ForegroundColor Yellow }
}
$Target = $Target.TrimEnd('\')
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
Set-Content -LiteralPath $savedPath -Value $Target -Encoding UTF8

# A fresh install the .bat started without the update (2026-10-16, Lionel: "don't download the full update on the start,
# because what if a user wants to do the full modpack download?"): it fetched only this script and its small companions
# from GitHub. The whole pack says which update it already holds (lionels-updater-pack-version.txt, written by
# make_full_pack.py only when every file of that update is in it): the latest, and nothing more is downloaded; older or
# unknown, and the update zip is fetched now and applied as usual.
$haveFiles = Test-Path -LiteralPath "$src\overwrite"
if (-not $haveFiles -and $env:LIONEL_UPDATER_LATER_ZIP) {
  $work = Split-Path -Parent $src
  $latestFile = Join-Path $src 'version.txt'
  & "$env:SystemRoot\System32\curl.exe" -L --fail -s -o $latestFile $env:LIONEL_UPDATER_LATER_VERSION
  $latest = if (-not $LASTEXITCODE -and (Test-Path -LiteralPath $latestFile)) { (Get-Content -LiteralPath $latestFile -TotalCount 1).Trim() } else { '' }
  $packMark = Join-Path $Target 'lionels-updater-pack-version.txt'
  $inPack = if (Test-Path -LiteralPath $packMark) { (Get-Content -LiteralPath $packMark -TotalCount 1).Trim() } else { '' }
  if ($latest -and $inPack -eq $latest) {
    Write-Host "`nThe whole pack already has the latest update ($latest): nothing more to download."
  } else {
    if (Test-Path -LiteralPath $latestFile) { Remove-Item -LiteralPath $latestFile -Force }   # the zip brings its own
    Write-Host "`nThe whole pack is older than the latest update, so the update comes too (about 800 MB)..."
    $zipFile = Join-Path $work 'update.zip'
    $unpacked = Join-Path $work 'update'
    $ok = Invoke-Download $env:LIONEL_UPDATER_LATER_ZIP $zipFile 'The latest update'
    if ($ok) {
      New-Item -ItemType Directory -Force -Path $unpacked | Out-Null
      & "$env:SystemRoot\System32\tar.exe" -xf $zipFile -C $unpacked 2>$null
      $ok = -not $LASTEXITCODE -and (Test-Path -LiteralPath "$unpacked\overwrite")
    }
    if (Test-Path -LiteralPath $zipFile) { Remove-Item -LiteralPath $zipFile -Force }
    if (-not $ok) { Fail "The new instance is there, but the latest update could not be downloaded.`nRun the updater again and choose Update for it." }
    $src = $unpacked
    $haveFiles = $true
  }
}

$label = if (Test-Path -LiteralPath "$src\version.txt") { (Get-Content -LiteralPath "$src\version.txt" -TotalCount 1).Trim() } else { 'unknown' }
Write-Section "Lionel's Additions, update $label"
Write-Host "  Folder: $Target`n"
$packVersion = (Select-String -LiteralPath (Join-Path $Target 'config\bcc-common.toml') -Pattern 'modpackVersion\s*=\s*"([^"]+)"').Matches.Groups[1].Value
if ($packVersion -ne '8.1') { Write-Host "Note: this is ATM10 version $packVersion. These files were made for 8.1.`n" -ForegroundColor Yellow }

# 2. The game holds its mod files open. Updating underneath it would leave a half-changed pack.
foreach ($jar in @(Get-ChildItem -LiteralPath (Join-Path $Target 'mods') -Filter *.jar -File)) {
  try { $jar.Open('Open', 'ReadWrite', 'None').Close() }
  catch { Fail 'Minecraft looks like it is running from this folder. Close the game and run the updater again. Nothing was changed.' }
}

# Check every path this update names before changing anything, so a bad update changes nothing at all.
$recordPath = Join-Path $Target 'lionels-updater-installed.txt'
$named = @(Get-Files "$src\overwrite") + @(Get-Files "$src\if-missing")
foreach ($list in "$src\delete.txt", $recordPath) {
  if (Test-Path -LiteralPath $list) { $named += @(Get-Content -LiteralPath $list | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' }) }
}
try { foreach ($rel in $named) { Resolve-Safe $rel | Out-Null } } catch { Fail "$($_.Exception.Message)`nThis update is faulty. Nothing was changed. Tell Lionel." }

# Room on the ATM10 drive for what this update copies (a size that differs means a copy; 200 MB to spare).
$needBytes = 0
foreach ($set in 'overwrite', 'if-missing') {
  foreach ($rel in (Get-Files "$src\$set")) {
    $from = Get-Item -LiteralPath (Join-Path "$src\$set" $rel)
    $dest = Join-Path $Target $rel.Replace('/', '\')
    if (-not (Test-Path -LiteralPath $dest)) { $needBytes += $from.Length }
    elseif ($set -eq 'overwrite') { $needBytes += [math]::Max(0, $from.Length - (Get-Item -LiteralPath $dest).Length) }
  }
}
$needBytes += 200MB
$freeBytes = (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $Target).Path))).AvailableFreeSpace
if ($env:LIONEL_UPDATER_FREE_MB) { $freeBytes = [int64]$env:LIONEL_UPDATER_FREE_MB * 1MB }
if ($freeBytes -lt $needBytes) {
  Fail ("Not enough free space on the drive of your ATM10 folder: {0:N0} MB free, about {1:N0} MB needed.`nFree some space there and run the updater again. Nothing was changed." -f ($freeBytes / 1MB), ($needBytes / 1MB))
}

$added = 0; $updated = 0; $removed = 0; $unchanged = 0

# 3. Overwrite set: make these files match the zip.
Write-Section 'Mods, scripts and resource packs'
$installed = Get-Files "$src\overwrite"
$i = 0
foreach ($rel in $installed) {
  Show-LookBar 'Checking files' ($i++ / [Math]::Max(1, $installed.Count)) "$i of $($installed.Count)"
  $dest = Resolve-Safe $rel
  $from = Join-Path "$src\overwrite" $rel
  if (-not (Test-Path -LiteralPath $dest)) { Copy-To $from $dest; $added++; Write-Change '+' $rel }
  elseif (-not (Same-File $from $dest)) { Copy-To $from $dest; $updated++; Write-Change '~' $rel }
  else { $unchanged++ }
}
Clear-LookLine

# 4. Files an earlier update installed that are no longer part of it (an old version of a mod, for instance).
#    Only with the update's files at hand: without them every listed file would look gone from the update.
if ($haveFiles) {
  if (Test-Path -LiteralPath $recordPath) {
    foreach ($rel in @(Get-Content -LiteralPath $recordPath | Where-Object { $_.Trim() -and $installed -notcontains $_.Trim() })) {
      $old = Resolve-Safe $rel
      if (Test-Path -LiteralPath $old -PathType Leaf) { Remove-Item -LiteralPath $old -Force; $removed++; Write-Change '-' $rel }
    }
  }
  Set-Content -LiteralPath $recordPath -Value $installed -Encoding UTF8
}

# 3b. Another version of a mod this update installs (2026-10-16, Lionel: "on my old stale profile, i have Voxy and an
#     outdated CC:Tweaked"). Two jars with one mod id stop the game, and delete.txt can only name versions known
#     today. Any jar in mods\ that this update did not install but that declares a mod id one of its jars declares
#     is moved to the backup folder, whatever its file name.
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Get-ModIds([string]$jar) {
  $ids = @()
  try {
    $z = [IO.Compression.ZipFile]::OpenRead($jar)
    try {
      foreach ($name in 'META-INF/neoforge.mods.toml', 'META-INF/mods.toml') {
        $e = $z.GetEntry($name)
        if (-not $e) { continue }
        $r = New-Object IO.StreamReader($e.Open())
        $inMods = $false
        foreach ($line in ($r.ReadToEnd() -split "`n")) {
          if ($line -match '^\s*\[\[\s*mods\s*\]\]') { $inMods = $true; continue }
          if ($line -match '^\s*\[') { $inMods = $false; continue }
          if ($inMods -and $line -match '^\s*modId\s*=\s*"([^"]+)"') { $ids += $Matches[1]; $inMods = $false }
        }
        $r.Close()
        break
      }
    } finally { $z.Dispose() }
  } catch { }
  $ids
}
$shippedIds = @{}
$shippedJars = @{}
if (Test-Path -LiteralPath "$src\overwrite\mods") {
  foreach ($j in @(Get-ChildItem -LiteralPath "$src\overwrite\mods" -Filter *.jar -File)) {
    $shippedJars[$j.Name.ToLowerInvariant()] = $true
    foreach ($id in (Get-ModIds $j.FullName)) { $shippedIds[$id] = $j.Name }
  }
}
if ($shippedIds.Count) {
  $jars = @(Get-ChildItem -LiteralPath (Join-Path $Target 'mods') -Filter *.jar -File)
  $i = 0
  foreach ($j in $jars) {
    Show-LookBar 'Looking for old versions of the same mods' ($i++ / [Math]::Max(1, $jars.Count)) "$i of $($jars.Count)"
    if ($shippedJars[$j.Name.ToLowerInvariant()]) { continue }
    $clash = @(Get-ModIds $j.FullName | Where-Object { $shippedIds.ContainsKey($_) })
    if (-not $clash.Count) { continue }
    $backup = Join-Path (Join-Path $Target 'lionels-updater-backup') "mods\$($j.Name)"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
    Move-Item -LiteralPath $j.FullName -Destination $backup -Force
    $removed++; Write-Change '-' "mods/$($j.Name)  (another version of $($shippedIds[$clash[0]]); kept in lionels-updater-backup)"
  }
  Clear-LookLine
}

# 5. Pack files this update removes. Moved to a backup folder, not erased. A * in the last part of a line matches any
#    characters (mods/voxy-*.jar: every Voxy version).
if (Test-Path -LiteralPath "$src\delete.txt") {
  $expanded = @()
  foreach ($line in @(Get-Content -LiteralPath "$src\delete.txt" | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' })) {
    $r = $line.Trim().Replace('\', '/')
    if (-not $r.Contains('*')) { $expanded += $r; continue }
    $dir = $r.Substring(0, $r.LastIndexOf('/') + 1)
    $parent = if ($dir) { Join-Path $Target $dir.TrimEnd('/').Replace('/', '\') } else { $Target }
    if (Test-Path -LiteralPath $parent -PathType Container) {
      foreach ($f in @(Get-ChildItem -LiteralPath $parent -File | Where-Object { $_.Name -like $r.Substring($dir.Length) })) { $expanded += $dir + $f.Name }
    }
  }
  foreach ($rel in $expanded) {
    $victim = Resolve-Safe $rel
    if ($rel.Trim() -match '[\\/]$') {
      # A line ending in / names a whole folder (a removed mod's download cache, say). Deleted, not backed up.
      if (Test-Path -LiteralPath $victim -PathType Container) {
        Remove-Item -LiteralPath $victim -Recurse -Force
        $removed++; Write-Change '-' "$($rel.Trim())  (folder)"
      }
    }
    elseif (Test-Path -LiteralPath $victim -PathType Leaf) {
      $backup = Join-Path (Join-Path $Target 'lionels-updater-backup') $rel.Trim().Replace('/', '\')
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
      Move-Item -LiteralPath $victim -Destination $backup -Force
      $removed++; Write-Change '-' "$($rel.Trim())  (kept in lionels-updater-backup)"
    }
  }
}

# 6. Defaults: only where the player has no file of their own.
Write-Section 'Settings'
foreach ($rel in (Get-Files "$src\if-missing")) {
  $dest = Resolve-Safe $rel
  if (-not (Test-Path -LiteralPath $dest)) { Copy-To (Join-Path "$src\if-missing" $rel) $dest; $added++; Write-Change '+' $rel }
}

# 7. The Shooting Star font pack has to be switched on. This adds that one entry to the resource pack list in
#    options.txt and changes nothing else in the file. The last entry in the list has the highest priority.
$options = Join-Path $Target 'options.txt'
$pack = 'file/lionel-shooting-star-fonts'
if ((Test-Path -LiteralPath $options) -and (Test-Path -LiteralPath (Join-Path $Target 'resourcepacks\lionel-shooting-star-fonts'))) {
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $text = [IO.File]::ReadAllText($options, $utf8)
  $line = [regex]::Match($text, '(?m)^resourcePacks:\[(.*?)\](?=\r?$)')
  if ($line.Success -and $line.Value -notmatch [regex]::Escape("`"$pack`"")) {
    if (-not (Test-Path -LiteralPath "$options.bak-lionel")) { Copy-Item -LiteralPath $options -Destination "$options.bak-lionel" }
    $list = $line.Groups[1].Value
    $newLine = 'resourcePacks:[' + $list + $(if ($list) { ',' }) + "`"$pack`"]"
    [IO.File]::WriteAllText($options, $text.Remove($line.Index, $line.Length).Insert($line.Index, $newLine), $utf8)
    Write-Change '~' 'options.txt: switched on the Shooting Star font pack (your other settings are untouched)'
  }
}

# 8. WaterFrames needs WaterMedia 2.1, and FancyMenu refuses to start beside any WaterMedia older than 3.0.
#    The pack's own remedy is a dependency override in config\fml.toml. Without this line the game will not
#    start once WaterMedia is installed, so it is added here: one line, nothing else in the file changes.
$fml = Join-Path $Target 'config\fml.toml'
if ((Test-Path -LiteralPath $fml) -and @(Get-ChildItem -LiteralPath (Join-Path $Target 'mods') -Filter 'watermedia-2.*.jar').Count) {
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $text = [IO.File]::ReadAllText($fml, $utf8)
  if ($text -notmatch '(?m)^\s*fancymenu\s*=') {
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $override = "`tfancymenu = [`"-watermedia`"]"
    $section = [regex]::Match($text, '(?m)^\[dependencyOverrides\][^\r\n]*\r?\n?')
    if (-not (Test-Path -LiteralPath "$fml.bak-lionel")) { Copy-Item -LiteralPath $fml -Destination "$fml.bak-lionel" }
    if ($section.Success) {
      $insert = $section.Value.TrimEnd("`r", "`n") + $nl + $override + $nl
      $text = $text.Remove($section.Index, $section.Length).Insert($section.Index, $insert)
    }
    else { $text = $text.TrimEnd("`r", "`n") + $nl + '[dependencyOverrides]' + $nl + $override + $nl }
    [IO.File]::WriteAllText($fml, $text, $utf8)
    Write-Change '~' 'config\fml.toml: allowed FancyMenu to run beside WaterMedia 2 (one line added)'
  }
}

# 9. JEI indexed every item's tooltip on each world join (25 of its 40 seconds) and again after each F3+T.
#    This switches that one search mode off, once, and only from the pack's default: the backup is the marker,
#    so a player who chose another value, or turns it back on afterwards, keeps their choice.
$jei = Join-Path $Target 'config\jei\jei-client.ini'
if ((Test-Path -LiteralPath $jei) -and -not (Test-Path -LiteralPath "$jei.bak-lionel")) {
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $text = [IO.File]::ReadAllText($jei, $utf8)
  $line = [regex]::Match($text, '(?m)^(\s*tooltipSearchMode\s*=\s*)ENABLED(?=\r?$)')
  if ($line.Success) {
    Copy-Item -LiteralPath $jei -Destination "$jei.bak-lionel"
    [IO.File]::WriteAllText($jei, $text.Remove($line.Index, $line.Length).Insert($line.Index, $line.Groups[1].Value + 'DISABLED'), $utf8)
    Write-Change '~' 'config\jei\jei-client.ini: tooltip search ($) switched off, so joining a world no longer freezes (one line; JEI''s settings turn it back on)'
  }
}

# 10, 11. The same kind of edit for two more files: each pattern's first group is kept and what follows it is
#    replaced, once, and only from the pack's default. The backup is the marker again, so whatever the player
#    sets afterwards stays.
function Edit-Once([string]$rel, [object[]]$edits, [string]$said) {
  $file = Join-Path $Target $rel
  if (-not (Test-Path -LiteralPath $file) -or (Test-Path -LiteralPath "$file.bak-lionel")) { return }
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $before = [IO.File]::ReadAllText($file, $utf8)
  $text = $before
  foreach ($edit in $edits) {
    $line = [regex]::Match($text, $edit[0])
    if ($line.Success) { $text = $text.Remove($line.Index, $line.Length).Insert($line.Index, $line.Groups[1].Value + $edit[1]) }
  }
  if ($text -cne $before) {
    Copy-Item -LiteralPath $file -Destination "$file.bak-lionel"
    [IO.File]::WriteAllText($file, $text, $utf8)
    Write-Change '~' "$rel`: $said"
  }
}
# 10. The title screen plays the Aether's menu theme (it is in the layout this update installs); the game's own
#     menu music would play over it. And the window gets the pack's name, where the player has set none.
Edit-Once 'config\fancymenu\options.txt' @(
  @('(?m)^(B:play_vanilla_menu_music = )''true'';(?=\r?$)', "'false';"),
  @('(?m)^(S:custom_window_title = )'''';(?=\r?$)', "'ATM10: Lionels Additions';")
) 'the title screen has its own music now, so the game''s menu music is off (two lines; FancyMenu''s settings change it back)'
# 11. Crash Assistant counts mods added to ATM10 and, from five, tells the player they changed too much and get
#     no support. This pack adds far more than five on purpose. A negative count switches that warning off.
Edit-Once 'config\crash_assistant\config.toml' @(
  , @('(?ms)^(\[too_many_changes_warning\]\r?\n(?:[ \t]*#[^\n]*\n)*[ \t]*count = )5(?=\r?$)', '-1')
) 'the "too many changes" warning is off: this pack adds its mods on purpose (one line)'
# 11a. Lionel's Pong on the loading screen (lionel-pong, 2026-10-16: "lionel pong was missing"). The jar does nothing
#      until config\fml.toml names it as the loading window. Switched once, only from the pack's default and only with
#      the jar installed; config\fml.toml.bak-lionel-pong is the marker (fml.toml.bak-lionel belongs to step 8), so a
#      player who sets "fmlearlywindow" back keeps it.
$pongMark = "$fml.bak-lionel-pong"
if ((Test-Path -LiteralPath $fml) -and -not (Test-Path -LiteralPath $pongMark) -and
    @(Get-ChildItem -LiteralPath (Join-Path $Target 'mods') -Filter 'lionel-pong-*.jar').Count) {
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $text = [IO.File]::ReadAllText($fml, $utf8)
  $line = [regex]::Match($text, '(?m)^(earlyWindowProvider\s*=\s*)"fmlearlywindow"')
  if ($line.Success) {
    Copy-Item -LiteralPath $fml -Destination $pongMark
    $text = $text.Remove($line.Index, $line.Length).Insert($line.Index, $line.Groups[1].Value + '"lionelpong"')
    [IO.File]::WriteAllText($fml, $text, $utf8)
    Write-Change '~' 'config\fml.toml: the loading screen plays Pong (earlyWindowProvider = "lionelpong")'
  }
}

# 11b. TaCZ writes "[O] to interact" in the middle of the screen whenever a gun is held and the crosshair is on
#      something usable. The O key keeps working; only the text goes.
Edit-Once 'config\tacz-client.toml' @(
  , @('(?m)^([ \t]*DisableInteractHudText = )false(?=\r?$)', 'true')
) 'TaCZ''s "[O] to interact" text is off; the key still works (one line)'
# 11d. Not Enough Animations spreads the player's arms while gliding with an Elytra; with a TaCZ gun out that drew a
#      second pair of arms in first person beside the ones on the gun (Lionel, 2026-10-16: "just turn it off").
Edit-Once 'config\notenoughanimations.json' @(
  , @('("tweakElytraAnimation"\s*:\s*)true', 'false')
) 'Not Enough Animations'' Elytra arm pose is off: it doubled the arms on a gun while gliding (one line)'
# 11c. lionel-turbo reads a missing switch as off, and config\lionel-turbo.properties is if-missing, so a player who
#      already has the file would never get a switch added later (2026-10-09: megaCellsCompressionIndex,
#      punchyMappedBonesOnly). Each switch of the shipped file that the player's file does not mention at all is
#      appended with its comment line. A switch the player has, on or off, is never touched.
$turboRel = 'config\lionel-turbo.properties'
$turboShipped = Join-Path $src "if-missing\$turboRel"
$turboFile = Join-Path $Target $turboRel
if ((Test-Path -LiteralPath $turboShipped) -and (Test-Path -LiteralPath $turboFile)) {
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $mine = [IO.File]::ReadAllText($turboFile, $utf8)
  $shippedLines = [IO.File]::ReadAllLines($turboShipped, $utf8)
  $append = ''
  $names = @()
  for ($i = 0; $i -lt $shippedLines.Length; $i++) {
    $m = [regex]::Match($shippedLines[$i], '^([A-Za-z0-9_]+)=')
    if (-not $m.Success) { continue }
    $key = $m.Groups[1].Value
    if ([regex]::IsMatch($mine, '(?m)^[ \t]*' + [regex]::Escape($key) + '[ \t]*=')) { continue }
    $comment = ''
    if ($i -gt 0 -and $shippedLines[$i - 1].StartsWith('#')) { $comment = $shippedLines[$i - 1] + "`n" }
    $append += "`n" + $comment + $shippedLines[$i] + "`n"
    $names += $key
  }
  if ($names.Count -gt 0) {
    if ($mine.Length -gt 0 -and -not $mine.EndsWith("`n")) { $append = "`n" + $append }
    [IO.File]::WriteAllText($turboFile, $mine + $append, $utf8)
    Write-Change '~' "$turboRel`: new speed-up switches added: $($names -join ', ') (your other switches unchanged)"
  }
}

# 12. Speed setup, the same as Lionel's (2026-10-16, Lionel: "make sure their optimization setup matches mine (JVM
#     arguments, and whatever other magic is done) give clear instructions"). Three parts: Java 21.0.12.1 of the
#     updater's own (Azul Zulu, 47 MB, once), because the resolver patch (70 s of module resolving down to under one) is
#     one class of exactly that Java; Lionel's Java arguments with the patch; the memory preset. ATLauncher keeps these
#     in the instance's instance.json, which this writes (ATLauncher closed, or it writes its own copy back); the Modrinth
#     app keeps them in its database, so its player is walked through three pastes. Java and patch go in a folder whose
#     path has no spaces: launchers split the Java arguments at spaces.
Write-Section 'Speed setup'
$toolDir = $stateDir
if ($toolDir -match '\s') { $toolDir = Join-Path $env:PUBLIC 'lionels-updater' }
New-Item -ItemType Directory -Force -Path $toolDir | Out-Null
$javaName = 'zulu21.52.203-ca-jre21.0.12.1-win_x64'
$javaHome = Join-Path $toolDir $javaName
$javaUrl = if ($env:LIONEL_UPDATER_JAVA_URL) { $env:LIONEL_UPDATER_JAVA_URL } else { "https://cdn.azul.com/zulu/bin/$javaName.zip" }
function Test-Java {
  $rel = Join-Path $javaHome 'release'
  (Test-Path -LiteralPath (Join-Path $javaHome 'bin\javaw.exe')) -and (Test-Path -LiteralPath $rel) -and
    [bool](Select-String -LiteralPath $rel -Pattern '^JAVA_VERSION="21\.0\.12\.1"' -Quiet)
}
if (-not (Test-Java) -and $javaUrl -ne 'none') {
  Write-Host "`nDownloading Java 21.0.12.1 for the faster start (about 50 MB, once)..."
  $javaZip = Join-Path $toolDir 'java.zip.part'
  if (Invoke-Download $javaUrl $javaZip 'Java 21.0.12.1' -QuietPlain) {
    if (Test-Path -LiteralPath $javaHome) { Remove-Item -LiteralPath $javaHome -Recurse -Force }
    & "$env:SystemRoot\System32\tar.exe" -xf $javaZip -C $toolDir
  }
  if (Test-Path -LiteralPath $javaZip) { Remove-Item -LiteralPath $javaZip -Force }
  if (-not (Test-Java)) { Write-Host '  Could not get it. The game still starts, about a minute slower; run the updater again later to retry.' -ForegroundColor Yellow }
}
$javaOk = Test-Java
$patchFrom = Join-Path $src 'java\resolver-patch.jar'
$patchArg = ''
if ($javaOk -and (Test-Path -LiteralPath $patchFrom)) {
  $patchTo = Join-Path $toolDir 'resolver-patch.jar'
  if (-not (Test-Path -LiteralPath $patchTo) -or -not (Same-File $patchFrom $patchTo)) { Copy-To $patchFrom $patchTo }
  if ($patchTo -notmatch '\s') { $patchArg = " --patch-module=java.base=$patchTo" }
}
$ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
if ($env:LIONEL_UPDATER_RAM_GB) { $ramGb = [int]$env:LIONEL_UPDATER_RAM_GB }
# Memory preset (2026-10-16, Lionel: "presets like 8, 12, 16 and have the launch options reflect the user choice"):
# asked on every run, Enter keeps the last choice (first time: the one that suits this PC's RAM).
$memSeen = Join-Path $stateDir 'memory.txt'
$memGb = if ($ramGb -ge 30) { 16 } elseif ($ramGb -ge 20) { 12 } else { 8 }
$memWhy = 'suits this PC'
if (Test-Path -LiteralPath $memSeen) {
  $last = (Get-Content -LiteralPath $memSeen -TotalCount 1).Trim()
  if ($last -in '8', '12', '16') { $memGb = [int]$last; $memWhy = 'your last choice' }
}
Write-Host "`nMemory for Minecraft: $memGb GB ($memWhy; this PC has $ramGb GB of RAM)."
Write-Host '  Press Enter to keep it, or type 8, 12 or 16 and press Enter: ' -NoNewline
$pick = if ($env:LIONEL_UPDATER_MEMORY) { $env:LIONEL_UPDATER_MEMORY } else { [Console]::ReadLine() }
Write-Host ''
if ($pick) { $pick = $pick.Trim().ToUpper().TrimEnd('B').TrimEnd('G').Trim() }
if ($pick -in '8', '12', '16') { $memGb = [int]$pick }
elseif ($pick) { Write-Host "  '$pick' is not 8, 12 or 16: keeping $memGb GB." -ForegroundColor Yellow }
if ($memGb -gt $ramGb - 6) { Write-Host "  Warning: $memGb GB leaves Windows less than 6 GB of this PC's $ramGb GB. Pick a smaller preset if the PC slows down." -ForegroundColor Yellow }
Set-Content -LiteralPath $memSeen -Value $memGb -Encoding UTF8
$memMb = $memGb * 1024
# 12 and 16 GB: Lionel's own line (generational ZGC). 8 GB: ZGC needs room to spare, so the G1 flags most packs use.
$gc = if ($memGb -ge 12) { ' -XX:+UseZGC -XX:+ZGenerational' }
  else { ' -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40' +
         ' -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4' +
         ' -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:SurvivorRatio=32 -XX:MaxTenuringThreshold=1' }
# ATLauncher sets -Xmx from its memory setting, so its line starts after it.
$argRest = "-XX:+UnlockExperimentalVMOptions$gc -XX:+DisableExplicitGC -XX:+PerfDisableSharedMem" +
  ' -XX:+UseFastUnorderedTimeStamps -Dfml.readTimeout=180 -Dfml.loginTimeout=180' + $patchArg +
  ' -XX:+UnlockDiagnosticVMOptions -XX:-BytecodeVerificationRemote'
$argLine = "-Xmx${memGb}G $argRest"
$javaExe = Join-Path $javaHome 'bin\javaw.exe'
$javaNote = if ($javaOk) { "Java: $javaExe (Java 21.0.12.1, which the patch needs)." }
  else { 'Java: the launcher''s own (Java 21.0.12.1 could not be downloaded, so the resolver patch is left out: about a minute slower).' }
$argText = @"
Lionel's Additions: speed setup (fastest start, the same as Lionel's). Written by the updater; run it again to redo it.

ATLAUNCHER: the updater writes these into the instance itself (ATLauncher must be closed while it runs). By hand:
  Instances tab > this instance > Settings > Java/Minecraft:
    Maximum Memory: $memMb MB
    Java Path: $javaHome
    Java Parameters: $argRest

MODRINTH APP: open this instance, click the three dots beside Play, then Settings > Java and memory:
  1. Turn on "Custom Java installation" and set: $javaExe
  2. Turn on "Custom Java arguments" and replace the box's contents with this ONE line:

$argLine

  3. Turn on "Custom memory allocation" and set $memMb MB.

Memory preset: $memGb GB ($memMb MB) of this PC's $ramGb GB; the updater asks every run (8, 12 or 16 GB).
$javaNote
-XX:-BytecodeVerificationRemote skips Java's re-check of mod code as it loads (25 to 40 s); a broken mod then crashes
less politely. To go back: turn the custom settings off; the launcher uses its own defaults again.
"@
$argFile = Join-Path $Target 'LAUNCH-ARGUMENTS.txt'
[IO.File]::WriteAllText($argFile, $argText.Replace("`r`n", "`n").Replace("`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
# What was set up last time, per instance: the Modrinth walk-through is shown again only when something changed.
$argSeen = Join-Path $stateDir 'launch-args.txt'
$argKey = "$Target | $(if ($javaOk) { $javaExe }) | $memMb | $argLine"
$lastKey = if (Test-Path -LiteralPath $argSeen) { (Get-Content -LiteralPath $argSeen -TotalCount 1) } else { '' }

function Json-Text([string]$s) { '"' + $s.Replace('\', '\\').Replace('"', '\"') + '"' }
# One key of instance.json's "launcher" section, replaced where it is or added at the section's start. A regex, not
# ConvertTo-Json: the file is megabytes of library lists that Windows PowerShell's JSON would reflow and cut short.
function Set-JsonKey([string]$json, [string]$key, [string]$value) {
  $rx = [regex]('"' + $key + '"\s*:\s*(?:"(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?|true|false|null)')
  if ($rx.IsMatch($json)) { return $rx.Replace($json, ('"' + $key + '": ' + $value).Replace('$', '$$'), 1) }
  $at = [regex]::Match($json, '"launcher"\s*:\s*\{')
  if (-not $at.Success) { throw 'instance.json has no "launcher" section' }
  $json.Insert($at.Index + $at.Length, "`n    `"$key`": $value,")
}
function Test-ATLauncherOpen {
  if ($env:LIONEL_UPDATER_ATL_OPEN) { return $env:LIONEL_UPDATER_ATL_OPEN -eq '1' }   # test.ps1
  [bool](Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and ($_.Path -match '\\ATLauncher\.exe$' -or $_.Path -match '\\ATLauncher\\jre\\') })
}

$setupDone = $false
if ($Launcher -eq 'ATLauncher') {
  $atlJson = Join-Path $Target 'instance.json'
  if (-not (Test-Path -LiteralPath $atlJson)) {
    Write-Host "`nThis folder has no instance.json, so it is not an ATLauncher instance: set up the speed settings by hand (LAUNCH-ARGUMENTS.txt in it)." -ForegroundColor Yellow
  } else {
    for ($try = 0; (Test-ATLauncherOpen) -and $try -lt 3; $try++) {
      Write-Host "`nATLauncher is open. Close it completely (its window, and its icon by the clock if there is one), then press Enter here." -ForegroundColor Yellow
      Write-Host '  (It keeps its own copy of the instance settings and would write it back over the new ones.) ' -NoNewline
      if ($null -eq [Console]::ReadLine()) { break }
    }
    if (Test-ATLauncherOpen) {
      Write-Host "`nATLauncher stayed open, so its speed settings were not written. Run the updater again with it closed, or" -ForegroundColor Yellow
      Write-Host '  set them by hand: LAUNCH-ARGUMENTS.txt in your ATM10 folder has the steps.' -ForegroundColor Yellow
    } else {
      $json = [IO.File]::ReadAllText($atlJson)
      $new = Set-JsonKey $json 'javaArguments' (Json-Text $argRest)
      $new = Set-JsonKey $new 'maximumMemory' "$memMb"
      if ($javaOk) { $new = Set-JsonKey $new 'javaPath' (Json-Text $javaHome); $new = Set-JsonKey $new 'useJavaProvidedByMinecraft' 'false' }
      if ($new -cne $json) {
        if (-not (Test-Path -LiteralPath "$atlJson.bak-lionel")) { Copy-Item -LiteralPath $atlJson "$atlJson.bak-lionel" }
        [IO.File]::WriteAllText($atlJson, $new, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "`nNEW LAUNCH ARGUMENTS written into ATLauncher's settings for this instance:" -ForegroundColor Cyan
        Write-Host "  memory $memMb MB; $(if ($javaOk) { "Java 21.0.12.1 ($javaHome); " })Java arguments: $argRest"
      }
      $setupDone = $true
    }
  }
} elseif ($lastKey -ne $argKey) {
  # The Modrinth app: one paste at a time, each value already copied.
  Write-Host "`nNEW LAUNCH ARGUMENTS: the speed setup for the Modrinth app, three steps." -ForegroundColor Cyan
  Write-Host '  In the Modrinth app, open this ATM10 instance, click the three dots beside Play, then Settings, then "Java and memory".'
  $steps = @()
  if ($javaOk) { $steps += , @('Turn on "Custom Java installation", click in its box, select all (Ctrl+A) and paste (Ctrl+V):', $javaExe) }
  $steps += , @('Turn on "Custom Java arguments", click in its box, select all (Ctrl+A) and paste (Ctrl+V):', $argLine)
  $steps += , @("Turn on `"Custom memory allocation`" and set it to $memMb MB (type it in the box next to the slider):", "$memMb")
  for ($i = 0; $i -lt $steps.Count; $i++) {
    Write-Host ("`n  {0}. {1}" -f ($i + 1), $steps[$i][0])
    Write-Host "     $($steps[$i][1])" -ForegroundColor White
    if (-not $env:LIONEL_UPDATER_NO_CLIPBOARD) { try { Set-Clipboard -Value $steps[$i][1]; Write-Host '     (Already copied.)' } catch { } }
    Write-Host '     Press Enter here when done. ' -NoNewline
    [void][Console]::ReadLine()
  }
  Write-Host "`n  The same steps are in LAUNCH-ARGUMENTS.txt in your ATM10 folder."
  $setupDone = $true
} else { $setupDone = $true }
if ($setupDone) { Set-Content -LiteralPath $argSeen -Value $argKey -Encoding UTF8 }

# The stub compares this with the small version file online and skips the big download when they match.
if (Test-Path -LiteralPath "$src\version.txt") { Copy-Item -LiteralPath "$src\version.txt" -Destination (Join-Path $stateDir 'version.txt') -Force }

Write-Host "`nDone. Added $added, updated $updated, removed $removed, already up to date $unchanged." -ForegroundColor Green
Show-Toast 'Advancement Made!' $(if ($Mode -eq 'fresh') { "Lionel's ATM10, installed ($label)" } else { "Up to date: update $label" })
$instanceName = Split-Path -Leaf $(if ((Split-Path -Leaf $Target) -match '^\.?minecraft$') { Split-Path -Parent $Target } else { $Target })
Write-Host "`nWhat to do now:" -ForegroundColor Cyan
if ($Launcher -eq 'ATLauncher') {
  Write-Host "  1. Open ATLauncher, go to the Instances tab, and click Play on `"$instanceName`"."
  if (-not $setupDone) { Write-Host '     First set its speed settings (ATLauncher was open): see LAUNCH-ARGUMENTS.txt in the ATM10 folder.' }
} else {
  Write-Host "  1. In the Modrinth app, click Play on `"$instanceName`"."
  Write-Host '     If you skipped a speed step above, LAUNCH-ARGUMENTS.txt in the ATM10 folder has all of them.'
}
if ($Mode -eq 'fresh') { Write-Host '     The first start of a new instance takes longer than later ones (5 minutes or more is normal).' }
Write-Host "  2. On the title screen, click `"Join Lionel's Server`" (or turn on Auto-join next to it to join on every start)."
Write-Host '  3. Next time there is an update, just run this updater again.'
