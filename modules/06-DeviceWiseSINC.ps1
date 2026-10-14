#Requires -Version 5.1
<#
.SYNOPSIS
    Step 6 - deviceWise SINC integration (SOP D01555607 2.1.1, deviceWise - SINC Integration).
.DESCRIPTION
    No Workbench and no API: imports the SINC part of the approved baseline backup through the
    gateway's import folder (DeviceWise.ps1), as the SOP's Projects > Import of the SINC project:
      - project SINC and its triggers (SINC/*; saved as started in the baseline)
      - its local-DB transactions (Manifest.DeviceWise.SINCImport.Transactions, built-in LOCALDB1)
      - devices SINC_SETTING (settings) and Devicewise_OPC_UA_Sinc (OPC UA client to this gateway's
        own server, opc.tcp://localhost:48020, anonymous, security None)
      - local tables CNC_SETTING, CNC_FILE_STATUS, CNC_TRACKER_LOG; only CNC_SETTING gets rows
        (user decision 2026-10-13: a new VM starts without the baseline gateway's file history)
    This VM's values:
      - CNC_SETTING: one row per assigned CNC - ASSET_NAME CNCn, CNC_ASSET = the CNCnetPDM machine name
        (Site DB f_cnc_asset), CNC_TYPE, alarm values from Manifest.SINCDefaultSettings (as on the
        production gateways: 2_599 / 1.0 / PATH / 18000 / 5, user decision 2026-10-13). The SOP's
        CNC_ASSET_Management + CNC_Settings tables are this one table on the real gateways.
      - EMAIL_TO (SINC/0_DefaultConfiguration) = the wizard's SINC email list (State.SINCEmail).
    Checks: every item status 0, the SOP's SINC components imported (Manifest.SINCComponents, with the
    baseline's 10_BuildAndSendEmail / 10_SendAlertEmail instead of the SOP's 10_SendEmail, and
    SINCMasterResetComponents), every SINC trigger started (DWCORE.db triggers.state = 1), the
    staging\SINC\CNCn\Processing / DoneSuccess / DoneError folders (Step 3).
    dwcore restarts for the import, which empties CNCAsset / CNCType, so they are written again.
#>

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'DeviceWise.ps1')

function Invoke-DeviceWiseSINC {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [switch]$NonInteractive
    )

    Write-Log STEP 'deviceWise SINC Integration'
    $dw    = $Manifest.DeviceWise
    $paths = Get-DwPaths -Manifest $Manifest
    $phase = 'deviceWise SINC'
    $cfg   = $dw.SINCImport

    $cncs = Get-AssignedCNCs -State $State -Manifest $Manifest   # already an array (return ,$result); @() would nest it
    if (-not $cncs.Count) { throw 'No CNC machines in the state. Run Step 1 first.' }
    if (-not (Test-Path (Join-Path $paths.Packages 'dwfilewatcher.xml'))) { throw 'The deviceWise base platform is not set up (FileWatcher package missing). Run Step 4 first.' }

    # EMAIL_TO: the wizard asks for a ';' separated list; SINC sends to a ',' separated one (as in the baseline)
    $email = (@(([string]$State['SINCEmail']) -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) -join ','
    if ($email.Length -gt 128) { throw "The SINC email list is $($email.Length) characters; EMAIL_TO holds at most 128." }

    $baseline = Get-DwBaseline -Manifest $Manifest
    Write-Log INFO "Baseline: $($baseline.FullName)"
    $projects = @($cfg.Projects)
    $build = New-DwImportFromBaseline -BaselinePath $baseline.FullName -Keep {
        param($type, $name)
        switch ($type) {
            'project'     { $projects -contains $name }
            'trigger'     { @($projects | Where-Object { $name -like "$_/*" }).Count -gt 0 }
            'transaction' { @($cfg.Transactions) -contains $name }
            'device'      { @($cfg.Devices) -contains $name }
            'dbtable'     { @($cfg.Tables) -contains $name }
            'dbtabledata' { @($cfg.TablesWithData) -contains $name }
            default       { $false }
        }
    }
    $xml = $build.Xml

    # CNC_SETTING rows for this VM (column order taken from the baseline's own data)
    $data = $xml.SelectSingleNode("//exportcontent[@type='dbtabledata' and @name='CNC_SETTING']/exportitem")
    if (-not $data) { throw 'CNC_SETTING data not found in the baseline.' }
    $table = ConvertFrom-DwTableData -Base64 $data.InnerText
    $set   = $Manifest.SINCDefaultSettings
    $rows  = New-Object System.Collections.Generic.List[object]   # a list: one row would otherwise unroll into its fields
    foreach ($c in $cncs) {
        $values = @{
            ASSET_NAME = "CNC$($c.CNCIndex)"; CNC_ASSET = [string]$c.MachineName; CNC_TYPE = [string]$c.CNCType
            ALARM_TAG  = [string]$set.ALARM_TAG; ALARM_VALUE = [string]$set.ALARM_VALUE; ALARM_PATH = [string]$set.ALARM_PATH
            WAIT_TIME  = [string]$set.WAIT_TIME; RETRY_COUNT = [string]$set.RETRY_COUNT; NOTES = [string]$set.NOTES
        }
        $rows.Add([string[]]@($table.Columns | ForEach-Object {
            if (-not $values.ContainsKey($_)) { throw "CNC_SETTING has a column the wizard does not fill: $_" }
            $values[$_]
        }))
    }
    $data.InnerText = ConvertTo-DwTableData -Columns $table.Columns -Rows $rows.ToArray()
    foreach ($r in $rows) { Write-Log INFO ("  CNC_SETTING: " + ($r -join ' | ')) }

    # EMAIL_TO default of SINC/0_DefaultConfiguration
    $var = $xml.SelectSingleNode("//exportcontent[@type='trigger' and @name='SINC/0_DefaultConfiguration']//VariableInfo[@name='EMAIL_TO']")
    if (-not $var) { throw 'EMAIL_TO not found in SINC/0_DefaultConfiguration in the baseline.' }
    $var.SetAttribute('default', $email)
    Write-Log INFO "  EMAIL_TO = $(if ($email) { $email } else { '(empty)' })"
    Write-Log INFO ("Import: {0} item(s) - project {1}, {2} transaction(s), devices {3}, tables {4} (rows only in {5})" -f `
        $build.Items.Count, ($projects -join ', '), @($cfg.Transactions).Count, (@($cfg.Devices) -join ', '), (@($cfg.Tables) -join ', '), (@($cfg.TablesWithData) -join ', '))

    $safety = Join-Path (Get-RunDir -State $State -Name Backups -Manifest $Manifest) 'deviceWise-before-step6'
    try {
        $res = Invoke-DwImport -Paths $paths -Xml $xml -Label 'step6-sinc' -SafetyDir $safety -SaveDatabases -TimeoutSec $dw.ImportTimeoutSec
    } catch {
        Add-Result -Phase $phase -Check 'SINC import' -Status FAIL -Detail $_.Exception.Message
        throw
    }
    [void](Add-DwImportResults -Phase $phase -Result $res -Summary 'SINC import')

    $rowItem = @($res.Items | Where-Object { $_.Type -eq 'dbtabledata' -and $_.Item -eq 'CNC_SETTING' }) | Select-Object -First 1
    $rowsOk  = $rowItem -and $rowItem.Status -eq 0
    Add-Result -Phase $phase -Check 'CNC_SETTING rows' -Status $(if ($rowsOk) { 'PASS' } else { 'FAIL' }) `
        -Detail ("{0}{1}" -f $(if ($rowsOk) { '' } else { "not imported (status $(if ($rowItem) { $rowItem.Status } else { 'missing' })): " }),
                 (($rows | ForEach-Object { "{0} = {1} ({2})" -f $_[0], $_[@($table.Columns).IndexOf('CNC_ASSET')], $_[@($table.Columns).IndexOf('CNC_TYPE')] }) -join '; '))
    Add-Result -Phase $phase -Check 'SINC EMAIL_TO' -Status $(if ($email) { 'PASS' } else { 'WARN' }) `
        -Detail $(if ($email) { $email } else { 'no SINC email list entered - SINC alert emails go nowhere' })

    # The SOP's component lists: present = imported with status 0
    $imported = @($res.Items | Where-Object { $_.Type -eq 'trigger' -and $_.Status -eq 0 } | ForEach-Object { ($_.Item -split '/', 2)[-1] })
    foreach ($comp in @($Manifest.SINCComponents) + @($Manifest.SINCMasterResetComponents)) {
        $ok = $imported -contains $comp
        Add-Result -Phase $phase -Check "Component $comp" -Status $(if ($ok) { 'PASS' } else { 'FAIL' }) -Detail $(if ($ok) { 'imported' } else { 'not imported' })
    }

    # Started: DWCORE.db triggers.state = 1 (what Workbench shows as Started / Loaded)
    try {
        $states  = Get-DwTriggerStates -Paths $paths -Project 'SINC'
        $stopped = @($states.Keys | Where-Object { $states[$_] -ne 1 } | Sort-Object)
        foreach ($name in $stopped) {
            # a file watcher cannot start while its watch folder is missing (state 3, fresh VM 2026-10-14)
            $why = "start it in Workbench > Projects > SINC"
            if ($name -match '^2_MonitorNewFileAtWatcher_(CNC\d)$') {
                $dir = Join-Path $dw.SINCStaging $Matches[1]
                if (-not (Test-Path $dir)) { $why = "its watch folder $dir is missing - run Step 3, then restart dwcore" }
            }
            Add-Result -Phase $phase -Check "Started $name" -Status FAIL -Detail "state $($states[$name]) - $why"
        }
        Add-Result -Phase $phase -Check 'SINC triggers started' -Status $(if ($stopped.Count -or -not $states.Count) { 'FAIL' } else { 'PASS' }) `
            -Detail ("{0} of {1} trigger(s) started" -f ($states.Count - $stopped.Count), $states.Count)
    } catch {
        Add-Result -Phase $phase -Check 'SINC triggers started' -Status MANUAL `
            -Detail "could not read DWCORE.db ($($_.Exception.Message)). Workbench > Projects > SINC: State = Started, Status = Loaded"
    }

    # SINC folders (made by Step 3) - the file watchers watch staging\SINC\CNCn
    foreach ($c in $cncs) {
        $base = Join-Path $dw.SINCStaging "CNC$($c.CNCIndex)"
        $missing = @('Processing', 'DoneSuccess', 'DoneError' | Where-Object { -not (Test-Path (Join-Path $base $_)) })
        Add-Result -Phase $phase -Check "SINC folders CNC$($c.CNCIndex)" -Status $(if ($missing.Count) { 'WARN' } else { 'PASS' }) `
            -Detail $(if ($missing.Count) { "missing in $($base): $($missing -join ', ') - run Step 3" } else { $base })
    }

    # SINC's devices started; Devicewise_OPC_UA_Sinc (its OPC UA client to this gateway) is saved as Stopped
    # at every dwcore shutdown, which Restart-DwCore makes up for (manifest DeviceWise.KeepStartedDevices)
    Test-DwDevicesStarted -Paths $paths -Names @($cfg.Devices) -Phase $phase

    Set-DwCncAssetValues -Manifest $Manifest -Cncs $cncs -Phase $phase
    Write-Log PASS 'deviceWise SINC integration complete.'
}
