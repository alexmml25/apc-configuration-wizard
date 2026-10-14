#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    TEST VM ONLY. Runs one of the wizard's deviceWise steps (4 base platform, 5 CHMI, 6 SINC, 8 CNCnetPDM) or Step 7 (CNCnetPDM) or Step 13 (verification; look at its deviceWise / CNCnetPDM lines) on its own.
.DESCRIPTION
    Loads the wizard's manifest and the step's module and runs it with the CNCs given here, so
    Step 1 (Site DB) is not needed. Results and the log go to C:\APC_Config\Test-Step0<n>_<ts>\
    (Logs, Backups with the safety copy of the gateway databases).
    -PackageDir (the package payload folder from tools\Export-DwPackagePayload.ps1) / -Baseline (the .dbk
    file) override the repository share paths from the manifest.
    This CHANGES the gateway.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Test-DwStep.ps1 -Step 5 -Cnc "Citizen 01|CITIZEN_L20X_IV,Citizen 03|CITIZEN_L20X_IV,Citizen 08|CITIZEN_L20X_IV"
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Test-DwStep.ps1 -Step 4 -Cnc 'Citizen 01|CITIZEN_L20X_IV' -Baseline D:\APC_Config\Baseline_Backup.dbk -PackageDir D:\APC_Config\packages
#>
param(
    [ValidateSet(4, 5, 6, 7, 8, 13)] [int]$Step = 4,
    # Step 6: the SINC email list (';' or ',' separated), as entered in the wizard
    [string]$Email = '',
    # Step 13: the site code shown in the report
    [ValidateSet('MPR', 'MCR')] [string]$Site = 'MPR',
    # 'Machine name|CNC type[|DLL name|IP address]' per CNC, in CNC1..CNC3 order (the Site DB f_cnc_asset,
    # type, f_dllname, f_ip_address). DLL and IP are needed by Step 7 only (DLL default citizenm.dll).
    [Parameter(Mandatory)] [string[]]$Cnc,
    [string]$PackageDir,
    [string]$Baseline
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$steps = @{
    4 = @{ File = '04-DeviceWiseBase.ps1'; Fn = 'Invoke-DeviceWiseBase'; Name = 'deviceWise base platform' }
    5 = @{ File = '05-DeviceWiseCHMI.ps1'; Fn = 'Invoke-DeviceWiseCHMI'; Name = 'deviceWise CHMI' }
    6 = @{ File = '06-DeviceWiseSINC.ps1'; Fn = 'Invoke-DeviceWiseSINC'; Name = 'deviceWise SINC' }
    7 = @{ File = '07-CNCnetPDM.ps1';        Fn = 'Invoke-CNCnetPDM';        Name = 'CNCnetPDM configuration' }
    8 = @{ File = '08-DeviceWiseCNCPDM.ps1'; Fn = 'Invoke-DeviceWiseCNCPDM'; Name = 'deviceWise CNCnetPDM' }
    13 = @{ File = '13-Verification.ps1';    Fn = 'Invoke-Verification';     Name = 'verification (read-only)' }
}
$def  = $steps[$Step]
$run  = Join-Path 'C:\APC_Config' ("Test-Step{0:D2}_{1}" -f $Step, (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path (Join-Path $run 'Logs') -Force | Out-Null
$Script:LogFile = Join-Path $run ("Logs\step{0:D2}.log" -f $Step)

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
    if ($p.Count -lt 2 -or -not $p[0].Trim() -or -not $p[1].Trim()) { throw "Use 'Machine name|CNC type[|DLL|IP]', got '$c'" }
    $dll = if ($p.Count -ge 3 -and $p[2].Trim()) { $p[2].Trim() } else { 'citizenm.dll' }
    $ip  = if ($p.Count -ge 4) { $p[3].Trim() } else { '' }
    if ($Step -eq 7 -and -not $ip) { throw "Step 7 needs the IP address: 'Machine name|CNC type|DLL|IP', got '$c'" }
    # the same fields Step 1 reads from the Site DB; an empty Port means the CNCnetPDM default (683)
    [pscustomobject]@{ MachineName = $p[0].Trim(); CNCType = $p[1].Trim(); AssetFamily = $p[1].Trim(); DLLName = $dll; IPAddress = $ip; Port = '' }
}

$manifestPath = Join-Path $root 'APC_ConfigManifest.json'
$manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host "Manifest: $manifestPath ($((Get-Item $manifestPath).LastWriteTime)) - packages: $($manifest.DeviceWise.PackagesRepoSubPath)"
if ($PackageDir)  { $manifest.DeviceWise.PackagesRepoSubPath = (Resolve-Path $PackageDir).ProviderPath }
if ($Baseline)    { $manifest.DeviceWise.BaselineRepoSubPath = (Resolve-Path $Baseline).ProviderPath }

$state = @{
    RunRoot               = $run
    CNCMachines           = @($machines)
    DOCCount              = @($machines).Count
    DOCMachineAssignments = @($machines | ForEach-Object { $_.MachineName })
    SINCEmail             = $Email
    SiteCode              = $Site
}

Write-Host "Step $Step ($($def.Name)) test on $env:COMPUTERNAME - run folder $run" -ForegroundColor Cyan
$machines | ForEach-Object -Begin { $i = 0 } -Process { $i++; Write-Host ("  CNC{0} = {1} ({2})" -f $i, $_.MachineName, $_.CNCType) }
Write-Host 'This changes the deviceWise gateway configuration. TEST VM ONLY.' -ForegroundColor Yellow
if ((Read-Host "Type STEP$Step to continue") -ne "STEP$Step") { Write-Host 'Cancelled.'; return }

. (Join-Path $root "modules\$($def.File)")
$failed = $null
try { & $def.Fn -Manifest $manifest -State $state -NonInteractive }
catch { $failed = $_; Write-Log ERROR "Step $Step stopped: $($_.Exception.Message)" }

Write-Host "`r`n===== Summary =====" -ForegroundColor Cyan
$Global:ConfigResults | Group-Object Status | ForEach-Object { Write-Host ("  {0,-7} {1}" -f $_.Name, $_.Count) }
$Global:ConfigResults | Where-Object { $_.Status -in 'FAIL', 'WARN', 'MANUAL' } |
    ForEach-Object { Write-Host ("  [{0}] {1} - {2}" -f $_.Status, $_.Check, $_.Detail) }
$Global:ConfigResults | Export-Csv (Join-Path $run ("Logs\step{0:D2}-results.csv" -f $Step)) -NoTypeInformation -Encoding UTF8
Write-Host "Log: $Script:LogFile"
if ($failed) { exit 1 }
