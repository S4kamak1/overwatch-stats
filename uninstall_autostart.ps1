$ErrorActionPreference = "SilentlyContinue"
$TaskName = "S4kamak1-Overwatch-Live-Collector"
Stop-ScheduledTask -TaskName $TaskName
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Host "Removed scheduled task: $TaskName"
