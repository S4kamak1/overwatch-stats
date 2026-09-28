@echo off
setlocal
cd /d "%~dp0"

where python >nul 2>nul
if errorlevel 1 (
  echo Python was not found in PATH.
  echo Install Python 3.12+ or open a terminal where python works.
  pause
  exit /b 1
)

echo Starting Overwatch live event bridge...
echo Keep this window open while playing.
echo.
python local_bridge.py

pause
