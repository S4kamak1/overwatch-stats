$ErrorActionPreference = "Stop"

$BridgePath = Join-Path $PSScriptRoot "overlooker_bridge_runtime.ps1"
$LogRoot = Join-Path $HOME ".overlooker\logs"

function Get-Sha256Prefix([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value.Trim())
        $hash = $sha.ComputeHash($bytes)
        return (-join ($hash | ForEach-Object { $_.ToString("x2") })).Substring(0,16)
    } finally { $sha.Dispose() }
}

if (-not (Test-Path $BridgePath)) { throw "Prepared bridge runtime not found. Run apply_final_patch.ps1 first." }
if (-not (Test-Path $LogRoot)) { throw "OverLooker log root not found." }

# Load parser functions only; do not start the bridge or upload anything.
$bridgeSource = Get-Content $BridgePath -Raw
$marker = 'if ($PreviewLatest) { Preview-Latest; exit }'
$markerIndex = $bridgeSource.IndexOf($marker)
if ($markerIndex -lt 0) { throw "Could not isolate bridge parser functions." }
$prelude = $bridgeSource.Substring(0, $markerIndex)
. ([ScriptBlock]::Create($prelude))

function Get-StatsContainerFromMatch($Text, $Match) {
    $i = [int]$Match.ValueStart
    while ($i -lt $Text.Length -and [char]::IsWhiteSpace($Text[$i])) { $i++ }
    if ($i -ge $Text.Length) { return $null }
    if ($Text[$i] -eq '{' -or $Text[$i] -eq '[' -or $Text[$i] -eq '(') {
        return Get-ContainerFromOpen $Text $i
    }
    return $null
}

function Get-OwnStatsSignature([string]$Container) {
    if (-not $Container) { return $null }
    $vals = [ordered]@{
        k = Get-NumberCandidate $Container @('k')
        a = Get-NumberCandidate $Container @('a')
        d = Get-NumberCandidate $Container @('d')
        dmg = Get-NumberCandidate $Container @('dmg')
        heal = Get-NumberCandidate $Container @('heal')
        mit = Get-NumberCandidate $Container @('mit')
    }
    $present = 0
    $nonzero = 0
    foreach ($name in @('k','a','d','dmg','heal','mit')) {
        $v = $vals[$name]
        if ($null -ne $v) {
            $present++
            if ([Math]::Abs([double]$v) -gt 0.0000001) { $nonzero++ }
        }
    }
    return [pscustomobject][ordered]@{
        values = $vals
        present_fields = $present
        nonzero_fields = $nonzero
    }
}

$files = @(Get-ChildItem $LogRoot -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '(?i)^updater\.log$' } |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 5)

$rows = @()
foreach ($file in $files) {
    $lines = @(Get-Content $file.FullName -Tail 20000 -ErrorAction SilentlyContinue)
    foreach ($lineObj in $lines) {
        $line = [string]$lineObj
        if ($line -notmatch '(?i)pseudo_match_id' -or $line -notmatch '(?i)is_local' -or $line -notmatch '(?i)result') { continue }

        $pseudo = Get-FieldValue $line 'pseudo_match_id'
        if ($null -eq $pseudo -or [string]::IsNullOrWhiteSpace([string]$pseudo)) { continue }
        $pseudoHash = Get-Sha256Prefix ([string]$pseudo)

        $trueEntries = @((Get-AllFieldEntries $line 'is_local') | Where-Object { $_.Value -eq $true })
        if ($trueEntries.Count -ne 1) { continue }
        $anchor = $trueEntries[0]
        $depth = [int]$anchor.Depth

        # Privacy boundary: a stats field is considered local only when the nearest is_local
        # field at the same parser depth is the single is_local=true anchor.
        $sameDepthPlayerAnchors = @((Get-AllFieldEntries $line 'is_local') | Where-Object { $_.Depth -eq $depth })
        $statsMatches = @((Get-FieldMatches $line 'stats') | Where-Object { $_.Depth -eq $depth })

        $localCandidates = @()
        foreach ($sm in $statsMatches) {
            if ($sameDepthPlayerAnchors.Count -eq 0) { continue }
            $nearest = @($sameDepthPlayerAnchors | Sort-Object @{Expression={ [Math]::Abs([int]$_.Index - [int]$sm.Index) }}, Index)[0]
            if ([int]$nearest.Index -ne [int]$anchor.Index) { continue }

            $container = Get-StatsContainerFromMatch $line $sm
            if (-not $container) { continue }
            $sig = Get-OwnStatsSignature $container
            if (-not $sig) { continue }

            $localCandidates += [pscustomobject][ordered]@{
                relative_chars = ([int]$sm.Index - [int]$anchor.Index)
                depth = [int]$sm.Depth
                currently_nearest = $false
                present_fields = $sig.present_fields
                nonzero_fields = $sig.nonzero_fields
                stats = $sig.values
            }
        }

        if ($localCandidates.Count -gt 0) {
            $nearestIndex = 0
            $nearestDistance = [double]::PositiveInfinity
            for ($ci = 0; $ci -lt $localCandidates.Count; $ci++) {
                $dist = [Math]::Abs([int]$localCandidates[$ci].relative_chars)
                if ($dist -lt $nearestDistance) { $nearestDistance = $dist; $nearestIndex = $ci }
            }
            $localCandidates[$nearestIndex].currently_nearest = $true
        }

        $rows += [pscustomobject][ordered]@{
            file = $file.Name
            pseudo_hash = $pseudoHash
            result = Normalize-Result (Get-FieldValue $line 'result')
            local_anchor_depth = $depth
            local_stats_candidates = $localCandidates.Count
            candidates = $localCandidates
        }
    }
}

if ($rows.Count -gt 6) { $rows = @($rows | Select-Object -Last 6) }
$out = [ordered]@{
    local_only = $true
    records = $rows
    privacy = 'Stats values are shown only for stats containers whose nearest same-depth is_local field is the single local-player anchor. No other player names, IDs, raw lines, or unassigned stats are exported.'
}

Write-Host ""
Write-Host "Local-player stats-candidate diagnostic completed."
$out | ConvertTo-Json -Depth 10
Write-Host ""
Write-Host "Nothing is uploaded."
