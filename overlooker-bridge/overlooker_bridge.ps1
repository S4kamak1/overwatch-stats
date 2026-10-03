param(
    [switch]$Install,
    [switch]$PreviewLatest,
    [switch]$RunOnce
)

$ErrorActionPreference = "Stop"

$ConfigDir = Join-Path $env:LOCALAPPDATA "OWStatsBridge"
$ConfigPath = Join-Path $ConfigDir "live_config.json"
$ProbeConfigPath = Join-Path $ConfigDir "log_probe_config.json"
$StatePath = Join-Path $ConfigDir "live_state.json"
$BridgeLogPath = Join-Path $ConfigDir "bridge.log"
$InstalledScriptPath = Join-Path $ConfigDir "overlooker_bridge.ps1"
$TaskName = "OWStats-OverLooker-Bridge"
$LogRoot = Join-Path $HOME ".overlooker\logs"
$Endpoint = "https://overwatch-stats-ingest.vercel.app/api/ingest"
$ScriptSelf = $PSCommandPath

function Write-BridgeLog([string]$Message) {
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    ("[{0}] {1}" -f ([DateTime]::UtcNow.ToString("o")), $Message) | Add-Content -Encoding UTF8 $BridgeLogPath
}

function Get-Sha256Hex([string]$Value) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        $hash = $sha.ComputeHash($bytes)
        return (-join ($hash | ForEach-Object { $_.ToString("x2") }))
    } finally {
        $sha.Dispose()
    }
}

function Save-TokenConfig {
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    $secure = Read-Host "OW_INGEST_TOKEN (hidden)" -AsSecureString
    $encrypted = ConvertFrom-SecureString $secure
    [ordered]@{ token = $encrypted } | ConvertTo-Json | Set-Content -Encoding UTF8 $ConfigPath
}

function Ensure-Config {
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null

    if (Test-Path $ConfigPath) {
        try {
            $existing = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            if ($existing.token) { return }
        } catch {}
    }

    # Reuse the token that already succeeded in probe_logs.bat, when available.
    if (Test-Path $ProbeConfigPath) {
        try {
            $probe = Get-Content $ProbeConfigPath -Raw | ConvertFrom-Json
            if ($probe.token) {
                [ordered]@{ token = [string]$probe.token } | ConvertTo-Json | Set-Content -Encoding UTF8 $ConfigPath
                return
            }
        } catch {}
    }

    Save-TokenConfig
}

function Get-Config {
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $secure = ConvertTo-SecureString ([string]$cfg.token)
    $cred = New-Object System.Management.Automation.PSCredential("ow", $secure)
    return [ordered]@{
        endpoint = $Endpoint
        token = $cred.GetNetworkCredential().Password
    }
}

function Get-BracketDepth([string]$Text, [int]$StopIndex) {
    $depth = 0
    $quote = [char]0
    $escaped = $false
    for ($i = 0; $i -lt $StopIndex -and $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($quote -ne [char]0) {
            if ($escaped) { $escaped = $false; continue }
            if ([int][char]$ch -eq 92) { $escaped = $true; continue }
            if ($ch -eq $quote) { $quote = [char]0 }
            continue
        }
        if ([int][char]$ch -eq 34 -or [int][char]$ch -eq 39) { $quote = $ch; continue }
        if ($ch -eq '{' -or $ch -eq '[' -or $ch -eq '(') { $depth++ }
        elseif ($ch -eq '}' -or $ch -eq ']' -or $ch -eq ')') { if ($depth -gt 0) { $depth-- } }
    }
    return $depth
}

function Get-FieldMatches([string]$Text, [string]$Name) {
    $escaped = [regex]::Escape($Name)
    $patterns = @(
        ('(?i)"' + $escaped + '"\s*[:=]\s*'),
        ('(?i)(?<![A-Za-z0-9_])' + $escaped + '\s*[:=]\s*')
    )
    $rows = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($pattern in $patterns) {
        foreach ($m in [regex]::Matches($Text, $pattern)) {
            if ($seen.ContainsKey([string]$m.Index)) { continue }
            $seen[[string]$m.Index] = $true
            [void]$rows.Add([pscustomobject]@{
                Index = [int]$m.Index
                ValueStart = [int]($m.Index + $m.Length)
                Depth = [int](Get-BracketDepth $Text $m.Index)
            })
        }
    }
    return @($rows | Sort-Object Depth, Index)
}

