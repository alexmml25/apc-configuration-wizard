#Requires -Version 5.1
<#
.SYNOPSIS
    Step 11 - Configure CHMI / APC UI OPC UA connection and guide operator through manual steps.
.DESCRIPTION
    Automated sub-steps:
    - Update OPC UA Server URL registry key for 800xA Engineering Workplace
    - Patch OperateITData XML aspect file as fallback if registry key not found

    Guided sub-steps (wizard pauses with numbered checklist until operator confirms):
    1. UA Management Portal: Create Root Certificate → Connect 800xAOpcUaConnect → Update Certs
    2. Engineering Workplace: OPC UA Server Node → update URL → Upload to 800xA
    3. Functional Structure: locate CNC OPC object → rename to "OPC" if needed
    4. Operator confirms completion
#>

function Invoke-CHMI {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [switch]$NonInteractive
    )

    Write-Log STEP "CHMI / APC UI OPC UA Configuration"

    $chmiCfg    = $Manifest.CHMI
    $computerName = $env:COMPUTERNAME
    $opcUaUrl   = "opc.tcp://${computerName}:48020"

    #region -- Automated: update OPC UA Server URL ----------------------------

    Write-Log INFO "Attempting to update OPC UA Server URL in registry..."
    $regUpdated = $false

    # Try known registry paths for 800xA OPC UA connector
    $regPaths = @(
        'HKLM:\SOFTWARE\ABB\800xA\OpcUaConnect',
        'HKLM:\SOFTWARE\WOW6432Node\ABB\800xA\OpcUaConnect',
        'HKLM:\SOFTWARE\ABB\OpcUaConnect',
        'HKLM:\SOFTWARE\WOW6432Node\ABB\OpcUaConnect'
    )

    foreach ($regBase in $regPaths) {
        if (Test-Path $regBase) {
            try {
                $keys = Get-ChildItem $regBase -ErrorAction SilentlyContinue
                foreach ($key in $keys) {
                    $serverUrl = Get-ItemProperty $key.PSPath -Name 'ServerUrl' -ErrorAction SilentlyContinue
                    if ($serverUrl) {
                        Set-ItemProperty $key.PSPath -Name 'ServerUrl' -Value $opcUaUrl
                        Write-Log INFO "  Registry updated: $($key.PSPath) → ServerUrl = $opcUaUrl"
                        $regUpdated = $true
                    }
                }
                # Also try value directly on the base key
                $directUrl = Get-ItemProperty $regBase -Name 'ServerUrl' -ErrorAction SilentlyContinue
                if ($directUrl) {
                    Set-ItemProperty $regBase -Name 'ServerUrl' -Value $opcUaUrl
                    $regUpdated = $true
                }
            } catch {
                Write-Log WARN "Registry update at $regBase failed: $_"
            }
        }
    }

    if ($regUpdated) {
        Add-Result -Phase CHMI -Check "OPC UA URL (registry)" -Status PASS -Detail $opcUaUrl
    } else {
        Write-Log INFO "Registry path not found — attempting OperateITData XML fallback..."

        # Fallback: patch the 800xA aspect XML files
        $operateItPath = $chmiCfg.OperateITDataPath
        if (Test-Path $operateItPath) {
            $xmlFiles = Get-ChildItem $operateItPath -Filter '*OpcUa*.xml' -Recurse -ErrorAction SilentlyContinue
            if (-not $xmlFiles -or $xmlFiles.Count -eq 0) {
                $xmlFiles = Get-ChildItem $operateItPath -Filter '*opc*ua*.xml' -Recurse -ErrorAction SilentlyContinue
            }

            $patched = 0
            foreach ($xf in $xmlFiles) {
                try {
                    $content = [System.IO.File]::ReadAllText($xf.FullName)
                    if ($content -match 'opc\.tcp://[^"<]+:48020') {
                        $newContent = $content -replace 'opc\.tcp://[^"<]+:48020', $opcUaUrl
                        [System.IO.File]::WriteAllText($xf.FullName, $newContent)
                        Write-Log INFO "  Patched: $($xf.FullName)"
                        $patched++
                    }
                } catch {
                    Write-Log WARN "  Could not patch $($xf.Name): $_"
                }
            }

            if ($patched -gt 0) {
                Add-Result -Phase CHMI -Check "OPC UA URL (XML patch)" -Status PASS -Detail "$patched file(s) patched → $opcUaUrl"
            } else {
                Add-Result -Phase CHMI -Check "OPC UA URL" -Status WARN `
                    -Detail "No registry key or XML file found with existing OPC UA URL — update manually in Step 2 below"
            }
        } else {
            Add-Result -Phase CHMI -Check "OPC UA URL" -Status WARN `
                -Detail "OperateITData path not found ($operateItPath) — set OPC UA Server URL manually in Engineering Workplace"
        }
    }

    #endregion

    #region -- Certificate trust (automated attempt) --------------------------

    $certMgr = $chmiCfg.UaCertificateManagerPath
    if (Test-Path $certMgr) {
        try {
            Write-Log INFO "Invoking AfwUaCertificateManager to trust pending certificate..."
            $proc = Start-Process -FilePath $certMgr -ArgumentList '--trust-pending' `
                -Wait -PassThru -NoNewWindow -ErrorAction Stop
            if ($proc.ExitCode -eq 0) {
                Add-Result -Phase CHMI -Check "OPC UA certificate trust" -Status PASS
            } else {
                Add-Result -Phase CHMI -Check "OPC UA certificate trust" -Status WARN `
                    -Detail "Certificate manager exited $($proc.ExitCode) — trust certificate manually in UA Management Portal"
            }
        } catch {
            Add-Result -Phase CHMI -Check "OPC UA certificate trust" -Status WARN `
                -Detail "Could not invoke certificate manager — trust manually: $_"
        }
    } else {
        Add-Result -Phase CHMI -Check "OPC UA certificate trust" -Status WARN `
            -Detail "AfwUaCertificateManager not found at $certMgr — trust pending certificate manually"
    }

    #endregion

    #region -- Guided checklist (pause for operator) --------------------------

    Write-Log MANUAL "CHMI requires manual steps in Engineering Workplace."
    Write-Log MANUAL ""
    Write-Log MANUAL "== GUIDED STEPS (complete in order, then press Continue) =="
    Write-Log MANUAL ""
    Write-Log MANUAL "1. Open UA Management Portal (800xA Engineering Workplace → Tools → UA Mgmt Portal)"
    Write-Log MANUAL "   a. Navigate to Certificates → Create Root Certificate (if not already created)"
    Write-Log MANUAL "   b. Select '800xAOpcUaConnect' → Connect"
    Write-Log MANUAL "   c. Click 'Update Application Certificates'"
    Write-Log MANUAL ""
    Write-Log MANUAL "2. In Engineering Workplace:"
    Write-Log MANUAL "   a. Browse to the OPC UA Server node in the object tree"
    Write-Log MANUAL "   b. Update 'Server URL' to: $opcUaUrl"
    Write-Log MANUAL "   c. Right-click → Upload to 800xA"
    Write-Log MANUAL ""
    Write-Log MANUAL "3. In Functional Structure:"
    Write-Log MANUAL "   a. Locate the CNC OPC object (usually under the CNC control structure)"
    Write-Log MANUAL "   b. If the object is NOT named 'OPC', right-click → Rename → OPC"
    Write-Log MANUAL "   c. Verify OPC connection status shows green"
    Write-Log MANUAL ""
    Write-Log MANUAL "4. Press 'Continue' in the wizard when all steps above are complete."

    # Non-interactive mode: skip prompt, log as incomplete
    if ($NonInteractive) {
        Add-Result -Phase CHMI -Check "CHMI guided steps" -Status WARN `
            -Detail "NonInteractive mode — manual steps above must be completed before system is operational"
    } else {
        # Wizard will detect MANUAL log entries and pause the step card automatically
        # The "Continue" button in the wizard resumes execution; this function returns
        # and the wizard marks the step PASS once the operator clicks Continue.
        $State['CHMIPausedForManualSteps'] = $true
    }

    #endregion

    Write-Log PASS "CHMI step complete. Verify OPC UA connection is shown as Connected in Engineering Workplace before proceeding."
}
