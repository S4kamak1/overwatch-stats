$ErrorActionPreference = "Stop"

$LogRoot = Join-Path $HOME ".overlooker\logs"
$OutputDir = Join-Path $env:LOCALAPPDATA "OWStatsBridge"
$OutputPath = Join-Path $OutputDir "overlooker-uuid-context.json"
$UuidPattern = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b'
$Keywords = @(
  "match", "complete", "upload", "saved", "share", "public", "private",
  "api", "graphql", "scoreboard", "rank", "result", "victory", "defeat",
  "draw", "hero", "map", "mode", "player", "score", "damage", "healing"
)

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

function Add-Count([hashtable]$Target, [string]$Key) {
  if (-not $Target.ContainsKey($Key)) { $Target[$Key] = 0 }
  $Target[$Key]++
}

function Count-Keywords([string]$Text, [hashtable]$Target) {
  foreach ($keyword in $Keywords) {
    if ($Text.IndexOf($keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
      Add-Count $Target $keyword
    }
  }
}

$contexts = @{}
$files = @()

if (Test-Path $LogRoot) {
  $files = @(Get-ChildItem $LogRoot -File -Recurse -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 5)
}

foreach ($file in $files) {
  $lines = @(Get-Content $file.FullName -Tail 5000 -ErrorAction SilentlyContinue)
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = [string]$lines[$i]
    foreach ($m in [regex]::Matches($line, $UuidPattern)) {
      $hash = Get-ShortHash $m.Value
      if (-not $contexts.ContainsKey($hash)) {
        $contexts[$hash] = @{
          occurrences = 0
          same_line_keywords = @{}
          nearby_keywords = @{}
        }
      }
      $ctx = $contexts[$hash]
      $ctx.occurrences++
      Count-Keywords $line $ctx.same_line_keywords

      $start = [Math]::Max(0, $i - 2)
      $end = [Math]::Min($lines.Count - 1, $i + 2)
      for ($j = $start; $j -le $end; $j++) {
        if ($j -eq $i) { continue }
        Count-Keywords ([string]$lines[$j]) $ctx.nearby_keywords
      }
    }
  }
}

$outContexts = @()
foreach ($hash in @($contexts.Keys | Sort-Object)) {
  $ctx = $contexts[$hash]
  $outContexts += [ordered]@{
    hash = $hash
    occurrences = [int]$ctx.occurrences
    same_line_keywords = $ctx.same_line_keywords
    nearby_keywords = $ctx.nearby_keywords
  }
}

$result = [ordered]@{
  generated_at = [DateTime]::UtcNow.ToString("o")
  log_root_exists = (Test-Path $LogRoot)
  files_scanned = $files.Count
  uuid_contexts = $outContexts
  privacy_note = "Raw log lines and raw UUID values are not included. Only truncated SHA-256 hashes and keyword counts are written."
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$result | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 $OutputPath

Write-Host ""
Write-Host "OverLooker UUID context diagnostic completed."
Write-Host ("Files scanned: " + $files.Count)
Write-Host ("UUID hashes found: " + $outContexts.Count)
Write-Host ("Output: " + $OutputPath)
Write-Host ""
foreach ($item in $outContexts) {
  Write-Host ("UUID hash: " + $item.hash + "  occurrences=" + $item.occurrences)
  Write-Host ("  same-line: " + (($item.same_line_keywords.Keys | Sort-Object) -join ", "))
  Write-Host ("  nearby:    " + (($item.nearby_keywords.Keys | Sort-Object) -join ", "))
}
Write-Host ""
Write-Host "No raw UUID values or raw log lines were exported."
