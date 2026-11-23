@echo off
setlocal
if not exist "%~dp0WindowsClient\Win32\Release\RobloxPlayerBeta.exe" (
    echo Build Zbloc Player with TESTEX.exe first. >&2
    exit /b 1
)
start "Zbloc Player" /D "%~dp0WindowsClient\Win32\Release" "%~dp0WindowsClient\Win32\Release\RobloxPlayerBeta.exe" %*
