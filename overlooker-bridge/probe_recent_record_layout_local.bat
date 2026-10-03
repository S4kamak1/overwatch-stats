@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0probe_recent_record_layout_local.ps1"
echo.
pause
