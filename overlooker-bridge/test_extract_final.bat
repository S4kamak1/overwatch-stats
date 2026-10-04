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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0apply_competitive_stats_fix.ps1"
if errorlevel 1 (
  echo Failed to prepare competitive repeated-stats handling.
  echo.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0apply_match_type_patch.ps1"
if errorlevel 1 (
  echo Failed to prepare match-type extraction.
  echo.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0apply_utf8_log_patch.ps1"
if errorlevel 1 (
  echo Failed to prepare UTF-8 OverLooker log reading.
  echo.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0apply_hidden_startup_patch.ps1"
if errorlevel 1 (
  echo Failed to prepare hidden startup launcher.
  echo.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0overlooker_bridge_runtime.ps1" -PreviewLatest
echo.
pause