function Read-Token([string]$Text, [int]$StartIndex) {
    $i = $StartIndex
    while ($i -lt $Text.Length -and [char]::IsWhiteSpace($Text[$i])) { $i++ }
    if ($i -ge $Text.Length) { return $null }

    $first = $Text[$i]
    if ([int][char]$first -eq 34 -or [int][char]$first -eq 39) {
        $quote = $first
        $sb = New-Object System.Text.StringBuilder
        $escaped = $false
        for ($j = $i + 1; $j -lt $Text.Length; $j++) {
            $ch = $Text[$j]
            if ($escaped) {
                [void]$sb.Append($ch)
                $escaped = $false
                continue
            }
            if ([int][char]$ch -eq 92) {
                $escaped = $true
                continue
            }
            if ($ch -eq $quote) {
                return $sb.ToString()
            }
            [void]$sb.Append($ch)
        }
        return $sb.ToString()
    }

    $start = $i
    while ($i -lt $Text.Length) {
        $ch = $Text[$i]
        if ([char]::IsWhiteSpace($ch) -or $ch -eq ',' -or $ch -eq '}' -or $ch -eq ']' -or $ch -eq ')') { break }
        $i++
    }
    if ($i -le $start) { return $null }
    return $Text.Substring($start, $i - $start)
}

function Convert-TokenValue($Token) {
    if ($null -eq $Token) { return $null }
    $s = ([string]$Token).Trim()
    if (-not $s) { return $null }
    if ($s -match '^(?i:true)$') { return $true }
    if ($s -match '^(?i:false)$') { return $false }
    if ($s -match '^(?i:null|none)$') { return $null }
    if ($s -match '^-?\d+$') {
        try { return [long]$s } catch {}
    }
    if ($s -match '^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$') {
        try { return [double]::Parse($s, [Globalization.CultureInfo]::InvariantCulture) } catch {}
    }
    return $s
}

function Get-AllFieldEntries([string]$Text, [string]$Name) {
    $out = @()
    foreach ($m in @(Get-FieldMatches $Text $Name)) {
        $raw = Read-Token $Text $m.ValueStart
        $out += [pscustomobject]@{
            Index = $m.Index
            ValueStart = $m.ValueStart
            Depth = $m.Depth
            Value = Convert-TokenValue $raw
        }
    }
    return $out
}

function Get-FieldEntry([string]$Text, [string]$Name) {
    $entries = @(Get-AllFieldEntries $Text $Name)
    if ($entries.Count -eq 0) { return $null }
    return $entries[0]
}

function Get-FieldValue([string]$Text, [string]$Name) {
    $entry = Get-FieldEntry $Text $Name
    if ($null -eq $entry) { return $null }
    return $entry.Value
}

function Get-EnclosingContainer([string]$Text, [int]$Index) {
    $stack = New-Object System.Collections.ArrayList
    $quote = [char]0
    $escaped = $false

    for ($i = 0; $i -lt $Index -and $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($quote -ne [char]0) {
            if ($escaped) { $escaped = $false; continue }
            if ([int][char]$ch -eq 92) { $escaped = $true; continue }
            if ($ch -eq $quote) { $quote = [char]0 }
            continue
        }
        if ([int][char]$ch -eq 34 -or [int][char]$ch -eq 39) { $quote = $ch; continue }

        if ($ch -eq '{' -or $ch -eq '[' -or $ch -eq '(') {
            [void]$stack.Add([pscustomobject]@{ Ch = $ch; Index = $i })
        } elseif ($ch -eq '}' -or $ch -eq ']' -or $ch -eq ')') {
            if ($stack.Count -gt 0) { $stack.RemoveAt($stack.Count - 1) }
        }
    }

    if ($stack.Count -eq 0) { return $null }
    $open = $stack[$stack.Count - 1]
    return Get-ContainerFromOpen $Text ([int]$open.Index)
}

