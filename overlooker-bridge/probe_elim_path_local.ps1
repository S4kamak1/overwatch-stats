$ErrorActionPreference = "Stop"
$LogRoot = Join-Path $HOME ".overlooker\logs"

function Get-BracketDepth([string]$Text,[int]$StopIndex) {
    $depth=0; $quote=[char]0; $escaped=$false
    for($i=0;$i -lt $StopIndex -and $i -lt $Text.Length;$i++){
        $ch=$Text[$i]
        if($quote -ne [char]0){ if($escaped){$escaped=$false;continue}; if([int][char]$ch -eq 92){$escaped=$true;continue}; if($ch -eq $quote){$quote=[char]0}; continue }
        if([int][char]$ch -eq 34 -or [int][char]$ch -eq 39){$quote=$ch;continue}
        if($ch -eq '{' -or $ch -eq '[' -or $ch -eq '('){$depth++} elseif($ch -eq '}' -or $ch -eq ']' -or $ch -eq ')'){if($depth -gt 0){$depth--}}
    }
    return $depth
}

function Get-FieldMatches([string]$Text,[string]$Name){
    $escaped=[regex]::Escape($Name)
    $patterns=@(('(?i)"'+$escaped+'"\s*[:=]\s*'),('(?i)(?<![A-Za-z0-9_])'+$escaped+'\s*[:=]\s*'))
    $rows=@();$seen=@{}
    foreach($pattern in $patterns){foreach($m in [regex]::Matches($Text,$pattern)){if($seen.ContainsKey([string]$m.Index)){continue};$seen[[string]$m.Index]=$true;$rows += [pscustomobject]@{Index=$m.Index;ValueStart=$m.Index+$m.Length}}}
    return @($rows|Sort-Object Index)
}

function Read-Token([string]$Text,[int]$StartIndex){
    $i=$StartIndex; while($i -lt $Text.Length -and [char]::IsWhiteSpace($Text[$i])){$i++}; if($i -ge $Text.Length){return $null}
    $first=$Text[$i]
    if([int][char]$first -eq 34 -or [int][char]$first -eq 39){$q=$first;$sb=New-Object Text.StringBuilder;$esc=$false;for($j=$i+1;$j -lt $Text.Length;$j++){$ch=$Text[$j];if($esc){[void]$sb.Append($ch);$esc=$false;continue};if([int][char]$ch -eq 92){$esc=$true;continue};if($ch -eq $q){return $sb.ToString()};[void]$sb.Append($ch)};return $sb.ToString()}
    $start=$i;while($i -lt $Text.Length){$ch=$Text[$i];if([char]::IsWhiteSpace($ch)-or $ch -eq ',' -or $ch -eq '}' -or $ch -eq ']' -or $ch -eq ')'){break};$i++};if($i -le $start){return $null};return $Text.Substring($start,$i-$start)
}

function Convert-TokenValue($Token){if($null -eq $Token){return $null};$s=([string]$Token).Trim();if($s -match '^(?i:true)$'){return $true};if($s -match '^(?i:false)$'){return $false};if($s -match '^-?\d+(?:\.\d+)?$'){try{return [double]::Parse($s,[Globalization.CultureInfo]::InvariantCulture)}catch{}};return $s}

function Get-AllFieldEntries([string]$Text,[string]$Name){$out=@();foreach($m in @(Get-FieldMatches $Text $Name)){$out += [pscustomobject]@{Index=$m.Index;Value=(Convert-TokenValue (Read-Token $Text $m.ValueStart))}};return $out}

function Get-ContainerFromOpen([string]$Text,[int]$OpenIndex){
    if($OpenIndex -lt 0 -or $OpenIndex -ge $Text.Length){return $null};$open=$Text[$OpenIndex];if($open -eq '{'){$close='}'}elseif($open -eq '['){$close=']'}elseif($open -eq '('){$close=')'}else{return $null}
    $depth=0;$quote=[char]0;$escaped=$false
    for($i=$OpenIndex;$i -lt $Text.Length;$i++){$ch=$Text[$i];if($quote -ne [char]0){if($escaped){$escaped=$false;continue};if([int][char]$ch -eq 92){$escaped=$true;continue};if($ch -eq $quote){$quote=[char]0};continue};if([int][char]$ch -eq 34 -or [int][char]$ch -eq 39){$quote=$ch;continue};if($ch -eq $open){$depth++}elseif($ch -eq $close){$depth--;if($depth -eq 0){return $Text.Substring($OpenIndex,$i-$OpenIndex+1)}}};return $null
}

