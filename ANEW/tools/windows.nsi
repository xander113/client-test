Unicode True
Name "${TITLE}"
OutFile "${INSTALLER}"
InstallDir "$LOCALAPPDATA\Pot\${TITLE}"
InstallDirRegKey HKCU "Software\Pot\${KEY}" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "${TITLE}"
VIAddVersionKey "FileDescription" "${TITLE} Developer Installer"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "Pot"
Page directory
Page instfiles
UninstPage uninstConfirm
UninstPage instfiles
Section
  SetOutPath "$INSTDIR"
  File /r "${PAYLOAD}/*"
  WriteRegStr HKCU "Software\Pot\${KEY}" "InstallDir" "$INSTDIR"
  CreateDirectory "$SMPROGRAMS\Pot"
  CreateShortcut "$SMPROGRAMS\Pot\${TITLE}.lnk" "$INSTDIR\${TITLE}.exe"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Pot-${KEY}" "DisplayName" "${TITLE}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Pot-${KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Pot-${KEY}" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
SectionEnd
Section "Uninstall"
  Delete "$SMPROGRAMS\Pot\${TITLE}.lnk"
  RMDir "$SMPROGRAMS\Pot"
  !include "${CLEANUP}"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  DeleteRegKey HKCU "Software\Pot\${KEY}"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Pot-${KEY}"
SectionEnd
