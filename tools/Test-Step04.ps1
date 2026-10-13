#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    TEST VM ONLY. Runs the wizard's Step 4 (deviceWise base platform) on its own.
.DESCRIPTION
    Loads the wizard's manifest and modules\04-DeviceWiseBase.ps1 and runs Invoke-DeviceWiseBase with
    the CNCs given here, so Step 1 (Site DB) is not needed. Results and the log go to
    C:\APC_Config\Test-Step04_<ts>\ (Logs, Backups with the safety copy of the gateway databases).
    -PackageDir (the package payload folder from tools\Export-DwPackagePayload.ps1) / -Baseline (the .dbk
    file) override the repository share paths from the manifest.
    This CHANGES the gateway.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Test-Step04.ps1 -Cnc 'Citizen 01|CITIZEN_L20X_IV','Citizen 03|CITIZEN_L20X_IV','Citizen 08|CITIZEN_L20X_IV'
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Test-Step04.ps1 -Cnc 'Citizen 01|CITIZEN_L20X_IV' -Baseline D:\APC_Config\Baseline_Backup.dbk -PackageDir D:\APC_Config\packages
#>
param(
    # 'Machine name|CNC type' per CNC, in CNC1..CNC3 order (the Site DB f_cnc_asset and type)
    [Parameter(Mandatory)] [string[]]$Cnc,
    [string]$PackageDir,
    [string]$Baseline
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$run  = Join-Path 'C:\APC_Config' ("Test-Step04_{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path (Join-Path $run 'Logs') -Force | Out-Null
$Script:LogFile = Join-Path $run 'Logs\step04.log'

function Write-Log {
    param([string]$Level, [string]$Message)
    $line = "[{0}][{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8
    $color = @{ WARN = 'Yellow'; ERROR = 'Red'; FAIL = 'Red'; PASS = 'Green'; STEP = 'Magenta'; MANUAL = 'Yellow' }[$Level]
    if ($color) { Write-Host $line -ForegroundColor $color } else { Write-Host $line -ForegroundColor Cyan }
}
$Global:ConfigResults = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Phase, [string]$Check, [ValidateSet('PASS','FAIL','SKIP','MANUAL','WARN')] [string]$Status, [string]$Detail = '')
    $Global:ConfigResults.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail })
    Write-Log $Status "$Phase | $Check$(if ($Detail) { " | $Detail" })"
}

# powershell -File passes "a,b" as one string; split on commas between quoted CNCs
$Cnc = @($Cnc | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$machines = foreach ($c in $Cnc) {
    $p = $c -split '\|'
    if ($p.Count -lt 2 -or -not $p[0].Trim() -or -not $p[1].Trim()) { throw "Use 'Machine name|CNC type', got '$c'" }
    [pscustomobject]@{ MachineName = $p[0].Trim(); CNCType = $p[1].Trim(); AssetFamily = $p[1].Trim(); DLLName = 'n/a' }
}

$manifest = Get-Content (Join-Path $root 'APC_ConfigManifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($PackageDir)  { $manifest.DeviceWise.PackagesRepoSubPath = (Resolve-Path $PackageDir).Path }
if ($Baseline)    { $manifest.DeviceWise.BaselineRepoSubPath = (Resolve-Path $Baseline).Path }

$state = @{
    RunRoot               = $run
    CNCMachines           = @($machines)
    DOCCount              = @($machines).Count
    DOCMachineAssignments = @($machines | ForEach-Object { $_.MachineName })
}

Write-Host "Step 4 test on $env:COMPUTERNAME - run folder $run" -ForegroundColor Cyan
$machines | ForEach-Object -Begin { $i = 0 } -Process { $i++; Write-Host ("  CNC{0} = {1} ({2})" -f $i, $_.MachineName, $_.CNCType) }
Write-Host 'This installs packages and imports the base configuration into the gateway. TEST VM ONLY.' -ForegroundColor Yellow
if ((Read-Host 'Type STEP4 to continue') -ne 'STEP4') { Write-Host 'Cancelled.'; return }

. (Join-Path $root 'modules\04-DeviceWiseBase.ps1')
$failed = $null
try { Invoke-DeviceWiseBase -Manifest $manifest -State $state -NonInteractive }
catch { $failed = $_; Write-Log ERROR "Step 4 stopped: $($_.Exception.Message)" }

Write-Host "`r`n===== Summary =====" -ForegroundColor Cyan
$Global:ConfigResults | Group-Object Status | ForEach-Object { Write-Host ("  {0,-7} {1}" -f $_.Name, $_.Count) }
$Global:ConfigResults | Where-Object { $_.Status -in 'FAIL', 'WARN', 'MANUAL' } |
    ForEach-Object { Write-Host ("  [{0}] {1} - {2}" -f $_.Status, $_.Check, $_.Detail) }
$Global:ConfigResults | Export-Csv (Join-Path $run 'Logs\step04-results.csv') -NoTypeInformation -Encoding UTF8
Write-Host "Log: $Script:LogFile"
if ($failed) { exit 1 }
