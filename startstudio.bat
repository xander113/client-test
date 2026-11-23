@echo off
setlocal
if not exist "%~dp0RobloxStudio\bin\Release\RobloxStudioBeta.exe" (
    echo Build Zbloc Studio with TESTEX.exe first. >&2
    exit /b 1
)
start "Zbloc Studio" /D "%~dp0RobloxStudio\bin\Release" "%~dp0RobloxStudio\bin\Release\RobloxStudioBeta.exe" %*
