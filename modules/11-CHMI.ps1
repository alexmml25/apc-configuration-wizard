#Requires -Version 5.1
<#
.SYNOPSIS
    Step 11 - CHMI / APC UI: 800xA General Properties (automated) and the guided SOP steps.
.DESCRIPTION
    800xA General Properties (first, config-driven): each entry of Manifest.ABB800xA.Properties is read,
    written and read back through the proven kit in kits\800xA (32-bit cscript), with before/after values
    logged to C:\APC_Config\Logs\800xA_changes_<ts>.log. The step stops at the first failed read/write.
    Today: Inspections GP CSV folders (BENCH / 100%) and Verification GP shift settings, per DOC-assigned
    Cell_n, with values from Manifest.ABB800xA.Settings.

    The only automated action in the flow is the General Property write above.

    Read-only checks - OFF in the flow (Manifest.CHMI.AutomatedChecks = false; code kept for later use,
    Step 13 still runs its own certificate / server checks):
    - 800xA OPC UA certificates (Manifest.CHMI.PkiRoot): the root in OpcUaConnect\pki\issuer, and whether
      800xAOpcUaConnect and 800xAOpcUaManagementPortal are signed by it. The root is never created by the
      wizard: when one exists the guided text says not to create another (it would invalidate every
      application certificate).
    - deviceWise OPC UA server as seen by 800xA (Node Administration -> DEVICEWISE OPC UA): server state,
      product and version. The Server URL is aspect data and cannot be read over OPC; the default
      opc.tcp://localhost:48020 is fine.

    Guided steps (D01555607 CHMI / APC UI, wizard pauses until the operator confirms): UA Management Portal
    certificates, OPC UA Server Info aspect (URL, placements, Upload to 800xA), OPC folder per CNC cell.
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

    Invoke-800xAPropertyStep -Manifest $Manifest -State $State -Phase CHMI

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
            Add-Result -Phase CHMI -Check "OPC UA root certificate" -Status WARN -Detail "Not found ($($rootCert.Path)) - create it in guided step 1"
        }
        foreach ($c in $certs | Select-Object -Skip 1) {
            $label = "OPC UA certificate $($c.Name)"
            if (-not $c.Found) {
                Add-Result -Phase CHMI -Check $label -Status WARN -Detail "Not found ($($c.Path)) - see guided step 1"
            } elseif ($c.IssuedByRoot) {
                Add-Result -Phase CHMI -Check $label -Status PASS -Detail "Signed by the current root ($($rootCert.Thumbprint))"
            } else {
                Add-Result -Phase CHMI -Check $label -Status WARN -Detail "Not signed by the current root - Update Application Certificates in guided step 1"
            }
        }

        $serverDetail = Test-800xAOpcUaServer -Manifest $Manifest -Phase CHMI
        Write-Log INFO "deviceWise OPC UA server (as seen by 800xA): $serverDetail"
    }

    #endregion

    #region -- Guided checklist (pause for operator) --------------------------

    $account = ([string]$Manifest.AppAccount) -replace '\{SITE\}', [string]$State['SiteCode']
    $cells = @(Get-AssignedCNCs -State $State -Manifest $Manifest | ForEach-Object { "Cell_$($_.CNCIndex)" })
    if (-not $cells) { $cells = @('CNCx_Cell') }

    Write-Log MANUAL "CHMI requires manual steps (D01555607, CHMI / APC UI)."
    Write-Log MANUAL ""
    Write-Log MANUAL "== GUIDED STEPS (complete in order, then press Continue) =="
    Write-Log MANUAL ""
    Write-Log MANUAL "1. UA Management Portal (ABB Start Menu -> ABB System 800xA -> System -> Tools -> UA Management Portal)"
    if ($rootCert -and $rootCert.Found) {
        Write-Log MANUAL "   a. The root certificate already exists ($($rootCert.Thumbprint), created $($rootCert.NotBefore))."
        Write-Log MANUAL "      Do NOT click Create... : a new root makes every application certificate invalid."
        Write-Log MANUAL "      If the portal says 'No private key for the root certificate', stop and contact the APC Team."
    } elseif ($rootCert) {
        Write-Log MANUAL "   a. Create... -> Create Root Certificate -> Yes"
    } else {
        Write-Log MANUAL "   a. If the portal opens on the Sign page, a root certificate already exists: do NOT create another one"
        Write-Log MANUAL "      (a new root makes every application certificate invalid). Otherwise: Create... -> Create Root Certificate -> Yes"
    }
    Write-Log MANUAL "   b. Connect... -> 800xAOpcUaConnect -> Connect... (log in as $account)"
    Write-Log MANUAL "   c. With 800xAOpcUaConnect selected: Update Application Certificates..."
    Write-Log MANUAL "   d. Check the Issuer of 800xAManagementPortal and 800xAOpcUaConnect is 800xAOPCUARoot (Step 13 also checks it)"
    Write-Log MANUAL ""
    Write-Log MANUAL "2. Engineering Workplace -> Node Administration Structure -> All Nodes ->"
    Write-Log MANUAL "   DeviceWISE OPC UA, OPC UA Server Node -> DeviceWISE OPC UA, OPC UA Server -> OPC UA Server Info aspect"
    Write-Log MANUAL "   a. General: Server URL points to the deviceWise OPC UA Server (default opc.tcp://localhost:48020)"
    Write-Log MANUAL "   b. Placements: Remove Placement on legacy nodes; Add New Placement... -> Add Selected Placement -> OK"
    Write-Log MANUAL "   c. Upload: Upload to 800xA, then check Node Status = Uploaded with no errors"
    Write-Log MANUAL ""
    Write-Log MANUAL "3. Functional Structure -> Medtronic -> $($cells -join ', ')"
    Write-Log MANUAL "   Each cell must have a child named 'OPC'. If the uploaded node has another name, rename it to OPC."
    Write-Log MANUAL ""
    Write-Log MANUAL "4. Press 'Continue' in the wizard when all steps above are complete."

    # Non-interactive mode: skip prompt, log as incomplete
    if ($NonInteractive) {
        Add-Result -Phase CHMI -Check "CHMI guided steps" -Status WARN `
            -Detail "NonInteractive mode  -  manual steps above must be completed before system is operational"
    } else {
        # Wizard will detect MANUAL log entries and pause the step card automatically
        # The "Continue" button in the wizard resumes execution; this function returns
        # and the wizard marks the step PASS once the operator clicks Continue.
        $State['CHMIPausedForManualSteps'] = $true
    }

    #endregion

    Write-Log PASS "CHMI step complete. Step 13 re-checks the certificates and the deviceWise OPC UA server connection."
}
