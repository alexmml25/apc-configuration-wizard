#Requires -Version 5.1
<#
.SYNOPSIS
    Step 5 - deviceWise CHMI integration (SOP D01555607 2.1.1, deviceWise - CHMI Integration).
.DESCRIPTION
    No Workbench and no API: imports the CHMI part of the approved baseline backup through the
    gateway's import folder (DeviceWise.ps1), as the SOP's Projects > Import of the CHMI project:
      - project CHMI and its triggers (CHMI/*; saved as started in the baseline)
      - the transactions the CHMI triggers use (Manifest.DeviceWise.CHMIImport.Transactions) and
        their database connection (CHMIImport.Transports: TimescaleDB = local apcuser@localhost:5432).
        The connection's password is stored encrypted in the baseline, so the local apcuser
        password must be the one used on the baseline gateway.
    Checks: every imported item status 0, every component the SOP lists (Manifest.CHMIComponents
    Loaded / Started) present, and every CHMI trigger started: DWCORE.db triggers.state = 1, which is
    what Workbench shows as Started / Loaded (fresh VM, 2026-10-13). The CNCn_PATH monitors start
    before Step 8 too.
    dwcore restarts for the import, which empties CNCAsset / CNCType, so they are written again.
#>

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'DeviceWise.ps1')

function Invoke-DeviceWiseCHMI {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [switch]$NonInteractive
    )

    Write-Log STEP 'deviceWise CHMI Integration'
    $dw    = $Manifest.DeviceWise
    $paths = Get-DwPaths -Manifest $Manifest
    $phase = 'deviceWise CHMI'
    $cfg   = $dw.CHMIImport

    $cncs = Get-AssignedCNCs -State $State -Manifest $Manifest   # already an array (return ,$result); @() would nest it
    if (-not $cncs.Count) { throw 'No CNC machines in the state. Run Step 1 first.' }
    if (-not (Test-Path (Join-Path $paths.Packages 'dwopcua_server_v3.xml'))) { throw 'The deviceWise base platform is not set up. Run Step 4 first.' }

    $baseline = Get-DwBaseline -Manifest $Manifest
    Write-Log INFO "Baseline: $($baseline.FullName)"
    $projects = @($cfg.Projects)
    $build = New-DwImportFromBaseline -BaselinePath $baseline.FullName -Keep {
        param($type, $name)
        switch ($type) {
            'project'     { $projects -contains $name }
            'trigger'     { @($projects | Where-Object { $name -like "$_/*" }).Count -gt 0 }
            'transaction' { @($cfg.Transactions) -contains $name }
            'transport'   { @($cfg.Transports) -contains $name }
            default       { $false }
        }
    }
    Write-Log INFO ("Import: {0} item(s) - projects {1}, transactions {2}, transports {3}" -f `
        $build.Items.Count, ($projects -join ', '), (@($cfg.Transactions) -join ', '), (@($cfg.Transports) -join ', '))

    $safety = Join-Path (Get-RunDir -State $State -Name Backups -Manifest $Manifest) 'deviceWise-before-step5'
    try {
        $res = Invoke-DwImport -Paths $paths -Xml $build.Xml -Label 'step5-chmi' -SafetyDir $safety -SaveDatabases -TimeoutSec $dw.ImportTimeoutSec
    } catch {
        Add-Result -Phase $phase -Check 'CHMI import' -Status FAIL -Detail $_.Exception.Message
        throw
    }
    [void](Add-DwImportResults -Phase $phase -Result $res -Summary 'CHMI import')

    # The SOP's component lists: present = imported with status 0
    $imported = @($res.Items | Where-Object { $_.Type -eq 'trigger' -and $_.Status -eq 0 } | ForEach-Object { ($_.Item -split '/', 2)[-1] })
    foreach ($list in 'Loaded', 'Started') {
        foreach ($comp in @($Manifest.CHMIComponents.$list)) {
            $ok = $imported -contains $comp
            Add-Result -Phase $phase -Check "Component $comp" -Status $(if ($ok) { 'PASS' } else { 'FAIL' }) `
                -Detail $(if ($ok) { "imported (SOP: $list)" } else { "not imported (SOP: $list)" })
        }
    }
    # Started: DWCORE.db triggers.state = 1 (what Workbench shows as Started / Loaded)
    try {
        $states  = Get-DwTriggerStates -Paths $paths -Project 'CHMI'
        $sop     = @(@($Manifest.CHMIComponents.Loaded) + @($Manifest.CHMIComponents.Started))
        $stopped = @()
        foreach ($name in @($states.Keys | Sort-Object)) {
            if ($states[$name] -eq 1) {
                if ($sop -contains $name) { Add-Result -Phase $phase -Check "Started $name" -Status PASS -Detail 'state 1' }
            } else {
                $stopped += $name
                Add-Result -Phase $phase -Check "Started $name" -Status FAIL -Detail "state $($states[$name]) - start it in Workbench > Projects > CHMI"
            }
        }
        Add-Result -Phase $phase -Check 'CHMI triggers started' -Status $(if ($stopped.Count -or -not $states.Count) { 'FAIL' } else { 'PASS' }) `
            -Detail ("{0} of {1} trigger(s) started" -f ($states.Count - $stopped.Count), $states.Count)
    } catch {
        Add-Result -Phase $phase -Check 'CHMI triggers started' -Status MANUAL `
            -Detail "could not read DWCORE.db ($($_.Exception.Message)). Workbench > Projects > CHMI: State = Started, Status = Loaded"
    }
    # The connection stores the baseline's apcuser password encrypted; Step 2 checks this VM's against the standard one
    if ($State['APCUserPasswordStandard'] -eq $true) {
        Add-Result -Phase $phase -Check 'TimescaleDB connection' -Status PASS -Detail 'apcuser password confirmed as the standard one in Step 2'
    } else {
        Add-Result -Phase $phase -Check 'TimescaleDB connection' -Status MANUAL `
            -Detail "Uses the baseline's stored apcuser password; it works only if this VM's apcuser password (Step 2) is the standard one - not confirmed in this run"
    }

    Set-DwCncAssetValues -Manifest $Manifest -Cncs $cncs -Phase $phase
    Write-Log PASS 'deviceWise CHMI integration complete.'
}
