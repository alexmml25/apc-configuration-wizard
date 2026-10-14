#Requires -Version 5.1
<#
.SYNOPSIS
    Step 8 - deviceWise CNCnetPDM integration (SOP D01555607 2.1.1, deviceWise - CNCnetPDM Integration).
.DESCRIPTION
    Runs after Step 7 (CNCnetPDM configured and running), as in the SOP. No Workbench and no API:
      1. Registers the CNCnetPDM instance (SOP: Administration > CNCnetPDM Instance Management > Add).
         The registration is not part of an export; the gateway keeps it in DWUSER.db, persistence
         group cncnetpdm.instances, name = the CNCnetPDM folder name, value = the folder
         (seen on SJUM1CAPPD0017: CNCNetPDM = C:\Medtronic\CNCNetPDM). Written with dwcore stopped.
      2. Imports the CNCn_PATH devices (SOP: Devices > CNCX_Paths > pair each CNCnetPDM machine) from
         the approved baseline, one per assigned CNC, through the gateway's import folder, with
         instance = that folder name and machine = '<DeviceNr> - <machine name>' - the entry the
         Workbench drop-down shows, read from CNCnetPDM; Step 7 writes the same DeviceNr and name.
         Saved as started. Steps 1 and 2 share one dwcore restart.
      3. Checks: import status, instance registered, devices in the gateway, each DeviceNr in
         CNCnetPDM.ini; CNCAsset / CNCType written again (the restart emptied them).
    Whether the instance shows Connected and the machines answer is a Workbench check for now.
#>

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'DeviceWise.ps1')

