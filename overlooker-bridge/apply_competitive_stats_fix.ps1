$ErrorActionPreference = "Stop"

$RuntimePath = Join-Path $PSScriptRoot "overlooker_bridge_runtime.ps1"
if (-not (Test-Path $RuntimePath)) { throw "Runtime bridge not found: $RuntimePath" }

$src = Get-Content $RuntimePath -Raw

if ($src -notmatch 'OWStatsCompetitiveFinalStats') {
    $marker = 'function Convert-SyntheticFieldToken($Value) {'
    $idx = $src.IndexOf($marker)
    if ($idx -lt 0) { throw "Could not locate local-player fallback helper insertion point." }

    $helper = @'
# OWStatsCompetitiveFinalStats: competitive records can carry multiple same-depth
# stats snapshots for the same local player. Select the final complete stats block
# owned by the local player: after is_local=true, before the next player anchor,
# and before the player's same-depth kills container when present.
function Get-LastOwnedFieldContainerAtDepth([string]$Text, [string]$Name, [int]$AnchorIndex, [int]$Depth) {
    $endIndex = $Text.Length

    $nextPlayers = @(Get-AllFieldEntries $Text "is_local" |
        Where-Object { $_.Depth -eq $Depth -and [int]$_.Index -gt $AnchorIndex } |
        Sort-Object Index)
    if ($nextPlayers.Count -gt 0) {
        $endIndex = [int]$nextPlayers[0].Index
    }

    # In both observed normal and competitive player records, the final scoreboard
    # stats precede the same-depth kills object. Treat that as a stronger local bound.
    $killMarkers = @(Get-FieldMatches $Text "kills" |
        Where-Object { $_.Depth -eq $Depth -and [int]$_.Index -gt $AnchorIndex -and [int]$_.Index -lt $endIndex } |
        Sort-Object Index)
    if ($killMarkers.Count -gt 0) {
        $endIndex = [int]$killMarkers[0].Index
    }

    $matches = @(Get-FieldMatches $Text $Name |
        Where-Object { $_.Depth -eq $Depth -and [int]$_.Index -gt $AnchorIndex -and [int]$_.Index -lt $endIndex } |
        Sort-Object Index)

    for ($mi = $matches.Count - 1; $mi -ge 0; $mi--) {
        $m = $matches[$mi]
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

'@
    $src = $src.Substring(0, $idx) + $helper + $src.Substring($idx)

    $oldCall = '$statsContainer = Get-NearestFieldContainerAtDepth $Line "stats" $entry.Index $depth'
    $newCall = '$statsContainer = Get-LastOwnedFieldContainerAtDepth $Line "stats" $entry.Index $depth'
    if (-not $src.Contains($oldCall)) {
        throw "Could not locate fallback stats selection call."
    }
    $src = $src.Replace($oldCall, $newCall)
}

if ($src -notmatch 'OWStatsCompetitiveFinalStats') { throw "Competitive final-stats patch verification failed." }
if ($src -notmatch 'Get-LastOwnedFieldContainerAtDepth \$Line "stats"') { throw "Competitive stats selector wiring verification failed." }

Set-Content -LiteralPath $RuntimePath -Value $src -Encoding UTF8
Write-Host "Competitive/local repeated-stats handling prepared."
Write-Host "Local stats selection: final same-depth block before kills/next player"
