@echo off
rem Lionel's Additions updater. Keep this file: run it again whenever there is an update.
rem It checks whether there is a newer update, downloads the update zip, unpacks it, and runs the
rem update.ps1 found inside it. To use a zip you downloaded yourself, drag the zip onto this file.
rem lionels-updater stub (the self-update below checks a downloaded copy for this line)
setlocal
title Lionel's Additions updater

set "DRIVE_ID=1czcjd-xR4lmtCPN5fUlQ1XYYMoG7Z7Oo"
set "VERSION_ID=1B6Y0M7Evhnf-dArbi0-KD2ZICqmMAVZB"
set "STATE=%APPDATA%\lionels-updater"
set "HAVE=%STATE%\version.txt"
set "TEMPPICK=%STATE%\temp-folder.txt"
set "LATEST=%TEMP%\lionels-updater-latest.txt"
set "WORK="
set "RC=1"
rem The download (about 800 MB) and its unpacked copy, with room to spare. A dragged-in zip is only unpacked.
set "NEED_MB=2000"
set "ZIP_URL=https://drive.usercontent.google.com/download?id=%DRIVE_ID%&export=download&confirm=t"
set "VERSION_URL=https://drive.usercontent.google.com/download?id=%VERSION_ID%&export=download&confirm=t"
rem update.ps1 and its companions for a fresh install (publish.ps1 pushes them there)
set "LOGIC_URL=https://raw.githubusercontent.com/lionelvlv/lionels-updater/main"
rem Used by test.ps1 only.
if defined LIONEL_UPDATER_LOGIC_URL set "LOGIC_URL=%LIONEL_UPDATER_LOGIC_URL%"
if defined LIONEL_UPDATER_ZIP_URL set "ZIP_URL=%LIONEL_UPDATER_ZIP_URL%"
if defined LIONEL_UPDATER_VERSION_URL set "VERSION_URL=%LIONEL_UPDATER_VERSION_URL%"

rem Self-update (2026-10-16): when the copy of this file on GitHub differs, it replaces this one and runs in its
rem place, once a run. No answer, or not this updater (an error page), and this copy just carries on.
set "SELF_URL=https://raw.githubusercontent.com/lionelvlv/lionels-updater/main/updater.bat"
if defined LIONEL_UPDATER_SELF_URL set "SELF_URL=%LIONEL_UPDATER_SELF_URL%"
set "SELF=%TEMP%\lionels-updater-self.bat"
if defined LIONEL_UPDATER_SELF_DONE goto :selfdone
if /i "%SELF_URL%"=="none" goto :selfdone
"%SystemRoot%\System32\curl.exe" -L --fail -s -o "%SELF%" "%SELF_URL%"
if errorlevel 1 goto :selfdone
findstr /b /c:"rem lionels-updater stub" "%SELF%" >nul 2>&1
if errorlevel 1 goto :selfdone
fc /b "%SELF%" "%~f0" >nul 2>&1
if not errorlevel 1 goto :selfdone
echo Updating the updater itself...
set "LIONEL_UPDATER_SELF_DONE=1"
rem One line on purpose: cmd has read all of it before the copy changes this file under it.
copy /y "%SELF%" "%~f0" >nul & del /q "%SELF%" & "%~f0" %* & exit /b
:selfdone
if exist "%SELF%" del /q "%SELF%"
rem update.ps1 keeps a copy of this file beside its Java, for the launcher's pre-launch check (lionel-check.jar).
set "LIONEL_UPDATER_STUB=%~f0"
rem Started by that check (2026-10-16): that instance only, update only, and the update it has is its own record.
if defined LIONEL_UPDATER_HOOK set "LIONEL_UPDATER_MODE=update"
if defined LIONEL_UPDATER_HOOK set "HAVE=%LIONEL_UPDATER_HOOK%\lionels-updater-version.txt"

rem Leftovers from a run that was interrupted.
if exist "%TEMP%\lionels-updater" rmdir /s /q "%TEMP%\lionels-updater"
if exist "%LATEST%" del /q "%LATEST%"

