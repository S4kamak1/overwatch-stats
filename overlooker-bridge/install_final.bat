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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0apply_upgrade_safety.ps1"
if errorlevel 1 (
  echo Failed to prepare upgrade-safe bridge runtime.
  echo.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0overlooker_bridge_runtime.ps1" -Install
echo.
pause
