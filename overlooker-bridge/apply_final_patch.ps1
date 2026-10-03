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

# Newer OverLooker records can contain bracket-like logger text around the serialized match.
# Use typed bracket matching, then fall back to same-depth local-player field extraction.
if ($src -notmatch 'Get-NearestFieldEntryAtDepth') {
    $start = $src.IndexOf('function Get-EnclosingContainer')
    $end = $src.IndexOf('function Get-ContainerFromOpen', $start)
    if ($start -lt 0 -or $end -lt 0 -or $end -le $start) {
        throw "Could not locate enclosing-container parser for hardening."
    }

    $newEnclosing = @'
function Get-EnclosingContainer([string]$Text, [int]$Index) {
    $stack = New-Object System.Collections.ArrayList
    $quote = [char]0
    $escaped = $false

    for ($i = 0; $i -lt $Index -and $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($quote -ne [char]0) {
            if ($escaped) { $escaped = $false; continue }
            if ([int][char]$ch -eq 92) { $escaped = $true; continue }
            if ($ch -eq $quote) { $quote = [char]0 }
            continue
        }
        if ([int][char]$ch -eq 34 -or [int][char]$ch -eq 39) { $quote = $ch; continue }

        if ($ch -eq '{' -or $ch -eq '[' -or $ch -eq '(') {
            [void]$stack.Add([pscustomobject]@{ Ch = $ch; Index = $i })
            continue
        }

        if ($ch -eq '}' -or $ch -eq ']' -or $ch -eq ')') {
            if ($stack.Count -eq 0) { continue }
            $top = $stack[$stack.Count - 1]
            $expected = if ($top.Ch -eq '{') { '}' } elseif ($top.Ch -eq '[') { ']' } else { ')' }
            if ($ch -eq $expected) { $stack.RemoveAt($stack.Count - 1) }
        }
    }

    if ($stack.Count -eq 0) { return $null }
    for ($s = $stack.Count - 1; $s -ge 0; $s--) {
        $candidate = Get-ContainerFromOpen $Text ([int]$stack[$s].Index)
        if ($candidate) { return $candidate }
    }
    return $null
}

'@
    $src = $src.Substring(0, $start) + $newEnclosing + $src.Substring($end)

    $localStart = $src.IndexOf('function Get-LocalPlayerContainer')
    $localEnd = $src.IndexOf('function Get-NumberCandidate', $localStart)
    if ($localStart -lt 0 -or $localEnd -lt 0 -or $localEnd -le $localStart) {
        throw "Could not locate local-player parser for hardening."
    }

    $newLocal = @'
function Get-NearestFieldEntryAtDepth([string]$Text, [string]$Name, [int]$AnchorIndex, [int]$Depth) {
    $entries = @(Get-AllFieldEntries $Text $Name | Where-Object { $_.Depth -eq $Depth })
    if ($entries.Count -eq 0) { return $null }
    return @($entries | Sort-Object @{ Expression = { [Math]::Abs([int]$_.Index - $AnchorIndex) } }, Index)[0]
}

function Get-NearestFieldContainerAtDepth([string]$Text, [string]$Name, [int]$AnchorIndex, [int]$Depth) {
    $matches = @(Get-FieldMatches $Text $Name | Where-Object { $_.Depth -eq $Depth } |
        Sort-Object @{ Expression = { [Math]::Abs([int]$_.Index - $AnchorIndex) } }, Index)
    foreach ($m in $matches) {
        $i = [int]$m.ValueStart
        while ($i -lt $Text.Length -and [char]::IsWhiteSpace($Text[$i])) { $i++ }
        if ($i -ge $Text.Length) { continue }
        if ($Text[$i] -eq '{' -or $Text[$i] -eq '[' -or $Text[$i] -eq '(') {
            $container = Get-ContainerFromOpen $Text $i
            if ($container) { return $container }
        }
    }
    return $null
}

function Convert-SyntheticFieldToken($Value) {
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [string]) { return (ConvertTo-Json -InputObject ([string]$Value) -Compress) }
    try { return ([Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)) } catch {
        return (ConvertTo-Json -InputObject ([string]$Value) -Compress)
    }
}

function Get-LocalPlayerContainer([string]$Line) {
    foreach ($entry in @(Get-AllFieldEntries $Line "is_local")) {
        if ($entry.Value -ne $true) { continue }

        $container = Get-EnclosingContainer $Line $entry.Index
        if ($container) {
            $trueInside = @((Get-AllFieldEntries $container "is_local") | Where-Object { $_.Value -eq $true }).Count
            if ($trueInside -eq 1 -and (Get-FieldContainer $container "stats")) { return $container }
        }

        # Fallback for a record whose surrounding player object cannot be balanced reliably.
        # Only use fields at the exact same bracket depth as is_local=true, so adjacent players
        # cannot donate their hero/role/stats into the local-player payload.
        $depth = [int]$entry.Depth
        $statsContainer = Get-NearestFieldContainerAtDepth $Line "stats" $entry.Index $depth
        if (-not $statsContainer) { continue }

        $parts = New-Object System.Collections.ArrayList
        [void]$parts.Add('"is_local":true')
        foreach ($field in @('hero','role','team_side')) {
            $near = Get-NearestFieldEntryAtDepth $Line $field $entry.Index $depth
            if ($near) {
                [void]$parts.Add(('"' + $field + '":' + (Convert-SyntheticFieldToken $near.Value)))
            }
        }
        [void]$parts.Add(('"stats":' + $statsContainer))
        return ('{' + ($parts -join ',') + '}')
    }
    return $null
}

'@
    $src = $src.Substring(0, $localStart) + $newLocal + $src.Substring($localEnd)
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
if ($src -notmatch 'Get-NearestFieldEntryAtDepth') {
    throw "Local-player parser hardening verification failed."
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
Write-Host "Local-player parser: typed brackets + same-depth fallback"
Write-Host "Autostart: Task Scheduler with non-admin HKCU fallback"