set "ZIP=%~1"
if not "%ZIP%"=="" set "NEED_MB=1000"
if not "%ZIP%"=="" goto :space

rem Update or fresh install, asked before anything big is downloaded (2026-10-16): a fresh install needs only the
rem whole pack, and the update only if the pack is older than it (update.ps1 decides). LIONEL_UPDATER_MODE answers it.
if /i "%LIONEL_UPDATER_MODE%"=="fresh" goto :fresh
if /i "%LIONEL_UPDATER_MODE%"=="update" goto :update
echo.
echo What would you like to do?
echo   1) Update the ATM10 you already have
echo   2) Install the whole pack fresh, as a new instance (about 2.6 GB to download)
set "PICKMODE="
set /p "PICKMODE=Type 1 or 2 and press Enter (Enter alone: 1), or Q to stop: "
if /i "%PICKMODE%"=="Q" goto :done
if "%PICKMODE%"=="2" goto :fresh
set "LIONEL_UPDATER_MODE=update"
goto :update

:fresh
set "LIONEL_UPDATER_MODE=fresh"
set "FRESH=1"
rem the whole pack, and the update and its unpacked copy if the pack turns out older
set "NEED_MB=4500"
goto :space

:update
if "%DRIVE_ID%"=="PUT_DRIVE_FILE_ID_HERE" if not defined LIONEL_UPDATER_ZIP_URL (
  echo This updater has not been given its download link yet.
  echo Ask Lionel for the update zip and drag it onto this file.
  goto :done
)

rem Nothing new? Then skip the big download. Any doubt (no record, no answer) means download.
if "%VERSION_ID%"=="PUT_VERSION_FILE_ID_HERE" if not defined LIONEL_UPDATER_VERSION_URL goto :space
if not exist "%HAVE%" goto :space
"%SystemRoot%\System32\curl.exe" -L --fail -s -o "%LATEST%" "%VERSION_URL%"
if errorlevel 1 goto :space
fc /b "%LATEST%" "%HAVE%" >nul 2>&1
if errorlevel 1 goto :space
if defined LIONEL_UPDATER_HOOK goto :hooklatest
echo You already have the latest update.
set "AGAIN="
set /p "AGAIN=Press Enter to close, or type R and press Enter to install it again: "
if /i "%AGAIN%"=="R" goto :space
set "RC=0"
set "QUIET=1"
goto :done

rem The check saw the new update on GitHub before Google Drive has finished uploading it: nothing to get yet.
:hooklatest
echo The new update is still on its way to the download folder. Try again in a few minutes.
echo The game starts now.
"%SystemRoot%\System32\timeout.exe" /t 5 >nul 2>&1
set "RC=0"
set "QUIET=1"
goto :done

rem Where the download goes: Windows' temporary folder, or the folder the player chose last time. If that drive
rem has too little free space, the player pastes or picks another folder (remembered for next time).
:space
set "BASE=%TEMP%"
if exist "%TEMPPICK%" set /p BASE=<"%TEMPPICK%"
if not exist "%BASE%\" set "BASE=%TEMP%"

:checkspace
set "FREE_MB=0"
for /f "delims=" %%F in ('powershell.exe -NoProfile -Command "try { [math]::Floor((New-Object IO.DriveInfo ([IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $env:BASE).Path))).AvailableFreeSpace / 1MB) } catch { 0 }"') do set "FREE_MB=%%F"
if defined LIONEL_UPDATER_TEMP_FREE_MB if /i "%BASE%"=="%TEMP%" set "FREE_MB=%LIONEL_UPDATER_TEMP_FREE_MB%"
if %FREE_MB% GEQ %NEED_MB% goto :work

