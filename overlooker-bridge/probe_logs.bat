@echo off
setlocal
cd /d "%~dp0"

echo OverLooker log diagnostic
echo --------------------------
echo This sends only sanitized structure information.
echo Raw log lines, BattleTags, raw UUIDs and query strings are not uploaded.
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0probe_logs.ps1"

echo.
pause
