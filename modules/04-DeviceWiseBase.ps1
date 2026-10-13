#Requires -Version 5.1
<#
.SYNOPSIS
    Step 4 - deviceWise base platform (SOP D01555607 2.1.1, deviceWise - Base Platform Setup).
.DESCRIPTION
    No Workbench and no API: everything goes through the gateway's import folder (DeviceWise.ps1).
      1. Packages OPC UA Server, OPC UA Client, FileWatcher, CNCnetPDM: the approved .pkg files from
         <RepositoryRoot>\<DeviceWise.PackagesRepoSubPath>, one per dwcore restart, skipped when
         already installed (Gateway\dwcore\packages\<name>.xml).
      2. Base configuration from the approved baseline backup (<DeviceWise.BaselineRepoSubPath>,
         5-Automation\Baseline_Backup.dbk = the SJUM7AAPPS0065 backup): licence client (MSPM7AAPPS0342; the source VM's voucher
         removed), OPC UA tag definitions (devices CNC1-3 + their OPC UA device files), OPC UA server
         endpoint (48020, security modes/policies, user auth, anonymous; host = this VM), users
         (MedtronicSU) / roles / policy, gateway name = this VM, CNCn CNCAsset / CNCType = the Site DB
         machine name and type (as variable defaults: the devices do not persist values).
      3. Checks: each imported item status 0, OPC UA endpoint listening, gateway name.
    Projects (CHMI, SINC, TimescaleDB), tables and the CNCn_PATH devices are imported by Steps 5, 6, 8.
    A safety copy of the gateway databases is kept in the run's Backups\deviceWise-before-step4.
#>

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'DeviceWise.ps1')

