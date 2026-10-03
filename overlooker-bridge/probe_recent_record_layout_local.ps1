$ErrorActionPreference = "Stop"

$LogRoot = Join-Path $HOME ".overlooker\logs"
$Window = 12

function Get-Sha256Prefix([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value.Trim().ToLowerInvariant())
        $hash = $sha.ComputeHash($bytes)
        return (-join ($hash | ForEach-Object { $_.ToString("x2") })).Substring(0,16)
    } finally { $sha.Dispose() }
}

function Get-PseudoHash([string]$Line) {
    $uuid = [regex]::Match($Line, '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b')
    if ($uuid.Success) { return Get-Sha256Prefix $uuid.Value }

    $m = [regex]::Match($Line, '(?i)pseudo_match_id\s*[:=]\s*["'']?([^,"''\s}\]]+)')
    if ($m.Success) { return Get-Sha256Prefix $m.Groups[1].Value }
    return $null
}

function Has-Field([string]$Line,[string]$Name) {
    return [regex]::IsMatch($Line, ('(?i)(?:["'']?' + [regex]::Escape($Name) + '["'']?\s*[:=]|\b' + [regex]::Escape($Name) + '\b)'))
}

function Nearest-Offset($Lines,[int]$Index,[string]$Field,[int]$Radius) {
    $best = $null
    for ($d=0; $d -le $Radius; $d++) {
        $offsets = if ($d -eq 0) { @(0) } else { @(-$d,$d) }
        foreach ($off in $offsets) {
            $j = $Index + $off
            if ($j -lt 0 -or $j -ge $Lines.Count) { continue }
            if (Has-Field ([string]$Lines[$j]) $Field) { return $off }
        }
    }
    return $best
}

if (-not (Test-Path $LogRoot)) { throw "OverLooker log root not found." }
$files = @(Get-ChildItem $LogRoot -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '(?i)^updater\.log$' } |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 5)

$fields = @('is_local','result','map','mode','queue_type','duration_ms','players','stats','k','a','d','dmg','heal','mit','hero','role','ended_at','submitted')
$records = @()

foreach ($file in $files) {
    $lines = @(Get-Content $file.FullName -Tail 20000 -ErrorAction SilentlyContinue)
    $indices = @()
    for ($i=0; $i -lt $lines.Count; $i++) {
        if (Has-Field ([string]$lines[$i]) 'pseudo_match_id') { $indices += $i }
    }
    if ($indices.Count -gt 8) { $indices = @($indices | Select-Object -Last 8) }

    foreach ($i in $indices) {
        $line = [string]$lines[$i]
        $offsets = [ordered]@{}
        foreach ($field in $fields) { $offsets[$field] = Nearest-Offset $lines $i $field $Window }

        $sameLineIsLocal = Has-Field $line 'is_local'
        $sameLineResult = Has-Field $line 'result'
        $records += [pscustomobject][ordered]@{
            file = $file.Name
            pseudo_hash = Get-PseudoHash $line
            legacy_single_line_shape = ($sameLineIsLocal -and $sameLineResult)
            nearest_line_offsets = $offsets
        }
    }
}

$out = [ordered]@{
    local_only = $true
    scanned_files = $files.Count
    window_lines = $Window
    pseudo_record_candidates = $records.Count
    records = $records
    privacy = 'Only hashed pseudo-match identifiers, whitelisted field names, and relative line offsets are shown. No raw log lines or player names are exported.'
}

Write-Host ""
Write-Host "Recent OverLooker record-layout diagnostic completed."
$out | ConvertTo-Json -Depth 8
Write-Host ""
Write-Host "Nothing is uploaded."