function Get-ContainerFromOpen([string]$Text, [int]$OpenIndex) {
    if ($OpenIndex -lt 0 -or $OpenIndex -ge $Text.Length) { return $null }
    $open = $Text[$OpenIndex]
    $close = $null
    if ($open -eq '{') { $close = '}' }
    elseif ($open -eq '[') { $close = ']' }
    elseif ($open -eq '(') { $close = ')' }
    else { return $null }

    $depth = 0
    $quote = [char]0
    $escaped = $false
    for ($i = $OpenIndex; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
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
            if ($depth -eq 0) { return $Text.Substring($OpenIndex, $i - $OpenIndex + 1) }
        }
    }
    return $null
}

function Get-FieldContainer([string]$Text, [string]$Name) {
    foreach ($m in @(Get-FieldMatches $Text $Name)) {
        $i = $m.ValueStart
        while ($i -lt $Text.Length -and [char]::IsWhiteSpace($Text[$i])) { $i++ }
        if ($i -ge $Text.Length) { continue }
        if ($Text[$i] -eq '{' -or $Text[$i] -eq '[' -or $Text[$i] -eq '(') {
            $container = Get-ContainerFromOpen $Text $i
            if ($container) { return $container }
        }
    }
    return $null
}

function Get-LocalPlayerContainer([string]$Line) {
    foreach ($entry in @(Get-AllFieldEntries $Line "is_local")) {
        if ($entry.Value -eq $true) {
            $container = Get-EnclosingContainer $Line $entry.Index
            if ($container) { return $container }
        }
    }
    return $null
}

function Get-NumberCandidate([string]$Text, [string[]]$Names) {
    foreach ($name in $Names) {
        $value = Get-FieldValue $Text $name
        if ($null -eq $value) { continue }
        try { return [double]$value } catch {}
    }
    return $null
}

function Normalize-Result($Value) {
    if ($null -eq $Value) { return $null }
    $s = ([string]$Value).Trim().ToLowerInvariant()
    if ($s -in @("win", "won", "victory")) { return "win" }
    if ($s -in @("loss", "lost", "defeat")) { return "loss" }
    if ($s -in @("draw", "tie")) { return "draw" }
    if (-not $s) { return $null }
    return $s
}

function Round-IfNumber($Value, [int]$Digits = 2) {
    if ($null -eq $Value) { return $null }
    try { return [Math]::Round([double]$Value, $Digits) } catch { return $null }
}

