$ErrorActionPreference = "Stop"

$RunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$RunName = "OWStatsOverLookerApp"

$candidates = @(
    (Join-Path $env:LOCALAPPDATA "Programs\overlooker\overlooker.exe")
)

$running = Get-CimInstance Win32_Process -Filter "Name='overlooker.exe'" -ErrorAction SilentlyContinue |
    Select-Object -First 1

$exePath = $null
if ($running -and $running.ExecutablePath -and (Test-Path -LiteralPath $running.ExecutablePath)) {
    $exePath = $running.ExecutablePath
}

if (-not $exePath) {
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            $exePath = $candidate
            break
        }
    }
}

if (-not $exePath) {
    Write-Warning "OverLooker executable was not found. Bridge installation will continue, but OverLooker app autostart was not configured."
    exit 0
}

New-Item -Path $RunKey -Force | Out-Null
$runCommand = "`"$exePath`""
New-ItemProperty -Path $RunKey -Name $RunName -Value $runCommand -PropertyType String -Force | Out-Null

$alreadyRunning = Get-CimInstance Win32_Process -Filter "Name='overlooker.exe'" -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $alreadyRunning) {
    Start-Process -FilePath $exePath
}

Write-Host "OverLooker app autostart configured."
Write-Host "Executable: $exePath"
Write-Host "Autostart: current-user Run key ($RunName)"
