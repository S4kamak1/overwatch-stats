@echo off
setlocal
powershell -NoProfile -Command "try { $r = Invoke-RestMethod http://127.0.0.1:32145/health -TimeoutSec 3; $r | ConvertTo-Json } catch { Write-Host 'Collector is not running.'; exit 1 }"
echo.
pause
