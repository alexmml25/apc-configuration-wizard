#Requires -Version 5.1
<#
.SYNOPSIS
    Step 4 - deviceWise base platform (SOP D01555607 2.1.1, deviceWise - Base Platform Setup).
.DESCRIPTION
    No Workbench and no API: everything goes through the gateway's import folder (DeviceWise.ps1).
      1. Packages OPC UA Server, OPC UA Client, FileWatcher, CNCnetPDM from the approved payload in
         <RepositoryRoot>\<DeviceWise.PackagesRepoSubPath> (tools\Export-DwPackagePayload.ps1; the .pkg
         files are encrypted and rejected by the gateway): each package's own install instructions
         are followed, all in one dwcore stop, files checked against SHA256SUMS.txt; skipped when
         already installed (Gateway\dwcore\packages\<name>.xml).
      2. Base configuration from the approved baseline backup (<DeviceWise.BaselineRepoSubPath>,
         5-Automation\Baseline_Backup.dbk = the SJUM7AAPPS0065 backup): licence client (MSPM7AAPPS0342; the source VM's voucher
         removed), OPC UA tag definitions (devices CNC1-3 + their OPC UA device files), OPC UA server
         endpoint (48020, security modes/policies, user auth, anonymous; host = this VM), users
         (MedtronicSU) / roles / policy, gateway name = this VM, CNCn CNCAsset / CNCType = the Site DB
         machine name and type (as variable defaults: the devices do not persist values).
      3. Checks: each imported item status 0, OPC UA endpoint listening, gateway name, OPC UA flags.
      4. CNCn CNCAsset / CNCType written live through the gateway's OPC UA server (OPC Foundation stack
         from 800xA, copied to C:\APC_Config\OpcUaStack) and read back. Known limitation: the CNC
         devices do not persist values, so these are empty again after the next dwcore restart.
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
    # A deviceWise factory reset removes staging\system\import (seen on SJUM7AAPPS0048); the gateway
    # only looks for import.dwx in it at startup, so the folder can simply be created
    if (-not (Test-Path $paths.ImportDir)) {
        New-Item -ItemType Directory -Path $paths.ImportDir -Force | Out-Null
        Write-Log INFO "Created the import folder $($paths.ImportDir)"
    }

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

    $plan = Get-DwPackagePlan -Paths $paths -PayloadDir $pkgDir -Keys @($dw.Packages)
    foreach ($p in $plan | Where-Object { $_.Installed }) {
        Add-Result -Phase $phase -Check "Package $($p.Key)" -Status PASS -Detail 'already installed'
    }
    $installed = @(Install-DwPackages -Paths $paths -Plan $plan -BeforeCopy {
        Save-DwDatabases -Paths $paths -Dest $safety
        Write-Log INFO "Safety copy of the gateway databases: $safety"
    })
    if ($installed.Count) { $saved = $true }
    foreach ($p in $plan | Where-Object { $installed -contains $_.Key }) {
        $ok = Test-Path (Join-Path $paths.Packages "$($p.Key).xml")
        Add-Result -Phase $phase -Check "Package $($p.Key)" -Status $(if ($ok) { 'PASS' } else { 'FAIL' }) -Detail "$($p.Name) $($p.Version)"
    }

    #endregion

    #region -- 2. Base configuration import ---------------------------------------

    $gateway = $env:COMPUTERNAME
    $build = New-DwBaseImport -BaselinePath $baseline.FullName -Manifest $Manifest -Cncs $cncs -GatewayName $gateway
    Write-Log INFO "Import: $($build.Items.Count) item(s) from $($baseline.Name)"
    $build.Changes | ForEach-Object { Write-Log INFO "  $_" }

    try {
        $res = Invoke-DwImport -Paths $paths -Xml $build.Xml -Label 'step4-base' -SafetyDir $safety -SaveDatabases:(-not $saved) -TimeoutSec $dw.ImportTimeoutSec
    } catch {
        Add-Result -Phase $phase -Check 'Base configuration import' -Status FAIL -Detail $_.Exception.Message
        throw
    }
    [void](Add-DwImportResults -Phase $phase -Result $res -Summary 'Base configuration import')

    #endregion

    #region -- 2b. OPC UA server: switched on, SOP security policies ----------------

    # The import brings the endpoint settings but not the 'switched on' flags that Workbench's Start
    # button writes (enable / status in DWUSER.db, group opcua_server_v3 - compared with a gateway
    # set up in Workbench, 2026-10-13). It also stored the two AES policies the wrong way round
    # (file: Aes128Sha256RsaOeap; stored: aes128 false / aes256 true), so the policy flags are written too.
    $policyKeys = [ordered]@{
        Basic128Rsa15 = 'security_basic128rsa15'; Basic256 = 'security_basic256'; Basic256Sha256 = 'security_basic256sha256'
        Aes128Sha256RsaOeap = 'security_aes128sha256'; Aes256Sha256RsaPss = 'security_aes256sha256'
    }
    $ua = [ordered]@{ enable = 'Yes'; status = 'Started' }
    foreach ($p in $policyKeys.Keys) { $ua[$policyKeys[$p]] = ([string](@($dw.OpcUaSecurityPolicies) -contains $p)).ToLower() }
    Restart-DwCore -WhileStopped { Set-DwPersistence -Paths $paths -Group 'opcua_server_v3' -Values $ua }
    Add-Result -Phase $phase -Check 'OPC UA server switched on' -Status PASS `
        -Detail ("enable=Yes, status=Started; policies: {0}" -f (@($dw.OpcUaSecurityPolicies) -join ', '))

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
        # the stored value carries a leading control byte (0x01, seen on SJUM7AAPPS0048), so compare the printable part
        $name = ([string]$sys['module.name']) -replace '[\x00-\x1F]', ''
        Add-Result -Phase $phase -Check 'Gateway name' -Status $(if ($name -eq $gateway) { 'PASS' } else { 'WARN' }) -Detail "module.name = $name"
    } catch {
        Add-Result -Phase $phase -Check 'Gateway name' -Status WARN -Detail "could not read DWUSER.db: $($_.Exception.Message)"
    }

    try {
        $stored = Get-DwPersistence -Paths $paths -Group 'opcua_server_v3'
        $diff = @($ua.Keys | Where-Object { (([string]$stored[$_]) -replace '[\x00-\x1F]', '') -ne $ua[$_] })
        Add-Result -Phase $phase -Check 'OPC UA server settings stored' -Status $(if ($diff.Count) { 'WARN' } else { 'PASS' }) `
            -Detail $(if ($diff.Count) { "differs: $($diff -join ', ')" } else { 'enable, status and security policies as written' })
    } catch {
        Add-Result -Phase $phase -Check 'OPC UA server settings stored' -Status WARN -Detail "could not read DWUSER.db: $($_.Exception.Message)"
    }

    #endregion

    #region -- 4. CNCAsset / CNCType through the gateway's OPC UA server --------------

    # Not in the import and not persisted by the CNC devices: written live (Set-DwCncAssetValues).
    # Steps 5, 6 and 8 restart dwcore and write them again at their end.
    Set-DwCncAssetValues -Manifest $Manifest -Cncs $cncs -Phase $phase -WaitSec 30

    #endregion

    $State['DeviceWiseBaseline'] = $baseline.FullName
    Write-Log PASS 'deviceWise base platform configuration complete.'
}
