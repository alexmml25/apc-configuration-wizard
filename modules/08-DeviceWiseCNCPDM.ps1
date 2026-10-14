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

    Add-Result -Phase $phase -Check 'CNCnetPDM connection' -Status MANUAL `
        -Detail "Workbench > Administration > CNCnetPDM Instance Management: $instance Connected; Devices: CNCn_PATH started"

    Set-DwCncAssetValues -Manifest $Manifest -Cncs $cncs -Phase $phase
    Write-Log PASS 'deviceWise CNCnetPDM integration complete.'
}