function Get-EnclosingContainer([string]$Text,[int]$Index){
    $stack=New-Object Collections.ArrayList;$quote=[char]0;$escaped=$false
    for($i=0;$i -lt $Index -and $i -lt $Text.Length;$i++){$ch=$Text[$i];if($quote -ne [char]0){if($escaped){$escaped=$false;continue};if([int][char]$ch -eq 92){$escaped=$true;continue};if($ch -eq $quote){$quote=[char]0};continue};if([int][char]$ch -eq 34 -or [int][char]$ch -eq 39){$quote=$ch;continue};if($ch -eq '{' -or $ch -eq '[' -or $ch -eq '('){[void]$stack.Add($i)}elseif($ch -eq '}' -or $ch -eq ']' -or $ch -eq ')'){if($stack.Count -gt 0){$stack.RemoveAt($stack.Count-1)}}}
    if($stack.Count -eq 0){return $null};return Get-ContainerFromOpen $Text ([int]$stack[$stack.Count-1])
}

function Get-LocalPlayerContainer([string]$Line){foreach($entry in @(Get-AllFieldEntries $Line "is_local")){if($entry.Value -eq $true){$c=Get-EnclosingContainer $Line $entry.Index;if($c){return $c}}};return $null}

$latest=$null
if(Test-Path $LogRoot){$files=@(Get-ChildItem $LogRoot -File -Recurse -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 8);foreach($file in $files){$lines=@(Get-Content $file.FullName -Tail 12000 -ErrorAction SilentlyContinue);for($i=$lines.Count-1;$i -ge 0;$i--){$line=[string]$lines[$i];if($line -match '(?i)pseudo_match_id' -and $line -match '(?i)is_local' -and $line -match '(?i)result'){$latest=$line;break}};if($latest){break}}}
if(-not $latest){throw "No completed OverLooker match record found."}
$local=Get-LocalPlayerContainer $latest
if(-not $local){throw "Local player object not found."}

$pairPattern='(?is)(?:"(?<qkey>[^"\r\n]{1,64})"|(?<ukey>[A-Za-z_][A-Za-z0-9_.-]{0,63}))\s*[:=]\s*(?<num>-?\d+(?:\.\d+)?)'
$blocked='(?i)(battle|tag|name|account|user|uuid|pseudo|mcp|player.?id|session.?id)'
$candidates=@()
foreach($m in [regex]::Matches($local,$pairPattern)){
    $value=[double]::Parse($m.Groups['num'].Value,[Globalization.CultureInfo]::InvariantCulture)
    if([Math]::Abs($value-16.0) -gt 0.0001){continue}
    $key=if($m.Groups['qkey'].Success){$m.Groups['qkey'].Value}else{$m.Groups['ukey'].Value}
    if($key -match $blocked){$key='<redacted>'}
    $candidates += [ordered]@{field=$key;depth=(Get-BracketDepth $local $m.Index);value=16}
}

# Also count literal 16 tokens in case the value is stored in an array instead of a key/value pair.
$literalCount=0
foreach($m in [regex]::Matches($local,'(?<![0-9.])16(?:\.0+)?(?![0-9.])')){$literalCount++}

$out=[ordered]@{local_only=$true;target=16;key_value_candidates=$candidates;literal_16_occurrences=$literalCount}
Write-Host ""
Write-Host "Local-player elimination-path diagnostic completed."
$out|ConvertTo-Json -Depth 6
Write-Host ""
Write-Host "Only numeric value 16 and non-sensitive field names from the local player object are shown. Nothing is uploaded."
