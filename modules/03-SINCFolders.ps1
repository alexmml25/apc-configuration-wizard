#Requires -Version 5.1
<#
.SYNOPSIS
    Step 3 - Create the SINC staging folder structure on the APC VM.
.DESCRIPTION
    For each CNC machine in State.CNCMachines, creates the three subdirectories
    required by the SINC integration:
      C:\Program Files\deviceWISE\Gateway\staging\SINC\{MachineName}\Processing
      C:\Program Files\deviceWISE\Gateway\staging\SINC\{MachineName}\DoneSuccess
      C:\Program Files\deviceWISE\Gateway\staging\SINC\{MachineName}\DoneError
    Uses the machine name as the folder name (matching deviceWise CNC path naming).
#>

function Invoke-SINCFolders {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [switch]$NonInteractive
    )

    Write-Log STEP "SINC Staging Folder Structure"

    $machines   = $State['CNCMachines']
    $stagingRoot = $Manifest.DeviceWise.SINCStaging

    if (-not $machines -or $machines.Count -eq 0) {
        Add-Result -Phase SINC -Check "CNC machines in state" -Status FAIL -Detail "No machines found - run Step 1 first"
        throw "CNCMachines not populated. Run Step 1 (Site DB Fetch) first."
    }

    Write-Log INFO "SINC staging root: $stagingRoot"
    Write-Log INFO "Creating folder structure for $($machines.Count) CNC machine(s)"

    $subFolders = @('Processing', 'DoneSuccess', 'DoneError')

    foreach ($machine in $machines) {
        $cncName = $machine.MachineName
        $cncRoot = Join-Path $stagingRoot $cncName

        foreach ($sub in $subFolders) {
            $fullPath = Join-Path $cncRoot $sub
            try {
                if (-not (Test-Path $fullPath)) {
                    New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
                    Write-Log INFO "  Created: $fullPath"
                } else {
                    Write-Log INFO "  Exists:  $fullPath"
                }

                # Verify write permission
                $testFile = Join-Path $fullPath '.write_test'
                [System.IO.File]::WriteAllText($testFile, 'test')
                Remove-Item $testFile -Force

                Add-Result -Phase SINC -Check "$cncName\$sub" -Status PASS
            } catch {
                Add-Result -Phase SINC -Check "$cncName\$sub" -Status FAIL -Detail $_
            }
        }
    }

    # Also create root SINC directory entry for reference
    if (Test-Path $stagingRoot) {
        Add-Result -Phase SINC -Check "SINC staging root" -Status PASS -Detail $stagingRoot
    } else {
        Add-Result -Phase SINC -Check "SINC staging root" -Status WARN -Detail "Root does not exist yet ($stagingRoot)  -  deviceWise may create it on service start"
    }

    Write-Log PASS "SINC folder structure creation complete."
}
