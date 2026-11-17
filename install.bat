@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Chrono setup
cd /d "%~dp0"
echo.
echo  Chrono setup
echo  ============
echo.

for %%F in (chrono.rb chrono_gui.rbw chrono_schedule.rb chrono_eaccess.rb chrono_logins.rb chrono_rewards.rb chrono_lich_passwords.rb chrono_github.rb chrono_cronjob.rb chrono_update.rb chrono_sealedbox.rb chrono_config.rb chrono_helper.lic chrono.ico chrono.png) do (
  if not exist "%%F" (
    echo  ERROR: %%F is missing. Unzip the whole Chrono4Lich folder, then run install.bat from inside it.
    goto :fail
  )
)

rem ---- find the Ruby that runs Lich ----
rem In this order: Ruby4Lich5's "current" folder; its newest version folder (compared as versions);
rem the Ruby that opens .rbw files; the first rubyw.exe on the PATH. Always confirmed below.
set "RUBYW="
if exist "C:\Ruby4Lich5\current\bin\rubyw.exe" set "RUBYW=C:\Ruby4Lich5\current\bin\rubyw.exe"
if not defined RUBYW for /f "delims=" %%R in ('powershell -NoProfile -Command "$best=$null; foreach($x in @(Get-ChildItem -LiteralPath 'C:\Ruby4Lich5' -Directory -ErrorAction SilentlyContinue)){ if($x.Name -match '^[0-9]+([.][0-9]+){1,3}$' -and (Test-Path (Join-Path $x.FullName 'bin\rubyw.exe'))){ if(-not $best -or [version]$x.Name -gt [version]$best.Name){ $best=$x } } }; if($best){ Join-Path $best.FullName 'bin\rubyw.exe' }" 2^>nul') do set "RUBYW=%%R"
if not defined RUBYW for /f "delims=" %%R in ('powershell -NoProfile -Command "$q=[char]34; $c=(Get-ItemProperty -LiteralPath 'Registry::HKEY_CLASSES_ROOT\RubyWFile\shell\open\command' -ErrorAction SilentlyContinue).'(default)'; if($c){ $c=$c.Trim(); if($c.StartsWith($q)){ $p=$c.Substring(1).Split($q)[0] } else { $p=$c.Split(' ')[0] }; if(Test-Path -LiteralPath $p){ $p } }" 2^>nul') do set "RUBYW=%%R"
if not defined RUBYW for /f "delims=" %%R in ('where rubyw.exe 2^>nul') do if not defined RUBYW set "RUBYW=%%R"

if defined RUBYW (
  echo  Found Ruby: !RUBYW!
  set "ANSWER="
  set /p "ANSWER= Use this Ruby? [Y/n] "
  if /i "!ANSWER!"=="n" set "RUBYW="
)

:askruby
if not defined RUBYW (
  echo.
  echo  Paste the full path to rubyw.exe for the Ruby that runs Lich.
  echo  Tip: right-click the shortcut you use to start Lich, choose Properties,
  echo  and copy the first part of the Target box.
  set /p "RUBYW= rubyw.exe path: "
)
if not defined RUBYW goto :askruby
set "RUBYW=!RUBYW:"=!"
set "RUBYW=!RUBYW:ruby.exe=rubyw.exe!"
if not exist "!RUBYW!" (
  echo  ERROR: "!RUBYW!" doesn't exist.
  set "RUBYW="
  goto :askruby
)
for %%P in ("!RUBYW!") do set "RUBYDIR=%%~dpP"
set "RUBY=!RUBYDIR!ruby.exe"
if not exist "!RUBY!" (
  echo  ERROR: there is no ruby.exe next to "!RUBYW!".
  set "RUBYW="
  goto :askruby
)

echo  Checking that this Ruby has GTK, which the window needs. This takes a few seconds...
set "GTKOUT=%TEMP%\chrono-gtk-check.txt"
"!RUBY!" -e "require 'gtk3'" > "!GTKOUT!" 2>&1
if errorlevel 1 (
  echo  ERROR: This Ruby can't load GTK3. It said:
  for /f "usebackq delims=" %%L in ("!GTKOUT!") do echo     %%L
  echo  Use the Ruby that came with Lich, usually C:\Ruby4Lich5\current\bin\rubyw.exe.
  echo  Don't run "gem install gtk3" on Lich's Ruby: it replaces the GTK that Lich itself needs.
  del "!GTKOUT!" >nul 2>&1
  set "RUBYW="
  goto :askruby
)
del "!GTKOUT!" >nul 2>&1
echo  OK.

rem ---- command-line shortcut: chrono.bat ----
> "chrono.bat" (
  echo @echo off
  echo rem Made by install.bat. Runs chrono.rb with the Ruby that runs Lich.
  echo "!RUBY!" "%%~dp0chrono.rb" %%*
)
if errorlevel 1 (
  echo  ERROR: couldn't write chrono.bat in this folder.
  goto :fail
)

rem ---- desktop shortcut ----
set "LS_RUBYW=!RUBYW!"
set "LS_GUI=%~dp0chrono_gui.rbw"
set "LS_ICON=%~dp0chrono.ico"
set "LS_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$q=[char]34; $lnk=Join-Path ([Environment]::GetFolderPath('Desktop')) 'Chrono.lnk'; $s=(New-Object -ComObject WScript.Shell).CreateShortcut($lnk); $s.TargetPath=$env:LS_RUBYW; $s.Arguments=$q+$env:LS_GUI+$q; $s.WorkingDirectory=$env:LS_DIR; $s.Description='Chrono - scheduled Lich logins'; $s.IconLocation=$env:LS_ICON; $s.Save()"
if errorlevel 1 (
  echo  ERROR: couldn't create the desktop shortcut.
  goto :fail
)

rem ---- replace lichsched, Chrono's old name ----
powershell -NoProfile -ExecutionPolicy Bypass -Command "$l=Join-Path ([Environment]::GetFolderPath('Desktop')) 'lichsched.lnk'; if (Test-Path $l) { Remove-Item $l }"
echo  Updating your schedules...
"!RUBY!" "%~dp0chrono.rb" rebuild-tasks >nul 2>&1
if errorlevel 3 (
  echo  NOTE: some characters are still online from lichsched. Type QUIT in the game
  echo        for each one, then open Chrono. Your old schedules are brought over then.
) else if errorlevel 1 (
  echo  WARNING: updating your schedules failed. Open Chrono and click
  echo           "Rebuild scheduled tasks" on the Settings tab to see why.
)

echo.
echo  Done.
echo   - A "Chrono" shortcut is on your desktop.
echo   - The first time it opens, it finds your Lich folder or asks you for it.
echo   - If you move this folder or update Ruby, run install.bat again, then click
echo     "Rebuild scheduled tasks" on the Settings tab.
echo.
set "OPEN="
set /p "OPEN= Open Chrono now? [Y/n] "
if /i not "!OPEN!"=="n" start "" "!RUBYW!" "%~dp0chrono_gui.rbw"
exit /b 0

:fail
echo.
echo  Setup did not finish.
pause
exit /b 1
