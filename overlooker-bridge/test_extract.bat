@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0overlooker_bridge.ps1" -PreviewLatest
echo.
pause
