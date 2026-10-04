$ErrorActionPreference = "Stop"

$RuntimePath = Join-Path $PSScriptRoot "overlooker_bridge_runtime.ps1"
if (-not (Test-Path $RuntimePath)) { throw "Runtime bridge not found: $RuntimePath" }

$src = Get-Content $RuntimePath -Raw

if ($src -notmatch 'OWStatsUtf8LogRead') {
    $old = '$lines = @(Get-Content $File.FullName -Tail 12000 -ErrorAction SilentlyContinue)'
    $new = @'
# OWStatsUtf8LogRead: OverLooker log files are UTF-8. Windows PowerShell 5.1 otherwise
# uses the active ANSI code page for BOM-less text, which can corrupt map names such as Paraíso.
$lines = @(Get-Content $File.FullName -Encoding UTF8 -Tail 12000 -ErrorAction SilentlyContinue)
'@
    if (-not $src.Contains($old)) { throw "Could not locate OverLooker log read line." }
    $src = $src.Replace($old, $new.TrimEnd("`r","`n"))
}

if ($src -notmatch 'OWStatsUtf8LogRead') { throw "UTF-8 log-read patch verification failed." }
if ($src -notmatch 'Get-Content \$File\.FullName -Encoding UTF8 -Tail 12000') { throw "UTF-8 log-read wiring verification failed." }

Set-Content -LiteralPath $RuntimePath -Value $src -Encoding UTF8
Write-Host "UTF-8 OverLooker log reading prepared."
Write-Host "Non-ASCII map names will be preserved when present in the source log."