function Convert-LineToMatch([string]$Line) {
    if ($Line -notmatch '(?i)pseudo_match_id' -or $Line -notmatch '(?i)is_local' -or $Line -notmatch '(?i)result') { return $null }

    $pseudo = Get-FieldValue $Line "pseudo_match_id"
    if ($null -eq $pseudo -or -not ([string]$pseudo).Trim()) { return $null }

    $result = Normalize-Result (Get-FieldValue $Line "result")
    if (-not $result) { return $null }

    $local = Get-LocalPlayerContainer $Line
    if (-not $local) { return $null }

    $statsContainer = Get-FieldContainer $local "stats"
    if (-not $statsContainer) { $statsContainer = $local }

    $hero = Get-FieldValue $local "hero"
    $role = Get-FieldValue $local "role"
    $side = Get-FieldValue $local "team_side"

    $elim = Get-NumberCandidate $statsContainer @("e", "elim", "elims", "eliminations")
    $assist = Get-NumberCandidate $statsContainer @("a", "assist", "assists")
    $death = Get-NumberCandidate $statsContainer @("d", "death", "deaths")
    $damage = Get-NumberCandidate $statsContainer @("dmg", "damage")
    $healing = Get-NumberCandidate $statsContainer @("heal", "healing")
    $mitigation = Get-NumberCandidate $statsContainer @("mit", "mitigation")

    $durationMs = Get-NumberCandidate $Line @("duration_ms")
    $durationSeconds = $null
    if ($null -ne $durationMs -and $durationMs -gt 0) { $durationSeconds = $durationMs / 1000.0 }

    $kda = $null
    if ($null -ne $elim -or $null -ne $assist) {
        $ea = 0.0
        if ($null -ne $elim) { $ea += $elim }
        if ($null -ne $assist) { $ea += $assist }
        if ($null -ne $death -and $death -gt 0) { $kda = $ea / $death }
        elseif ($ea -gt 0) { $kda = $ea }
    }

    $per10 = [ordered]@{
        eliminations = $null
        assists = $null
        deaths = $null
        damage = $null
        healing = $null
        mitigation = $null
    }
    if ($null -ne $durationSeconds -and $durationSeconds -gt 0) {
        $scale = 600.0 / $durationSeconds
        if ($null -ne $elim) { $per10.eliminations = Round-IfNumber ($elim * $scale) }
        if ($null -ne $assist) { $per10.assists = Round-IfNumber ($assist * $scale) }
        if ($null -ne $death) { $per10.deaths = Round-IfNumber ($death * $scale) }
        if ($null -ne $damage) { $per10.damage = Round-IfNumber ($damage * $scale) }
        if ($null -ne $healing) { $per10.healing = Round-IfNumber ($healing * $scale) }
        if ($null -ne $mitigation) { $per10.mitigation = Round-IfNumber ($mitigation * $scale) }
    }

    $idHash = Get-Sha256Hex ([string]$pseudo)
    $matchId = "ol-" + $idHash.Substring(0, 24)

    $heroText = if ($null -ne $hero) { ([string]$hero).Trim().ToLowerInvariant() } else { $null }
    $roleText = if ($null -ne $role) { ([string]$role).Trim().ToLowerInvariant() } else { $null }
    $sideText = if ($null -ne $side) { ([string]$side).Trim().ToLowerInvariant() } else { $null }

    $heroes = @()
    if ($heroText) { $heroes = @($heroText) }

    return [pscustomobject][ordered]@{
        match_id = $matchId
        source = "overlooker-local-log"
        captured_at = [DateTime]::UtcNow.ToString("o")
        result = $result
        map = Get-FieldValue $Line "map"
        mode = Get-FieldValue $Line "mode"
        queue_type = Get-FieldValue $Line "queue_type"
        side = $sideText
        duration_ms = Round-IfNumber $durationMs 0
        duration_seconds = Round-IfNumber $durationSeconds 2
        role = $roleText
        primary_hero = $heroText
        heroes = $heroes
        stats = [ordered]@{
            eliminations = Round-IfNumber $elim 0
            assists = Round-IfNumber $assist 0
            deaths = Round-IfNumber $death 0
            damage = Round-IfNumber $damage 0
            healing = Round-IfNumber $healing 0
            mitigation = Round-IfNumber $mitigation 0
        }
        kda = Round-IfNumber $kda 2
        per_10_minutes = $per10
        privacy = "local-player-only"
    }
}

function Get-RecentLogFiles {
    if (-not (Test-Path $LogRoot)) { return @() }
    return @(Get-ChildItem $LogRoot -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 8)
}

function Get-MatchesFromFile($File) {
    $matches = @()
    $lines = @(Get-Content $File.FullName -Tail 12000 -ErrorAction SilentlyContinue)
    foreach ($lineObj in $lines) {
        $line = [string]$lineObj
        try {
            $match = Convert-LineToMatch $line
            if ($null -ne $match) { $matches += $match }
        } catch {}
    }
    return $matches
}

function New-State {
    return @{
        seen_matches = @{}
        initialized_at = [DateTime]::UtcNow.ToString("o")
    }
}

function Load-State {
    $state = New-State
    if (-not (Test-Path $StatePath)) { return $state }
    try {
        $obj = Get-Content $StatePath -Raw | ConvertFrom-Json
        if ($obj.initialized_at) { $state.initialized_at = [string]$obj.initialized_at }
        if ($obj.seen_matches) {
            foreach ($p in $obj.seen_matches.PSObject.Properties) {
                $state.seen_matches[$p.Name] = $true
            }
        }
    } catch {}
    return $state
}

function Save-State($State) {
    $payload = [ordered]@{
        version = 2
        initialized_at = $State.initialized_at
        seen_matches = $State.seen_matches
    }
    $payload | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $StatePath
}

