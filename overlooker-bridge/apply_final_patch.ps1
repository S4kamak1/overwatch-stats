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
        # Normalize CRLF source before one retry.
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

# Safety checks: fail closed rather than running a partially patched bridge.
if ($src -notmatch '\$elim\s*=\s*Get-NumberCandidate\s+\$statsContainer\s+@\("k"') {
    throw "Eliminations patch verification failed."
}
if ($src -notmatch 'if \(\$Digits -eq 0\) \{ return \[Math\]::Truncate') {
    throw "Score truncation patch verification failed."
}

Set-Content -LiteralPath $RuntimePath -Value $src -Encoding UTF8
Write-Host "Final OverLooker bridge runtime prepared."
Write-Host "Eliminations source: stats.k"
Write-Host "Scoreboard integer display: truncate decimals"
