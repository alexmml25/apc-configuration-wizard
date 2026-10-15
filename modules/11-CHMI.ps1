#Requires -Version 5.1
<#
.SYNOPSIS
    Step 11 - CHMI / APC UI: 800xA General Properties, OPC UA certificates and deviceWise server (all automated).
.DESCRIPTION
    800xA General Properties (first, config-driven): each entry of Manifest.ABB800xA.Properties is read,
    written and read back through the proven kit in kits\800xA (32-bit cscript), with before/after values
    logged to C:\APC_Config\Logs\800xA_changes_<ts>.log. The step stops at the first failed read/write.
    Today: Inspections GP CSV folders (BENCH / 100%) and Verification GP shift settings, per DOC-assigned
    Cell_n, with values from Manifest.ABB800xA.Settings.

    800xA OPC UA certificates (SOP sub-steps 1-4, Manifest.CHMI.AutomateCertificates): with the SVC account
    password from the window (State.SvcAccountPassword) Step 11 runs, with the UA Management Portal's own
    functions (32-bit, tools\):
      1. Invoke-800xACreateRoot.ps1 -IfNeeded -Confirmed: a new root only when this node cannot sign with the
         current one (none / no key here / left from the machine the VM was copied from); never replaces a root
         of another node of this system
      2. Invoke-800xAUpdateAppCerts.ps1 -Confirmed -NonInteractive: portal certificate, then OPC UA Connect
         (trust list, CSR signed by the root, push, reconnect check, 800xA aspect); applications already
         signed by the current root are left alone
    Both back up first (C:\APC_Config\Backups\<ts>_800xA-*) and write a report to the run's Logs folder.
    Proven on SJUM7AAPPS0048 2026-10-15.

    Read-only checks - OFF in the flow (Manifest.CHMI.AutomatedChecks = false; code kept for later use,
    Step 13 still runs its own certificate / server checks):
    - 800xA OPC UA certificates (Manifest.CHMI.PkiRoot): the root in OpcUaConnect\pki\issuer, and whether
      800xAOpcUaConnect and 800xAOpcUaManagementPortal are signed by it. The root is never created by the
      wizard check: whether the root exists and the application certificates are signed by it (a second root would invalidate every
      application certificate).
    - deviceWise OPC UA server as seen by 800xA (Node Administration -> DEVICEWISE OPC UA): server state,
      product and version. The Server URL is aspect data and cannot be read over OPC; the default
      opc.tcp://localhost:48020 is fine.

    deviceWise OPC UA server in 800xA (Manifest.CHMI.SetDeviceWiseServer): tools\Set-800xADeviceWiseServer.ps1
    -Confirmed points "DEVICEWISE OPC UA" (OPC UA Server Info aspect) at this VM's gateway (copied VMs keep the
    source machine's URL) and sets up the OPC UA trust between OPC UA Connect and the gateway.

    800xA calculations (Manifest.CHMI.CheckCalculations, the Calculation Status Viewer check): every Inform IT
    calculation (ICalculationASO, Calculation.dll) enabled with Status 0; a disabled or errored one is enabled again
    (tools\Invoke-800xACalculations.ps1 -Confirmed); FAIL when one stays disabled or in error.

    800xA services (Manifest.CHMI.ServiceChecks, D01558132 section 1.4 order): each must be SERVICE_STATE 'Service',
    S_STATUS 0, quality Good - FAIL otherwise. The 1.4 restart (untick/tick Enabled) itself is not scripted: its
    interface is internal to 800xA (IAfwAdminServiceProviderEdit is in no type library).

    No guided (manual) text: every part is automated and reported as PASS / FAIL (user, 2026-10-15).
#>

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'ABB800xA.ps1')

