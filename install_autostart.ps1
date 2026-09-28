$ErrorActionPreference = "Stop"

$Repo = Split-Path -Parent $MyInvocation.MyCommand.Path
$TaskName = "S4kamak1-Overwatch-Live-Collector"

$Python = Get-Command pythonw.exe -ErrorAction SilentlyContinue
if (-not $Python) {
    $Python = Get-Command python.exe -ErrorAction SilentlyContinue
}
if (-not $Python) {
    throw "Python was not found in PATH."
}

$PythonPath = $Python.Source
$ScriptPath = Join-Path $Repo "local_bridge.py"

$Action = New-ScheduledTaskAction -Execute $PythonPath -Argument ('"' + $ScriptPath + '"') -WorkingDirectory $Repo
$Trigger = New-ScheduledTaskTrigger -AtLogOn
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Description "Starts the local Overwatch live match collector at Windows logon." -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host ""
Write-Host "Autostart installed."
Write-Host "Task: $TaskName"
Write-Host "Bridge health: http://127.0.0.1:32145/health"
Write-Host ""
Write-Host "Load the Overwolf development extension once, then normal OW2 launches are enough."
