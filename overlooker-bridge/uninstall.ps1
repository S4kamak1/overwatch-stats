$ErrorActionPreference = "SilentlyContinue"

$TaskName = "OWStats-OverLooker-Bridge"
Stop-ScheduledTask -TaskName $TaskName
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Host "Removed scheduled task: $TaskName"

$RunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
foreach ($RunName in @("OWStatsOverLookerBridge", "OWStatsOverLookerApp")) {
    Remove-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue
    Write-Host "Removed Run-key autostart: $RunName"
}

$ConfigDir = Join-Path $env:LOCALAPPDATA "OWStatsBridge"
$LauncherPath = Join-Path $ConfigDir "start_bridge_hidden.vbs"
Remove-Item -LiteralPath $LauncherPath -Force -ErrorAction SilentlyContinue
Write-Host "Removed hidden bridge launcher if present."
