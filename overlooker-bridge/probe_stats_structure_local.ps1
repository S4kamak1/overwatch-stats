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

function Get-StatsContainerFromMatch($Text, $Match) {
    $i = [int]$Match.ValueStart
    while ($i -lt $Text.Length -and [char]::IsWhiteSpace($Text[$i])) { $i++ }
    if ($i -ge $Text.Length) { return $null }
    if ($Text[$i] -eq '{' -or $Text[$i] -eq '[' -or $Text[$i] -eq '(') {
        return Get-ContainerFromOpen $Text $i
    }
    return $null
}

function Get-ContainerRangeFromMatch([string]$Text, $Match) {
    $i = [int]$Match.ValueStart
    while ($i -lt $Text.Length -and [char]::IsWhiteSpace($Text[$i])) { $i++ }
    if ($i -ge $Text.Length) { return $null }
    $open = $Text[$i]
    if ($open -eq '{') { $close = '}' }
    elseif ($open -eq '[') { $close = ']' }
    elseif ($open -eq '(') { $close = ')' }
    else { return $null }

    $depth = 0
    $quote = [char]0
    $escaped = $false
    for ($j = $i; $j -lt $Text.Length; $j++) {
        $ch = $Text[$j]
        if ($quote -ne [char]0) {
            if ($escaped) { $escaped = $false; continue }
            if ([int][char]$ch -eq 92) { $escaped = $true; continue }
            if ($ch -eq $quote) { $quote = [char]0 }
            continue
        }
        if ([int][char]$ch -eq 34 -or [int][char]$ch -eq 39) { $quote = $ch; continue }
        if ($ch -eq $open) { $depth++ }
        elseif ($ch -eq $close) {
            $depth--
            if ($depth -eq 0) {
                return [pscustomobject]@{ Start = $i; End = $j }
            }
        }
    }
    return $null
}

function Get-StatsSignature([string]$Container) {
    if (-not $Container) { return $null }
    return [ordered]@{
        k = Get-NumberCandidate $Container @('k')
        a = Get-NumberCandidate $Container @('a')
        d = Get-NumberCandidate $Container @('d')
        dmg = Get-NumberCandidate $Container @('dmg')
        heal = Get-NumberCandidate $Container @('heal')
        mit = Get-NumberCandidate $Container @('mit')
    }
}

function Get-NearestEntry($Entries, [int]$Index) {
    if ($null -eq $Entries -or @($Entries).Count -eq 0) { return $null }
    return @($Entries | Sort-Object @{Expression={ [Math]::Abs([int]$_.Index - $Index) }}, Index)[0]
}

function Get-SectionPath([string]$Text, [int]$Index) {
    $known = @('players','rounds','hero_tabs','local_team')
    $rows = @()
    foreach ($name in $known) {
        foreach ($m in @(Get-FieldMatches $Text $name)) {
            $range = Get-ContainerRangeFromMatch $Text $m
            if ($range -and $Index -ge [int]$range.Start -and $Index -le [int]$range.End) {
                $rows += [pscustomobject]@{
                    name = $name
                    depth = [int]$m.Depth
                    span = ([int]$range.End - [int]$range.Start)
                }
            }
        }
    }
    if ($rows.Count -eq 0) { return @() }
    return @($rows | Sort-Object span -Descending | ForEach-Object { $_.name })
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

        $sameDepthPlayerAnchors = @((Get-AllFieldEntries $line 'is_local') | Where-Object { $_.Depth -eq $depth })
        $sameDepthHeroes = @((Get-AllFieldEntries $line 'hero') | Where-Object { $_.Depth -eq $depth })
        $sameDepthRoles = @((Get-AllFieldEntries $line 'role') | Where-Object { $_.Depth -eq $depth })
        $anchorHero = Get-NearestEntry $sameDepthHeroes ([int]$anchor.Index)
        $anchorRole = Get-NearestEntry $sameDepthRoles ([int]$anchor.Index)
        $statsMatches = @((Get-FieldMatches $line 'stats') | Where-Object { $_.Depth -eq $depth })

        $candidateRows = @()
        foreach ($sm in $statsMatches) {
            $nearestPlayer = Get-NearestEntry $sameDepthPlayerAnchors ([int]$sm.Index)
            if (-not $nearestPlayer -or [int]$nearestPlayer.Index -ne [int]$anchor.Index) { continue }

            $container = Get-StatsContainerFromMatch $line $sm
            if (-not $container) { continue }
            $candHero = Get-NearestEntry $sameDepthHeroes ([int]$sm.Index)
            $candRole = Get-NearestEntry $sameDepthRoles ([int]$sm.Index)

            $candidateRows += [pscustomobject][ordered]@{
                relative_chars = ([int]$sm.Index - [int]$anchor.Index)
                section_path = @(Get-SectionPath $line ([int]$sm.Index))
                nearest_hero_is_anchor_hero = ($anchorHero -and $candHero -and ([int]$anchorHero.Index -eq [int]$candHero.Index))
                nearest_role_is_anchor_role = ($anchorRole -and $candRole -and ([int]$anchorRole.Index -eq [int]$candRole.Index))
                stats = Get-StatsSignature $container
            }
        }

        $anchorOffsets = @()
        foreach ($p in $sameDepthPlayerAnchors) {
            $anchorOffsets += [pscustomobject][ordered]@{
                relative_chars = ([int]$p.Index - [int]$anchor.Index)
                is_local = [bool]$p.Value
            }
        }

        $rows += [pscustomobject][ordered]@{
            file = $file.Name
            pseudo_hash = $pseudoHash
            result = Normalize-Result (Get-FieldValue $line 'result')
            local_anchor_depth = $depth
            local_anchor_section_path = @(Get-SectionPath $line ([int]$anchor.Index))
            same_depth_is_local_offsets = $anchorOffsets
            candidates = $candidateRows
        }
    }
}

if ($rows.Count -gt 6) { $rows = @($rows | Select-Object -Last 6) }
$out = [ordered]@{
    local_only = $true
    records = $rows
    privacy = 'Only hashed pseudo-match IDs, booleans, structural section names, relative character offsets, and stats already assigned to the local anchor are shown. No player names, raw IDs, raw log text, or unassigned stats are exported.'
}

Write-Host ""
Write-Host "Local stats structure diagnostic completed."
$out | ConvertTo-Json -Depth 12
Write-Host ""
Write-Host "Nothing is uploaded."
