#Requires -Version 5.1
<#
.SYNOPSIS
    Configuration Restore - puts this VM's application configuration back from an approved run backup (Step 12).
.DESCRIPTION
    D01555607 4.2.2 Application Configuration Restore, for the components picked in the window
    (State.RestoreComponents; source State.RestoreSource = the run's Backups folder, same VM only):
      dw    deviceWise   db\*.db (DWCORE, DWAPP, DWUSER, DWTS), dwcore / dwjava .properties, staging\uaserver and
                         staging\uaclient, copied back while dwcore and dwts are stopped (the -wal / -shm files of
                         the restored databases are removed first); then CNCAsset / CNCType written again
      doc   DOC-n, File Manager, Data Collector, Data Analyzer folders of the backup copied over <drive>\Medtronic
                         (replacing files; the apps are closed first)
      cnc   CNCnetPDM folder copied over the install folder (service stopped first)
    What is replaced is saved first to <run>\Backups\BeforeRestore\ (so a restore can itself be undone).
    The apps and services are started again at the end. The 800xA (APC UI) backup is not restored (user 2026-10-16).
#>

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'DeviceWise.ps1')

function Invoke-ConfigRestore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [switch]$NonInteractive
    )

    Write-Log STEP "Configuration Restore"
    $phase = 'Restore'
    $info  = Get-ApcBackupInfo -Path ([string]$State['RestoreSource'])
    if ($info.Problem) { Add-Result -Phase $phase -Check 'Backup' -Status FAIL -Detail $info.Problem; throw $info.Problem }
    if ($info.VM -and $info.VM -ine $env:COMPUTERNAME) {
        Add-Result -Phase $phase -Check 'Backup belongs to this VM' -Status FAIL -Detail "The backup is from $($info.VM), this VM is $env:COMPUTERNAME"
        throw "The backup is from $($info.VM) - only this VM's own backups can be restored."
    }
    Add-Result -Phase $phase -Check 'Backup' -Status PASS -Detail "$($info.Backups) ($($info.VM), $($info.When), $($info.Type), $($info.Release))"
    $comps  = @($State['RestoreComponents'])
    $before = Join-Path (Get-RunDir -State $State -Name Backups -Manifest $Manifest) 'BeforeRestore'
    $logDir = Get-RunDir -State $State -Name Logs -Manifest $Manifest
    Write-Log INFO "Restoring: $($comps -join ', '). What is replaced is saved first to $before"

    # robocopy exit codes 0-7 mean success (8+ = failures); /E copies and replaces, files only on this VM are kept
    function Copy-Tree {
        param([string]$Source, [string]$Destination, [string]$Label, [string[]]$ExcludeDirs = @())
        $log  = Join-Path $logDir "robocopy_restore_$($Label -replace '\W', '').log"
        $argz = @($Source, $Destination, '/E', '/R:2', '/W:5', '/NP', "/LOG+:$log")
        if ($ExcludeDirs) { $argz += '/XD'; $argz += $ExcludeDirs }
        & robocopy.exe @argz | Out-Null
        return @{ Ok = ($LASTEXITCODE -le 7); Code = $LASTEXITCODE; Log = $log }
    }

    #region -- deviceWise ------------------------------------------------------------------------------------
    if ('dw' -in $comps) {
        $paths = Get-DwPaths -Manifest $Manifest
        $src   = Join-Path $info.Backups 'deviceWise'
        $gw    = $paths.Root.TrimEnd('\')
        try {
            # what is there now, while dwcore still runs (SQLite online backup, as Step 12)
            Backup-DwDatabases -Paths $paths -Dest (Join-Path $before 'deviceWise\db')
            foreach ($sub in 'dwcore', 'dwjava') {
                $d = Join-Path $before "deviceWise\$sub"; New-Item -ItemType Directory -Path $d -Force | Out-Null
                Get-ChildItem (Join-Path $gw $sub) -Filter '*.properties' -File -ErrorAction SilentlyContinue | Copy-Item -Destination $d -Force
            }
            foreach ($sub in 'staging\uaserver', 'staging\uaclient') {
                if (Test-Path (Join-Path $gw $sub)) { Copy-Item (Join-Path $gw $sub) (Join-Path $before "deviceWise\$sub") -Recurse -Force }
            }
            Add-Result -Phase $phase -Check 'deviceWise: current configuration saved' -Status PASS -Detail (Join-Path $before 'deviceWise')
        } catch {
            Add-Result -Phase $phase -Check 'deviceWise: current configuration saved' -Status FAIL -Detail "$($_.Exception.Message) - nothing restored"
            throw "deviceWise: the current configuration could not be saved, so it was not replaced."
        }
        $dbs = @(Get-ChildItem (Join-Path $src 'db') -Filter '*.db' -File | ForEach-Object { $_.Name })
        Restart-DwCore -Paths $paths -WhileStopped {
            Write-Log INFO 'Stopping dwts'
            Stop-Service 'dwts' -Force -WarningAction SilentlyContinue
            (Get-Service 'dwts').WaitForStatus('Stopped', [TimeSpan]::FromSeconds(120))
            try {
                foreach ($db in $dbs) {
                    # a leftover write-ahead log of the replaced database would be replayed into the restored one
                    foreach ($x in '-wal', '-shm', '-journal') { Remove-Item -LiteralPath (Join-Path $paths.Db "$db$x") -Force -ErrorAction SilentlyContinue }
                    Copy-Item -LiteralPath (Join-Path $src "db\$db") -Destination (Join-Path $paths.Db $db) -Force
                }
                foreach ($sub in 'dwcore', 'dwjava') {
                    $s = Join-Path $src $sub
                    if (Test-Path $s) { Get-ChildItem $s -Filter '*.properties' -File | Copy-Item -Destination (Join-Path $gw $sub) -Force }
                }
                foreach ($sub in 'staging\uaserver', 'staging\uaclient') {
                    $s = Join-Path $src $sub
                    if (Test-Path $s) { Copy-Item (Join-Path $s '*') (Join-Path $gw $sub) -Recurse -Force }
                }
                Add-Result -Phase $phase -Check 'deviceWise restored' -Status PASS -Detail "$($dbs -join ', '), properties, OPC UA certificates from $src"
            } catch {
                Add-Result -Phase $phase -Check 'deviceWise restored' -Status FAIL -Detail "$($_.Exception.Message) - the replaced files are in $before\deviceWise"
            } finally {
                Write-Log INFO 'Starting dwts'
                Start-Service 'dwts' -WarningAction SilentlyContinue
            }
        }
        $port = [int]$Manifest.DeviceWise.OpcUaEndpointPort
        $deadline = (Get-Date).AddSeconds(180); $listening = $false
        while (-not $listening -and (Get-Date) -lt $deadline) {
            $listening = [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
            if (-not $listening) { Start-Sleep -Seconds 5 }
        }
        Add-Result -Phase $phase -Check "deviceWise OPC UA server on $port" -Status $(if ($listening) { 'PASS' } else { 'FAIL' }) `
            -Detail $(if ($listening) { 'listening after the restore' } else { 'not listening 3 min after the restore' })
        # CNCAsset / CNCType are not kept by the gateway over a restart: written again (as Steps 4-8 do)
        $cncs = Get-AssignedCNCs -State $State -Manifest $Manifest   # already an array (return ,$result)
        if ($listening -and $cncs.Count) { Set-DwCncAssetValues -Manifest $Manifest -Cncs $cncs -Phase $phase -WaitSec 120 }
    }
    #endregion

    #region -- DOC and data applications ---------------------------------------------------------------------
    if ('doc' -in $comps) {
        $medtronic = [string]$Manifest.Backup.MedtronicDir   # on the install drive (the run's manifest)
        foreach ($name in $info.DocDirs) {
            # close the app that uses the folder: DOC-n by its folder, the data apps by their exe
            if ($name -match '^DOC-(\d+)$') {
                $p = Get-DOCProcess -Manifest $Manifest -Instance ([int]$Matches[1])
                if ($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Write-Log INFO "Closed $name (PID $($p.Id))" }
            } else {
                $exe = switch ($name) { 'File Manager' { $Manifest.DataApps.FileManagerConfig } 'Data Collector' { $Manifest.DataApps.DataCollectorConfig } 'Data Analyzer' { $Manifest.DataApps.DataAnalyzerConfig } }
                $proc = [IO.Path]::GetFileNameWithoutExtension((([string]$exe) -replace '\.config$', ''))
                foreach ($p in @(Get-Process -Name $proc -ErrorAction SilentlyContinue)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Write-Log INFO "Closed $proc (PID $($p.Id))" }
            }
        }
        Start-Sleep -Seconds 3
        foreach ($name in $info.DocDirs) {
            $target = Join-Path $medtronic $name
            $save = Copy-Tree -Source $target -Destination (Join-Path $before "Medtronic\$name") -Label "before_$name"
            if (-not $save.Ok) {
                Add-Result -Phase $phase -Check "$name restored" -Status FAIL -Detail "the current folder could not be saved (robocopy $($save.Code), $($save.Log)) - not replaced"
                continue
            }
            $r = Copy-Tree -Source (Join-Path $info.Backups "Medtronic\$name") -Destination $target -Label $name
            Add-Result -Phase $phase -Check "$name restored" -Status $(if ($r.Ok) { 'PASS' } else { 'FAIL' }) `
                -Detail $(if ($r.Ok) { "$target (was saved to $before\Medtronic\$name)" } else { "robocopy $($r.Code) - see $($r.Log)" })
        }
    }
    #endregion

    #region -- CNCnetPDM ------------------------------------------------------------------------------------
    if ('cnc' -in $comps) {
        $target = @($Manifest.CNCnetPDM.InstallDir, $Manifest.CNCnetPDM.FallbackDir) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
        $svc    = [string]$Manifest.Services.CNCnetPDM
        if (-not $target) {
            Add-Result -Phase $phase -Check 'CNCnetPDM restored' -Status FAIL -Detail 'CNCnetPDM install folder not found - install it with the Installation Manager first'
        } else {
            Stop-Service $svc -Force -ErrorAction SilentlyContinue
            try { (Get-Service $svc).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60)) } catch { }
            $save = Copy-Tree -Source $target -Destination (Join-Path $before 'CNCnetPDM') -Label 'before_CNCnetPDM' -ExcludeDirs @(Join-Path $target 'log')
            if (-not $save.Ok) {
                Add-Result -Phase $phase -Check 'CNCnetPDM restored' -Status FAIL -Detail "the current folder could not be saved (robocopy $($save.Code), $($save.Log)) - not replaced"
            } else {
                $r = Copy-Tree -Source $info.CncDir -Destination $target -Label 'CNCnetPDM'
                Add-Result -Phase $phase -Check 'CNCnetPDM restored' -Status $(if ($r.Ok) { 'PASS' } else { 'FAIL' }) `
                    -Detail $(if ($r.Ok) { "$target (was saved to $before\CNCnetPDM)" } else { "robocopy $($r.Code) - see $($r.Log)" })
            }
            Start-Service $svc -ErrorAction SilentlyContinue
            $s = Get-Service $svc -ErrorAction SilentlyContinue
            Add-Result -Phase $phase -Check "Service $svc" -Status $(if ($s -and $s.Status -eq 'Running') { 'PASS' } else { 'FAIL' }) -Detail $(if ($s) { [string]$s.Status } else { 'not installed' })
        }
    }
    #endregion

    # everything that should run is started again (DOC instances close their PartLookup_DB box until connected)
    foreach ($r in (Start-MissingApps -Manifest $Manifest -State $State)) { Add-Result -Phase $phase -Check "Started: $($r.Name)" -Status $r.Status -Detail $r.Detail }
    Write-Log PASS "Configuration restore complete. The replaced configuration is in $before"
}
