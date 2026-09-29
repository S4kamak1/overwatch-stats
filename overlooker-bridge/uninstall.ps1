$ErrorActionPreference = "SilentlyContinue"
$TaskName = "OWStats-OverLooker-Bridge"
Stop-ScheduledTask -TaskName $TaskName
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Host "Removed scheduled task: $TaskName"
