$ErrorActionPreference = "Stop"

$BridgePath = Join-Path $PSScriptRoot "overlooker_bridge.ps1"
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

if (-not (Test-Path $BridgePath)) { throw "Bridge script not found." }
if (-not (Test-Path $LogRoot)) { throw "OverLooker log root not found." }

# Load only the bridge variables/functions, never its runtime loop or uploader.
$bridgeSource = Get-Content $BridgePath -Raw
$marker = 'if ($PreviewLatest) { Preview-Latest; exit }'
$markerIndex = $bridgeSource.IndexOf($marker)
if ($markerIndex -lt 0) { throw "Could not isolate bridge parser functions." }
$prelude = $bridgeSource.Substring(0, $markerIndex)
. ([ScriptBlock]::Create($prelude))

$files = @(Get-ChildItem $LogRoot -File -Recurse -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 5)

$rows = @()
foreach ($file in $files) {
    $lines = @(Get-Content $file.FullName -Tail 20000 -ErrorAction SilentlyContinue)
    foreach ($lineObj in $lines) {
        $line = [string]$lineObj
        if ($line -notmatch '(?i)pseudo_match_id' -or $line -notmatch '(?i)is_local' -or $line -notmatch '(?i)result') { continue }

        $pseudo = $null
        $pseudoHash = $null
        $resultNormalized = $null
        $isLocalEntries = @()
        $trueLocalCount = 0
        $localContainer = $null
        $statsContainer = $null
        $converted = $null
        $exceptionType = $null

        try {
            $pseudo = Get-FieldValue $line "pseudo_match_id"
            if ($null -ne $pseudo -and -not [string]::IsNullOrWhiteSpace([string]$pseudo)) {
                $pseudoHash = Get-Sha256Prefix ([string]$pseudo)
            }
        } catch { $exceptionType = $_.Exception.GetType().Name }

        try { $resultNormalized = Normalize-Result (Get-FieldValue $line "result") } catch {
            if (-not $exceptionType) { $exceptionType = $_.Exception.GetType().Name }
        }

        try {
            $isLocalEntries = @(Get-AllFieldEntries $line "is_local")
            $trueLocalCount = @($isLocalEntries | Where-Object { $_.Value -eq $true }).Count
            $localContainer = Get-LocalPlayerContainer $line
            if ($localContainer) { $statsContainer = Get-FieldContainer $localContainer "stats" }
        } catch {
            if (-not $exceptionType) { $exceptionType = $_.Exception.GetType().Name }
        }

        try { $converted = Convert-LineToMatch $line } catch {
            if (-not $exceptionType) { $exceptionType = $_.Exception.GetType().Name }
        }

        $rows += [pscustomobject][ordered]@{
            file = $file.Name
            pseudo_hash = $pseudoHash
            pseudo_present = ($null -ne $pseudo -and -not [string]::IsNullOrWhiteSpace([string]$pseudo))
            result_present = (-not [string]::IsNullOrWhiteSpace([string]$resultNormalized))
            result_normalized = $resultNormalized
            is_local_fields = $isLocalEntries.Count
            is_local_true_fields = $trueLocalCount
            local_container_found = [bool]$localContainer
            stats_container_found = [bool]$statsContainer
            convert_success = ($null -ne $converted)
            converted_match_id = if ($converted) { [string]$converted.match_id } else { $null }
            converted_has_hero = if ($converted) { -not [string]::IsNullOrWhiteSpace([string]$converted.primary_hero) } else { $false }
            converted_has_eliminations = if ($converted) { $null -ne $converted.stats.eliminations } else { $false }
            exception_type = $exceptionType
        }
    }
}

if ($rows.Count -gt 10) { $rows = @($rows | Select-Object -Last 10) }

$out = [ordered]@{
    local_only = $true
    candidates = $rows.Count
    parser_gate_results = $rows
    privacy = "Only hashed pseudo_match_id values, boolean parser-stage results, normalized result labels, and exception type names are shown. No raw log lines or player names are exported."
}

Write-Host ""
Write-Host "Local OverLooker parser-gate diagnostic completed."
$out | ConvertTo-Json -Depth 8
Write-Host ""
Write-Host "Nothing is uploaded."
