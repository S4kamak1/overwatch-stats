$ErrorActionPreference = "Stop"

$RuntimePath = Join-Path $PSScriptRoot "overlooker_bridge_runtime.ps1"
if (-not (Test-Path $RuntimePath)) { throw "Runtime bridge not found: $RuntimePath" }

$src = Get-Content $RuntimePath -Raw

if ($src -notmatch 'OWStatsHiddenRunLauncher') {
    $oldLaunch = @'
        $runCommand = "`"$powershell`" $args"
        New-ItemProperty -Path $runKey -Name $runName -Value $runCommand -PropertyType String -Force | Out-Null
        Start-Process -FilePath $powershell -ArgumentList $args -WindowStyle Hidden
'@

    $newLaunch = @'
        # OWStatsHiddenRunLauncher: HKCU Run can briefly show a PowerShell console even
        # with -WindowStyle Hidden. Use Windows Script Host as a windowless launcher.
        $launcherPath = Join-Path $ConfigDir "start_bridge_hidden.vbs"
        $wscript = Join-Path $env:WINDIR "System32\wscript.exe"

        if (Test-Path $wscript) {
            $psCommand = "`"$powershell`" $args"
            $vbsCommand = $psCommand.Replace('"', '""')
            $vbs = "Set shell = CreateObject(""WScript.Shell"")`r`nshell.Run ""$vbsCommand"", 0, False`r`n"
            Set-Content -LiteralPath $launcherPath -Value $vbs -Encoding ASCII

            $runCommand = "`"$wscript`" `"$launcherPath`""
            New-ItemProperty -Path $runKey -Name $runName -Value $runCommand -PropertyType String -Force | Out-Null
            Start-Process -FilePath $wscript -ArgumentList "`"$launcherPath`""
            $autostartMode = "current-user-run-key-hidden"
        } else {
            # Rare fallback if Windows Script Host is unavailable.
            $runCommand = "`"$powershell`" $args"
            New-ItemProperty -Path $runKey -Name $runName -Value $runCommand -PropertyType String -Force | Out-Null
            Start-Process -FilePath $powershell -ArgumentList $args -WindowStyle Hidden
            $autostartMode = "current-user-run-key"
            Write-BridgeLog "wscript.exe unavailable; using PowerShell Run-key fallback."
        }
'@

    $normalized = $src -replace "`r`n", "`n"
    if (-not $normalized.Contains($oldLaunch)) {
        throw "Could not locate HKCU Run launch block for hidden-startup patch."
    }
    $normalized = $normalized.Replace($oldLaunch, $newLaunch)
    $src = $normalized -replace "`n", "`r`n"
}

if ($src -notmatch 'OWStatsHiddenRunLauncher') { throw "Hidden-startup patch verification failed." }
if ($src -notmatch 'start_bridge_hidden\.vbs') { throw "Hidden launcher path verification failed." }
if ($src -notmatch 'current-user-run-key-hidden') { throw "Hidden autostart mode verification failed." }

Set-Content -LiteralPath $RuntimePath -Value $src -Encoding UTF8
Write-Host "Hidden startup launcher prepared."
Write-Host "HKCU Run fallback: windowless WScript launcher"
