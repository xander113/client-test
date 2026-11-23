@echo off
setlocal
pushd "%~dp0" || exit /b 1
if exist "..\..\..\App\script\LuaGenCSNew.inl" (
    del "..\..\..\App\script\LuaGenCSNew.inl" || goto :failed
)

rsc.exe --rscloc "..\rsc.config" --verbose || goto :failed
cd /d "..\..\..\App\script" || goto :failed
if not exist "LuaGenCSNew.inl" goto :failed
if exist "LuaGenCS.inl" (
    fc /b "LuaGenCSNew.inl" "LuaGenCS.inl" >nul
    if errorlevel 2 goto :failed
    if not errorlevel 1 (
        del "LuaGenCSNew.inl" || goto :failed
        popd
        exit /b 0
    )
)

move /y "LuaGenCSNew.inl" "LuaGenCS.inl" >nul || goto :failed
popd
exit /b 0

:failed
echo Failed to generate CoreScripts. >&2
popd
exit /b 1
