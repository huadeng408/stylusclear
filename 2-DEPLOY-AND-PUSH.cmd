@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\wsl2-oneclick-finish.ps1" %*
set EXITCODE=%ERRORLEVEL%
if not "%EXITCODE%"=="0" (
    echo [ERROR] Local finish failed with exit code %EXITCODE%.
    pause
)
exit /b %EXITCODE%
