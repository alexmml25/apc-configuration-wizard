#Requires -Version 5.1
<#
.SYNOPSIS
    Step 8 - Register CNCnetPDM with deviceWise and map CNC paths.
.DESCRIPTION
    - Registers the CNCnetPDM instance folder with deviceWise
    - Polls until the instance reports Connected status
    - Maps each CNCnetPDM machine to its corresponding deviceWise CNC path
      (CNCnetPDM machine 1 -> CNC1_Path, etc.)

    Runs after Step 7 (CNCnetPDM configured and running), as in the SOP, so the
    CNCnetPDM machines are available when the paths are mapped.
#>

. (Join-Path $PSScriptRoot 'Common.ps1')

function Invoke-DeviceWiseCNCPDM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [switch]$NonInteractive
    )

    Write-Log STEP "deviceWise CNCnetPDM Integration"

    $dw       = $Manifest.DeviceWise
    $cncPdm   = $Manifest.CNCnetPDM
    $dwPort   = $State['DeviceWisePort']
    $dwToken  = $State['DeviceWiseToken']
    $machines = Get-AssignedCNCs -State $State -Manifest $Manifest   # CNC n = DOC instance n

    if ($dwPort -eq 0) { throw "DeviceWisePort not set. Run Step 4 first." }

    $baseUrl = "http://localhost:${dwPort}$($dw.ApiBasePath)"
    $headers = @{ 'Content-Type' = 'application/json' }
    if ($dwToken) { $headers['Authorization'] = "Bearer $dwToken" }

    function Invoke-DW {
        param([string]$Method, [string]$Path, [object]$Body = $null, [string]$Desc = '')
        $params = @{ Uri = "$baseUrl$Path"; Method = $Method; Headers = $headers; TimeoutSec = 30 }
        if ($Body) { $params['Body'] = ($Body | ConvertTo-Json -Depth 10) }
        try { return Invoke-RestMethod @params -ErrorAction Stop }
        catch { Write-Log WARN "$Desc failed: $_"; return $null }
    }

    #region -- Resolve CNCnetPDM install directory ----------------------------

    $cncPdmDir = $null
    foreach ($candidate in @($cncPdm.InstallDir, $cncPdm.FallbackDir)) {
        if (Test-Path $candidate) { $cncPdmDir = $candidate; break }
    }
    if (-not $cncPdmDir) {
        # Search for CNCnetPDM directory
        $found = Get-ChildItem 'C:\', 'C:\Medtronic\' -Directory -Filter '*CNCnetPDM*' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $cncPdmDir = $found.FullName }
    }

    if (-not $cncPdmDir) {
        Add-Result -Phase DeviceWise -Check "CNCnetPDM directory" -Status WARN `
            -Detail "Cannot locate CNCnetPDM directory. Register manually in Workbench -> Admin -> CNCnetPDM Instance Management"
    } else {
        Add-Result -Phase DeviceWise -Check "CNCnetPDM directory" -Status PASS -Detail $cncPdmDir
    }

    #endregion

    #region -- Register CNCnetPDM instance ------------------------------------

    if ($cncPdmDir) {
        $regResult = Invoke-DW -Method POST -Path "/cncnetpdm/instances" `
            -Body @{ path = $cncPdmDir } -Desc "Register CNCnetPDM instance ($cncPdmDir)"

        if ($regResult) {
            Add-Result -Phase DeviceWise -Check "CNCnetPDM instance registered" -Status PASS -Detail $cncPdmDir
        } else {
            Add-Result -Phase DeviceWise -Check "CNCnetPDM instance registered" -Status WARN `
                -Detail "Register manually: Admin -> CNCnetPDM Instance Management -> Add -> $cncPdmDir"
        }

        # Poll for Connected status (up to 60s  -  CNCnetPDM may not be configured yet)
        $waited = 0
        $connected = $false
        while ($waited -lt 60) {
            Start-Sleep -Seconds 5; $waited += 5
            $instances = Invoke-DW -Method GET -Path "/cncnetpdm/instances" -Desc "Instance status"
            if ($instances -and ($instances | Where-Object { $_.status -eq 'Connected' })) {
                $connected = $true; break
            }
        }

        if ($connected) {
            Add-Result -Phase DeviceWise -Check "CNCnetPDM connection" -Status PASS -Detail "Connected"
        } else {
            Add-Result -Phase DeviceWise -Check "CNCnetPDM connection" -Status WARN `
                -Detail "Not yet Connected  -  check that Step 7 (CNCnetPDM) completed and the CNCnetPDM service is running."
        }
    }

    #endregion

    #region -- Map CNC paths --------------------------------------------------

    Write-Log INFO "Mapping CNCnetPDM machines to deviceWise CNC paths..."
    for ($i = 0; $i -lt $machines.Count; $i++) {
        $machine  = $machines[$i]
        $cncIndex = $machine.CNCIndex
        $cncPath  = "CNC${cncIndex}_Path"

        $mapBody = @{
            machine  = $machine.MachineName
            cncPath  = $cncPath
            deviceNr = $machine.DeviceNr
        }
        $mapResult = Invoke-DW -Method PUT -Path "/devices/CNCX_Paths" `
            -Body $mapBody -Desc "Map $($machine.MachineName) -> $cncPath"

        if ($mapResult) {
            Add-Result -Phase DeviceWise -Check "CNC path mapping: $cncPath" -Status PASS -Detail "$($machine.MachineName) -> $cncPath"
        } else {
            Add-Result -Phase DeviceWise -Check "CNC path mapping: $cncPath" -Status WARN `
                -Detail "Map manually: Devices -> CNCX_Paths -> select $($machine.MachineName) -> $cncPath"
        }
    }

    #endregion

    Write-Log PASS "deviceWise CNCnetPDM integration complete."
    Write-Log INFO "NOTE: CNCnetPDM connectivity (green indicator) depends on the machine entries written by Step 7."
}
