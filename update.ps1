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
# Started from the launcher's pre-launch check (lionel-check.jar, step 12b): that instance, update only, and no
# questions, since the game waits to start. The .bat passes LIONEL_UPDATER_HOOK on.
$fromGame = $env:LIONEL_UPDATER_HOOK
if ($fromGame) { $Target = $fromGame }

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

# SHA-1 with .NET, not Get-FileHash (2026-10-21): started from PowerShell 7, Windows PowerShell 5.1 inherits a module
# path where Get-FileHash cannot be found, and the update stopped at the first file.
function Get-Sha1([string]$path) {
  $h = [Security.Cryptography.SHA1]::Create(); $f = [IO.File]::OpenRead($path)
  try { -join ($h.ComputeHash($f) | ForEach-Object { $_.ToString('x2') }) } finally { $f.Dispose(); $h.Dispose() }
}

function Same-File([string]$a, [string]$b) {
  (Get-Item -LiteralPath $a).Length -eq (Get-Item -LiteralPath $b).Length -and (Get-Sha1 $a) -eq (Get-Sha1 $b)
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
  # Also a Games folder on any local drive, as Find-Packs looks (2026-10-22: Lionel's D:\Games\ATLauncher; its Uninstall
  # entry still named an old AppData folder, so the fresh install had nowhere to write the instance)
  foreach ($di in [IO.DriveInfo]::GetDrives()) {
    if ($di.DriveType -ne 'Fixed') { continue }
    $dirs += if ($Launcher -eq 'Modrinth') { "$($di.Name)Games\Modrinth App", "$($di.Name)Modrinth App" } else { "$($di.Name)Games\ATLauncher", "$($di.Name)ATLauncher" }
  }
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
function Get-ATLauncherProcesses {
  @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and ($_.Path -match '\\ATLauncher\.exe$' -or $_.Path -match '\\ATLauncher\\jre\\') })
}
function Test-ATLauncherOpen {
  # test.ps1: 1 open, 0 closed, closable = open until Close-ATLauncher closes it
  if ($env:LIONEL_UPDATER_ATL_OPEN -eq 'closable') { return -not $script:atlTestClosed }
  if ($env:LIONEL_UPDATER_ATL_OPEN) { return $env:LIONEL_UPDATER_ATL_OPEN -eq '1' }
  [bool](Get-ATLauncherProcesses)
}
# ATLauncher closed by the updater where it must be (2026-10-22, Lionel: "see if you can close atlauncher automatically
# ... to do the instance settings and relaunch it yourself"): asked to close as its X button does (it saves its own
# settings as it goes), and started again at the end ($atlReopen). Not while a game runs: ATLauncher may be waiting on
# it. Did not close in 15 s (busy, or only in the tray): Enter ends it. Returns whether it is closed.
$atlReopen = $false
function Close-ATLauncher {
  if (-not (Test-ATLauncherOpen)) { return $true }
  if ($env:LIONEL_UPDATER_ATL_OPEN -eq 'closable') { $script:atlTestClosed = $true; $script:atlReopen = $true; Write-Host "`nATLauncher closed: it opens again when the updater is done."; return $true }
  if ($env:LIONEL_UPDATER_ATL_OPEN) { return $false }   # test.ps1 '1': one that cannot be closed
  if (@(Get-CimInstance Win32_Process -Filter "Name='javaw.exe' OR Name='java.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'BootstrapLauncher|net\.minecraft\.client\.main' }).Count) { return $false }
  $procs = Get-ATLauncherProcesses
  # Its exe, to start it again when it was not found by Find-LauncherExe: ATLauncher.exe, or the one beside its jre\
  if (-not $script:launcherExe -or -not (Test-Path -LiteralPath $script:launcherExe)) {
    foreach ($p in $procs) {
      $exe = if ($p.Path -match '\\ATLauncher\.exe$') { $p.Path } else { Join-Path ($p.Path -replace '\\jre\\.*$', '') 'ATLauncher.exe' }
      if (Test-Path -LiteralPath $exe) { $script:launcherExe = $exe; break }
    }
  }
  Write-Host "`nClosing ATLauncher: it opens again when the updater is done..."
  foreach ($p in $procs) { try { [void]$p.CloseMainWindow() } catch { } }
  for ($i = 0; $i -lt 30 -and (Test-ATLauncherOpen); $i++) { Start-Sleep -Milliseconds 500 }
  if (Test-ATLauncherOpen) {
    Write-Host '  ATLauncher did not close by itself (it may be busy, or only in the tray by the clock).' -ForegroundColor Yellow
    Write-Host '  Press Enter to end it now (or close it yourself first, then press Enter): ' -NoNewline
    if ($null -eq [Console]::ReadLine()) { return $false }
    foreach ($p in (Get-ATLauncherProcesses)) { try { $p.Kill() } catch { } }
    for ($i = 0; $i -lt 10 -and (Test-ATLauncherOpen); $i++) { Start-Sleep -Milliseconds 500 }
  }
  if (Test-ATLauncherOpen) { return $false }
  $script:atlReopen = $true
  $true
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
  Write-SignInSteps
  Write-Host "`nPress Enter here when you are signed in (or Q to stop): " -NoNewline
  if ((Clean-Path ([Console]::ReadLine())) -ieq 'Q') { Fail 'Stopped. Nothing was changed.' }
}
function Write-SignInSteps {
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
}

$launcherExe = if ($fromGame) { 'running' } else { Find-LauncherExe }   # the launcher started the check
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

# The potato mode question (5p). Returns on ($true) or off ($false); $null when no answer came (end of input, or the
# launch check's 20 s ran out). Enter keeps $current.
function Ask-Potato([bool]$current, [int]$ram) {
  Write-Host "`nPotato mode, for weak PCs: shaders and other visual mods off, the lowest settings (render distance 3,"
  Write-Host "Fast graphics, no particles, no sky, mobs and blocks drawn only close by), smaller textures, 8 GB."
  Write-Host "You still join the server as normal. Switching it off later puts your own settings back."
  Write-Host "This PC has $ram GB of RAM. Potato mode is $(if ($current) { 'ON' } else { 'OFF' })."
  if ($fromGame) { Write-Host '  (Asked until you answer once. In 20 seconds the game starts with this as it is. Change it any time by running the updater.)' }
  Write-Host '  Press Enter to keep it, or type Y (on) or N (off) and press Enter: ' -NoNewline
  $answer = if ($env:LIONEL_UPDATER_POTATO) { $env:LIONEL_UPDATER_POTATO } elseif ($fromGame) { Read-TimedLine 20 } else { [Console]::ReadLine() }
  Write-Host ''
  if ($null -eq $answer) { return $null }
  $answer = $answer.Trim().ToUpper()
  if ($answer -in 'Y', 'YES', 'ON') { return $true }
  if ($answer -in 'N', 'NO', 'OFF') { return $false }
  if ($answer) { Write-Host "  '$answer' is not Y or N: potato mode stays $(if ($current) { 'on' } else { 'off' })." -ForegroundColor Yellow }
  $current
}
function Get-RamGb {
  if ($env:LIONEL_UPDATER_RAM_GB) { return [int]$env:LIONEL_UPDATER_RAM_GB }
  [int][math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
}
# A fresh install asks it before the long download (2026-10-22, Lionel: "or if the user wants it as an option when
# installing fresh"), so the rest runs without questions; 5p takes this answer. Only when potato.txt has rules.
$potatoEarly = $null
if ($Mode -eq 'fresh' -and @(Get-Content -LiteralPath "$src\potato.txt" -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' }).Count) {
  $ram = Get-RamGb
  $potatoEarly = Ask-Potato ($ram -lt 16) $ram
}

# ATLauncher, the import done for the player (2026-10-22, Lionel: "is there no way to have the updater import on our
# behalf?"). ATLauncher cannot be told to import from outside, but an instance is only a folder in its instances\ with
# an instance.json, and at the first Play it downloads Minecraft, NeoForge and the libraries itself. The pack's files
# are unpacked there and atlauncher-instance.json (make_atl_template.py: the instance.json of one real import) written
# beside them. Returns the new folder, or '' when it cannot (no template, another Minecraft or NeoForge version than the
# template's, a pack with download links, ATLauncher left open): then the player imports it as before.
function Install-AtlInstance([string]$packFile) {
  $template = Join-Path $src 'atlauncher-instance.json'
  if (-not (Test-Path -LiteralPath $template) -or (Get-Item -LiteralPath $template).Length -lt 1000 -or -not $launcherExe -or -not (Test-Path -LiteralPath $launcherExe)) { return '' }
  $json = [IO.File]::ReadAllText($template)
  $t = $json | ConvertFrom-Json
  $zip = [IO.Compression.ZipFile]::OpenRead($packFile)
  try {
    # (names may start with ./, as test.ps1's packs made by tar do)
    $entry = @($zip.Entries | Where-Object { ($_.FullName -replace '^\./', '') -eq 'modrinth.index.json' })[0]
    if (-not $entry) { return '' }
    $r = New-Object IO.StreamReader($entry.Open()); $index = $r.ReadToEnd() | ConvertFrom-Json; $r.Close()
    if (@($index.files).Count -or $index.dependencies.minecraft -ne $t.id -or $index.dependencies.neoforge -ne $t.launcher.loaderVersion.version) {
      Write-Host "`n(This pack is for another Minecraft or NeoForge version than the updater knows, so ATLauncher imports it.)" -ForegroundColor Yellow
      return ''
    }
    # ATLauncher reads its instances when it starts and keeps them in memory: closed, it sees the new one next start.
    # Closed by the updater; asked of the player only when it could not (a game running).
    [void](Close-ATLauncher)
    for ($try = 0; (Test-ATLauncherOpen) -and $try -lt 3; $try++) {
      Write-Host "`nATLauncher is open. Close it completely (its window, and its icon by the clock if there is one), then press Enter" -ForegroundColor Yellow
      Write-Host '  here: the updater puts the pack in it as a new instance, and opens it again at the end. ' -NoNewline
      if ($null -eq [Console]::ReadLine()) { break }
    }
    if (Test-ATLauncherOpen) { Write-Host "`nATLauncher stayed open, so the pack is imported by hand instead." -ForegroundColor Yellow; return '' }
    $instances = Join-Path (Split-Path -Parent $launcherExe) 'instances'
    $n = 1
    do {
      $folder = 'LionelsATM10' + $(if ($n -gt 1) { "-$n" })
      $name = "Lionel's ATM10" + $(if ($n -gt 1) { " ($n)" })
      $n++
    } while (Test-Path -LiteralPath (Join-Path $instances $folder))
    $dest = Join-Path $instances $folder
    Write-Section "Installing into ATLauncher as `"$name`""
    # overrides\ first, then client-overrides\ over it (the Modrinth pack format)
    $files = @($zip.Entries | Where-Object { $_.Name -and $_.FullName -match '^(\./)?(client-)?overrides/' } | Sort-Object { $_.FullName -match '^(\./)?client-' })
    $total = [double](($files | Measure-Object -Property Length -Sum).Sum) + 1
    $done = 0
    try {
      foreach ($e in $files) {
        $rel = $e.FullName -replace '^(\./)?(client-)?overrides/', ''
        if ($rel -match '(^|/)\.\.(/|$)' -or $rel -match '^/' -or $rel -match ':') { throw "Unsafe path in the pack: $($e.FullName)" }
        $to = Join-Path $dest $rel.Replace('/', '\')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
        [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $to, $true)
        $done += $e.Length
        Show-LookBar 'Unpacking' ($done / $total) ('{0:N0} of {1:N0} MB' -f ($done / 1MB), ($total / 1MB))
      }
      Clear-LookLine
      $json = $json.Replace('__UUID__', [guid]::NewGuid().ToString()).Replace('__NAME__', $name.Replace('\', '\\').Replace('"', '\"'))
      [IO.File]::WriteAllText((Join-Path $dest 'instance.json'), $json, (New-Object Text.UTF8Encoding($false)))
    } catch {
      Clear-LookLine
      Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
      Fail "The pack could not be put into ATLauncher: $($_.Exception.Message)`nNothing was left behind. Check your free space and try again."
    }
    Write-Host "  $($files.Count) files into $dest"
    $script:atlMade = $name
    $dest
  } finally { $zip.Dispose() }
}

# A fresh install: the whole pack is downloaded and goes into the launcher as a new instance: written by the updater
# itself for ATLauncher (Install-AtlInstance), handed to the Modrinth app to import, or imported by the player as a
# last resort. The instance is then updated and set up like any other.
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
  Write-Host "`nDownloaded."
  if ($Launcher -eq 'ATLauncher') {
    $made = Install-AtlInstance $packFile
    if ($made) { return $made }
  }
  $before = @{}
  foreach ($p in (Find-LauncherPacks)) { $before[$p[0].ToLowerInvariant()] = $true }
  Show-SignIn $launcherExe
  # The Modrinth app imports a pack file it is started with ("Open with Modrinth App"), also when it is already open.
  $handed = $false
  if ($Launcher -eq 'Modrinth' -and -not $env:LIONEL_UPDATER_NO_START -and $launcherExe) {
    try { Start-Process -FilePath $launcherExe -ArgumentList "`"$packFile`""; $handed = $true } catch { }
  }
  if ($handed) {
    Write-Host "`nThe Modrinth app is opening the pack. If it asks, click Install, then wait until it has finished installing" -ForegroundColor Cyan
    Write-Host '  (a few minutes). If nothing shows up there, import it yourself:'
  } else {
    Write-Host "`nNow import it into $Launcher (the file's path is copied: you only paste it):" -ForegroundColor Cyan
  }
  if ($Launcher -eq 'ATLauncher') {
    # The box above Browse takes a pasted path (ATLauncher's ImportInstanceDialog opens it as a file), so its slow file
    # window is never needed (2026-10-22, Lionel: "too many folders, UI lags").
    Write-Host '  1. Open ATLauncher, go to its "Instances" tab and click "Import" at the top.'
    Write-Host '  2. Click in the box at the top (not "Browse"), press Ctrl+V, then click "Import".'
    Write-Host '  3. Wait until ATLauncher has finished installing it (it downloads Minecraft and NeoForge too: a few minutes).'
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

# Per-file updates (2026-10-21, Lionel: "is there a way to make the updater more efficient ... if they have to download
# the whole update.zip everytime"; option 1, Cloudflare R2). publish.ps1 puts every file of the update in a public R2
# bucket under its SHA-1 (files/<sha1>), and a manifest listing them: "version|<label>" then "<set>|<path>|<sha1>|<size>"
# lines (set: overwrite or if-missing). The .bat passes the bucket's address as LIONEL_UPDATER_FILES_URL and fetches
# only this script and its small companions; here only the files the player does not already have, byte for byte, are
# downloaded, straight into the instance (several at a time), each checked against its SHA-1. Unchanged files are never
# downloaded again. Without the address, or if the manifest cannot be read, the whole zip is used as before.
$filesUrl = $env:LIONEL_UPDATER_FILES_URL
$manifestMode = $false
$manifest = @()   # objects: Set, Rel, Sha, Size
function Read-Manifest {
  $mf = Join-Path $src 'manifest.txt'
  $vf = Join-Path $src 'version.txt'
  foreach ($pair in @(@("$filesUrl/manifest.txt", $mf), @("$filesUrl/version.txt", $vf))) {
    & "$env:SystemRoot\System32\curl.exe" -L --fail -s -o $pair[1] $pair[0]
    if ($LASTEXITCODE -or -not (Test-Path -LiteralPath $pair[1])) { return $false }
  }
  $list = @()
  foreach ($line in [IO.File]::ReadAllLines($mf, (New-Object System.Text.UTF8Encoding($false)))) {
    $p = $line.Split('|')
    if ($p.Count -eq 4 -and $p[0] -in 'overwrite', 'if-missing' -and $p[2] -match '^[0-9a-f]{40}$') {
      $list += [pscustomobject]@{ Set = $p[0]; Rel = $p[1]; Sha = $p[2]; Size = [int64]$p[3] }
    }
  }
  if (-not @($list | Where-Object { $_.Set -eq 'overwrite' }).Count) { return $false }
  $script:manifest = $list
  $true
}
# Downloads manifest entries to the given paths (each written as .part, checked, then moved into place). Several at a
# time with curl's --parallel; an older curl without it gets them one by one. Returns the entries that failed.
function Get-ManifestFiles([object[]]$items) {
  if (-not $items.Count) { return @() }
  $cfg = Join-Path (Split-Path -Parent $src) 'files.curl'
  $lines = foreach ($it in $items) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $it.To) | Out-Null
    # curl's config files treat \ as an escape inside quotes: forward slashes, which Windows' curl accepts
    'url = "' + "$filesUrl/files/$($it.Sha)" + '"'
    'output = "' + "$($it.To).part".Replace('\', '/') + '"'
  }
  [IO.File]::WriteAllLines($cfg, [string[]]$lines)
  Write-Host ('  Downloading {0} file(s), {1:N1} MB...' -f $items.Count, (($items | Measure-Object -Property Size -Sum).Sum / 1MB))
  & "$env:SystemRoot\System32\curl.exe" -L --fail -s --retry 2 --parallel --parallel-max 6 -K $cfg 2>$null
  if ($LASTEXITCODE -eq 2) { & "$env:SystemRoot\System32\curl.exe" -L --fail -s --retry 2 -K $cfg 2>$null }   # no --parallel
  Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue
  $failed = @()
  foreach ($it in $items) {
    $part = "$($it.To).part"
    if ((Test-Path -LiteralPath $part) -and (Get-Sha1 $part) -eq $it.Sha) {
      if (Test-Path -LiteralPath $it.To) { Remove-Item -LiteralPath $it.To -Force }
      Move-Item -LiteralPath $part -Destination $it.To
    } else {
      if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
      $failed += $it
    }
  }
  $failed
}
if (-not (Test-Path -LiteralPath "$src\overwrite") -and $filesUrl) {
  if (Read-Manifest) {
    $latest = (Get-Content -LiteralPath (Join-Path $src 'version.txt') -TotalCount 1).Trim()
    $packMark = Join-Path $Target 'lionels-updater-pack-version.txt'
    $inPack = if (Test-Path -LiteralPath $packMark) { (Get-Content -LiteralPath $packMark -TotalCount 1).Trim() } else { '' }
    if ($Mode -eq 'fresh' -and $inPack -eq $latest) {
      Write-Host "`nThe whole pack already has the latest update ($latest): nothing more to download."
      $env:LIONEL_UPDATER_LATER_ZIP = ''
    } else { $manifestMode = $true }
  } else {
    Write-Host "`nThe file list of the update could not be read; the whole update zip is used instead." -ForegroundColor Yellow
    foreach ($f in 'manifest.txt', 'version.txt') { $p = Join-Path $src $f; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } }
  }
}

# A fresh install the .bat started without the update (2026-10-16, Lionel: "don't download the full update on the start,
# because what if a user wants to do the full modpack download?"): it fetched only this script and its small companions
# from GitHub. The whole pack says which update it already holds (lionels-updater-pack-version.txt, written by
# make_full_pack.py only when every file of that update is in it): the latest, and nothing more is downloaded; older or
# unknown, and the update zip is fetched now and applied as usual.
$haveFiles = (Test-Path -LiteralPath "$src\overwrite") -or $manifestMode
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
$named = if ($manifestMode) { @($manifest | ForEach-Object { $_.Rel }) } else { @(Get-Files "$src\overwrite") + @(Get-Files "$src\if-missing") }
foreach ($list in "$src\delete.txt", $recordPath) {
  if (Test-Path -LiteralPath $list) { $named += @(Get-Content -LiteralPath $list | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' }) }
}
# The optional mods (step 5c), read here: their paths are checked with the rest, and step 4 leaves their files alone
# (an earlier update shipped Shoulder Surfing and Punchy, so the installed list names them).
$optionalMods = @()
if (Test-Path -LiteralPath "$src\optional.txt") {
  foreach ($line in @(Get-Content -LiteralPath "$src\optional.txt" | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' })) {
    $p = $line.Split('|')
    if ($p.Count -lt 6) { continue }
    $files = @()
    foreach ($f in $p[5].Split(';')) { $q = $f.Split('>'); if ($q.Count -eq 3) { $files += , @($q[0].Trim(), $q[1].Trim(), $q[2].Trim().ToLowerInvariant()) } }
    $optionalMods += , [pscustomobject]@{ Id = $p[0].Trim(); Name = $p[1].Trim(); About = $p[2].Trim(); Default = ($p[3].Trim() -eq 'on')
      ModIds = @($p[4].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }); Files = $files }
  }
}
$optionalPaths = @{}
foreach ($m in $optionalMods) { foreach ($f in $m.Files) { $optionalPaths[$f[0]] = $true; $named += $f[0] } }
try { foreach ($rel in $named) { Resolve-Safe $rel | Out-Null } } catch { Fail "$($_.Exception.Message)`nThis update is faulty. Nothing was changed. Tell Lionel." }

# Room on the ATM10 drive for what this update copies (a size that differs means a copy; 200 MB to spare).
$needBytes = 0
if ($manifestMode) {
  foreach ($e in $manifest) {
    $dest = Join-Path $Target $e.Rel.Replace('/', '\')
    if (-not (Test-Path -LiteralPath $dest)) { $needBytes += $e.Size }
    elseif ($e.Set -eq 'overwrite') { $needBytes += [math]::Max(0, $e.Size - (Get-Item -LiteralPath $dest).Length) }
  }
} else {
  foreach ($set in 'overwrite', 'if-missing') {
    foreach ($rel in (Get-Files "$src\$set")) {
      $from = Get-Item -LiteralPath (Join-Path "$src\$set" $rel)
      $dest = Join-Path $Target $rel.Replace('/', '\')
      if (-not (Test-Path -LiteralPath $dest)) { $needBytes += $from.Length }
      elseif ($set -eq 'overwrite') { $needBytes += [math]::Max(0, $from.Length - (Get-Item -LiteralPath $dest).Length) }
    }
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
$installed = if ($manifestMode) { @($manifest | Where-Object { $_.Set -eq 'overwrite' } | ForEach-Object { $_.Rel }) } else { Get-Files "$src\overwrite" }
if ($manifestMode) {
  # only the files that are missing or differ, straight into the instance
  $want = @()
  $i = 0
  $ow = @($manifest | Where-Object { $_.Set -eq 'overwrite' })
  foreach ($e in $ow) {
    Show-LookBar 'Checking files' ($i++ / [Math]::Max(1, $ow.Count)) "$i of $($ow.Count)"
    $dest = Resolve-Safe $e.Rel
    if ((Test-Path -LiteralPath $dest) -and (Get-Item -LiteralPath $dest).Length -eq $e.Size -and (Get-Sha1 $dest) -eq $e.Sha) { $unchanged++; continue }
    $want += [pscustomobject]@{ Rel = $e.Rel; Sha = $e.Sha; Size = $e.Size; To = $dest; New = -not (Test-Path -LiteralPath $dest) }
  }
  Clear-LookLine
  $bad = @(Get-ManifestFiles $want)
  if ($bad.Count) { Fail ("$($bad.Count) file(s) of the update could not be downloaded (first: $($bad[0].Rel)). The ones before were updated;`nrun the updater again to finish. Check your internet connection.") }
  foreach ($w in $want) { if ($w.New) { $added++; Write-Change '+' $w.Rel } else { $updated++; Write-Change '~' $w.Rel } }
}
$i = 0
foreach ($rel in $(if ($manifestMode) { @() } else { $installed })) {
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
    foreach ($rel in @(Get-Content -LiteralPath $recordPath | Where-Object { $_.Trim() -and $installed -notcontains $_.Trim() -and -not $optionalPaths[$_.Trim()] })) {
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
# Kept per jar for the run: step 5c reads the same jars again.
$modIdCache = @{}
function Get-ModIds([string]$jar) {
  if ($modIdCache.ContainsKey($jar)) { return $modIdCache[$jar] }
  $ids = Read-ModIds $jar
  $modIdCache[$jar] = $ids
  $ids
}
function Read-ModIds([string]$jar) {
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
$shippedDir = if ($manifestMode) { Join-Path $Target 'mods' } else { "$src\overwrite\mods" }
$shippedList = if ($manifestMode) { @($installed | Where-Object { $_ -match '^mods/[^/]+\.jar$' } | ForEach-Object { Get-Item -LiteralPath (Resolve-Safe $_) }) }
  elseif (Test-Path -LiteralPath $shippedDir) { @(Get-ChildItem -LiteralPath $shippedDir -Filter *.jar -File) } else { @() }
if ($shippedList.Count) {
  foreach ($j in $shippedList) {
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

# 5p. Potato mode (2026-10-21, Lionel: "a super low-spec pc complete with options and settings recommended for a
#     potato"; "maximum cuts for maximum performance"; "8gb is the potato mode starter"). potato.txt names what it does:
#     client-only mods off (renamed .jar.disabled), resource packs out of / into the list, settings in options.txt and
#     five mods' config files. The server needs none of the mods, so a potato player still joins. Asked on every run but
#     the launch check's (Enter keeps; first run: on with less than 16 GB of RAM). Everything it replaced is written down
#     in lionels-updater-potato.txt and goes back when it is switched off; a setting the player changed themselves in
#     the meantime stays as they set it. On, it also keeps every optional mod off (5c) and memory at 8 GB (12).
$potato = $false
$potatoMods = @{}; $potatoPacks = @(); $potatoSets = @()
if (Test-Path -LiteralPath "$src\potato.txt") {
  foreach ($line in @(Get-Content -LiteralPath "$src\potato.txt" -Encoding UTF8 | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' })) {
    $p = $line.Split('|')
    if ($p[0] -eq 'mod' -and $p.Count -ge 3) { $potatoMods[$p[1].Trim()] = $p[2].Trim() }
    elseif ($p[0] -eq 'pack' -and $p.Count -ge 3) { $potatoPacks += , @($p[1], $p[2].Trim()) }
    elseif ($p[0] -eq 'set' -and $p.Count -ge 6) { $potatoSets += [pscustomobject]@{ File = $p[1]; Kind = $p[2]; Section = $p[3]; Key = $p[4]; Value = ($p[5..($p.Count - 1)] -join '|') } }
  }
}
# Where a setting's value sits in a file's text: a match whose group 1 is the value, or $null.
function Find-Setting([string]$text, $s) {
  if ($s.Kind -eq 'kv') { $m = [regex]::Match($text, '(?m)^' + [regex]::Escape($s.Key) + ':(.*?)(?=\r?$)'); if ($m.Success) { return $m } else { return $null } }
  if ($s.Kind -eq 'json') {
    $start = 0
    if ($s.Section -ne '-') {
      $sec = [regex]::Match($text, '"' + [regex]::Escape($s.Section) + '"\s*:\s*\{')
      if (-not $sec.Success) { return $null }
      $start = $sec.Index + $sec.Length
    }
    $m = ([regex]('"' + [regex]::Escape($s.Key) + '"\s*:\s*("(?:[^"\\]|\\.)*"|[-+\d.eE]+|true|false|null)')).Match($text, $start)
    if ($m.Success) { return $m } else { return $null }
  }
  if ($s.Kind -eq 'toml') {
    # Section "-": a key at the top of the file, before the first [section].
    if ($s.Section -eq '-') { $after = 0 } else {
      $sec = [regex]::Match($text, '(?m)^[ \t]*\[' + [regex]::Escape($s.Section) + '\][ \t]*(?=\r?$)')
      if (-not $sec.Success) { return $null }
      $after = $sec.Index + $sec.Length
    }
    $next = ([regex]'(?m)^[ \t]*\[').Match($text, $after)
    $end = if ($next.Success) { $next.Index } else { $text.Length }
    $m = ([regex]('(?m)^[ \t]*' + [regex]::Escape($s.Key) + '[ \t]*=[ \t]*(.*?)[ \t]*(?=\r?$)')).Match($text, $after)
    if ($m.Success -and $m.Index -lt $end) { return $m } else { return $null }
  }
  $null
}
function Read-Utf8([string]$path) { [IO.File]::ReadAllText($path, (New-Object System.Text.UTF8Encoding($false))) }
# A line typed within $seconds ('' for a bare Enter), or $null when nothing was answered (also with no console).
function Read-TimedLine([int]$seconds) {
  try {
    $end = (Get-Date).AddSeconds($seconds); $typed = ''
    while ((Get-Date) -lt $end) {
      if ([Console]::KeyAvailable) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Enter') { return $typed }
        if ($k.Key -eq 'Backspace') { if ($typed) { $typed = $typed.Substring(0, $typed.Length - 1); Write-Host "`b `b" -NoNewline } }
        else { $typed += $k.KeyChar; Write-Host $k.KeyChar -NoNewline }
      } else { Start-Sleep -Milliseconds 50 }
    }
    return $null
  } catch { return $null }
}
function Write-Utf8([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false))) }
# resourcePacks:["a","b"] in options.txt: the match (group 1 = inside the brackets) and its entries.
function Get-PackList([string]$text) {
  $m = [regex]::Match($text, '(?m)^resourcePacks:\[(.*?)\](?=\r?$)')
  if (-not $m.Success) { return $null }
  $entries = @([regex]::Matches($m.Groups[1].Value, '"((?:[^"\\]|\\.)*)"') | ForEach-Object { $_.Groups[1].Value })
  [pscustomobject]@{ Match = $m; Entries = $entries }
}
function Test-PackRule([string]$entry, [string]$rule) {
  if ($rule.EndsWith('*')) { return $entry.StartsWith($rule.Substring(0, $rule.Length - 1)) }
  $entry -ceq $rule
}
if ($potatoMods.Count -or $potatoSets.Count) {
  Write-Section 'Potato mode'
  $potatoStatePath = Join-Path $Target 'lionels-updater-potato.txt'
  # The record: "potato<TAB>on", "mod<TAB>mods/x.jar", "packs<TAB><the list as it was>", "packsnow<TAB><the list potato
  # mode wrote>", "set<TAB>file<TAB>section<TAB>key<TAB>old value<TAB>potato value".
  $was = $false; $asked = $false; $recMods = @(); $recPacks = $null; $recPacksNow = $null; $recSets = @()
  if (Test-Path -LiteralPath $potatoStatePath) {
    foreach ($l in [IO.File]::ReadAllLines($potatoStatePath, (New-Object System.Text.UTF8Encoding($false)))) {
      $f = $l.Split("`t")
      switch ($f[0]) {
        'potato' { $was = ($f[1] -eq 'on') }
        'asked' { $asked = $true }
        'mod' { $recMods += $f[1] }
        'packs' { $recPacks = $f[1] }
        'packsnow' { $recPacksNow = $f[1] }
        'set' { if ($f.Count -ge 6) { $recSets += [pscustomobject]@{ File = $f[1]; Section = $f[2]; Key = $f[3]; Old = $f[4]; New = $f[5] } } }
      }
    }
  }
  $potatoRam = Get-RamGb
  $potatoNew = -not (Test-Path -LiteralPath $potatoStatePath)
  $potato = if ($potatoNew) { $potatoRam -lt 16 } else { $was }
  # "asked" in the record: the player has answered once (2026-10-21, Lionel: "at least once, and it remembers their
  # choice"). Records from before it, written with the silent default, get the question once too.
  # From the launch check too, but only the first time (2026-10-21, Lionel: "players updating should have the choice to
  # put on potato mode": most update from the game's start and were never asked). 20 s, then the default, so the game
  # never waits for an answer; later starts ask nothing, as before.
  if ($null -ne $potatoEarly) { $potato = $potatoEarly; $asked = $true }   # a fresh install asked before its download
  elseif (-not $fromGame -or -not $asked) {
    $answer = Ask-Potato $potato $potatoRam
    if ($null -ne $answer) { $potato = $answer; $asked = $true }   # no answer in time: asked again next update
  }
  $modsDir = Join-Path $Target 'mods'
  $optionsPath = Join-Path $Target 'options.txt'
  if ($potato) {
    # Mods: every enabled jar declaring one of the mod ids.
    foreach ($j in @(Get-ChildItem -LiteralPath $modsDir -Filter *.jar -File)) {
      $hit = @(Get-ModIds $j.FullName | Where-Object { $potatoMods.ContainsKey($_) })
      if (-not $hit.Count) { continue }
      if (Test-Path -LiteralPath "$($j.FullName).disabled") { Remove-Item -LiteralPath "$($j.FullName).disabled" -Force }
      Move-Item -LiteralPath $j.FullName -Destination "$($j.FullName).disabled"
      $rel = "mods/$($j.Name)"
      if ($recMods -notcontains $rel) { $recMods += $rel }
      $removed++; Write-Change '-' "$rel  ($($potatoMods[$hit[0]]): off for potato mode, renamed .jar.disabled)"
    }
    # Resource packs: taken out of / added to the list, the list as it was kept once.
    if (Test-Path -LiteralPath $optionsPath) {
      $text = Read-Utf8 $optionsPath
      $list = Get-PackList $text
      if ($list) {
        $keep = @($list.Entries | Where-Object { $e = $_; -not @($potatoPacks | Where-Object { $_[1] -eq 'off' -and (Test-PackRule $e $_[0]) }).Count })
        foreach ($r in $potatoPacks) {
          if ($r[1] -ne 'on' -or $keep -contains $r[0]) { continue }
          $file = $r[0] -replace '^file/', ''
          if ($r[0].StartsWith('file/') -and (Test-Path -LiteralPath (Join-Path (Join-Path $Target 'resourcepacks') $file))) { $keep += $r[0] }
        }
        $newInside = ($keep | ForEach-Object { '"' + $_ + '"' }) -join ','
        if ($newInside -cne $list.Match.Groups[1].Value) {
          if (-not (Test-Path -LiteralPath "$optionsPath.bak-lionel-potato")) { Copy-Item -LiteralPath $optionsPath -Destination "$optionsPath.bak-lionel-potato" }
          if ($null -eq $recPacks) { $recPacks = $list.Match.Groups[1].Value }
          $text = $text.Remove($list.Match.Groups[1].Index, $list.Match.Groups[1].Length).Insert($list.Match.Groups[1].Index, $newInside)
          Write-Utf8 $optionsPath $text
          $gone = @($list.Entries | Where-Object { $keep -notcontains $_ }); $new = @($keep | Where-Object { $list.Entries -notcontains $_ })
          Write-Change '~' ("options.txt: resource packs for potato mode" + $(if ($gone.Count) { "; off: $($gone -join ', ')" }) + $(if ($new.Count) { "; on: $($new -join ', ')" }))
        }
        $recPacksNow = $newInside
      }
    }
    # Settings: each one recorded the first time potato mode sets it, so a value the player changes afterwards stays.
    $changed = @{}
    # potato.txt changed since a setting was recorded (2026-10-22: 60 fps to unlimited, the sky back on): where the file
    # still has the value potato mode wrote, the new rule's value goes in, or the player's own when the rule is gone.
    $keepSets = @()
    foreach ($r in $recSets) {
      $rule = @($potatoSets | Where-Object { $_.File -eq $r.File -and $_.Section -eq $r.Section -and $_.Key -eq $r.Key })[0]
      if ($rule -and $rule.Value -ceq $r.New) { $keepSets += $r; continue }
      $to = if ($rule) { $rule.Value } else { $r.Old }
      $path = Join-Path $Target $r.File.Replace('/', '\')
      if (Test-Path -LiteralPath $path) {
        $text = Read-Utf8 $path
        $m = Find-Setting $text ([pscustomobject]@{ Kind = $(if ($r.File -eq 'options.txt') { 'kv' } elseif ($r.File.EndsWith('.toml')) { 'toml' } else { 'json' }); Section = $r.Section; Key = $r.Key })
        if ($m -and $m.Groups[1].Value -ceq $r.New -and $to -cne $r.New) {
          Write-Utf8 $path $text.Remove($m.Groups[1].Index, $m.Groups[1].Length).Insert($m.Groups[1].Index, $to)
          $changed[$r.File] = 1 + $(if ($changed.ContainsKey($r.File)) { $changed[$r.File] } else { 0 })
        }
      }
      if ($rule) { $keepSets += [pscustomobject]@{ File = $r.File; Section = $r.Section; Key = $r.Key; Old = $r.Old; New = $rule.Value } }
    }
    $recSets = $keepSets
    foreach ($s in $potatoSets) {
      $path = Join-Path $Target $s.File.Replace('/', '\')
      if (-not (Test-Path -LiteralPath $path)) { continue }   # written by the game on its first start: set on the next run
      if (@($recSets | Where-Object { $_.File -eq $s.File -and $_.Section -eq $s.Section -and $_.Key -eq $s.Key }).Count) { continue }
      $text = Read-Utf8 $path
      $m = Find-Setting $text $s
      if (-not $m) { continue }
      $old = $m.Groups[1].Value
      $recSets += [pscustomobject]@{ File = $s.File; Section = $s.Section; Key = $s.Key; Old = $old; New = $s.Value }
      if ($old -ceq $s.Value) { continue }
      if (-not (Test-Path -LiteralPath "$path.bak-lionel-potato")) { Copy-Item -LiteralPath $path -Destination "$path.bak-lionel-potato" }
      Write-Utf8 $path $text.Remove($m.Groups[1].Index, $m.Groups[1].Length).Insert($m.Groups[1].Index, $s.Value)
      $changed[$s.File] = 1 + $(if ($changed.ContainsKey($s.File)) { $changed[$s.File] } else { 0 })
    }
    foreach ($k in $changed.Keys) { Write-Change '~' "$k`: $($changed[$k]) setting(s) set for potato mode (your old values are kept to put back)" }
  }
  elseif ($was) {
    foreach ($rel in $recMods) {
      $jar = Resolve-Safe $rel
      if ((Test-Path -LiteralPath "$jar.disabled") -and -not (Test-Path -LiteralPath $jar)) {
        Move-Item -LiteralPath "$jar.disabled" -Destination $jar
        $added++; Write-Change '+' "$rel  (potato mode off: switched back on)"
      }
    }
    if ((Test-Path -LiteralPath $optionsPath) -and $null -ne $recPacks) {
      $text = Read-Utf8 $optionsPath
      $list = Get-PackList $text
      if ($list) {
        $inside = $list.Match.Groups[1].Value
        if ($inside -ceq $recPacksNow) { $back = $recPacks }   # untouched since: exactly as it was
        else {
          # the player changed packs meanwhile: theirs stay, the ones potato mode took out come back at the end, the
          # ones it added go
          $before = @([regex]::Matches($recPacks, '"((?:[^"\\]|\\.)*)"') | ForEach-Object { $_.Groups[1].Value })
          $potatoNow = @([regex]::Matches($recPacksNow, '"((?:[^"\\]|\\.)*)"') | ForEach-Object { $_.Groups[1].Value })
          $entries = @($list.Entries | Where-Object { $before -contains $_ -or $potatoNow -notcontains $_ })
          foreach ($e in $before) { if ($entries -notcontains $e) { $entries += $e } }
          $back = ($entries | ForEach-Object { '"' + $_ + '"' }) -join ','
        }
        if ($back -cne $inside) {
          Write-Utf8 $optionsPath $text.Remove($list.Match.Groups[1].Index, $list.Match.Groups[1].Length).Insert($list.Match.Groups[1].Index, $back)
          Write-Change '~' 'options.txt: your resource packs as they were before potato mode'
        }
      }
    }
    $restored = @{}
    foreach ($r in $recSets) {
      $path = Join-Path $Target $r.File.Replace('/', '\')
      if (-not (Test-Path -LiteralPath $path)) { continue }
      $text = Read-Utf8 $path
      $m = Find-Setting $text ([pscustomobject]@{ Kind = $(if ($r.File -eq 'options.txt') { 'kv' } elseif ($r.File.EndsWith('.toml')) { 'toml' } else { 'json' }); Section = $r.Section; Key = $r.Key })
      if (-not $m -or $m.Groups[1].Value -cne $r.New -or $r.Old -ceq $r.New) { continue }   # changed by the player since: theirs
      Write-Utf8 $path $text.Remove($m.Groups[1].Index, $m.Groups[1].Length).Insert($m.Groups[1].Index, $r.Old)
      $restored[$r.File] = 1 + $(if ($restored.ContainsKey($r.File)) { $restored[$r.File] } else { 0 })
    }
    foreach ($k in $restored.Keys) { Write-Change '~' "$k`: $($restored[$k]) setting(s) back to yours (potato mode off)" }
    $recMods = @(); $recPacks = $null; $recPacksNow = $null; $recSets = @()
  }
  $out = @("potato`t$(if ($potato) { 'on' } else { 'off' })") + @(if ($asked) { "asked`tyes" }) + @($recMods | ForEach-Object { "mod`t$_" })
  if ($null -ne $recPacks) { $out += "packs`t$recPacks"; $out += "packsnow`t$recPacksNow" }
  $out += @($recSets | ForEach-Object { "set`t$($_.File)`t$($_.Section)`t$($_.Key)`t$($_.Old)`t$($_.New)" })
  [IO.File]::WriteAllLines($potatoStatePath, [string[]]$out, (New-Object System.Text.UTF8Encoding($false)))
  # For the .bat (2026-10-22): a player on the latest update who never answered is sent here instead of being told
  # there is nothing to do.
  if ($asked) { Set-Content -LiteralPath (Join-Path $stateDir 'potato-decided.txt') -Value $(if ($potato) { 'on' } else { 'off' }) -Encoding ASCII }
  if ($potato) { Write-Host '  Potato mode is on.' } elseif ($was) { Write-Host '  Potato mode is off: everything it changed is back.' }
}

# 5c. Optional mods (2026-10-17, Lionel: Shoulder Surfing and Punchy, "if it's already present, disable the mods
#     respectively"; "add distant horizons to the optional installs in the updater (updating or fresh install)").
#     optional.txt names them. Asked on every run but the launch check's (Enter keeps); the choice is kept per instance
#     in lionels-updater-optional.txt. First run: on if the player already has it (an enabled jar declaring its mod
#     id), otherwise its default. On: its files are downloaded (SHA-1 checked) or a .disabled copy renamed back, then
#     any other jar with its mod id goes to the backup folder (two of one mod stop the game). Off: every jar declaring
#     its mod id is renamed .jar.disabled, the player's own copies too. Nothing is deleted.
if ($optionalMods.Count) {
  Write-Section 'Optional mods'
  $choicePath = Join-Path $Target 'lionels-updater-optional.txt'
  $saved = @{}
  if (Test-Path -LiteralPath $choicePath) {
    foreach ($l in Get-Content -LiteralPath $choicePath) { if ($l -match '^\s*([\w.-]+)\s*=\s*(on|off)\s*$') { $saved[$Matches[1]] = ($Matches[2] -eq 'on') } }
  }
  $byId = @{}
  $jars = @(Get-ChildItem -LiteralPath (Join-Path $Target 'mods') -Filter *.jar -File)
  $i = 0
  foreach ($j in $jars) {
    Show-LookBar 'Looking for optional mods' ($i++ / [Math]::Max(1, $jars.Count)) "$i of $($jars.Count)"
    foreach ($id in (Get-ModIds $j.FullName)) { if (-not $byId.ContainsKey($id)) { $byId[$id] = @() }; $byId[$id] += $j.FullName }
  }
  Clear-LookLine
  # A player who disabled one themselves before this menu existed (renamed .jar.disabled, or switched off in the
  # Modrinth app): their first run reads that as "off", instead of switching it back on by default.
  $offById = @{}
  foreach ($j in @(Get-ChildItem -LiteralPath (Join-Path $Target 'mods') -Filter *.jar.disabled -File)) {
    foreach ($id in (Get-ModIds $j.FullName)) { $offById[$id] = $true }
  }
  $on = @{}
  foreach ($m in $optionalMods) {
    $has = [bool]@($m.ModIds | Where-Object { $byId.ContainsKey($_) }).Count
    $hadOff = [bool]@($m.ModIds | Where-Object { $offById.ContainsKey($_) }).Count
    $on[$m.Id] = if ($saved.ContainsKey($m.Id)) { $saved[$m.Id] } elseif ($has) { $true } elseif ($hadOff) { $false } else { $m.Default }
  }
  # Potato mode (5p): all off for this run, without asking; the player's own choices stay saved for when it is off.
  $ownChoice = @{}; foreach ($k in $on.Keys) { $ownChoice[$k] = $on[$k] }
  if ($potato) { foreach ($m in $optionalMods) { $on[$m.Id] = $false }; Write-Host "`nOptional mods: all off while potato mode is on." }
  elseif (-not $fromGame) {
    while ($true) {
      Write-Host "`nOptional mods (only on this PC; the server does not need them):"
      for ($k = 0; $k -lt $optionalMods.Count; $k++) {
        $m = $optionalMods[$k]
        Write-Host ('  {0}) [{1}] {2}: {3}' -f ($k + 1), $(if ($on[$m.Id]) { 'x' } else { ' ' }), $m.Name, $m.About)
      }
      Write-Host 'Type numbers to switch them on or off (e.g. 1 3) and press Enter; press Enter alone to keep these: ' -NoNewline
      $answer = if ($env:LIONEL_UPDATER_OPTIONAL) { $env:LIONEL_UPDATER_OPTIONAL } else { [Console]::ReadLine() }
      Write-Host ''
      $answer = if ($answer) { $answer.Trim() } else { '' }
      if (-not $answer -or $answer -eq 'keep') { break }
      foreach ($n in ($answer -split '[\s,]+')) {
        if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $optionalMods.Count) { $m = $optionalMods[[int]$n - 1]; $on[$m.Id] = -not $on[$m.Id] }
        else { Write-Host "  '$n' is not one of the numbers above." -ForegroundColor Yellow }
      }
      if ($env:LIONEL_UPDATER_OPTIONAL) { break }   # test.ps1 answers once
    }
  }
  $sha = { param($p) Get-Sha1 $p }
  $backupMods = Join-Path (Join-Path $Target 'lionels-updater-backup') 'mods'
  foreach ($m in $optionalMods) {
    if ($on[$m.Id]) {
      $mine = @{}
      $complete = $true
      foreach ($f in $m.Files) {
        $dest = Resolve-Safe $f[0]
        $mine[$dest.ToLowerInvariant()] = $true
        if ((Test-Path -LiteralPath $dest) -and (& $sha $dest) -eq $f[2]) { continue }
        if ((Test-Path -LiteralPath "$dest.disabled") -and (& $sha "$dest.disabled") -eq $f[2]) {
          if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
          Move-Item -LiteralPath "$dest.disabled" -Destination $dest
          $added++; Write-Change '+' "$($f[0])  (switched back on)"
          continue
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        $part = "$dest.part"
        $ok = Invoke-Download $f[1] $part $m.Name
        if ($ok -and (Test-Path -LiteralPath $part) -and (& $sha $part) -eq $f[2]) {
          if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force; $updated++ } else { $added++ }
          Move-Item -LiteralPath $part -Destination $dest
          Write-Change '+' $f[0]
        } else {
          if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
          $complete = $false
          Write-Host "  $($m.Name) could not be downloaded, or was not the expected file: not installed. Run the updater again later." -ForegroundColor Yellow
        }
      }
      if ($complete) {
        foreach ($id in $m.ModIds) {
          foreach ($jar in @($byId[$id])) {
            if (-not $jar -or $mine[$jar.ToLowerInvariant()] -or -not (Test-Path -LiteralPath $jar)) { continue }
            New-Item -ItemType Directory -Force -Path $backupMods | Out-Null
            Move-Item -LiteralPath $jar -Destination (Join-Path $backupMods (Split-Path -Leaf $jar)) -Force
            $removed++; Write-Change '-' "mods/$(Split-Path -Leaf $jar)  (another copy of $($m.Name); kept in lionels-updater-backup)"
          }
        }
      }
    } else {
      foreach ($id in $m.ModIds) {
        foreach ($jar in @($byId[$id])) {
          if (-not $jar -or -not (Test-Path -LiteralPath $jar)) { continue }
          if (Test-Path -LiteralPath "$jar.disabled") { Remove-Item -LiteralPath "$jar.disabled" -Force }
          Move-Item -LiteralPath $jar -Destination "$jar.disabled"
          $removed++; Write-Change '-' "mods/$(Split-Path -Leaf $jar)  ($($m.Name) switched off: renamed .jar.disabled)"
        }
      }
    }
  }
  $keepChoice = if ($potato) { $ownChoice } else { $on }
  Set-Content -LiteralPath $choicePath -Value @($optionalMods | ForEach-Object { "$($_.Id)=$(if ($keepChoice[$_.Id]) { 'on' } else { 'off' })" }) -Encoding ASCII
}

# 6. Defaults: only where the player has no file of their own.
Write-Section 'Settings'
if ($manifestMode) {
  $want = @($manifest | Where-Object { $_.Set -eq 'if-missing' -and -not (Test-Path -LiteralPath (Resolve-Safe $_.Rel)) } |
    ForEach-Object { [pscustomobject]@{ Rel = $_.Rel; Sha = $_.Sha; Size = $_.Size; To = (Resolve-Safe $_.Rel) } })
  $bad = @(Get-ManifestFiles $want)
  foreach ($w in $want) { if ($bad -notcontains $w) { $added++; Write-Change '+' $w.Rel } }
  if ($bad.Count) { Write-Host "  $($bad.Count) default file(s) could not be downloaded; the next run tries again." -ForegroundColor Yellow }
} else {
  foreach ($rel in (Get-Files "$src\if-missing")) {
    $dest = Resolve-Safe $rel
    if (-not (Test-Path -LiteralPath $dest)) { Copy-To (Join-Path "$src\if-missing" $rel) $dest; $added++; Write-Change '+' $rel }
  }
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
# 11e. More Overlays' item search (double-click the JEI search bar) built every inventory item's whole tooltip, every
#      mod's tooltip code included, on every tick: 31% of Lionel's frame time in a Spark profile (2026-10-17, Lionel:
#      "max the performance"). Names only from now on; the mod's own config says false "will increase performance".
Edit-Once 'config\moreoverlays.toml' @(
  @('(?m)^([ \t]*search_tooltip = )true(?=\r?$)', 'false'),
  @('(?m)^([ \t]*custom_search = )true(?=\r?$)', 'false')
) 'More Overlays'' item search matches item names only, not whole tooltips (two lines; it cost a third of the frame time)'
# 11f. Chloride's Fast Chests (2026-10-17, Lionel: "keep chloride and turn on fast chests"): chests drawn as plain block
#      models instead of one animated model each, a real gain in big chest rooms; the lid no longer animates. Chloride
#      writes its file on the first start, so a player who has not started the game since gets it on the next update.
Edit-Once 'config\chloride-client.toml' @(
  , @('(?m)^(\[fastBlocks\]\r?\n(?:[ \t]*#[^\n]*\n)*[ \t]*chests = )false(?=\r?$)', 'true')
) 'Chloride''s Fast Chests are on: chests draw as plain models, much cheaper in chest rooms; lids no longer animate (one line)'
# 11g. ImmediatelyFast's font atlas resizing (2026-10-18): a player's text all came out as black boxes (tooltips, item
#      counts, titles; shaders off made no difference) while a few glyphs drew fine, so glyph pages of the resized font
#      atlas were broken on his graphics driver. Off: the game keeps its own font pages (a few more draw calls for text).
Edit-Once 'config\immediatelyfast.json' @(
  , @('(?m)^([ \t]*"font_atlas_resizing": )true(?=,?\r?$)', 'false')
) 'ImmediatelyFast''s font atlas resizing is off: on some graphics drivers it turned all text into black boxes (one line)'
# 11h. One titanium (2026-10-18, Lionel: "there's 2 titanium ... should dedupe them", option A): Almost Unified merges
#      Antarchy's titanium into Modern Industrialization's once "titanium" is one of its materials. The server does the
#      recipes; this only keeps the player's recipe viewer from showing both. Added after "tin", once, if absent.
Edit-Once 'config\almostunified\placeholders.json' @(
  , @('(?m)^([ \t]*)"tin",(?=\r?\n)(?![\s\S]*"titanium")', "`"tin`",`n    `"titanium`",")
) 'Almost Unified merges the two titaniums (one line)'
# 11c. lionel-turbo reads a missing switch as off, and config\lionel-turbo.properties is if-missing, so a player who
#      already has the file would never get a switch added later (2026-10-09: megaCellsCompressionIndex,
#      punchyMappedBonesOnly). Each switch of the shipped file that the player's file does not mention at all is
#      appended with its comment line. A switch the player has, on or off, is never touched.
$turboRel = 'config\lionel-turbo.properties'
$turboShipped = Join-Path $src "if-missing\$turboRel"
if ($manifestMode) {
  $t = @($manifest | Where-Object { $_.Set -eq 'if-missing' -and $_.Rel -eq $turboRel.Replace('\', '/') })
  if ($t.Count) { [void](Get-ManifestFiles @([pscustomobject]@{ Rel = $t[0].Rel; Sha = $t[0].Sha; Size = $t[0].Size; To = $turboShipped })) }
}
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
if ($potato) { $memGb = 8; $memWhy = 'potato mode' }
Write-Host "`nMemory for Minecraft: $memGb GB ($memWhy; this PC has $ramGb GB of RAM)."
if ($potato -or ($fromGame -and -not $env:LIONEL_UPDATER_MEMORY)) { $pick = '' }   # kept: potato mode, or the game is waiting
else {
  Write-Host '  Press Enter to keep it, or type 8, 12 or 16 and press Enter: ' -NoNewline
  $pick = if ($env:LIONEL_UPDATER_MEMORY) { $env:LIONEL_UPDATER_MEMORY } else { [Console]::ReadLine() }
  Write-Host ''
}
if ($pick) { $pick = $pick.Trim().ToUpper().TrimEnd('B').TrimEnd('G').Trim() }
if ($pick -in '8', '12', '16') { $memGb = [int]$pick }
elseif ($pick) { Write-Host "  '$pick' is not 8, 12 or 16: keeping $memGb GB." -ForegroundColor Yellow }
if ($memGb -gt $ramGb - 6) { Write-Host "  Warning: $memGb GB leaves Windows less than 6 GB of this PC's $ramGb GB. Pick a smaller preset if the PC slows down." -ForegroundColor Yellow }
if (-not $potato) { Set-Content -LiteralPath $memSeen -Value $memGb -Encoding UTF8 }   # potato mode keeps the player's own preset for later
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
# 12c. The graphics card (2026-10-21, Lionel: "research any black magic"): on a laptop with a built-in and a dedicated
#      graphics chip, Windows may hand Java the weak built-in one, a large frame-rate loss. Windows' own per-program
#      setting (Settings, Display, Graphics: "High performance") for the Java the launchers are told to use. Per user, no
#      admin; set only when the player has not chosen anything for that Java themselves.
if ($javaOk) {
  $gpuKey = if ($env:LIONEL_UPDATER_GPU_KEY) { $env:LIONEL_UPDATER_GPU_KEY } else { 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' }
  $gpuNow = (Get-ItemProperty -LiteralPath $gpuKey -ErrorAction SilentlyContinue).$javaExe
  if (-not $gpuNow) {
    try {
      if (-not (Test-Path -LiteralPath $gpuKey)) { New-Item -Path $gpuKey -Force | Out-Null }
      New-ItemProperty -LiteralPath $gpuKey -Name $javaExe -Value 'GpuPreference=2;' -PropertyType String -Force | Out-Null
      Write-Change '~' 'Windows graphics setting: the game''s Java uses the high-performance graphics card (Settings, Display, Graphics changes it)'
    } catch { Write-Host '  Could not set the graphics card preference; the game runs as before.' -ForegroundColor Yellow }
  }
}
# 12d. Windows Security exclusion (2026-10-21, Lionel: "sure add the exclusion"): Windows Security scans every mod jar
#      the game opens at each start, ~500 of them, which drags a weak PC's start out further. With the player's yes,
#      the ATM10 folder and the updater's Java folder are excluded (an admin prompt; Windows asks itself). Nothing else.
#      Asked once per ATM10 folder (Enter is no); the answer is kept in defender.txt, so a no is not asked again.
if (-not $fromGame) {
  $defSeen = Join-Path $stateDir 'defender.txt'
  $defLines = if (Test-Path -LiteralPath $defSeen) { @(Get-Content -LiteralPath $defSeen) } else { @() }
  if (-not @($defLines | Where-Object { $_.EndsWith("`t$Target") }).Count) {
    Write-Host "`nWindows Security checks every mod file each time the game starts (about 500 of them), which makes"
    Write-Host 'the start slower, much slower on a weak PC. The updater can tell it to skip two folders:'
    Write-Host "  $Target"
    if ($javaOk) { Write-Host "  $javaHome" }
    Write-Host 'Windows Security will then no longer check those folders for viruses. Windows asks for admin permission.'
    Write-Host '  Add the exclusion? Type Y and press Enter; Enter alone or N skips it (not asked again for this folder): ' -NoNewline
    $answer = if ($env:LIONEL_UPDATER_DEFENDER) { $env:LIONEL_UPDATER_DEFENDER } else { [Console]::ReadLine() }
    Write-Host ''
    $answer = if ($answer) { $answer.Trim().ToUpper() } else { '' }
    $result = 'no'
    if ($answer -in 'Y', 'YES') {
      $paths = @($Target) + $(if ($javaOk) { @($javaHome) } else { @() })
      $cmd = 'Add-MpPreference -ExclusionPath ' + (($paths | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ',') + '; exit $(if ($?) { 0 } else { 1 })'
      if ($env:LIONEL_UPDATER_DEFENDER_DRY) { Set-Content -LiteralPath $env:LIONEL_UPDATER_DEFENDER_DRY -Value $cmd; $ok = $true }
      else {
        try {
          $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
          $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList "-NoProfile -EncodedCommand $enc"
          $ok = ($p.ExitCode -eq 0)
        } catch { $ok = $false }   # the admin prompt was declined
      }
      if ($ok) { $result = 'yes'; Write-Change '~' "Windows Security: $($paths -join ' and ') excluded from scanning" }
      else { $result = ''; Write-Host '  Not added (the admin prompt was declined, or another antivirus is in charge). Asked again next time.' -ForegroundColor Yellow }
    }
    if ($result) { Add-Content -LiteralPath $defSeen -Value "$result`t$Target" -Encoding UTF8 }
  }
}
$javaNote = if ($javaOk) { "Java: $javaExe (Java 21.0.12.1, which the patch needs)." }
  else { 'Java: the launcher''s own (Java 21.0.12.1 could not be downloaded, so the resolver patch is left out: about a minute slower).' }

# 12b. The update check at each start (2026-10-16, Lionel: "prompts the user for an update y/n and if yes it updates
#     then launches the game"): lionel-check.jar (..\lionel-check), which the launcher runs before the game, with no
#     mod loaded. It runs on this Java and needs the jar and a copy of the .bat beside it, and two files in the instance:
#     lionels-updater-check.properties (here) and lionels-updater-version.txt (step 13). The launchers split the command
#     differently: ATLauncher at every space, quotes kept as they are (the folder has no spaces); the Modrinth app like a
#     Unix shell, where a backslash outside quotes is an escape, so there its paths go in single quotes.
$checkFrom = Join-Path $src 'java\lionel-check.jar'
$checkJar = Join-Path $toolDir 'lionel-check.jar'
$stubCopy = Join-Path $toolDir 'updater.bat'
$hookCmd = ''
if ($javaOk -and (Test-Path -LiteralPath $checkFrom) -and $toolDir -notmatch '\s') {
  if (-not (Test-Path -LiteralPath $checkJar) -or -not (Same-File $checkFrom $checkJar)) { Copy-To $checkFrom $checkJar }
  $stubFrom = $env:LIONEL_UPDATER_STUB
  if ($stubFrom -and (Test-Path -LiteralPath $stubFrom) -and $stubFrom -ne $stubCopy) { Copy-To $stubFrom $stubCopy }
  if (Test-Path -LiteralPath $stubCopy) {
    $hookCmd = if ($Launcher -eq 'ATLauncher') { "$javaExe -jar $checkJar" } else { "'$javaExe' -jar '$checkJar'" }
    $checkUrl = if ($env:LIONEL_UPDATER_CHECK_URL) { $env:LIONEL_UPDATER_CHECK_URL } else { 'https://raw.githubusercontent.com/lionelvlv/lionels-updater/main/version.txt' }
    $props = "# Read by lionel-check.jar (the launcher's check before each start) and the title-screen notice. Written by the updater.`r`n" +
      "versionUrl=$checkUrl`r`nstub=$stubCopy`r`nlauncher=$Launcher`r`n"
    [IO.File]::WriteAllText((Join-Path $Target 'lionels-updater-check.properties'), $props, (New-Object System.Text.UTF8Encoding($false)))
  }
}
$hookText = if ($hookCmd) { @"

UPDATE CHECK AT EACH START: before the game starts, the launcher runs a small check (lionel-check.jar, half a second).
When there is a new update it asks; Update now runs this updater, then the game starts. Offline it just starts.
  ATLauncher: written by the updater (Settings > Commands of this instance: Pre-launch command).
  Modrinth app: this instance's Settings > Launch hooks: switch "Custom game launch hooks" on, and in "Pre-launch":
$hookCmd
  (Or once for all instances: the app's Settings > Instance defaults > Launch hooks > Pre-launch hook. But an instance
  with "Custom game launch hooks" switched on ignores that one, even with its boxes empty.)
"@ } else { '' }
$argText = @"
Lionel's Additions: speed setup (fastest start, the same as Lionel's). Written by the updater; run it again to redo it.

ATLAUNCHER: the updater writes these into the instance itself (ATLauncher must be closed while it runs). By hand:
  Instances tab > this instance > Settings > Java/Minecraft:
    Maximum Memory: $memMb MB
    Java Path: $javaHome
    Java Parameters: $argRest

MODRINTH APP: open this instance's Settings, then "Java and memory":
  1. Switch "Custom memory allocation" on and type $memMb in the box right of the slider.
  2. Switch "Custom Java installation" on and put this in its box: $javaExe
  3. Switch "Custom Java arguments" on and replace the box's contents with this ONE line:

$argLine

Memory preset: $memGb GB ($memMb MB) of this PC's $ramGb GB; the updater asks every run (8, 12 or 16 GB).
$javaNote
-XX:-BytecodeVerificationRemote skips Java's re-check of mod code as it loads (25 to 40 s); a broken mod then crashes
less politely. To go back: turn the custom settings off; the launcher uses its own defaults again.
$hookText
"@
$argFile = Join-Path $Target 'LAUNCH-ARGUMENTS.txt'
[IO.File]::WriteAllText($argFile, $argText.Replace("`r`n", "`n").Replace("`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
# What was set up last time, per instance: the Modrinth walk-through is shown again only when something changed.
$argSeen = Join-Path $stateDir 'launch-args.txt'
$argKey = "$Target | $(if ($javaOk) { $javaExe }) | $memMb | $argLine"
$lastKey = if (Test-Path -LiteralPath $argSeen) { (Get-Content -LiteralPath $argSeen -TotalCount 1) } else { '' }
# A picture of the launcher's settings page, its numbered boxes the step numbers of Read-Steps (guide\, shipped in the
# zip and fetched with the updater for a fresh install; the GitHub copy if it is missing). Opened in the PC's own
# picture viewer, only when the player asks for it.
function Show-Guide([string]$name) {
  if ($env:LIONEL_UPDATER_NO_START) { Write-Host '     (picture: not opened in tests)'; return }   # test.ps1
  $local = Join-Path $src "guide\$name"
  $target = if (Test-Path -LiteralPath $local) { $local } else { "https://raw.githubusercontent.com/lionelvlv/lionels-updater/main/guide/$name" }
  try { Start-Process $target; Write-Host '     (The picture opened. Its numbers are these step numbers.)' } catch { Write-Host "     (Could not open it: $target)" }
}

# Steps for the player to do in a launcher, one at a time: "Step 2 of 4", the value under it (already copied), then
# Enter to go on, or P and Enter to see the picture first.
function Read-Steps([object[]]$steps, [string]$picture) {
  Write-Host '  At any step, type P and press Enter to see a picture of the page, numbered like the steps.'
  for ($i = 0; $i -lt $steps.Count; $i++) {
    Write-Host ("`n  Step {0} of {1}: {2}" -f ($i + 1), $steps.Count, $steps[$i][0])
    if ($steps[$i][1]) {
      Write-Host "     $($steps[$i][1])" -ForegroundColor White
      if (-not $env:LIONEL_UPDATER_NO_CLIPBOARD) { try { Set-Clipboard -Value $steps[$i][1]; Write-Host '     (Already copied: just paste.)' } catch { } }
    }
    while ($true) {
      Write-Host '     Press Enter when done (P: picture). ' -NoNewline
      $answer = [Console]::ReadLine()
      if ($answer -and $answer.Trim() -ieq 'P') { Show-Guide $picture; continue }
      break
    }
  }
}

# The Modrinth app's pre-launch hook (12b) is looked for in its own database, read only, the way Find-Packs reads it:
# found, nothing to do; not found, one paste in the app's settings (2026-10-17, Lionel: "add the update checker to the
# updater as well"). Read in 4 MB pieces (app.db can be 90 MB); the hook's text is stored as plain text there.
function Test-ModrinthHook {
  if ($env:LIONEL_UPDATER_MR_HOOK) { return $env:LIONEL_UPDATER_MR_HOOK -eq '1' }   # test.ps1
  $needle = 'lionel-check.jar'
  $latin = [Text.Encoding]::GetEncoding(28591)
  foreach ($db in "$env:APPDATA\ModrinthApp\app.db", "$env:APPDATA\ModrinthApp\app.db-wal") {
    if (-not [IO.File]::Exists($db)) { continue }
    try {
      $fs = [IO.File]::Open($db, 'Open', 'Read', 'ReadWrite, Delete')
      try {
        $buf = New-Object byte[] 4194304
        $tail = ''
        while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
          $chunk = $tail + $latin.GetString($buf, 0, $n)
          if ($chunk.Contains($needle)) { return $true }
          $tail = $chunk.Substring([Math]::Max(0, $chunk.Length - $needle.Length))
        }
      } finally { $fs.Dispose() }
    } catch { }
  }
  $false
}

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
$setupDone = $false
if ($Launcher -eq 'ATLauncher') {
  $atlJson = Join-Path $Target 'instance.json'
  if (-not (Test-Path -LiteralPath $atlJson)) {
    Write-Host "`nThis folder has no instance.json, so it is not an ATLauncher instance: set up the speed settings by hand (LAUNCH-ARGUMENTS.txt in it)." -ForegroundColor Yellow
  } elseif ($fromGame) {
    # ATLauncher is open (it is starting the game) and would write its own copy back: next time by hand, if needed.
    if ($lastKey -ne $argKey) { Write-Host "`nThe speed settings changed: run the updater yourself once, with ATLauncher closed, to set them." -ForegroundColor Yellow }
  } else {
    # The instance's settings as they should be; ATLauncher is closed (by the updater) only when they differ, since it
    # keeps its own copy and would write it back over the new ones.
    $makeNew = {
      $new = Set-JsonKey $json 'javaArguments' (Json-Text $argRest)
      $new = Set-JsonKey $new 'maximumMemory' "$memMb"
      if ($javaOk) { $new = Set-JsonKey $new 'javaPath' (Json-Text $javaHome); $new = Set-JsonKey $new 'useJavaProvidedByMinecraft' 'false' }
      if ($hookCmd) {
        # A pre-launch command of the player's own stays (there is one per instance).
        $prev = [regex]::Match($new, '"preLaunchCommand"\s*:\s*"((?:[^"\\]|\\.)*)"')
        if (-not $prev.Success -or -not $prev.Groups[1].Value -or $prev.Groups[1].Value -match 'lionel-check') {
          $new = Set-JsonKey $new 'enableCommands' 'true'
          $new = Set-JsonKey $new 'preLaunchCommand' (Json-Text $hookCmd)
        } else {
          Write-Host "`nThis instance already has a pre-launch command of its own, so the update check at each start was not added." -ForegroundColor Yellow
        }
      }
      $new
    }
    $json = [IO.File]::ReadAllText($atlJson)
    $new = & $makeNew
    if ($new -cne $json -and -not (Close-ATLauncher)) {
      for ($try = 0; (Test-ATLauncherOpen) -and $try -lt 3; $try++) {
        Write-Host "`nATLauncher is open. Close it completely (its window, and its icon by the clock if there is one), then press Enter here." -ForegroundColor Yellow
        Write-Host '  (It keeps its own copy of the instance settings and would write it back over the new ones.) ' -NoNewline
        if ($null -eq [Console]::ReadLine()) { break }
      }
    }
    if ($new -cne $json -and (Test-ATLauncherOpen)) {
      Write-Host "`nATLauncher stayed open, so its speed settings were not written. Run the updater again with it closed, or" -ForegroundColor Yellow
      Write-Host '  set them by hand: LAUNCH-ARGUMENTS.txt in your ATM10 folder has the steps.' -ForegroundColor Yellow
    } else {
      $json = [IO.File]::ReadAllText($atlJson)   # again: ATLauncher may have saved it as it closed
      $new = & $makeNew
      if ($new -cne $json) {
        if (-not (Test-Path -LiteralPath "$atlJson.bak-lionel")) { Copy-Item -LiteralPath $atlJson "$atlJson.bak-lionel" }
        [IO.File]::WriteAllText($atlJson, $new, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "`nNEW LAUNCH ARGUMENTS written into ATLauncher's settings for this instance:" -ForegroundColor Cyan
        Write-Host "  memory $memMb MB; $(if ($javaOk) { "Java 21.0.12.1 ($javaHome); " })Java arguments: $argRest"
      }
      $setupDone = $true
    }
  }
} elseif ($fromGame) {
  if ($lastKey -ne $argKey) { Write-Host "`nThe speed settings changed: run the updater yourself once to set them (LAUNCH-ARGUMENTS.txt has them)." -ForegroundColor Yellow }
} else {
  # The Modrinth app: one step at a time, each value already copied; P shows a picture of that page whose numbered boxes
  # are these step numbers (guide\, from Lionel's screenshots of 2026-10-17, "the numbers are unintuitive and ... the user
  # has input to view the image"). Labels also checked in modrinth/code, apps/app-frontend.
  if ($lastKey -ne $argKey) {
    $steps = @(, @('Open this ATM10 instance''s Settings in the Modrinth app and click "Java and memory" on the left.', $null))
    $steps += , @('Memory: switch "Custom memory allocation" on, click the number box at the right end of the slider, select all (Ctrl+A) and paste (Ctrl+V):', "$memMb")
    if ($javaOk) { $steps += , @('Java: switch "Custom Java installation" on, click in its box, select all (Ctrl+A) and paste (Ctrl+V):', $javaExe) }
    $steps += , @('Arguments: switch "Custom Java arguments" on, click in its box, select all (Ctrl+A) and paste (Ctrl+V):', $argLine)
    Write-Host "`nSPEED SETTINGS for the Modrinth app, $($steps.Count) steps." -ForegroundColor Cyan
    Read-Steps $steps 'modrinth-java-and-memory.png'
    Write-Host "`n  The same steps are in LAUNCH-ARGUMENTS.txt in your ATM10 folder."
  }
  if ($hookCmd) {
    # In the instance's own Launch hooks: an instance with "Custom game launch hooks" on ignores the app-wide hook even
    # with its boxes empty (Modrinth's run.rs), so this is the place that always works.
    if (Test-ModrinthHook) {
      Write-Host "`nThe update check at each start is set up in the Modrinth app." -ForegroundColor Green
    } else {
      Write-Host "`nUPDATE CHECK AT EACH START for the Modrinth app, 3 steps: it asks `"update now?`" when you press Play and there is an update." -ForegroundColor Cyan
      Read-Steps @(
        @('In this ATM10 instance''s Settings, click "Launch hooks" on the left.', $null),
        @('Switch "Custom game launch hooks" on.', $null),
        @('Click in the "Pre-launch" box, select all (Ctrl+A) and paste (Ctrl+V):', $hookCmd)
      ) 'modrinth-launch-hooks.png'
      if (Test-ModrinthHook) { Write-Host '  Found it: the check is set up.' -ForegroundColor Green }
      else { Write-Host '  Not found in the app yet (it can take a moment to save). If it is pasted, all is well; otherwise the next run asks again.' -ForegroundColor Yellow }
    }
  }
  $setupDone = $true
}
if ($setupDone) { Set-Content -LiteralPath $argSeen -Value $argKey -Encoding UTF8 }

# 13. The stub compares this with the small version file online and skips the big download when they match; the
#     instance's own copy is what the check at each start compares (and the stub, when the check started it).
if (Test-Path -LiteralPath "$src\version.txt") {
  Copy-Item -LiteralPath "$src\version.txt" -Destination (Join-Path $stateDir 'version.txt') -Force
  Copy-Item -LiteralPath "$src\version.txt" -Destination (Join-Path $Target 'lionels-updater-version.txt') -Force
}

Write-Host "`nDone. Added $added, updated $updated, removed $removed, already up to date $unchanged." -ForegroundColor Green
Show-Toast 'Advancement Made!' $(if ($Mode -eq 'fresh') { "Lionel's ATM10, installed ($label)" } else { "Up to date: update $label" })
if ($fromGame) { Write-Host "`nThe game starts now." -ForegroundColor Cyan; exit 0 }
$instanceName = Split-Path -Leaf $(if ((Split-Path -Leaf $Target) -match '^\.?minecraft$') { Split-Path -Parent $Target } else { $Target })
if ($atlMade) { $instanceName = $atlMade }
Write-Host "`nWhat to do now:" -ForegroundColor Cyan
if ($atlReopen -and -not $atlMade) {   # the updater closed it (Close-ATLauncher): open again
  Start-Launcher $launcherExe
  Write-Host '  ATLauncher is opening again.'
}
if ($atlMade) {
  # The instance was written with ATLauncher closed, so the sign-in comes now (Install-AtlInstance).
  Start-Launcher $launcherExe
  Write-Host "  0. ATLauncher is opening. If you have not signed in to Minecraft in it yet:"
  Write-SignInSteps
}
if ($Launcher -eq 'ATLauncher') {
  Write-Host "  1. Open ATLauncher, go to the Instances tab, and click Play on `"$instanceName`"."
  if (-not $setupDone) { Write-Host '     First set its speed settings (ATLauncher was open): see LAUNCH-ARGUMENTS.txt in the ATM10 folder.' }
} else {
  Write-Host "  1. In the Modrinth app, click Play on `"$instanceName`"."
  Write-Host '     If you skipped a speed step above, LAUNCH-ARGUMENTS.txt in the ATM10 folder has all of them.'
}
if ($Mode -eq 'fresh') { Write-Host '     The first start of a new instance takes longer than later ones (5 minutes or more is normal).' }
Write-Host "  2. On the title screen, click `"Join Lionel's Server`" (or turn on Auto-join next to it to join on every start)."
if ($hookCmd) { Write-Host '  3. Next time there is an update, the launcher asks when you press Play (or run this updater again).' }
else { Write-Host '  3. Next time there is an update, just run this updater again.' }
