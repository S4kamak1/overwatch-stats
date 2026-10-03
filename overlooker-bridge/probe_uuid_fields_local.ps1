$ErrorActionPreference = "Stop"

$ConfigDir = Join-Path $env:LOCALAPPDATA "OWStatsBridge"
$OutputPath = Join-Path $ConfigDir "overlooker-uuid-fields.json"
$LogRoot = Join-Path $HOME ".overlooker\logs"
$UuidPattern = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b'
$Keywords = @(
  "match","complete","upload","saved","hero","map","mode","player",
  "rank","result","score","victory","damage","healing","heal","assist",
  "death","elimination","kill","role","duration","time"
)

function Get-ShortHash([string]$Value) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value.ToLowerInvariant())
        $hash = $sha.ComputeHash($bytes)
        $hex = -join ($hash | ForEach-Object { $_.ToString("x2") })
        return $hex.Substring(0, 16)
    } finally { $sha.Dispose() }
}

function Get-Keywords([string]$Text) {
    $found = New-Object System.Collections.ArrayList
    foreach ($k in $Keywords) {
        if ($Text.IndexOf($k, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            [void]$found.Add($k)
        }
    }
    return @($found | Sort-Object -Unique)
}

function Get-FieldNames([string]$Text) {
    $found = New-Object System.Collections.ArrayList
    $patterns = @(
        '"([A-Za-z_][A-Za-z0-9_.-]{1,48})"\s*:',
        '(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_.-]{1,48})\s*=',
        '(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_.-]{1,48})\s*:'
    )
    foreach ($pattern in $patterns) {
        foreach ($m in [regex]::Matches($Text, $pattern)) {
            $name = $m.Groups[1].Value.ToLowerInvariant()
            if ($name.Length -lt 2) { continue }
            if ($name -match '^(http|https|debug|info|warn|error|trace)$') { continue }
            if (-not $found.Contains($name) -and $found.Count -lt 80) {
                [void]$found.Add($name)
            }
        }
    }
    return @($found | Sort-Object -Unique)
}

New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
$rows = @()

if (Test-Path $LogRoot) {
    $files = @(Get-ChildItem $LogRoot -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 8)

    foreach ($file in $files) {
        $lines = @(Get-Content $file.FullName -Tail 8000 -ErrorAction SilentlyContinue)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = [string]$lines[$i]
            $matches = @([regex]::Matches($line, $UuidPattern))
            if ($matches.Count -eq 0) { continue }

            $start = [Math]::Max(0, $i - 2)
            $end = [Math]::Min($lines.Count - 1, $i + 2)
            $window = (($lines[$start..$end] | ForEach-Object { [string]$_ }) -join " ")

            foreach ($m in $matches) {
                $rows += [ordered]@{
                    uuid_hash = Get-ShortHash $m.Value
                    file = [regex]::Replace($file.Name, $UuidPattern, "<uuid>")
                    same_line_keywords = @(Get-Keywords $line)
                    nearby_keywords = @(Get-Keywords $window)
                    same_line_fields = @(Get-FieldNames $line)
                    nearby_fields = @(Get-FieldNames $window)
                }
            }
        }
    }
}

$grouped = @()
foreach ($g in ($rows | Group-Object uuid_hash)) {
    $sameKeys = @($g.Group | ForEach-Object { $_.same_line_keywords } | Sort-Object -Unique)
    $nearKeys = @($g.Group | ForEach-Object { $_.nearby_keywords } | Sort-Object -Unique)
    $sameFields = @($g.Group | ForEach-Object { $_.same_line_fields } | Sort-Object -Unique)
    $nearFields = @($g.Group | ForEach-Object { $_.nearby_fields } | Sort-Object -Unique)
    $grouped += [ordered]@{
        uuid_hash = $g.Name
        occurrences = $g.Count
        same_line_keywords = $sameKeys
        nearby_keywords = $nearKeys
        same_line_fields = $sameFields
        nearby_fields = $nearFields
    }
}

$result = [ordered]@{
    generated_at = [DateTime]::UtcNow.ToString("o")
    log_root_exists = (Test-Path $LogRoot)
    uuid_groups = $grouped
    privacy_note = "Local only. Raw UUIDs, raw log lines and field values are not exported."
}

$result | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 $OutputPath

Write-Host ""
Write-Host "OverLooker UUID field-name diagnostic completed."
Write-Host ("UUID groups: " + $grouped.Count)
Write-Host ("Output: " + $OutputPath)
Write-Host ""
foreach ($item in $grouped) {
    Write-Host ("UUID hash: " + $item.uuid_hash + "  occurrences=" + $item.occurrences)
    Write-Host ("  same-line keywords: " + ($item.same_line_keywords -join ", "))
    Write-Host ("  same-line fields:   " + ($item.same_line_fields -join ", "))
    Write-Host ("  nearby fields:      " + ($item.nearby_fields -join ", "))
}
Write-Host ""
Write-Host "No raw UUID values, raw log lines, player names or field values were exported."