echo.
echo Not enough free space for the download in %BASE%
echo   %FREE_MB% MB free, about %NEED_MB% MB needed. It is only used during the update and removed afterwards.
echo Paste a folder on a drive with more free space and press Enter,
echo or type P and press Enter to pick one in a window, or just press Enter to stop.
set "PICK="
set /p "PICK=Folder: "
if not defined PICK goto :done
set "PICK=%PICK:"=%"
if /i "%PICK%"=="P" set "PICK="
if not defined PICK for /f "delims=" %%P in ('powershell.exe -NoProfile -STA -Command "Add-Type -AssemblyName System.Windows.Forms; $d = New-Object System.Windows.Forms.FolderBrowserDialog; $d.Description = 'Choose a folder for the updater''s temporary files (about 2 GB, removed afterwards)'; $o = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }; if ($d.ShowDialog($o) -eq 'OK') { $d.SelectedPath }"') do set "PICK=%%P"
if not defined PICK goto :checkspace
if "%PICK:~-1%"=="\" set "PICK=%PICK:~0,-1%"
if not exist "%PICK%\" goto :nofolder
set "BASE=%PICK%"
if not exist "%STATE%" mkdir "%STATE%"
> "%TEMPPICK%" echo %PICK%
goto :checkspace

:nofolder
echo That folder does not exist: %PICK%
goto :checkspace

:work
set "WORK=%BASE%\lionels-updater"
if /i not "%BASE%"=="%TEMP%" echo Temporary files go to %WORK%
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%\files" || goto :done
if not "%ZIP%"=="" goto :unpack
if defined FRESH goto :logic

:download
echo Downloading the latest update...
"%SystemRoot%\System32\curl.exe" -L --fail --progress-bar -o "%WORK%\update.zip.part" "%ZIP_URL%"
if errorlevel 1 goto :baddownload
ren "%WORK%\update.zip.part" update.zip
set "ZIP=%WORK%\update.zip"

:unpack
"%SystemRoot%\System32\tar.exe" -xf "%ZIP%" -C "%WORK%\files" 2>nul
if errorlevel 1 goto :baddownload
if not exist "%WORK%\files\update.ps1" goto :baddownload
goto :run

rem A fresh install: only the updater's own small files, from the GitHub copy publish.ps1 keeps current. The update
rem itself is fetched by update.ps1 if the whole pack turns out older than it.
:logic
echo Getting the updater...
for %%F in (update.ps1 look.ps1 delete.txt optional.txt java/resolver-patch.jar java/lionel-check.jar guide/modrinth-java-and-memory.png guide/modrinth-launch-hooks.png) do (
  "%SystemRoot%\System32\curl.exe" -L --fail -s --create-dirs -o "%WORK%\files\%%F" "%LOGIC_URL%/%%F"
  if errorlevel 1 goto :baddownload
)
findstr /b /c:"# Lionel's Additions updater: the logic." "%WORK%\files\update.ps1" >nul 2>&1
if errorlevel 1 goto :baddownload
set "LIONEL_UPDATER_LATER_ZIP=%ZIP_URL%"
set "LIONEL_UPDATER_LATER_VERSION=%VERSION_URL%"

:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%WORK%\files\update.ps1"
set "RC=%ERRORLEVEL%"
goto :done

:baddownload
echo.
echo The update could not be downloaded or is not a valid zip.
echo Check your internet connection and free disk space, and try again. If it keeps failing, download
echo the zip in your browser and drag it onto this file.

:done
cd /d "%TEMP%"
if exist "%LATEST%" del /q "%LATEST%"
if not defined WORK goto :end
if exist "%WORK%" rmdir /s /q "%WORK%"
if exist "%WORK%" echo Could not remove temporary files in %WORK%
if not exist "%WORK%" if not defined QUIET echo Temporary files removed.

:end
echo.
rem From the launch check, a finished update goes straight on to the game; a failed one waits to be read.
if defined LIONEL_UPDATER_HOOK if "%RC%"=="0" set "QUIET=1"
if defined LIONEL_UPDATER_HOOK if "%RC%"=="0" "%SystemRoot%\System32\timeout.exe" /t 5 2>nul
if not defined QUIET pause
exit /b %RC%
