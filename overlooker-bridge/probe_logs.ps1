$ErrorActionPreference = "Stop"

$ConfigDir = Join-Path $env:LOCALAPPDATA "OWStatsBridge"
$ConfigPath = Join-Path $ConfigDir "log_probe_config.json"
$OutputPath = Join-Path $ConfigDir "overlooker-log-diagnostic.json"
$LogRoot = Join-Path $HOME ".overlooker\logs"
$DefaultEndpoint = "https://overwatch-stats-ingest.vercel.app/api/overlooker-log-diagnostic"
$UuidPattern = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b'
$UrlPattern = 'https?://[^\s"''<>]+'
$Keywords = @(
    "match", "complete", "upload", "saved", "share", "public", "private",
    "api", "graphql", "oauth", "scoreboard", "rank", "result"
)

function Ensure-Config {
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    if (Test-Path $ConfigPath) { return }

    $endpoint = Read-Host "Diagnostic endpoint [$DefaultEndpoint]"
    if ([string]::IsNullOrWhiteSpace($endpoint)) { $endpoint = $DefaultEndpoint }

    $secure = Read-Host "OW_INGEST_TOKEN (hidden)" -AsSecureString
    $encrypted = ConvertFrom-SecureString $secure

    [ordered]@{
        endpoint = $endpoint
        token = $encrypted
    } | ConvertTo-Json | Set-Content -Encoding UTF8 $ConfigPath
}

function Get-Config {
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $secure = ConvertTo-SecureString ([string]$cfg.token)
    $credential = New-Object System.Management.Automation.PSCredential("ow", $secure)
    return [ordered]@{
        endpoint = [string]$cfg.endpoint
        token = $credential.GetNetworkCredential().Password
    }
}

function Get-ShortHash([string]$Value) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value.ToLowerInvariant())
        $hash = $sha.ComputeHash($bytes)
        $hex = -join ($hash | ForEach-Object { $_.ToString("x2") })
        return $hex.Substring(0, 16)
    } finally {
        $sha.Dispose()
    }
}

function Sanitize-FileName([string]$Name) {
    return [regex]::Replace($Name, $UuidPattern, "<uuid>")
}

function Get-UrlRoute([string]$RawUrl) {
    try {
        $trimmed = $RawUrl.TrimEnd('.', ',', ';', ')', ']', '}')
        $uri = [Uri]$trimmed
        if ($uri.Scheme -ne "http" -and $uri.Scheme -ne "https") { return $null }
        return ($uri.Host.ToLowerInvariant() + $uri.AbsolutePath)
    } catch {
        return $null
    }
}

function Add-Unique([System.Collections.ArrayList]$List, $Value, [int]$Limit) {
    if ($null -eq $Value) { return }
    if ($List.Count -ge $Limit) { return }
    if (-not $List.Contains($Value)) { [void]$List.Add($Value) }
}

function Analyze-LogFile($File) {
    $lines = @(Get-Content $File.FullName -Tail 5000 -ErrorAction SilentlyContinue)
    $uuidHashes = New-Object System.Collections.ArrayList
    $urlRoutes = New-Object System.Collections.ArrayList
    $jsonKeySets = New-Object System.Collections.ArrayList
    $keywordCounts = [ordered]@{}
    foreach ($keyword in $Keywords) { $keywordCounts[$keyword] = 0 }
    $uuidCount = 0

    foreach ($lineObj in $lines) {
        $line = [string]$lineObj

        foreach ($match in [regex]::Matches($line, $UuidPattern)) {
            $uuidCount++
            Add-Unique $uuidHashes (Get-ShortHash $match.Value) 50
        }

        foreach ($keyword in $Keywords) {
            if ($line.IndexOf($keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $keywordCounts[$keyword]++
            }
        }

        foreach ($urlMatch in [regex]::Matches($line, $UrlPattern)) {
            $route = Get-UrlRoute $urlMatch.Value
            Add-Unique $urlRoutes $route 80
        }

        $trimmed = $line.Trim()
        if ($trimmed.StartsWith("{") -and $trimmed.EndsWith("}")) {
            try {
                $obj = $trimmed | ConvertFrom-Json
                $keys = @($obj.PSObject.Properties.Name | Sort-Object -Unique | Select-Object -First 40)
                if ($keys.Count -gt 0) {
                    $signature = ($keys -join "|")
                    $already = $false
                    foreach ($existing in $jsonKeySets) {
                        if (($existing -join "|") -eq $signature) { $already = $true; break }
                    }
                    if (-not $already -and $jsonKeySets.Count -lt 40) {
                        [void]$jsonKeySets.Add($keys)
                    }
                }
            } catch {}
        }
    }

    return [ordered]@{
        name = Sanitize-FileName $File.Name
        size_bytes = $File.Length
        modified_utc = $File.LastWriteTimeUtc.ToString("o")
        lines_scanned = $lines.Count
        uuid_count = $uuidCount
        unique_uuid_hashes = @($uuidHashes)
        keyword_counts = $keywordCounts
        url_routes = @($urlRoutes)
        json_key_sets = @($jsonKeySets)
    }
}

Ensure-Config
$cfg = Get-Config
$filesOut = @()

if (Test-Path $LogRoot) {
    $files = @(Get-ChildItem $LogRoot -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 20)

    foreach ($file in $files) {
        $filesOut += Analyze-LogFile $file
    }
}

$diagnostic = [ordered]@{
    generated_at = [DateTime]::UtcNow.ToString("o")
    log_root_exists = (Test-Path $LogRoot)
    files = $filesOut
}

$payload = [ordered]@{ diagnostic = $diagnostic }
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
$payload | ConvertTo-Json -Depth 20 | Set-Content -Encoding UTF8 $OutputPath

$json = $payload | ConvertTo-Json -Depth 20 -Compress
$response = Invoke-RestMethod `
    -Uri $cfg.endpoint `
    -Method Post `
    -Headers @{ Authorization = ("Bearer " + $cfg.token) } `
    -ContentType "application/json" `
    -Body $json

Write-Host ""
Write-Host "OverLooker log diagnostic completed."
Write-Host ("Log root found: " + $diagnostic.log_root_exists)
Write-Host ("Files inspected: " + $filesOut.Count)
Write-Host ("Cloud response: " + ($response | ConvertTo-Json -Compress))
Write-Host ("Local privacy-safe diagnostic: " + $OutputPath)
Write-Host ""
Write-Host "No raw log lines or raw UUID values were uploaded."
