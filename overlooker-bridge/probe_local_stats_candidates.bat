@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0apply_final_patch.ps1"
if errorlevel 1 (
  echo Failed to prepare finalized bridge runtime.
  echo.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0probe_local_stats_candidates.ps1"
echo.
pause
