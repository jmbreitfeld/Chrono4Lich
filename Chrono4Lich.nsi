; Chrono installer (NSIS 3). Build with:  makensis Chrono4Lich.nsi
; Installs for the current user only, so no admin rights are needed.
; Replaces lichsched (Chrono's old name) if it's installed, keeping its schedules.

Unicode true
!define APPNAME   "Chrono"
!define FOLDER    "Chrono4Lich"
!define PUBLISHER "Peggyanne"
!ifndef VERSION   ; the GitHub build passes the release's version with -DVERSION=x.y.z
  !define VERSION "1.6.1"
!endif
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${FOLDER}"
!define APPKEY    "Software\${FOLDER}"
!define OLDKEY    "Software\lichsched"

Name "${APPNAME} ${VERSION}"
OutFile "${FOLDER}-setup-${VERSION}.exe"
InstallDir "$LOCALAPPDATA\${FOLDER}"
InstallDirRegKey HKCU "${APPKEY}" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
BrandingText "${APPNAME} ${VERSION}"
Icon "chrono.ico"
UninstallIcon "chrono.ico"

VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "${APPNAME}"
VIAddVersionKey "FileDescription" "${APPNAME} installer - scheduled Lich5 logins for GemStone IV"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "CompanyName" "${PUBLISHER}"
VIAddVersionKey "LegalCopyright" "Copyright (c) 2026 ${PUBLISHER}. MIT License."

!include "MUI2.nsh"
!include "nsDialogs.nsh"
!include "FileFunc.nsh"
!include "LogicLib.nsh"

Var RubyW
Var RubyDir
Var RubyText

!define MUI_ICON "chrono.ico"
!define MUI_UNICON "chrono.ico"
!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TITLE "Welcome to Chrono"
!define MUI_WELCOMEPAGE_TEXT "Chrono logs your GemStone IV characters in and out through Lich5, by hand or on a schedule.$\r$\n$\r$\nYou need Lich5 installed with its own Ruby (from the Ruby4Lich5 installer), and your characters saved in Lich's login window.$\r$\n$\r$\nIf you have lichsched (Chrono's old name) installed, it's replaced and your schedules are kept.$\r$\n$\r$\nNo admin rights are needed."
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
Page custom RubyPage RubyPageLeave
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_TEXT "Open Chrono now"
!define MUI_FINISHPAGE_RUN_FUNCTION LaunchApp
!define MUI_FINISHPAGE_SHOWREADME "$INSTDIR\README.txt"
!define MUI_FINISHPAGE_SHOWREADME_TEXT "Show the README"
!define MUI_FINISHPAGE_SHOWREADME_NOTCHECKED
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

; ---------- finding Ruby ----------

Function .onInit
  ; Reuse the Ruby picked last time (by Chrono, or by lichsched before it), if it's still there.
  ReadRegStr $RubyW HKCU "${APPKEY}" "RubyW"
  ${If} $RubyW == ""
    ReadRegStr $RubyW HKCU "${OLDKEY}" "RubyW"
  ${EndIf}
  ${If} $RubyW != ""
  ${AndIf} ${FileExists} "$RubyW"
    Return
  ${EndIf}
  StrCpy $RubyW ""
  Call DetectRuby
FunctionEnd

Function DetectRuby
  ${If} ${FileExists} "C:\Ruby4Lich5\bin\rubyw.exe"
    StrCpy $RubyW "C:\Ruby4Lich5\bin\rubyw.exe"
  ${EndIf}
  ; Ruby4Lich5\<version>\bin\rubyw.exe - the last version folder found wins
  FindFirst $0 $1 "C:\Ruby4Lich5\*"
  ${DoWhile} $1 != ""
    ${If} $1 != "."
    ${AndIf} $1 != ".."
    ${AndIf} ${FileExists} "C:\Ruby4Lich5\$1\bin\rubyw.exe"
      StrCpy $RubyW "C:\Ruby4Lich5\$1\bin\rubyw.exe"
    ${EndIf}
    FindNext $0 $1
  ${Loop}
  FindClose $0
  ${If} $RubyW != ""
    Return
  ${EndIf}
  ; any other C:\Ruby* install
  FindFirst $0 $1 "C:\Ruby*"
  ${DoWhile} $1 != ""
    ${If} ${FileExists} "C:\$1\bin\rubyw.exe"
      StrCpy $RubyW "C:\$1\bin\rubyw.exe"
    ${EndIf}
    FindNext $0 $1
  ${Loop}
  FindClose $0
FunctionEnd

Function RubyPage
  !insertmacro MUI_HEADER_TEXT "Ruby for Lich" "Pick the rubyw.exe that runs Lich."
  nsDialogs::Create 1018
  Pop $0
  ${If} $0 == error
    Abort
  ${EndIf}

  ${If} $RubyW != ""
    ${NSD_CreateLabel} 0 0 100% 30u "Chrono runs with the same Ruby as Lich. This one was found on your computer. If it's the one Lich uses, click Next."
  ${Else}
    ${NSD_CreateLabel} 0 0 100% 30u "Chrono couldn't find Lich's Ruby. Click Browse and pick rubyw.exe, usually in C:\Ruby4Lich5\<version>\bin."
  ${EndIf}
  Pop $0

  ${NSD_CreateText} 0 36u 78% 12u "$RubyW"
  Pop $RubyText
  ${NSD_CreateBrowseButton} 80% 35u 20% 14u "Browse..."
  Pop $0
  ${NSD_OnClick} $0 OnBrowseRuby

  ${NSD_CreateLabel} 0 60u 100% 40u "Not sure? Right-click the shortcut you use to start Lich and choose Properties. The first part of the Target box is the Ruby Lich uses."
  Pop $0
  nsDialogs::Show
FunctionEnd

Function OnBrowseRuby
  ${NSD_GetText} $RubyText $1
  nsDialogs::SelectFileDialog open "$1" "rubyw.exe|rubyw.exe|Programs (*.exe)|*.exe"
  Pop $0
  ${If} $0 != ""
    ${NSD_SetText} $RubyText $0
  ${EndIf}
FunctionEnd

Function RubyPageLeave
  ${NSD_GetText} $RubyText $0
  ${If} $0 == ""
    MessageBox MB_ICONEXCLAMATION "Pick the rubyw.exe that runs Lich first."
    Abort
  ${EndIf}
  ${IfNot} ${FileExists} "$0"
    MessageBox MB_ICONEXCLAMATION "This file doesn't exist:$\r$\n$0"
    Abort
  ${EndIf}
  ; Accept ruby.exe or rubyw.exe; use the folder either way.
  ${GetParent} "$0" $RubyDir
  ${IfNot} ${FileExists} "$RubyDir\rubyw.exe"
  ${OrIfNot} ${FileExists} "$RubyDir\ruby.exe"
    MessageBox MB_ICONEXCLAMATION "There's no rubyw.exe and ruby.exe in:$\r$\n$RubyDir$\r$\n$\r$\nPick the rubyw.exe that runs Lich."
    Abort
  ${EndIf}
  StrCpy $RubyW "$RubyDir\rubyw.exe"

  ; The window needs GTK, which Lich's Ruby includes.
  Banner::show /NOUNLOAD "Checking that this Ruby has GTK..."
  nsExec::ExecToStack `"$RubyDir\ruby.exe" -e "require 'gtk3'; print 'ok'"`
  Pop $1
  Pop $2
  Banner::destroy
  ${If} $1 != "0"
    MessageBox MB_ICONEXCLAMATION "This Ruby can't load GTK3, which the Chrono window needs:$\r$\n$RubyDir$\r$\n$\r$\nPick the Ruby that came with Lich, usually under C:\Ruby4Lich5."
    Abort
  ${EndIf}
FunctionEnd

; ---------- replacing lichsched ----------

Function RemoveLichsched
  ReadRegStr $0 HKCU "${OLDKEY}" "InstallDir"
  ${If} $0 == ""
  ${OrIfNot} ${FileExists} "$0\uninstall.exe"
    Return
  ${EndIf}
  DetailPrint "Replacing lichsched (Chrono's old name)..."
  ; keep the Lich folder it had saved
  ${If} ${FileExists} "$0\lichsched_config.json"
  ${AndIfNot} ${FileExists} "$INSTDIR\chrono_config.json"
    CopyFiles /SILENT "$0\lichsched_config.json" "$INSTDIR\chrono_config.json"
  ${EndIf}
  ; Its uninstaller removes its tasks, shortcuts and files. Its schedules stay in Lich's data folder.
  ExecWait `"$0\uninstall.exe" /S _?=$0` $1
  ${If} $1 != "0"
    DetailPrint "lichsched's uninstaller reported a problem ($1); removing what's left."
  ${EndIf}
  Delete "$0\uninstall.exe"
  RMDir "$0"
  Delete "$DESKTOP\lichsched.lnk"
  Delete "$SMPROGRAMS\lichsched\lichsched.lnk"
  Delete "$SMPROGRAMS\lichsched\Uninstall lichsched.lnk"
  RMDir "$SMPROGRAMS\lichsched"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\lichsched"
  DeleteRegKey HKCU "${OLDKEY}"
FunctionEnd

; ---------- install ----------

Section "Install"
  SetOutPath "$INSTDIR"
  Call RemoveLichsched

  File "chrono.rb"
  File "chrono_config.rb"
  File "chrono_schedule.rb"
  File "chrono_eaccess.rb"
  File "chrono_logins.rb"
  File "chrono_rewards.rb"
  File "chrono_lich_passwords.rb"
  File "chrono_github.rb"
  File "chrono_sealedbox.rb"
  File "chrono_gui.rbw"
  File "chrono_helper.lic"
  File "chrono.ico"
  File "chrono.png"
  File "README.txt"
  ; chrono_config.json (the saved Lich folder) is left alone on upgrades.

  ; command-line shortcut
  FileOpen $0 "$INSTDIR\chrono.bat" w
  FileWrite $0 "@echo off$\r$\n"
  FileWrite $0 "rem Made by the Chrono installer. Runs chrono.rb with the Ruby that runs Lich.$\r$\n"
  FileWrite $0 `"$RubyDir\ruby.exe" "%~dp0chrono.rb" %*$\r$\n`
  FileClose $0

  ; shortcuts
  CreateShortCut "$DESKTOP\Chrono.lnk" "$RubyW" `"$INSTDIR\chrono_gui.rbw"` "$INSTDIR\chrono.ico" 0 SW_SHOWNORMAL "" "Chrono - scheduled Lich logins"
  CreateDirectory "$SMPROGRAMS\${FOLDER}"
  CreateShortCut "$SMPROGRAMS\${FOLDER}\Chrono.lnk" "$RubyW" `"$INSTDIR\chrono_gui.rbw"` "$INSTDIR\chrono.ico" 0 SW_SHOWNORMAL "" "Chrono - scheduled Lich logins"
  CreateShortCut "$SMPROGRAMS\${FOLDER}\Uninstall Chrono.lnk" "$INSTDIR\uninstall.exe"

  ; remember choices for upgrades and the uninstaller
  WriteRegStr HKCU "${APPKEY}" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "${APPKEY}" "RubyW" "$RubyW"

  ; Add or remove programs
  WriteUninstaller "$INSTDIR\uninstall.exe"
  WriteRegStr   HKCU "${UNINSTKEY}" "DisplayName" "${APPNAME}"
  WriteRegStr   HKCU "${UNINSTKEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr   HKCU "${UNINSTKEY}" "Publisher" "${PUBLISHER}"
  WriteRegStr   HKCU "${UNINSTKEY}" "DisplayIcon" "$INSTDIR\chrono.ico"
  WriteRegStr   HKCU "${UNINSTKEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr   HKCU "${UNINSTKEY}" "UninstallString" `"$INSTDIR\uninstall.exe"`
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  WriteRegDWORD HKCU "${UNINSTKEY}" "EstimatedSize" $0

  ; Point schedules at the new files and Ruby. This also carries over lichsched's schedules.
  DetailPrint "Updating your schedules..."
  nsExec::ExecToLog `"$RubyDir\ruby.exe" "$INSTDIR\chrono.rb" rebuild-tasks`
  Pop $0
  ${If} $0 == "3"
    MessageBox MB_ICONINFORMATION "Some characters are still online from lichsched, Chrono's old version, so Chrono can't log them out.$\r$\n$\r$\nType QUIT in the game for each one, then open Chrono. Your old schedules are brought over then."
  ${ElseIf} $0 != "0"
    MessageBox MB_ICONEXCLAMATION "Chrono is installed, but updating your schedules failed.$\r$\n$\r$\nOpen Chrono and click 'Rebuild scheduled tasks' on the Settings tab. If that fails too, the error will say why."
  ${EndIf}
SectionEnd

Function LaunchApp
  Exec `"$RubyW" "$INSTDIR\chrono_gui.rbw"`
FunctionEnd

; ---------- uninstall ----------

Section "Uninstall"
  ReadRegStr $0 HKCU "${APPKEY}" "RubyW"
  ${GetParent} "$0" $1
  ${If} ${FileExists} "$1\ruby.exe"
    DetailPrint "Removing scheduled tasks..."
    nsExec::ExecToLog `"$1\ruby.exe" "$INSTDIR\chrono.rb" remove-tasks`
    Pop $2
    ${If} $2 != "0"
      MessageBox MB_ICONEXCLAMATION "Couldn't remove Chrono's scheduled tasks. Open Task Scheduler and delete the '${FOLDER}' folder by hand." /SD IDOK
    ${EndIf}
  ${Else}
    MessageBox MB_ICONEXCLAMATION "Lich's Ruby wasn't found, so Chrono's scheduled tasks couldn't be removed. Open Task Scheduler and delete the '${FOLDER}' folder by hand." /SD IDOK
  ${EndIf}

  Delete "$INSTDIR\chrono.rb"
  Delete "$INSTDIR\chrono_config.rb"
  Delete "$INSTDIR\chrono_schedule.rb"
  Delete "$INSTDIR\chrono_eaccess.rb"
  Delete "$INSTDIR\chrono_logins.rb"
  Delete "$INSTDIR\chrono_rewards.rb"
  Delete "$INSTDIR\chrono_lich_passwords.rb"
  Delete "$INSTDIR\chrono_github.rb"
  Delete "$INSTDIR\chrono_sealedbox.rb"
  Delete "$INSTDIR\chrono_gui.rbw"
  Delete "$INSTDIR\chrono_helper.lic"
  Delete "$INSTDIR\chrono.ico"
  Delete "$INSTDIR\chrono.png"
  Delete "$INSTDIR\README.txt"
  Delete "$INSTDIR\chrono.bat"
  Delete "$INSTDIR\chrono_config.json"
  Delete "$INSTDIR\chrono.log"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"

  Delete "$DESKTOP\Chrono.lnk"
  Delete "$SMPROGRAMS\${FOLDER}\Chrono.lnk"
  Delete "$SMPROGRAMS\${FOLDER}\Uninstall Chrono.lnk"
  RMDir "$SMPROGRAMS\${FOLDER}"

  DeleteRegKey HKCU "${UNINSTKEY}"
  DeleteRegKey HKCU "${APPKEY}"
SectionEnd
