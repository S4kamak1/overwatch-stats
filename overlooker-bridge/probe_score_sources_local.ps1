$ErrorActionPreference = "Stop"

$LogRoot = Join-Path $HOME ".overlooker\logs"

function Get-BracketDepth([string]$Text, [int]$StopIndex) {
    $depth = 0; $quote = [char]0; $escaped = $false
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
    $rows = @(); $seen = @{}
    foreach ($pattern in $patterns) {
        foreach ($m in [regex]::Matches($Text, $pattern)) {
            if ($seen.ContainsKey([string]$m.Index)) { continue }
            $seen[[string]$m.Index] = $true
            $rows += [pscustomobject]@{ Index=[int]$m.Index; ValueStart=[int]($m.Index+$m.Length); Depth=[int](Get-BracketDepth $Text $m.Index) }
        }
    }
    return @($rows | Sort-Object Depth,Index)
}

function Read-Token([string]$Text, [int]$StartIndex) {
    $i=$StartIndex
    while ($i -lt $Text.Length -and [char]::IsWhiteSpace($Text[$i])) { $i++ }
    if ($i -ge $Text.Length) { return $null }
    $first=$Text[$i]
    if ([int][char]$first -eq 34 -or [int][char]$first -eq 39) {
        $quote=$first; $sb=New-Object System.Text.StringBuilder; $escaped=$false
        for ($j=$i+1; $j -lt $Text.Length; $j++) {
            $ch=$Text[$j]
            if ($escaped) { [void]$sb.Append($ch); $escaped=$false; continue }
            if ([int][char]$ch -eq 92) { $escaped=$true; continue }
            if ($ch -eq $quote) { return $sb.ToString() }
            [void]$sb.Append($ch)
        }
        return $sb.ToString()
    }
    $start=$i
    while ($i -lt $Text.Length) {
        $ch=$Text[$i]
        if ([char]::IsWhiteSpace($ch) -or $ch -eq ',' -or $ch -eq '}' -or $ch -eq ']' -or $ch -eq ')') { break }
        $i++
    }
    if ($i -le $start) { return $null }
    return $Text.Substring($start,$i-$start)
}

function Convert-TokenValue($Token) {
    if ($null -eq $Token) { return $null }
    $s=([string]$Token).Trim()
    if (-not $s -or $s -match '^(?i:null|none)$') { return $null }
    if ($s -match '^(?i:true)$') { return $true }
    if ($s -match '^(?i:false)$') { return $false }
    if ($s -match '^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$') {
        try { return [double]::Parse($s,[Globalization.CultureInfo]::InvariantCulture) } catch {}
    }
    return $s
}

function Get-AllFieldEntries([string]$Text,[string]$Name) {
    $out=@()
    foreach ($m in @(Get-FieldMatches $Text $Name)) {
        $out += [pscustomobject]@{ Index=$m.Index; ValueStart=$m.ValueStart; Depth=$m.Depth; Value=(Convert-TokenValue (Read-Token $Text $m.ValueStart)) }
    }
    return $out
}

function Get-ContainerFromOpen([string]$Text,[int]$OpenIndex) {
    if ($OpenIndex -lt 0 -or $OpenIndex -ge $Text.Length) { return $null }
    $open=$Text[$OpenIndex]; $close=$null
    if ($open -eq '{') { $close='}' } elseif ($open -eq '[') { $close=']' } elseif ($open -eq '(') { $close=')' } else { return $null }
    $depth=0; $quote=[char]0; $escaped=$false
    for ($i=$OpenIndex; $i -lt $Text.Length; $i++) {
        $ch=$Text[$i]
        if ($quote -ne [char]0) {
            if ($escaped) { $escaped=$false; continue }
            if ([int][char]$ch -eq 92) { $escaped=$true; continue }
            if ($ch -eq $quote) { $quote=[char]0 }
            continue
        }
        if ([int][char]$ch -eq 34 -or [int][char]$ch -eq 39) { $quote=$ch; continue }
        if ($ch -eq $open) { $depth++ } elseif ($ch -eq $close) { $depth--; if ($depth -eq 0) { return $Text.Substring($OpenIndex,$i-$OpenIndex+1) } }
    }
    return $null
}

