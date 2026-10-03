$ErrorActionPreference = "Stop"

$ConfigDir = Join-Path $env:LOCALAPPDATA "OWStatsBridge"
$OutputPath = Join-Path $ConfigDir "overlooker-safe-schema.json"
$LogRoot = Join-Path $HOME ".overlooker\logs"
$UuidPattern = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b'

$AllowedFields = @(
    "mcp_match_id", "pseudo_match_id", "match_id", "match", "complete", "submitted",
    "map", "map_code", "mode", "mode_code", "game_type", "queue_type", "role",
    "result", "result_source", "victory", "score", "score_progression", "rounds",
    "hero", "hero_swaps", "hero_tabs", "hero_panels", "hero_bans",
    "kills", "kill", "assists", "assist", "deaths", "death", "eliminations", "elimination",
    "dmg", "damage", "heal", "healing", "mit", "mitigation", "stats",
    "duration_ms", "started_at", "ended_at", "started", "ended",
    "rank_min", "rank_max", "rank_update", "players", "team", "team_side", "local_team",
    "is_local", "is_wide_match", "is_backfill", "joined_at", "left_at"
)
$Allowed = @{}
foreach ($f in $AllowedFields) { $Allowed[$f] = $true }

function Get-ShortHash([string]$Value) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value.ToLowerInvariant())
        $hash = $sha.ComputeHash($bytes)
        $hex = -join ($hash | ForEach-Object { $_.ToString("x2") })
        return $hex.Substring(0, 16)
    } finally { $sha.Dispose() }
}

function Get-BracketDepth([string]$Text, [int]$StopIndex) {
    $depth = 0
    $quote = [char]0
    $escaped = $false
    for ($i = 0; $i -lt $StopIndex -and $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($quote -ne [char]0) {
            if ($escaped) { $escaped = $false; continue }
            if ($ch -eq '\\') { $escaped = $true; continue }
            if ($ch -eq $quote) { $quote = [char]0 }
            continue
        }
        if ($ch -eq '"' -or $ch -eq "'") { $quote = $ch; continue }
        if ($ch -eq '{' -or $ch -eq '[' -or $ch -eq '(') { $depth++ }
        elseif ($ch -eq '}' -or $ch -eq ']' -or $ch -eq ')') { if ($depth -gt 0) { $depth-- } }
    }
    return $depth
}

function Get-ValueType([string]$Text, [int]$StartIndex) {
    if ($StartIndex -ge $Text.Length) { return "unknown" }
    $tail = $Text.Substring($StartIndex).TrimStart()
    if (-not $tail) { return "unknown" }
    if ($tail.StartsWith("{")) { return "object" }
    if ($tail.StartsWith("[")) { return "array" }
    if ($tail.StartsWith("(") ) { return "tuple" }
    if ($tail.StartsWith('"') -or $tail.StartsWith("'")) { return "string" }
    if ($tail -match '^(?i:true|false)\b') { return "bool" }
    if ($tail -match '^(?i:null|none)\b') { return "null" }
    if ($tail -match '^-?\d+(?:\.\d+)?\b') { return "number" }
    if ($tail -match ('^' + $UuidPattern)) { return "uuid" }
    return "identifier"
}

function Get-SchemaTokens([string]$Line) {
    $tokens = New-Object System.Collections.ArrayList
    $patterns = @(
        '"([A-Za-z_][A-Za-z0-9_]*)"\s*:',
        '(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)\s*=',
        '(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)\s*:'
    )
    foreach ($pattern in $patterns) {
        foreach ($m in [regex]::Matches($Line, $pattern)) {
            $name = $m.Groups[1].Value.ToLowerInvariant()
            if (-not $Allowed.ContainsKey($name)) { continue }
            $depth = Get-BracketDepth $Line $m.Index
            $valueStart = $m.Index + $m.Length
            $type = Get-ValueType $Line $valueStart
            $signature = ("{0}:{1}:{2}" -f $depth, $name, $type)
            if (-not $tokens.Contains($signature) -and $tokens.Count -lt 120) {
                [void]$tokens.Add($signature)
            }
        }
    }
    return @($tokens | Sort-Object)
}

New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
$rows = New-Object System.Collections.ArrayList

if (Test-Path $LogRoot) {
    $files = @(Get-ChildItem $LogRoot -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 8)

    foreach ($file in $files) {
        $lines = @(Get-Content $file.FullName -Tail 10000 -ErrorAction SilentlyContinue)
        foreach ($lineObj in $lines) {
            $line = [string]$lineObj
            $uuidMatches = @([regex]::Matches($line, $UuidPattern))
            if ($uuidMatches.Count -eq 0) { continue }
            if ($line -notmatch '(?i)\b(match|result|players|hero|stats|map|rank|submitted|complete)\b') { continue }
            $schema = @(Get-SchemaTokens $line)
            if ($schema.Count -eq 0) { continue }

            foreach ($u in $uuidMatches) {
                [void]$rows.Add([pscustomobject][ordered]@{
                    uuid_hash = Get-ShortHash $u.Value
                    schema = $schema
                })
            }
        }
    }
}

$groups = @()
foreach ($g in ($rows | Group-Object uuid_hash)) {
    $schema = @($g.Group | ForEach-Object { $_.schema } | Sort-Object -Unique)
    $groups += [pscustomobject][ordered]@{
        uuid_hash = [string]$g.Name
        occurrences = [int]$g.Count
        schema = $schema
    }
}

$result = [ordered]@{
    generated_at = [DateTime]::UtcNow.ToString("o")
    log_root_exists = (Test-Path $LogRoot)
    uuid_groups = $groups
    privacy_note = "Local only. Only whitelisted field names, approximate nesting depth and value types are exported. No field values or player names are included."
}
$result | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 $OutputPath

Write-Host ""
Write-Host "OverLooker safe schema diagnostic completed."
Write-Host ("UUID groups: " + $groups.Count)
Write-Host ("Output: " + $OutputPath)
Write-Host ""
foreach ($item in $groups) {
    Write-Host ("UUID hash: " + $item.uuid_hash + "  occurrences=" + $item.occurrences)
    foreach ($s in $item.schema) { Write-Host ("  " + $s) }
    Write-Host ""
}
Write-Host "Only whitelisted field names, depth and value types were exported."
