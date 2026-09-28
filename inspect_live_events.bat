@echo off
setlocal
cd /d "%~dp0"

python inspect_live_events.py
echo.
echo Diagnostic created:
echo data\live\event-diagnostic.json
echo.
echo Attach that file to ChatGPT for the next parser step.
pause