function Invoke-CHMI {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [switch]$NonInteractive
    )

    Write-Log STEP "CHMI / APC UI OPC UA Configuration"

    #region -- 800xA General Properties (Manifest.ABB800xA.Properties) --------

    Invoke-800xAPropertyStep -Manifest $Manifest -State $State -Phase CHMI -LogDir (Get-RunDir -State $State -Name Logs)

    #endregion

    #region -- 800xA OPC UA certificates (SOP sub-steps 1-4) -----------------

    $certsDone = $false
    if ([bool]$Manifest.CHMI.AutomateCertificates) {
        $certsDone = Invoke-800xACertificateSetup -Manifest $Manifest -State $State
    }

    #endregion

    #region -- deviceWise OPC UA server in 800xA (OPC UA Server Info: Server URL) --

    if ([bool]$Manifest.CHMI.SetDeviceWiseServer) {
        Invoke-800xADeviceWiseServer -Manifest $Manifest -State $State
    }

    #endregion

    #region -- 800xA services in normal state (D01558132 section 1.4 list) -----
    # The 1.4 untick/tick Enabled is not scripted (internal 800xA interface); Step 11 checks every service in the
    # list runs with no fault and FAILs on any that does not (user decision 2026-10-15).

    foreach ($svc in @(Get-800xAServiceStates -Manifest $Manifest)) {
        if ($svc.Missing) { Write-Log INFO "800xA service $($svc.Name): $($svc.Detail)"; continue }
        Add-Result -Phase CHMI -Check "800xA service $($svc.Name)" -Status $(if ($svc.Ok) { 'PASS' } else { 'FAIL' }) -Detail $svc.Detail
    }

    #endregion

    #region -- 'OPC' child per cell, live from deviceWise (SOP CHMI: each cell has a child named OPC) --

    foreach ($c in @(Get-800xACellOpcStates -Manifest $Manifest -State $State)) {
        Add-Result -Phase CHMI -Check "800xA $($c.Cell) OPC (CNC$($c.Cell -replace 'Cell_', ''))" -Status $(if ($c.Ok) { 'PASS' } else { 'FAIL' }) -Detail $c.Detail
    }

    #endregion

    #region -- Calculations enabled (Calculation Status Viewer, D01558132 1.4) --

    if ([bool]$Manifest.CHMI.CheckCalculations) {
        $c = Invoke-800xACalculationCheck -Manifest $Manifest -LogDir (Get-RunDir -State $State -Name Logs) -Confirm
        foreach ($l in $c.Lines) { if ($l.Trim()) { Write-Log INFO "  [calcs] $l" } }
        $summary = @($c.Lines | Where-Object { $_ -match '^(All |No calculations|  \d+ running )' }) -join '; '
        switch ($c.Code) {
            0       { Add-Result -Phase CHMI -Check '800xA calculations enabled' -Status PASS -Detail "$summary - report $($c.Report)" }
            5       { Add-Result -Phase CHMI -Check '800xA calculations enabled' -Status FAIL -Detail "Still disabled or in error after Enable - see $($c.Report)" }
            7       { Add-Result -Phase CHMI -Check '800xA calculations enabled' -Status FAIL -Detail "$summary - calculations not readable; see $($c.Report)" }
            8       { Add-Result -Phase CHMI -Check '800xA calculations enabled' -Status FAIL -Detail "$summary - NOT enabled for safety (type check or count); check the Calculation Status Viewer - see $($c.Report)" }
            default { Add-Result -Phase CHMI -Check '800xA calculations enabled' -Status FAIL -Detail "Could not check (exit $($c.Code)) - see $($c.Report)" }
        }
    }

    #endregion

    #region -- Read-only checks: certificates and OPC UA server ---------------
    # Not part of the current flow: only the General Property write is automated in Step 11.
    # Set Manifest.CHMI.AutomatedChecks = true to run these again.

    $rootCert = $null
    if ([bool]$Manifest.CHMI.AutomatedChecks) {
        $certs    = @(Get-800xAOpcUaCertificates -Manifest $Manifest)
        $rootCert = $certs[0]
        if ($rootCert.Found) {
            Add-Result -Phase CHMI -Check "OPC UA root certificate" -Status PASS `
                -Detail "Exists: $($rootCert.Thumbprint), created $($rootCert.NotBefore) - do not create another one"
        } else {
            Add-Result -Phase CHMI -Check "OPC UA root certificate" -Status WARN -Detail "Not found ($($rootCert.Path)) - Step 11 creates it when AutomateCertificates is on"
        }
        foreach ($c in $certs | Select-Object -Skip 1) {
            $label = "OPC UA certificate $($c.Name)"
            if (-not $c.Found) {
                Add-Result -Phase CHMI -Check $label -Status WARN -Detail "Not found ($($c.Path)) - Step 11 updates it when AutomateCertificates is on"
            } elseif ($c.IssuedByRoot) {
                Add-Result -Phase CHMI -Check $label -Status PASS -Detail "Signed by the current root ($($rootCert.Thumbprint))"
            } else {
                Add-Result -Phase CHMI -Check $label -Status WARN -Detail "Not signed by the current root - Step 11 updates it when AutomateCertificates is on"
            }
        }

        $serverDetail = Test-800xAOpcUaServer -Manifest $Manifest -Phase CHMI
        Write-Log INFO "deviceWise OPC UA server (as seen by 800xA): $serverDetail"
    }

    #endregion


    Write-Log PASS "CHMI step complete. Step 13 re-checks the certificates and the deviceWise OPC UA server connection."
}

function Invoke-800xACertificateSetup {
    <#
        Create Root (only if needed) + Update Application Certificates with the portal's own functions, through
        tools\Invoke-800xACreateRoot.ps1 and tools\Invoke-800xAUpdateAppCerts.ps1 in 32-bit PowerShell. The SVC
        account password goes to the update tool in an environment variable of that process only.
        Returns $true when both parts end with the certificates signed by the current root.
    #>
    param([Parameter(Mandatory)] [object]$Manifest, [Parameter(Mandatory)] [hashtable]$State)
    $account = Get-AppAccount -Manifest $Manifest -State $State
    $secure  = $State['SvcAccountPassword']
    if (-not $account -or $secure -isnot [Security.SecureString] -or $secure.Length -eq 0) {
        Add-Result -Phase CHMI -Check '800xA OPC UA certificates' -Status FAIL `
            -Detail "No password for the SVC account ($account) in this run - enter it on the Sign in page and re-run Step 11"
        return $false
    }
    $tools  = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools'
    $ps32   = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    $logDir = Get-RunDir -State $State -Name Logs
    $run = {
        param([string]$Tool, [string[]]$ToolArgs)
        $out = & $ps32 -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $tools $Tool) -OutDir $logDir @ToolArgs 2>&1
        $code = $LASTEXITCODE
        foreach ($l in @($out)) { if ("$l".Trim()) { Write-Log INFO "  [$([IO.Path]::GetFileNameWithoutExtension($Tool))] $l" } }
        $report = @($out | ForEach-Object { "$_" } | Where-Object { $_ -match '^Written: ' } | Select-Object -Last 1) -replace '^Written: ', ''
        @{ Code = $code; Report = "$report" }
    }

    Write-Log INFO "800xA OPC UA root certificate (create only if this node cannot sign with the current one)..."
    $r = & $run 'Invoke-800xACreateRoot.ps1' @('-IfNeeded', '-Confirmed')
    switch ($r.Code) {
        0  { Add-Result -Phase CHMI -Check '800xA OPC UA root certificate' -Status PASS -Detail "New root created on this node - report $($r.Report)" }
        11 { Add-Result -Phase CHMI -Check '800xA OPC UA root certificate' -Status PASS -Detail "Root already usable on this node - kept" }
        12 { Add-Result -Phase CHMI -Check '800xA OPC UA root certificate' -Status FAIL -Detail "The root belongs to another node of this 800xA system - not replaced; see $($r.Report)"; return $false }
        default { Add-Result -Phase CHMI -Check '800xA OPC UA root certificate' -Status FAIL -Detail "Create Root ended with exit code $($r.Code) - see $($r.Report)"; return $false }
    }

    Write-Log INFO "800xA OPC UA application certificates (portal + OPC UA Connect)..."
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $env:APC_OPCUA_PWD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    try { $u = & $run 'Invoke-800xAUpdateAppCerts.ps1' @('-Confirmed', '-NonInteractive', '-UserName', $account) }
    finally { Remove-Item Env:\APC_OPCUA_PWD -ErrorAction SilentlyContinue }
    if ($u.Code -eq 0) {
        Add-Result -Phase CHMI -Check '800xA OPC UA application certificates' -Status PASS -Detail "Signed by the current root (portal, OPC UA Connect) - report $($u.Report)"
        return $true
    }
    Add-Result -Phase CHMI -Check '800xA OPC UA application certificates' -Status FAIL -Detail "Update ended with exit code $($u.Code) - see $($u.Report)"
    return $false
}

