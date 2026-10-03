$ErrorActionPreference = "Stop"

$BaseDir = Split-Path -Parent $PSCommandPath
$RuntimePath = Join-Path $BaseDir "overlooker_bridge_runtime.ps1"
if (-not (Test-Path $RuntimePath)) { throw "Runtime bridge not found: $RuntimePath" }

$src = Get-Content $RuntimePath -Raw

if ($src -notmatch 'OWStatsUpgradePreserveState') {
    $oldState = @'
    $state = New-State
    $baseline = Initialize-Baseline $state
'@
    $newState = @'
    # OWStatsUpgradePreserveState: first install baselines history; upgrades preserve prior seen state.
    if (Test-Path $StatePath) {
        $state = Load-State
        $baseline = 0
    } else {
        $state = New-State
        $baseline = Initialize-Baseline $state
    }
'@

    $normalized = $src -replace "`r`n", "`n"
    if (-not $normalized.Contains($oldState)) {
        throw "Could not locate installer state initialization block."
    }
    $normalized = $normalized.Replace($oldState, $newState)
    $src = $normalized -replace "`n", "`r`n"
}

if ($src -notmatch 'OWStatsUpgradeRestartExisting') {
    $needle = '    $powershell = (Get-Command powershell.exe).Source'
    $insert = @'
    # OWStatsUpgradeRestartExisting: stop only the previously installed bridge process.
    # The installer itself runs from the extracted package path, so it is not matched here.
    try {
        $installedPattern = [regex]::Escape([string]$InstalledScriptPath)
        foreach ($proc in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)) {
            if ($proc.ProcessId -eq $PID -or -not $proc.CommandLine) { continue }
            if ([string]$proc.CommandLine -match $installedPattern) {
                Stop-Process -Id ([int]$proc.ProcessId) -Force -ErrorAction SilentlyContinue
            }
        }
        Start-Sleep -Milliseconds 700
    } catch {
        Write-BridgeLog ("Upgrade restart warning: " + $_.Exception.Message)
    }

'@
    $idx = $src.IndexOf($needle)
    if ($idx -lt 0) { throw "Could not locate installer autostart block." }
    $src = $src.Substring(0, $idx) + $insert + $src.Substring($idx)
}

if ($src -notmatch 'OWStatsUpgradePreserveState') { throw "Upgrade state preservation verification failed." }
if ($src -notmatch 'OWStatsUpgradeRestartExisting') { throw "Upgrade restart verification failed." }

Set-Content -LiteralPath $RuntimePath -Value $src -Encoding UTF8
Write-Host "Upgrade-safe bridge runtime prepared."
Write-Host "Existing seen-match state will be preserved."
Write-Host "Previous installed bridge process will be restarted onto the new runtime."
