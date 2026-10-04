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

$bridgeSource = Get-Content $BridgePath -Raw
$marker = 'if ($PreviewLatest) { Preview-Latest; exit }'
$markerIndex = $bridgeSource.IndexOf($marker)
if ($markerIndex -lt 0) { throw "Could not isolate bridge parser functions." }
$prelude = $bridgeSource.Substring(0, $markerIndex)
. ([ScriptBlock]::Create($prelude))

function Get-NearestAnchor($Entries, [int]$Index, [string]$Direction) {
    $eligible = if ($Direction -eq 'before') {
        @($Entries | Where-Object { [int]$_.Index -lt $Index } | Sort-Object Index -Descending)
    } else {
        @($Entries | Where-Object { [int]$_.Index -gt $Index } | Sort-Object Index)
    }
    if ($eligible.Count -eq 0) { return $null }
    $e = $eligible[0]
    return [pscustomobject][ordered]@{
        relative_chars = ([int]$e.Index - $Index)
        depth = [int]$e.Depth
        is_local = [bool]$e.Value
    }
}

function Get-NearbyMarkers([string]$Line, [int]$Center, [int]$Radius = 520) {
    $names = @('players','local_team','rounds','hero_tabs','kills','stats','hero','role','is_local','team_side','round','result','ended_at')
    $rows = @()
    foreach ($name in $names) {
        foreach ($m in @(Get-FieldMatches $Line $name)) {
            $rel = [int]$m.Index - $Center
            if ([Math]::Abs($rel) -gt $Radius) { continue }
            $rows += [pscustomobject][ordered]@{
                field = $name
                relative_chars = $rel
                depth = [int]$m.Depth
            }
        }
    }
    return @($rows | Sort-Object relative_chars)
}

$files = @(Get-ChildItem $LogRoot -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '(?i)^updater\.log$' } |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 5)

$records = @()
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

        $allLocalEntries = @(Get-AllFieldEntries $line 'is_local' | Sort-Object Index)
        $sameDepthAnchors = @($allLocalEntries | Where-Object { $_.Depth -eq $depth })
        $statsMatches = @((Get-FieldMatches $line 'stats') | Where-Object { $_.Depth -eq $depth })

        $candidates = @()
        foreach ($sm in $statsMatches) {
            if ($sameDepthAnchors.Count -eq 0) { continue }
            $nearestSameDepth = @($sameDepthAnchors | Sort-Object @{Expression={ [Math]::Abs([int]$_.Index - [int]$sm.Index) }}, Index)[0]
            if ([int]$nearestSameDepth.Index -ne [int]$anchor.Index) { continue }

            $i = [int]$sm.ValueStart
            while ($i -lt $line.Length -and [char]::IsWhiteSpace($line[$i])) { $i++ }
            if ($i -ge $line.Length -or ($line[$i] -ne '{' -and $line[$i] -ne '[' -and $line[$i] -ne '(')) { continue }
            $container = Get-ContainerFromOpen $line $i
            if (-not $container) { continue }

            $stats = [ordered]@{
                k = Get-NumberCandidate $container @('k')
                a = Get-NumberCandidate $container @('a')
                d = Get-NumberCandidate $container @('d')
                dmg = Get-NumberCandidate $container @('dmg')
                heal = Get-NumberCandidate $container @('heal')
                mit = Get-NumberCandidate $container @('mit')
            }

            $center = [int]$sm.Index
            $candidates += [pscustomobject][ordered]@{
                relative_to_local_anchor = ($center - [int]$anchor.Index)
                depth = [int]$sm.Depth
                nearest_is_local_before = Get-NearestAnchor $allLocalEntries $center 'before'
                nearest_is_local_after = Get-NearestAnchor $allLocalEntries $center 'after'
                nearby_structural_markers = Get-NearbyMarkers $line $center
                stats = $stats
            }
        }

        $records += [pscustomobject][ordered]@{
            file = $file.Name
            pseudo_hash = $pseudoHash
            result = Normalize-Result (Get-FieldValue $line 'result')
            local_anchor_depth = $depth
            candidates = $candidates
        }
    }
}

if ($records.Count -gt 4) { $records = @($records | Select-Object -Last 4) }
$out = [ordered]@{
    local_only = $true
    records = $records
    privacy = 'Only hashed pseudo-match IDs, structural field names, relative offsets, bracket depths, is_local booleans, and stats already assigned to the local anchor are shown. No player names, hero names, raw IDs, or raw log text are exported.'
}

Write-Host ""
Write-Host "Local field-topology diagnostic completed."
$out | ConvertTo-Json -Depth 12
Write-Host ""
Write-Host "Nothing is uploaded."
