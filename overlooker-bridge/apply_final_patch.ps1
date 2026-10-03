$ErrorActionPreference = "Stop"

$BaseDir = Split-Path -Parent $PSCommandPath
$SourcePath = Join-Path $BaseDir "overlooker_bridge.ps1"
$RuntimePath = Join-Path $BaseDir "overlooker_bridge_runtime.ps1"

if (-not (Test-Path $SourcePath)) {
    throw "Base bridge script not found: $SourcePath"
}

$src = Get-Content $SourcePath -Raw

# OverLooker stores the scoreboard eliminations value in stats.k.
if ($src -notmatch '\$elim\s*=\s*Get-NumberCandidate\s+\$statsContainer\s+@\("k"') {
    $oldElim = '$elim = Get-NumberCandidate $statsContainer @("e", "elim", "elims", "eliminations")'
    $newElim = '$elim = Get-NumberCandidate $statsContainer @("k", "e", "elim", "elims", "eliminations")'
    if (-not $src.Contains($oldElim)) {
        throw "Could not find eliminations extraction line to patch."
    }
    $src = $src.Replace($oldElim, $newElim)
}

# OverLooker UI truncates positive scoreboard decimals (for example 5527.27 -> 5527,
# 6448.68 -> 6448). Keep two-decimal derived metrics rounded normally.
if ($src -notmatch 'if \(\$Digits -eq 0\) \{ return \[Math\]::Truncate') {
    $oldRound = @'
function Round-IfNumber($Value, [int]$Digits = 2) {
    if ($null -eq $Value) { return $null }
    try { return [Math]::Round([double]$Value, $Digits) } catch { return $null }
}
'@
    $newRound = @'
function Round-IfNumber($Value, [int]$Digits = 2) {
    if ($null -eq $Value) { return $null }
    try {
        if ($Digits -eq 0) { return [Math]::Truncate([double]$Value) }
        return [Math]::Round([double]$Value, $Digits)
    } catch { return $null }
}
'@
    if (-not $src.Contains($oldRound)) {
        $normalized = $src -replace "`r`n", "`n"
        if (-not $normalized.Contains($oldRound)) {
            throw "Could not find numeric rounding function to patch."
        }
        $normalized = $normalized.Replace($oldRound, $newRound)
        $src = $normalized -replace "`n", "`r`n"
    } else {
        $src = $src.Replace($oldRound, $newRound)
    }
}

# Prefer Task Scheduler, but it can be blocked for standard users by local policy.
# Fall back to the current user's Run key, which needs no administrator rights.
if ($src -notmatch 'OWStatsOverLookerBridge') {
    $oldInstall = @'
    $powershell = (Get-Command powershell.exe).Source
    $args = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstalledScriptPath`""
    $action = New-ScheduledTaskAction -Execute $powershell -Argument $args
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description "Private local-player OverLooker match bridge" -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName

    Write-Host ""
    Write-Host "OverLooker live bridge installed."
    Write-Host ("Watching: " + $LogRoot)
    Write-Host ("Existing complete matches baselined: " + $baseline)
    Write-Host "Only the local player's normalized match stats are uploaded."
    Write-Host "Future completed matches will be sent automatically; Overwatch does not need to be closed."
'@
    $newInstall = @'
    $powershell = (Get-Command powershell.exe).Source
    $args = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstalledScriptPath`""
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $runName = "OWStatsOverLookerBridge"
    $autostartMode = "scheduled-task"

    try {
        $action = New-ScheduledTaskAction -Execute $powershell -Argument $args
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description "Private local-player OverLooker match bridge" -Force -ErrorAction Stop | Out-Null
        Remove-ItemProperty -Path $runKey -Name $runName -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    } catch {
        $autostartMode = "current-user-run-key"
        New-Item -Path $runKey -Force | Out-Null
        $runCommand = "`"$powershell`" $args"
        New-ItemProperty -Path $runKey -Name $runName -Value $runCommand -PropertyType String -Force | Out-Null
        Start-Process -FilePath $powershell -ArgumentList $args -WindowStyle Hidden
        Write-BridgeLog ("Task Scheduler unavailable; installed HKCU Run fallback. Reason=" + $_.Exception.Message)
    }

    Write-Host ""
    Write-Host "OverLooker live bridge installed."
    Write-Host ("Autostart: " + $autostartMode)
    Write-Host ("Watching: " + $LogRoot)
    Write-Host ("Existing complete matches baselined: " + $baseline)
    Write-Host "Only the local player's normalized match stats are uploaded."
    Write-Host "Future completed matches will be sent automatically; Overwatch does not need to be closed."
'@

    $normalized = $src -replace "`r`n", "`n"
    if (-not $normalized.Contains($oldInstall)) {
        throw "Could not find installer block to add non-admin fallback."
    }
    $normalized = $normalized.Replace($oldInstall, $newInstall)
    $src = $normalized -replace "`n", "`r`n"
}

# Prevent duplicate watchers if the installer is run repeatedly.
if ($src -notmatch 'OWStats-OverLooker-Bridge-Mutex') {
    $oldLoopStart = @'
Ensure-Config
$state = Load-State
$memoryStamps = @{}
Write-BridgeLog ("Live bridge started. Watching " + $LogRoot)
'@
    $newLoopStart = @'
Ensure-Config
$bridgeMutex = New-Object System.Threading.Mutex($false, "Local\OWStats-OverLooker-Bridge-Mutex")
if (-not $bridgeMutex.WaitOne(0)) {
    Write-BridgeLog "Another bridge instance is already running; exiting duplicate process."
    exit
}
$state = Load-State
$memoryStamps = @{}
Write-BridgeLog ("Live bridge started. Watching " + $LogRoot)
'@
    $normalized = $src -replace "`r`n", "`n"
    if (-not $normalized.Contains($oldLoopStart)) {
        throw "Could not find runtime loop initialization for duplicate-process guard."
    }
    $normalized = $normalized.Replace($oldLoopStart, $newLoopStart)
    $src = $normalized -replace "`n", "`r`n"
}

# Safety checks: fail closed rather than running a partially patched bridge.
if ($src -notmatch '\$elim\s*=\s*Get-NumberCandidate\s+\$statsContainer\s+@\("k"') {
    throw "Eliminations patch verification failed."
}
if ($src -notmatch 'if \(\$Digits -eq 0\) \{ return \[Math\]::Truncate') {
    throw "Score truncation patch verification failed."
}
if ($src -notmatch 'OWStatsOverLookerBridge') {
    throw "Non-admin autostart fallback verification failed."
}
if ($src -notmatch 'OWStats-OverLooker-Bridge-Mutex') {
    throw "Duplicate-process guard verification failed."
}

Set-Content -LiteralPath $RuntimePath -Value $src -Encoding UTF8
Write-Host "Final OverLooker bridge runtime prepared."
Write-Host "Eliminations source: stats.k"
Write-Host "Scoreboard integer display: truncate decimals"
Write-Host "Autostart: Task Scheduler with non-admin HKCU fallback"