function Invoke-DeviceWiseCNCPDM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [switch]$NonInteractive
    )

    Write-Log STEP 'deviceWise CNCnetPDM Integration'
    $dw    = $Manifest.DeviceWise
    $paths = Get-DwPaths -Manifest $Manifest
    $phase = 'deviceWise CNCnetPDM'

    $cncs = Get-AssignedCNCs -State $State -Manifest $Manifest   # already an array (return ,$result); @() would nest it
    if (-not $cncs.Count) { throw 'No CNC machines in the state. Run Step 1 first.' }
    $bad = @($cncs | Where-Object { $_.DeviceNrError -or -not $_.DeviceNr })
    if ($bad.Count) { throw ("No CNCnetPDM Device Nr for: " + (($bad | ForEach-Object { "CNC$($_.CNCIndex) $($_.MachineName): $($_.DeviceNrError)" }) -join '; ')) }
    if (-not (Test-Path (Join-Path $paths.Packages 'dwcncnetpdm.xml'))) { throw 'The CNCnetPDM package is not installed on the gateway. Run Step 4 first.' }

    $pdmDir = @($Manifest.CNCnetPDM.InstallDir, $Manifest.CNCnetPDM.FallbackDir) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $pdmDir) { throw "CNCnetPDM folder not found ($($Manifest.CNCnetPDM.InstallDir)). Run Step 7 first." }
    $instance = Split-Path $pdmDir -Leaf
    Write-Log INFO "CNCnetPDM instance: $instance = $pdmDir"
    $svc = Get-Service $Manifest.Services.CNCnetPDM -ErrorAction SilentlyContinue
    Add-Result -Phase $phase -Check 'CNCnetPDM service' -Status $(if ($svc -and $svc.Status -eq 'Running') { 'PASS' } else { 'WARN' }) `
        -Detail $(if ($svc) { "$($svc.Status) - deviceWise reads the machines from the running CNCnetPDM" } else { 'service not found' })

    # The CNCn_PATH devices from the baseline, one per assigned CNC
    $wanted   = @($cncs | ForEach-Object { "CNC$($_.CNCIndex)_PATH" })
    $baseline = Get-DwBaseline -Manifest $Manifest
    Write-Log INFO "Baseline: $($baseline.FullName)"
    $build = New-DwImportFromBaseline -BaselinePath $baseline.FullName -Keep { param($type, $name) $type -eq 'device' -and $wanted -contains $name }
    foreach ($c in $cncs) {
        $node = "CNC$($c.CNCIndex)_PATH"
        $ec   = $build.Xml.SelectSingleNode("//exportcontent[@type='device' and @name='$node']")
        if (-not $ec) { throw "Device $node is not in the baseline." }
        $machine = "$($c.DeviceNr) - $($c.MachineName)"
        foreach ($p in @{ instance = $instance; machine = $machine }.GetEnumerator()) {
            $prop = $ec.SelectSingleNode(".//DeviceDefinition/Properties/Property[@name='$($p.Key)']")
            if (-not $prop) { throw "Device $node in the baseline has no '$($p.Key)' property." }
            $prop.SetAttribute('value', $p.Value)
        }
        $st = $ec.SelectSingleNode("exportproperty[@key='state']")
        if ($st) { $st.SetAttribute('value', 'started') }
        Write-Log INFO "  $node = $instance / $machine"
    }

    $safety = Join-Path (Get-RunDir -State $State -Name Backups -Manifest $Manifest) 'deviceWise-before-step8'
    try {
        $res = Invoke-DwImport -Paths $paths -Xml $build.Xml -Label 'step8-cncnetpdm' -SafetyDir $safety -SaveDatabases -TimeoutSec $dw.ImportTimeoutSec `
            -WhileStopped { Set-DwPersistence -Paths $paths -Group 'cncnetpdm.instances' -Values @{ $instance = $pdmDir } }
    } catch {
        Add-Result -Phase $phase -Check 'CNCnetPDM devices import' -Status FAIL -Detail $_.Exception.Message
        throw
    }
    [void](Add-DwImportResults -Phase $phase -Result $res -Summary 'CNCnetPDM devices import')

    # Instance registration read back (values carry the gateway's leading marker byte)
    try {
        $inst = Get-DwPersistence -Paths $paths -Group 'cncnetpdm.instances'
        $got  = ([string]$inst[$instance]) -replace '[\x00-\x1F]', ''
        Add-Result -Phase $phase -Check 'CNCnetPDM instance registered' -Status $(if ($got -eq $pdmDir) { 'PASS' } else { 'FAIL' }) `
            -Detail "$instance = $(if ($got) { $got } else { '(missing)' })"
    } catch {
        Add-Result -Phase $phase -Check 'CNCnetPDM instance registered' -Status WARN -Detail "could not read DWUSER.db: $($_.Exception.Message)"
    }

    # Each '<DeviceNr> - <name>' must be a CNCnetPDM machine: [RS232] lines 'n = DeviceNr;baud;8;N;1;Name;IP;port;...'
    # (Step 7 writes them; CNCnetPDM keeps only the first 15 characters of the name)
    $ini = Join-Path $pdmDir $Manifest.CNCnetPDM.IniFile
    $pdmMachines = @{}
    if (Test-Path $ini) {
        $inRs = $false
        foreach ($line in Get-Content $ini) {
            if ($line -match '^\s*\[(.+)\]') { $inRs = ($Matches[1] -eq $Manifest.CNCnetPDM.RS232Section); continue }
            if ($inRs -and $line -match '^\s*\d+\s*=\s*(.+)$') {
                $f = $Matches[1] -split ';'
                if ($f.Count -ge 6) { $pdmMachines[$f[0].Trim()] = $f[5].Trim() }
            }
        }
    }
    foreach ($c in $cncs) {
        $nr = [string]$c.DeviceNr; $name = [string]$c.MachineName
        $ok = $pdmMachines.ContainsKey($nr) -and $pdmMachines[$nr] -eq $name
        $detail = if ($ok) { "$nr - $name in [$($Manifest.CNCnetPDM.RS232Section)]" }
                  elseif ($pdmMachines.ContainsKey($nr)) { "Device Nr $nr is '$($pdmMachines[$nr])' in CNCnetPDM, not '$name' - run Step 7" }
                  else { "Device Nr $nr not in [$($Manifest.CNCnetPDM.RS232Section)] of $ini - run Step 7" }
        Add-Result -Phase $phase -Check "CNC$($c.CNCIndex)_PATH machine in CNCnetPDM" -Status $(if ($ok) { 'PASS' } else { 'WARN' }) -Detail $detail
    }

    # Connected (Workbench: CNCnetPDM Instance Management > State Connected) = dwcore's TCP connection to
    # CNCnetPDM's MTC Adapter port (Test-DwCncnetpdmConnected, DeviceWise.ps1)
    $mtc  = Test-DwCncnetpdmConnected -IniPath $ini -WaitSec 60
    $conn = $mtc.Connected
    $mtcPort = $mtc.Port
    Add-Result -Phase $phase -Check 'CNCnetPDM instance connected' -Status $(if ($conn) { 'PASS' } else { 'FAIL' }) `
        -Detail $(if ($conn) { "dwcore connected to CNCnetPDM (MTC Adapter port $mtcPort)" } else { "no dwcore connection to CNCnetPDM port $mtcPort after 60 s - is the CNCnetPDM service running and configured (Step 7)?" })
    # CNCn_PATH started (DWCORE.db devices.state 1 = Started, 2 = Stopped). Right after the import they can be
    # stopped: they start before the CNCnetPDM connection is up (fresh VM 2026-10-14: state 2 after the import,
    # Started after the next dwcore start). One more dwcore restart, with the instance registered, starts them.
    $pathStates = {
        $all = Get-DwDeviceStates -Paths $paths
        $out = [ordered]@{}; foreach ($n in $wanted) { $out[$n] = if ($all.ContainsKey($n)) { $all[$n] } else { -1 } }
        $out
    }
    try {
        $st = & $pathStates
        if (@($st.Values | Where-Object { $_ -ne 1 }).Count -and $conn) {
            Write-Log INFO ("CNCn_PATH not all started ({0}) - restarting dwcore once more" -f (($st.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))
            Restart-DwCore -Paths $paths -WhileStopped { }
            $deadline = (Get-Date).AddSeconds(90)
            do { Start-Sleep -Seconds 5; $st = & $pathStates } while (@($st.Values | Where-Object { $_ -ne 1 }).Count -and (Get-Date) -lt $deadline)
        }
        foreach ($n in $wanted) {
            $v = $st[$n]
            Add-Result -Phase $phase -Check "$n started" -Status $(if ($v -eq 1) { 'PASS' } else { 'FAIL' }) `
                -Detail $(switch ($v) { 1 { 'Started' } 2 { 'Stopped - check the CNCnetPDM machine and Workbench > Devices' } -1 { 'not in the gateway' } default { "state $v" } })
        }
    } catch {
        Add-Result -Phase $phase -Check 'CNCn_PATH devices' -Status MANUAL -Detail "could not read DWCORE.db ($($_.Exception.Message)). Workbench > Devices: CNCn_PATH Started"
    }

    # Devices that must stay Started across dwcore restarts (SINC's OPC UA client), as left by this step's restarts
    if (@($paths.KeepStarted).Count) { Test-DwDevicesStarted -Paths $paths -Names @($paths.KeepStarted) -Phase $phase }

    Set-DwCncAssetValues -Manifest $Manifest -Cncs $cncs -Phase $phase
    Write-Log PASS 'deviceWise CNCnetPDM integration complete.'
}