function Get-EnclosingContainer([string]$Text,[int]$Index) {
    $stack=New-Object System.Collections.ArrayList; $quote=[char]0; $escaped=$false
    for ($i=0; $i -lt $Index -and $i -lt $Text.Length; $i++) {
        $ch=$Text[$i]
        if ($quote -ne [char]0) {
            if ($escaped) { $escaped=$false; continue }
            if ([int][char]$ch -eq 92) { $escaped=$true; continue }
            if ($ch -eq $quote) { $quote=[char]0 }
            continue
        }
        if ([int][char]$ch -eq 34 -or [int][char]$ch -eq 39) { $quote=$ch; continue }
        if ($ch -eq '{' -or $ch -eq '[' -or $ch -eq '(') { [void]$stack.Add([pscustomobject]@{Index=$i}) }
        elseif ($ch -eq '}' -or $ch -eq ']' -or $ch -eq ')') { if ($stack.Count -gt 0) { $stack.RemoveAt($stack.Count-1) } }
    }
    if ($stack.Count -eq 0) { return $null }
    return Get-ContainerFromOpen $Text ([int]$stack[$stack.Count-1].Index)
}

function Get-FieldContainer([string]$Text,[string]$Name) {
    foreach ($m in @(Get-FieldMatches $Text $Name)) {
        $i=$m.ValueStart
        while ($i -lt $Text.Length -and [char]::IsWhiteSpace($Text[$i])) { $i++ }
        if ($i -lt $Text.Length -and ($Text[$i] -eq '{' -or $Text[$i] -eq '[' -or $Text[$i] -eq '(')) {
            $c=Get-ContainerFromOpen $Text $i
            if ($c) { return $c }
        }
    }
    return $null
}

function Get-LocalPlayerContainer([string]$Line) {
    foreach ($entry in @(Get-AllFieldEntries $Line "is_local")) {
        if ($entry.Value -eq $true) {
            $c=Get-EnclosingContainer $Line $entry.Index
            if ($c) { return $c }
        }
    }
    return $null
}

function Get-DirectObjectSummary([string]$Container) {
    if (-not $Container) { return [ordered]@{present=$false; entries=0; numeric_values=0; numeric_sum=0; array_values=0; object_values=0} }
    $entryCount=0; $numericCount=0; $numericSum=0.0; $arrayCount=0; $objectCount=0
    $patterns=@('"[^"\r\n]+"\s*[:=]\s*','(?<![A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_.-]*\s*[:=]\s*')
    $seen=@{}
    foreach ($pattern in $patterns) {
        foreach ($m in [regex]::Matches($Container,$pattern)) {
            if ((Get-BracketDepth $Container $m.Index) -ne 1) { continue }
            if ($seen.ContainsKey([string]$m.Index)) { continue }
            $seen[[string]$m.Index]=$true; $entryCount++
            $i=$m.Index+$m.Length
            while ($i -lt $Container.Length -and [char]::IsWhiteSpace($Container[$i])) { $i++ }
            if ($i -ge $Container.Length) { continue }
            if ($Container[$i] -eq '[') { $arrayCount++; continue }
            if ($Container[$i] -eq '{' -or $Container[$i] -eq '(') { $objectCount++; continue }
            $v=Convert-TokenValue (Read-Token $Container $i)
            if ($v -is [double] -or $v -is [int] -or $v -is [long] -or $v -is [decimal]) { $numericCount++; $numericSum += [double]$v }
        }
    }
    return [ordered]@{present=$true; entries=$entryCount; numeric_values=$numericCount; numeric_sum=[Math]::Round($numericSum,3); array_values=$arrayCount; object_values=$objectCount}
}

