#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    APC Configuration Deployment Wizard - Headless Orchestrator
.DESCRIPTION
    Automates the APC system configuration workflow (D01555607) across all installed
    VM components. Runs all 13 configuration phases sequentially. Supports -SkipTo
    for recovery after partial runs. Does not store passwords in plain text.
.PARAMETER StateFile
    Path to the configuration state file. Default: C:\APC_Config\.config_state.json
.PARAMETER SkipTo
    Start at a specific phase number (1-13) for testing or recovery.
#>
[CmdletBinding()]
param(
    [string]$StateFile = 'C:\APC_Config\.config_state.json',
    [ValidateRange(1,13)]
    [int]$SkipTo = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:RootDir      = $PSScriptRoot
$Script:ModulesDir   = Join-Path $Script:RootDir 'modules'
$Script:ManifestPath = Join-Path $Script:RootDir 'APC_ConfigManifest.json'
$Script:StateFile    = $StateFile
$Script:LogDir       = 'C:\APC_Config\Logs'
$Script:LogFile      = $null

$Global:ConfigResults = [System.Collections.Generic.List[hashtable]]::new()

#region -- Logging -----------------------------------------------------------

function Initialize-Log {
    if (-not (Test-Path $Script:LogDir)) {
        New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
    }
    $Script:LogFile = Join-Path $Script:LogDir "APC_Config_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    Write-Log INFO "========================================================"
    Write-Log INFO " APC Configuration Deployment Wizard - Session Start"
    Write-Log INFO " Host : $env:COMPUTERNAME"
    Write-Log INFO " User : $env:USERNAME"
    Write-Log INFO " Time : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Log INFO "========================================================"
}

function Write-Log {
    [CmdletBinding()]
    param(
        [ValidateSet('INFO','WARN','ERROR','PASS','FAIL','STEP','PROMPT')]
        [string]$Level,
        [string]$Message
    )
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Message"
    if ($Script:LogFile) { Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8 }
    switch ($Level) {
        'INFO'   { Write-Host $line -ForegroundColor Cyan }
        'WARN'   { Write-Host $line -ForegroundColor Yellow }
        'ERROR'  { Write-Host $line -ForegroundColor Red }
        'PASS'   { Write-Host $line -ForegroundColor Green }
        'FAIL'   { Write-Host $line -ForegroundColor Red }
        'STEP'   { Write-Host "`n$('=' * 60)`n  STEP: $Message`n$('=' * 60)" -ForegroundColor Magenta }
        'PROMPT' { Write-Host $line -ForegroundColor White }
    }
}

function Add-Result {
    param(
        [string]$Phase,
        [string]$Check,
        [ValidateSet('PASS','FAIL','SKIP','MANUAL','WARN')]
        [string]$Status,
        [string]$Detail = ''
    )
    $Global:ConfigResults.Add(@{
        Phase     = $Phase
        Check     = $Check
        Status    = $Status
        Detail    = $Detail
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    })
    Write-Log $Status "$Phase | $Check$(if ($Detail) { " | $Detail" })"
}

#endregion

#region -- State Management --------------------------------------------------

function Get-ConfigState {
    if (Test-Path $Script:StateFile) {
        try { return Get-Content $Script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { Write-Log WARN "Could not parse state file: $_" }
    }
    return $null
}

function Save-ConfigState {
    param([hashtable]$State)
    $dir = Split-Path $Script:StateFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
    $State['LastUpdated'] = (Get-Date -Format 'o')
    $serializable = @{}
    foreach ($key in $State.Keys) {
        if ($State[$key] -isnot [System.Security.SecureString]) {
            $serializable[$key] = $State[$key]
        }
    }
    $serializable | ConvertTo-Json -Depth 10 | Set-Content $Script:StateFile -Encoding UTF8
}

#endregion

#region -- Manifest ----------------------------------------------------------

function Import-Manifest {
    if (-not (Test-Path $Script:ManifestPath)) {
        throw "Manifest not found: $Script:ManifestPath"
    }
    $m = Get-Content $Script:ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Log INFO "Manifest loaded: APC $($m.APC.Version) - $($m.APC.ReleaseLabel)"
    return $m
}

#endregion

#region -- Credential Collection ---------------------------------------------

function Read-PasswordDialog {
    param([string]$Prompt)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'APC Configuration Wizard - Credentials'
    $form.Size = New-Object System.Drawing.Size(420, 150)
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox     = $false
    $form.MinimizeBox     = $false
    $form.TopMost         = $true

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Prompt
    $lbl.Location = New-Object System.Drawing.Point(10, 15)
    $lbl.Size     = New-Object System.Drawing.Size(385, 20)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.UseSystemPasswordChar = $true
    $tb.Location = New-Object System.Drawing.Point(10, 42)
    $tb.Size     = New-Object System.Drawing.Size(385, 24)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'; $ok.Location = New-Object System.Drawing.Point(310, 78)
    $ok.Size = New-Object System.Drawing.Size(85, 26); $ok.DialogResult = 'OK'
    $form.AcceptButton = $ok
    $form.Controls.AddRange(@($lbl, $tb, $ok))
    $form.Add_Shown({ $tb.Focus() })

    if ($form.ShowDialog() -eq 'OK') {
        $ss = New-Object System.Security.SecureString
        foreach ($c in $tb.Text.ToCharArray()) { $ss.AppendChar($c) }
        $ss.MakeReadOnly(); $tb.Text = ''; return $ss
    }
    return New-Object System.Security.SecureString
}

function Get-ConfigCredentials {
    param([string]$SiteCode = '')
    Write-Host "`n$('=' * 60)" -ForegroundColor Cyan
    Write-Host '  APC CONFIGURATION - CREDENTIALS' -ForegroundColor Cyan
    Write-Host "$('=' * 60)`n" -ForegroundColor Cyan
    Write-Host '  A dialog will open for each password.' -ForegroundColor Yellow
    $creds = @{}
    $creds['SiteDBPassword']     = Read-PasswordDialog -Prompt 'Site DB PostgreSQL password'
    $creds['APCUserPassword']    = Read-PasswordDialog -Prompt 'apcuser password (local TSDB)'
    $creds['MedtronicSUPassword']= Read-PasswordDialog -Prompt 'MedtronicSU password (OPC UA user)'
    $creds['DeviceWisePassword'] = Read-PasswordDialog -Prompt 'deviceWise admin password'
    Write-Log INFO "Credentials collected (values redacted)."
    return $creds
}

function Get-OperatorInfo {
    Write-Host "`n$('=' * 60)" -ForegroundColor Cyan
    Write-Host '  APC CONFIGURATION DEPLOYMENT WIZARD' -ForegroundColor Cyan
    Write-Host "$('=' * 60)`n" -ForegroundColor Cyan

    $info = @{}
    $info['OperatorName'] = Read-Host 'Operator full name'
    $info['OperatorRole'] = Read-Host 'Operator role (e.g., Manufacturing Engineer)'

    Write-Host "`nAvailable sites: MCR, MFW, MPR, MWR"
    $info['SiteCode']   = (Read-Host 'Site code').ToUpper()
    $info['SiteDBHost'] = Read-Host 'Site DB hostname'
    $info['SiteDBUser'] = Read-Host 'Site DB username'
    $info['SINCEmail']  = Read-Host 'SINC email distribution list (semicolon-separated)'
    $docCount = Read-Host 'DOC instance count (1/2/3)'
    $info['DOCCount']   = [int]$docCount

    $info['VMHostname'] = $env:COMPUTERNAME
    $info['StartTime']  = Get-Date -Format 'o'

    Write-Host "`nConfiguration details:" -ForegroundColor Yellow
    Write-Host "  Operator : $($info.OperatorName) ($($info.OperatorRole))"
    Write-Host "  Site     : $($info.SiteCode)"
    Write-Host "  Site DB  : $($info.SiteDBHost)"
    Write-Host "  VM       : $($info.VMHostname)"
    Write-Host "  DOC count: $($info.DOCCount)"

    $confirm = Read-Host "`nProceed? (Y/N)"
    if ($confirm -notmatch '^[Yy]') { Write-Log INFO "Cancelled by operator."; exit 0 }
    return $info
}

#endregion

#region -- Phase Runner ------------------------------------------------------

function Invoke-Phase {
    param(
        [int]$PhaseNumber,
        [string]$ModuleFile,
        [string]$FunctionName,
        [object]$Manifest,
        [hashtable]$State
    )
    $modulePath = Join-Path $Script:ModulesDir $ModuleFile
    if (-not (Test-Path $modulePath)) {
        Write-Log ERROR "Module not found: $modulePath"; throw "Missing module: $ModuleFile"
    }
    Write-Log STEP "Phase $PhaseNumber - $(($ModuleFile -replace '^\d+-','') -replace '\.ps1$','')"
    . $modulePath
    try {
        & $FunctionName -Manifest $Manifest -State $State
        Write-Log PASS "Phase $PhaseNumber completed successfully."
        return $true
    } catch {
        Write-Log ERROR "Phase $PhaseNumber failed: $_"
        Add-Result -Phase "Phase$PhaseNumber" -Check "Phase Execution" -Status FAIL -Detail $_.Exception.Message
        return $false
    }
}

#endregion

#region -- Sign-off ----------------------------------------------------------

function Request-FinalSignOff {
    Write-Host "`n$('=' * 60)" -ForegroundColor Green
    Write-Host '  APC CONFIGURATION COMPLETE - SIGN-OFF' -ForegroundColor Green
    Write-Host "$('=' * 60)`n" -ForegroundColor Green

    $pass   = ($Global:ConfigResults | Where-Object { $_.Status -eq 'PASS'   }).Count
    $fail   = ($Global:ConfigResults | Where-Object { $_.Status -eq 'FAIL'   }).Count
    $manual = ($Global:ConfigResults | Where-Object { $_.Status -eq 'MANUAL' }).Count
    $warn   = ($Global:ConfigResults | Where-Object { $_.Status -eq 'WARN'   }).Count

    Write-Host "  PASS:   $pass"   -ForegroundColor Green
    Write-Host "  FAIL:   $fail"   -ForegroundColor $(if ($fail -gt 0) { 'Red' } else { 'Green' })
    Write-Host "  WARN:   $warn"   -ForegroundColor Yellow
    Write-Host "  MANUAL: $manual" -ForegroundColor Yellow

    if ($fail -gt 0) { Write-Host "`n[WARNING] $fail check(s) failed." -ForegroundColor Red }

    $reviewer     = Read-Host 'Reviewer full name'
    $reviewerRole = Read-Host 'Reviewer role'
    $signoff      = Read-Host "Type 'APPROVED' to sign off, or 'REJECTED' to flag issues"

    Write-Log INFO "Sign-off: $reviewer ($reviewerRole) - $signoff"
    return @{ ReviewerName = $reviewer; ReviewerRole = $reviewerRole; Decision = $signoff.ToUpper(); Timestamp = (Get-Date -Format 'o') }
}

#endregion

#region -- Main --------------------------------------------------------------

function Main {
    Initialize-Log

    $manifest = Import-Manifest

    $operatorInfo = Get-OperatorInfo
    $creds        = Get-ConfigCredentials -SiteCode $operatorInfo.SiteCode
    $startPhase   = if ($SkipTo -gt 0) { $SkipTo } else { 1 }

    $state = @{
        CurrentPhase      = $startPhase
        OperatorName      = $operatorInfo.OperatorName
        OperatorRole      = $operatorInfo.OperatorRole
        SiteCode          = $operatorInfo.SiteCode
        SiteDBHost        = $operatorInfo.SiteDBHost
        SiteDBUser        = $operatorInfo.SiteDBUser
        SINCEmail         = $operatorInfo.SINCEmail
        DOCCount          = $operatorInfo.DOCCount
        VMHostname        = $env:COMPUTERNAME
        StartTime         = $operatorInfo.StartTime
        CompletedPhases   = @()
        CNCMachines       = @()
        DeviceWisePort    = 0
        DeviceWiseToken   = ''
    }
    $state['SiteDBPassword']      = $creds.SiteDBPassword
    $state['APCUserPassword']     = $creds.APCUserPassword
    $state['MedtronicSUPassword'] = $creds.MedtronicSUPassword
    $state['DeviceWisePassword']  = $creds.DeviceWisePassword
    Save-ConfigState -State $state

    $phases = @(
        @{ Number =  1; File = '01-SiteDBFetch.ps1';      Fn = 'Invoke-SiteDBFetch'      },
        @{ Number =  2; File = '02-TimescaleDB.ps1';      Fn = 'Invoke-TimescaleDBSetup' },
        @{ Number =  3; File = '03-SINCFolders.ps1';      Fn = 'Invoke-SINCFolders'      },
        @{ Number =  4; File = '04-DeviceWiseBase.ps1';   Fn = 'Invoke-DeviceWiseBase'   },
        @{ Number =  5; File = '05-DeviceWiseCHMI.ps1';   Fn = 'Invoke-DeviceWiseCHMI'   },
        @{ Number =  6; File = '06-DeviceWiseSINC.ps1';   Fn = 'Invoke-DeviceWiseSINC'   },
        @{ Number =  7; File = '07-DeviceWiseCNCPDM.ps1'; Fn = 'Invoke-DeviceWiseCNCPDM' },
        @{ Number =  8; File = '08-CNCnetPDM.ps1';        Fn = 'Invoke-CNCnetPDMConfig'  },
        @{ Number =  9; File = '09-DOCConfig.ps1';        Fn = 'Invoke-DOCConfig'        },
        @{ Number = 10; File = '10-DataApps.ps1';         Fn = 'Invoke-DataAppsConfig'   },
        @{ Number = 11; File = '11-CHMI.ps1';             Fn = 'Invoke-CHMIConfig'       },
        @{ Number = 12; File = '12-Backup.ps1';           Fn = 'Invoke-ApplicationBackup'},
        @{ Number = 13; File = '13-Verification.ps1';     Fn = 'Invoke-ConfigVerification'}
    )

    $allPassed = $true
    foreach ($phase in $phases) {
        if ($phase.Number -lt $startPhase) { continue }
        $state.CurrentPhase = $phase.Number
        Save-ConfigState -State $state

        $ok = Invoke-Phase -PhaseNumber $phase.Number -ModuleFile $phase.File `
                           -FunctionName $phase.Fn -Manifest $manifest -State $state
        if ($ok) {
            if ($state.CompletedPhases -notcontains $phase.Number) { $state.CompletedPhases += $phase.Number }
            Save-ConfigState -State $state
        } else {
            $allPassed = $false
            $choice = Read-Host "`nPhase $($phase.Number) reported errors. Continue? (Y/N)"
            if ($choice -notmatch '^[Yy]') {
                Write-Log WARN "Stopped by operator after phase $($phase.Number) failure."
                break
            }
        }
    }

    if ($state.CompletedPhases -contains 13) {
        $signOff = Request-FinalSignOff
        $state['SignOff'] = $signOff
        Save-ConfigState -State $state
        if ($signOff.Decision -eq 'APPROVED') {
            Write-Log PASS "Configuration APPROVED by $($signOff.ReviewerName). Proceed to APC System Execution."
        } else {
            Write-Log WARN "Configuration flagged as $($signOff.Decision). Resolve issues before execution."
        }
    }

    Write-Log INFO "Session complete. Log: $Script:LogFile"
    Write-Host "`nConfiguration session complete. See log: $Script:LogFile" -ForegroundColor Cyan
}

Main
#endregion