function Initialize-Baseline($State) {
    $count = 0
    foreach ($file in @(Get-RecentLogFiles | Sort-Object LastWriteTimeUtc)) {
        foreach ($match in @(Get-MatchesFromFile $file)) {
            if (-not $State.seen_matches.ContainsKey([string]$match.match_id)) {
                $State.seen_matches[[string]$match.match_id] = $true
                $count++
            }
        }
    }
    Save-State $State
    return $count
}

function Send-Match($Match) {
    $cfg = Get-Config
    $payload = [ordered]@{
        kind = "normalized_match"
        received_at = [DateTime]::UtcNow.ToString("o")
        match = $Match
    }
    $jsonBody = $payload | ConvertTo-Json -Depth 12 -Compress
    return Invoke-RestMethod -Uri $cfg.endpoint -Method Post -Headers @{ Authorization = ("Bearer " + $cfg.token) } -ContentType "application/json" -Body $jsonBody
}

function Preview-Latest {
    $latest = $null
    foreach ($file in @(Get-RecentLogFiles | Sort-Object LastWriteTimeUtc)) {
        foreach ($match in @(Get-MatchesFromFile $file)) { $latest = $match }
    }
    Write-Host ""
    if ($null -eq $latest) {
        Write-Host "No complete local-player match object was found yet."
        return
    }
    Write-Host "Latest local-player match extracted successfully:"
    $latest | ConvertTo-Json -Depth 10
    Write-Host ""
    Write-Host "This preview is local only and does not upload anything."
}

function Process-ChangedLogs($State, [hashtable]$MemoryStamps) {
    $sent = 0
    foreach ($file in @(Get-RecentLogFiles)) {
        $stamp = "$($file.Length):$($file.LastWriteTimeUtc.Ticks)"
        if ($MemoryStamps.ContainsKey($file.FullName) -and $MemoryStamps[$file.FullName] -eq $stamp) { continue }
        $MemoryStamps[$file.FullName] = $stamp

        foreach ($match in @(Get-MatchesFromFile $file)) {
            $id = [string]$match.match_id
            if ($State.seen_matches.ContainsKey($id)) { continue }
            try {
                $response = Send-Match $match
                if ($response.ok -eq $true) {
                    $State.seen_matches[$id] = $true
                    Save-State $State
                    Write-BridgeLog ("Uploaded match " + $id + " result=" + $match.result + " hero=" + $match.primary_hero)
                    $sent++
                }
            } catch {
                Write-BridgeLog ("UPLOAD ERROR for " + $id + ": " + $_.Exception.Message)
            }
        }
    }
    return $sent
}

function Install-Bridge {
    Ensure-Config
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null

    if (-not $ScriptSelf) { throw "Cannot determine bridge script path." }
    if (([IO.Path]::GetFullPath($ScriptSelf)) -ne ([IO.Path]::GetFullPath($InstalledScriptPath))) {
        Copy-Item -LiteralPath $ScriptSelf -Destination $InstalledScriptPath -Force
    }

    $state = New-State
    $baseline = Initialize-Baseline $state

    $powershell = (Get-Command powershell.exe).Source
    $args = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstalledScriptPath`""
    $action = New-ScheduledTaskAction -Execute $powershell -Argument $args
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description "Private local-player OverLooker match bridge" -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName

    Write-Host ""
    Write-Host "OverLooker live bridge installed."
    Write-Host ("Watching: " + $LogRoot)
    Write-Host ("Existing complete matches baselined: " + $baseline)
    Write-Host "Only the local player's normalized match stats are uploaded."
    Write-Host "Future completed matches will be sent automatically; Overwatch does not need to be closed."
}

if ($PreviewLatest) { Preview-Latest; exit }
if ($Install) { Install-Bridge; exit }

Ensure-Config
$state = Load-State
$memoryStamps = @{}
Write-BridgeLog ("Live bridge started. Watching " + $LogRoot)

if ($RunOnce) {
    [void](Process-ChangedLogs $state $memoryStamps)
    exit
}

while ($true) {
    try {
        [void](Process-ChangedLogs $state $memoryStamps)
    } catch {
        Write-BridgeLog ("ERROR: " + $_.Exception.Message)
    }
    Start-Sleep -Seconds 5
}
