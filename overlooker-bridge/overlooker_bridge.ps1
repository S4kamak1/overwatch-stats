param([switch]$Install)

$ErrorActionPreference = "Stop"
$ConfigDir = Join-Path $env:LOCALAPPDATA "OWStatsBridge"
$ConfigPath = Join-Path $ConfigDir "config.json"
$StatePath = Join-Path $ConfigDir "state.json"
$LogPath = Join-Path $ConfigDir "bridge.log"
$TaskName = "OWStats-OverLooker-Bridge"
$RecordingRoot = Join-Path $HOME ".overlooker\recordings"
$DefaultEndpoint = "https://overwatch-stats-ingest.vercel.app/api/ingest"
$ScriptSelf = $PSCommandPath

function Write-BridgeLog([string]$Message) {
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    ("[{0}] {1}" -f ([DateTime]::UtcNow.ToString("o")), $Message) | Add-Content -Encoding UTF8 $LogPath
}

function Ensure-Config {
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    if (Test-Path $ConfigPath) { return }

    $endpoint = Read-Host "Cloud endpoint [$DefaultEndpoint]"
    if ([string]::IsNullOrWhiteSpace($endpoint)) { $endpoint = $DefaultEndpoint }
    $secure = Read-Host "OW_INGEST_TOKEN (hidden)" -AsSecureString
    $encrypted = ConvertFrom-SecureString $secure

    [ordered]@{ endpoint = $endpoint; token = $encrypted } |
        ConvertTo-Json | Set-Content -Encoding UTF8 $ConfigPath
}

function Get-Config {
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $secure = ConvertTo-SecureString ([string]$cfg.token)
    $cred = New-Object System.Management.Automation.PSCredential("ow", $secure)
    return [ordered]@{
        endpoint = [string]$cfg.endpoint
        token = $cred.GetNetworkCredential().Password
    }
}

function Get-Shape($Value, [int]$Depth = 0) {
    if ($Depth -ge 4) {
        if ($null -eq $Value) { return "null" }
        return $Value.GetType().Name
    }
    if ($null -eq $Value) { return "null" }

    if ($Value -is [PSCustomObject]) {
        $out = [ordered]@{}
        foreach ($p in ($Value.PSObject.Properties | Sort-Object Name)) {
            $out[$p.Name] = Get-Shape $p.Value ($Depth + 1)
        }
        return $out
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($k in ($Value.Keys | Sort-Object)) {
            $out[$k] = Get-Shape $Value[$k] ($Depth + 1)
        }
        return $out
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @($Value)
        if ($items.Count -eq 0) { return @() }
        return @(Get-Shape $items[0] ($Depth + 1))
    }

    return $Value.GetType().Name
}

function Add-Event([hashtable]$Counts, [hashtable]$Schemas, $Object) {
    if ($null -eq $Object) { return }
    $name = $null
    foreach ($key in @("name", "event", "type", "feature")) {
        $prop = $Object.PSObject.Properties[$key]
        if ($null -ne $prop -and $null -ne $prop.Value -and "$($prop.Value)" -ne "") {
            $name = "$($prop.Value)"
            break
        }
    }
    if (-not $name) { $name = "unknown" }
    if (-not $Counts.ContainsKey($name)) { $Counts[$name] = 0 }
    $Counts[$name]++
    if (-not $Schemas.ContainsKey($name)) { $Schemas[$name] = Get-Shape $Object }
}

function Analyze-Jsonl([string]$Path) {
    $counts = @{}
    $schemas = @{}
    $records = 0
    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if (-not $line) { return }
        try {
            $obj = $line | ConvertFrom-Json
            $records++
            if ($obj.events -is [System.Collections.IEnumerable] -and -not ($obj.events -is [string])) {
                foreach ($evt in @($obj.events)) { Add-Event $counts $schemas $evt }
            } else {
                Add-Event $counts $schemas $obj
            }
        } catch {}
    }
    return [ordered]@{ kind = "jsonl"; records = $records; event_counts = $counts; schema_by_event = $schemas }
}

function Analyze-Json([string]$Path) {
    try {
        $obj = Get-Content $Path -Raw | ConvertFrom-Json
        return [ordered]@{ kind = "json"; schema = Get-Shape $obj }
    } catch {
        return [ordered]@{ kind = "json"; parse_error = $true }
    }
}

function Load-State {
    $out = @{}
    if (Test-Path $StatePath) {
        try {
            $obj = Get-Content $StatePath -Raw | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) {
                $out[$p.Name] = [string]$p.Value
            }
        } catch {}
    }
    return $out
}

function Save-State([hashtable]$State) {
    $State | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $StatePath
}

function Send-Diagnostic([string]$Path, $Analysis) {
    $cfg = Get-Config
    $file = Get-Item $Path
    $relative = $Path.Substring($RecordingRoot.Length).TrimStart("\")
    $payload = [ordered]@{
        kind = "overlooker_recording_diagnostic"
        received_at = [DateTime]::UtcNow.ToString("o")
        diagnostic = [ordered]@{
            file_name = $file.Name
            relative_path = $relative
            size_bytes = $file.Length
            last_write_utc = $file.LastWriteTimeUtc.ToString("o")
            analysis = $Analysis
        }
    }
    $json = $payload | ConvertTo-Json -Depth 20 -Compress
    Invoke-RestMethod -Uri $cfg.endpoint -Method Post -Headers @{ Authorization = ("Bearer " + $cfg.token) } -ContentType "application/json" -Body $json | Out-Null
}

function Install-Bridge {
    Ensure-Config
    $self = $ScriptSelf
    if (-not $self) { throw "Cannot determine script path." }
    $powershell = (Get-Command powershell.exe).Source
    $args = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$self`""
    $action = New-ScheduledTaskAction -Execute $powershell -Argument $args
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description "Privacy-safe OverLooker diagnostic bridge" -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Write-Host ""
    Write-Host "Installed: $TaskName"
    Write-Host "Watching: $RecordingRoot"
    Write-Host "Raw recording values are not uploaded in diagnostic mode."
    return
}

if ($Install) { Install-Bridge; exit }
Ensure-Config
$state = Load-State
Write-BridgeLog "Bridge started. Watching $RecordingRoot"

while ($true) {
    try {
        if (Test-Path $RecordingRoot) {
            $files = Get-ChildItem $RecordingRoot -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq "overwolf.jsonl" -or $_.Extension -eq ".json" }

            foreach ($file in $files) {
                $stamp = "$($file.Length):$($file.LastWriteTimeUtc.Ticks)"
                if ($state[$file.FullName] -eq $stamp) { continue }
                if (([DateTime]::UtcNow - $file.LastWriteTimeUtc).TotalSeconds -lt 5) { continue }

                if ($file.Name -eq "overwolf.jsonl") {
                    $analysis = Analyze-Jsonl $file.FullName
                } else {
                    $analysis = Analyze-Json $file.FullName
                }

                Send-Diagnostic $file.FullName $analysis
                $state[$file.FullName] = $stamp
                Save-State $state
                Write-BridgeLog ("Sent diagnostic for " + $file.FullName)
            }
        }
    } catch {
        Write-BridgeLog ("ERROR: " + $_.Exception.Message)
    }
    Start-Sleep -Seconds 10
}