function Invoke-DeviceWiseBase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [switch]$NonInteractive
    )

    Write-Log STEP 'deviceWise Base Platform Configuration'
    $dw    = $Manifest.DeviceWise
    $paths = Get-DwPaths -Manifest $Manifest
    $phase = 'deviceWise Base'

    $cncs = Get-AssignedCNCs -State $State -Manifest $Manifest   # already an array (return ,$result); @() would nest it
    if (-not $cncs.Count) { throw 'No CNC machines in the state. Run Step 1 first.' }
    if ($cncs.Count -gt @($dw.CNCNodes).Count) { throw "$($cncs.Count) CNCs assigned; the baseline has only $(@($dw.CNCNodes) -join ', ')." }
    foreach ($svc in 'dwcore', 'dwts') {
        if (-not (Get-Service $svc -ErrorAction SilentlyContinue)) { throw "Service $svc not found - is the deviceWise Gateway installed?" }
    }
    if (-not (Test-Path $paths.ImportDir)) { throw "Import folder not found: $($paths.ImportDir)" }

    $pkgDir   = Get-DwRepoPath -Manifest $Manifest -SubPath $dw.PackagesRepoSubPath
    $basePath = Get-DwRepoPath -Manifest $Manifest -SubPath $dw.BaselineRepoSubPath
    if (-not (Test-Path $pkgDir))   { throw "Package folder not found: $pkgDir" }
    if (-not (Test-Path $basePath -PathType Leaf)) { throw "Baseline backup not found: $basePath" }
    $baseline = Get-Item $basePath
    Write-Log INFO "Packages: $pkgDir"
    Write-Log INFO "Baseline: $($baseline.FullName)"

    $safety = Join-Path (Get-RunDir -State $State -Name Backups -Manifest $Manifest) 'deviceWise-before-step4'
    $saved  = $false

    #region -- 1. Packages --------------------------------------------------------

    $pkgFiles = Get-ChildItem $pkgDir -Filter '*.pkg' -File
    foreach ($name in $dw.Packages) {
        if (Test-Path (Join-Path $paths.Packages "$name.xml")) {
            Add-Result -Phase $phase -Check "Package $name" -Status PASS -Detail 'already installed'
            continue
        }
        $file = $pkgFiles | Where-Object { $_.Name -like "dw.$name.*.pkg" } | Sort-Object Name | Select-Object -Last 1
        if (-not $file) {
            Add-Result -Phase $phase -Check "Package $name" -Status FAIL -Detail "no dw.$name.*.pkg in $pkgDir"
            throw "Package $name not found in $pkgDir"
        }
        if (-not $saved) {
            Restart-DwCore -WhileStopped { Save-DwDatabases -Paths $paths -Dest $safety }
            $saved = $true
            Write-Log INFO "Safety copy of the gateway databases: $safety"
        }
        Write-Log INFO "Installing $($file.Name)"
        $r = Install-DwPackage -Paths $paths -PkgFile $file.FullName -Name $name -TimeoutSec $dw.ImportTimeoutSec
        $r.Lines | ForEach-Object { Write-Log INFO "  $_" }
        if (-not $r.Ok) {
            Add-Result -Phase $phase -Check "Package $name" -Status FAIL -Detail $r.Detail
            throw "Package $name was not installed: $($r.Detail)"
        }
        Add-Result -Phase $phase -Check "Package $name" -Status PASS -Detail $file.Name
    }

    #endregion

    #region -- 2. Base configuration import ---------------------------------------

    $gateway = $env:COMPUTERNAME
    $build = New-DwBaseImport -BaselinePath $baseline.FullName -Manifest $Manifest -Cncs $cncs -GatewayName $gateway
    Write-Log INFO "Import: $($build.Items.Count) item(s) from $($baseline.Name)"
    $build.Changes | ForEach-Object { Write-Log INFO "  $_" }

    $target  = Join-Path $paths.ImportDir 'import.dwx'
    $result  = Join-Path $paths.ImportDir 'import.result'
    if (Test-Path $target) { throw "An import.dwx is already waiting in $($paths.ImportDir)." }
    foreach ($old in $result, "${result}s") { if (Test-Path $old) { Remove-Item $old -Force } }
    $staged = Join-Path $env:TEMP ("dw-step4-{0}.dwx" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Save-DwXml -Xml $build.Xml -Path $staged

    Restart-DwCore -WhileStopped {
        if (-not $saved) { Save-DwDatabases -Paths $paths -Dest $safety; Write-Log INFO "Safety copy of the gateway databases: $safety" }
        Copy-Item $staged $target
    }
    $done = Wait-DwImportFile -Queued $target -ResultFiles @($result, "${result}s") -TimeoutSec $dw.ImportTimeoutSec
    Remove-Item $staged -ErrorAction SilentlyContinue
    if (-not $done) {
        Add-Result -Phase $phase -Check 'Base configuration import' -Status FAIL -Detail "no import.result after $($dw.ImportTimeoutSec) s"
        throw 'The gateway did not process the import.'
    }
    New-Item -ItemType Directory -Path $safety -Force | Out-Null
    Copy-Item $done (Join-Path $safety 'step4-import.result')

    $res = Read-DwImportResult -Path $done
    foreach ($i in $res.Items) {
        $status = if ($i.Status -eq 0) { 'PASS' } else { 'FAIL' }
        Add-Result -Phase $phase -Check "Import $($i.Type) $($i.Item)" -Status $status -Detail "status $($i.Status)"
    }
    $bad = @($res.Items | Where-Object { $_.Status -ne 0 })
    Add-Result -Phase $phase -Check 'Base configuration import' -Status $(if ($bad.Count) { 'FAIL' } else { 'PASS' }) `
        -Detail ("{0} item(s), {1} failed, overall status {2}" -f $res.Items.Count, $bad.Count, $res.Overall)

    #endregion

    #region -- 3. Checks ------------------------------------------------------------

    $port = [int]$dw.OpcUaEndpointPort
    $deadline = (Get-Date).AddSeconds(120); $listening = $false
    while (-not $listening -and (Get-Date) -lt $deadline) {
        $listening = [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
        if (-not $listening) { Start-Sleep -Seconds 5 }
    }
    Add-Result -Phase $phase -Check "OPC UA endpoint port $port" -Status $(if ($listening) { 'PASS' } else { 'FAIL' }) `
        -Detail $(if ($listening) { "opc.tcp://${gateway}:$port listening" } else { 'not listening after 2 min' })

    try {
        $sys = Get-DwPersistence -Paths $paths -Group 'system'
        $name = $sys['module.name']
        Add-Result -Phase $phase -Check 'Gateway name' -Status $(if ($name -eq $gateway) { 'PASS' } else { 'WARN' }) -Detail "module.name = $name"
    } catch {
        Add-Result -Phase $phase -Check 'Gateway name' -Status WARN -Detail "could not read DWUSER.db: $($_.Exception.Message)"
    }

    foreach ($c in $cncs) {
        Add-Result -Phase $phase -Check "CNC$($c.CNCIndex) CNCAsset / CNCType" -Status MANUAL `
            -Detail "Workbench > Devices > CNC$($c.CNCIndex) > Variables: CNCAsset = $($c.MachineName), CNCType = $($c.CNCType)"
    }

    #endregion

    $State['DeviceWiseBaseline'] = $baseline.FullName
    Write-Log PASS 'deviceWise base platform configuration complete.'
}
