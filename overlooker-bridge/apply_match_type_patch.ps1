$ErrorActionPreference = "Stop"

$RuntimePath = Join-Path $PSScriptRoot "overlooker_bridge_runtime.ps1"
if (-not (Test-Path $RuntimePath)) { throw "Runtime bridge not found: $RuntimePath" }

$src = Get-Content $RuntimePath -Raw

if ($src -notmatch 'OWStatsMatchTypeClassification') {
    $marker = 'function Round-IfNumber($Value, [int]$Digits = 2) {'
    $idx = $src.IndexOf($marker)
    if ($idx -lt 0) { throw "Could not locate match-type helper insertion point." }

    $helper = @'
# OWStatsMatchTypeClassification: preserve OverLooker's game_type and also normalize
# it into the two categories used by analysis. Unknown/future values remain "unknown"
# rather than being guessed from queue_type (ROLE_QUEUE exists in both modes).
function Normalize-MatchType($Value) {
    if ($null -eq $Value) { return "unknown" }
    $s = ([string]$Value).Trim().ToLowerInvariant()
    if (-not $s) { return "unknown" }

    if ($s -match 'competitive|ranked|comp') { return "competitive" }
    if ($s -match 'quick.?play|unranked|casual|quick') { return "unranked" }
    return "unknown"
}

'@
    $src = $src.Substring(0, $idx) + $helper + $src.Substring($idx)

    $old = '        queue_type = Get-FieldValue $Line "queue_type"'
    $new = @'
        game_type = Get-FieldValue $Line "game_type"
        match_type = Normalize-MatchType (Get-FieldValue $Line "game_type")
        queue_type = Get-FieldValue $Line "queue_type"
'@
    if (-not $src.Contains($old)) { throw "Could not locate normalized match output queue_type field." }
    $src = $src.Replace($old, $new.TrimEnd("`r","`n"))
}

if ($src -notmatch 'OWStatsMatchTypeClassification') { throw "Match type helper verification failed." }
if ($src -notmatch 'match_type = Normalize-MatchType') { throw "Match type output wiring verification failed." }

Set-Content -LiteralPath $RuntimePath -Value $src -Encoding UTF8
Write-Host "Match-type extraction prepared."
Write-Host "Game type: preserved from OverLooker game_type"
Write-Host "Match type: competitive / unranked / unknown"