function Get-AnonymousNumericLeafSummary([string]$Container) {
    if (-not $Container) { return [ordered]@{present=$false; numeric_leaf_count=0; numeric_leaf_sum=0; numeric_leaf_values=@()} }
    $values = New-Object System.Collections.ArrayList
    $patterns=@('"[^"\r\n]+"\s*[:=]\s*','(?<![A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_.-]*\s*[:=]\s*')
    $seen=@{}
    foreach ($pattern in $patterns) {
        foreach ($m in [regex]::Matches($Container,$pattern)) {
            if ($seen.ContainsKey([string]$m.Index)) { continue }
            $seen[[string]$m.Index]=$true
            $i=$m.Index+$m.Length
            while ($i -lt $Container.Length -and [char]::IsWhiteSpace($Container[$i])) { $i++ }
            if ($i -ge $Container.Length) { continue }
            if ($Container[$i] -eq '[' -or $Container[$i] -eq '{' -or $Container[$i] -eq '(') { continue }
            $v=Convert-TokenValue (Read-Token $Container $i)
            if ($v -is [double] -or $v -is [int] -or $v -is [long] -or $v -is [decimal]) { [void]$values.Add([double]$v) }
        }
    }
    $sum=0.0; foreach($v in $values){$sum += [double]$v}
    return [ordered]@{present=$true; numeric_leaf_count=$values.Count; numeric_leaf_sum=[Math]::Round($sum,3); numeric_leaf_values=@($values | Sort-Object)}
}

$latest=$null
if (Test-Path $LogRoot) {
    $files=@(Get-ChildItem $LogRoot -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 8)
    foreach ($file in $files) {
        $lines=@(Get-Content $file.FullName -Tail 12000 -ErrorAction SilentlyContinue)
        for ($i=$lines.Count-1; $i -ge 0; $i--) {
            $line=[string]$lines[$i]
            if ($line -match '(?i)pseudo_match_id' -and $line -match '(?i)is_local' -and $line -match '(?i)result') { $latest=$line; break }
        }
        if ($latest) { break }
    }
}
if (-not $latest) { throw "No completed OverLooker match record found." }

$local=Get-LocalPlayerContainer $latest
if (-not $local) { throw "Local player object not found." }
$stats=Get-FieldContainer $local "stats"
$kills=Get-FieldContainer $local "kills"
$eContainer=if($stats){Get-FieldContainer $stats "e"}else{$null}

function CandidateValues([string[]]$Names) {
    $rows=@()
    foreach ($name in $Names) {
        foreach ($e in @(Get-AllFieldEntries $local $name)) {
            if ($null -ne $e.Value -and ($e.Value -is [double] -or $e.Value -is [int] -or $e.Value -is [long] -or $e.Value -is [decimal])) {
                $rows += [ordered]@{field=$name; depth=$e.Depth; value=[double]$e.Value}
            }
        }
    }
    return $rows
}

$out=[ordered]@{
    local_only=$true
    stats_candidates=[ordered]@{
        a=if($stats){@((Get-AllFieldEntries $stats "a")|ForEach-Object{$_.Value})}else{@()}
        d=if($stats){@((Get-AllFieldEntries $stats "d")|ForEach-Object{$_.Value})}else{@()}
        dmg=if($stats){@((Get-AllFieldEntries $stats "dmg")|ForEach-Object{$_.Value})}else{@()}
        heal=if($stats){@((Get-AllFieldEntries $stats "heal")|ForEach-Object{$_.Value})}else{@()}
        mit=if($stats){@((Get-AllFieldEntries $stats "mit")|ForEach-Object{$_.Value})}else{@()}
    }
    eliminations_e_object=[ordered]@{
        direct=(Get-DirectObjectSummary $eContainer)
        recursive_numeric=(Get-AnonymousNumericLeafSummary $eContainer)
    }
    kills_object=(Get-DirectObjectSummary $kills)
    heal_candidates=@(CandidateValues @("heal","healing","healed"))
    damage_candidates=@(CandidateValues @("dmg","damage"))
}

Write-Host ""
Write-Host "Local-player score-source diagnostic completed."
$out | ConvertTo-Json -Depth 8
Write-Host ""
Write-Host "The eliminations container is shown only as anonymous numeric counts/sums. Nothing is uploaded."