function Invoke-800xADeviceWiseServer {
    # tools\Set-800xADeviceWiseServer.ps1 -Confirmed (32-bit): Server URL of "DEVICEWISE OPC UA" -> this VM,
    # trusted server certificate -> this gateway's, file trust both ways
    param([Parameter(Mandatory)] [object]$Manifest, [Parameter(Mandatory)] [hashtable]$State)
    $tool = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools\Set-800xADeviceWiseServer.ps1'
    $ps32 = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    $url  = ([string]$Manifest.CHMI.DeviceWiseServerUrl) -replace '\{HOST\}', $env:COMPUTERNAME
    $toolArgs = @('-Confirmed', '-OutDir', (Get-RunDir -State $State -Name Logs), '-GatewayDir', [string]$Manifest.DeviceWise.GatewayInstallDir)
    if ($url) { $toolArgs += @('-ServerUrl', $url) }
    $out  = & $ps32 -NoProfile -STA -ExecutionPolicy Bypass -File $tool @toolArgs 2>&1
    $code = $LASTEXITCODE
    foreach ($l in @($out)) { if ("$l".Trim()) { Write-Log INFO "  [dwserver] $l" } }
    $rep  = @($out | ForEach-Object { "$_" } | Where-Object { $_ -match '^Written: ' } | Select-Object -Last 1) -replace '^Written: ', ''
    $now  = @($out | ForEach-Object { "$_" } | Where-Object { $_ -match 'Server URL now: ' } | Select-Object -Last 1) -replace '^.*Server URL now: ', ''
    $pl   = @($out | ForEach-Object { "$_" } | Where-Object { $_ -match '^Upload placements: ' } | Select-Object -Last 1) -replace '^Upload placements: ', ''
    if ($pl) {
        Add-Result -Phase CHMI -Check '800xA DEVICEWISE OPC UA placements uploaded' -Status $(if ($pl -match 'all Uploaded') { 'PASS' } else { 'FAIL' }) -Detail "$pl (OPC UA Server Info > Placements / Upload)"
    }
    if ($code -eq 0) {
        Add-Result -Phase CHMI -Check '800xA DEVICEWISE OPC UA server' -Status PASS -Detail "Server URL $now, this gateway's certificate trusted both ways - report $rep"
    } else {
        Add-Result -Phase CHMI -Check '800xA DEVICEWISE OPC UA server' -Status FAIL -Detail "Exit code $code - see $rep"
    }
}
