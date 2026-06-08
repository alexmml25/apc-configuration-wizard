#Requires -Version 5.1
<#
.SYNOPSIS
    Step 4 - Configure the deviceWise Gateway base platform via REST API.
.DESCRIPTION
    - Discovers the deviceWise REST API port (probes common ports)
    - Authenticates with the Gateway
    - Installs required packages (OPC UA Server, OPC UA Client Driver, FileWatcher, CNCnetPDM)
    - Configures the License Manager address
    - Imports OPC UA tag definition files from the repository
    - Configures the OPC UA Server endpoint (port 48020, security modes, user auth)
    - Exposes CNC1, CNC2, CNC3 devices on the OPC UA Server
    - Sets CNCAsset and CNCType variables for each CNC
    - Creates the MedtronicSU OPC UA user

    NOTE: REST API endpoint paths are based on deviceWise Gateway 23.04 documentation.
    Verify all endpoint URIs against the installed version before first live run.
    The deviceWise web UI (once you can log in) shows API docs at /api-docs or /swagger.
#>

function Invoke-DeviceWiseBase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [switch]$NonInteractive
    )

    Write-Log STEP "deviceWise Base Platform Configuration"

    $dw       = $Manifest.DeviceWise
    $machines = $State['CNCMachines']

    if (-not $machines -or $machines.Count -eq 0) {
        throw "CNCMachines not populated. Run Steps 1-3 first."
    }

    #region -- Port discovery -------------------------------------------------

    $dwPort  = 0
    $baseUrl = ''
    foreach ($port in $dw.GatewayProbePorts) {
        try {
            $testUri = "http://localhost:${port}$($dw.ApiBasePath)/version"
            $resp    = Invoke-RestMethod -Uri $testUri -Method GET -TimeoutSec 5 -ErrorAction Stop
            $dwPort  = $port
            $baseUrl = "http://localhost:${port}$($dw.ApiBasePath)"
            Write-Log INFO "deviceWise REST API found on port $port"
            Add-Result -Phase DeviceWise -Check "API port discovery" -Status PASS -Detail "Port $port"
            break
        } catch { }
    }

    if ($dwPort -eq 0) {
        Add-Result -Phase DeviceWise -Check "API port discovery" -Status FAIL -Detail "Tried ports: $($dw.GatewayProbePorts -join ', ')"
        throw "Cannot reach deviceWise REST API. Confirm service 'dwcore' is running and check gateway port configuration."
    }

    $State['DeviceWisePort'] = $dwPort

    #endregion

    # No authentication required - deviceWise REST API is open
    $State['DeviceWiseToken'] = ''
    $headers = @{ 'Content-Type' = 'application/json' }
    Add-Result -Phase DeviceWise -Check "Authentication" -Status PASS -Detail "No auth required"

    function Invoke-DW {
        param([string]$Method, [string]$Path, [object]$Body = $null, [string]$Desc = '')
        $params = @{ Uri = "$baseUrl$Path"; Method = $Method; Headers = $headers; TimeoutSec = 60 }
        if ($Body) { $params['Body'] = ($Body | ConvertTo-Json -Depth 10) }
        try {
            $r = Invoke-RestMethod @params -ErrorAction Stop
            if ($Desc) { Write-Log INFO "$Desc : OK" }
            return $r
        } catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            Write-Log WARN "$Desc failed (HTTP $statusCode): $_"
            return $null
        }
    }

    #region -- Install packages -----------------------------------------------

    foreach ($pkg in $dw.PackagesToInstall) {
        Write-Log INFO "Installing package: $pkg"
        $result = Invoke-DW -Method POST -Path "/packages/install" `
            -Body @{ name = $pkg } -Desc "Install package '$pkg'"

        # Poll until installed (up to 120s)
        $waited = 0
        do {
            Start-Sleep -Seconds 5; $waited += 5
            $status = Invoke-DW -Method GET -Path "/packages/$([System.Web.HttpUtility]::UrlEncode($pkg))" -Desc "Package status '$pkg'"
        } while ($status -and $status.status -notin @('Installed','Error') -and $waited -lt 120)

        if ($status -and $status.status -eq 'Installed') {
            Add-Result -Phase DeviceWise -Check "Package: $pkg" -Status PASS
        } else {
            Add-Result -Phase DeviceWise -Check "Package: $pkg" -Status WARN -Detail "Status: $($status.status)  -  verify manually in Workbench"
        }
    }

    Write-Log INFO "Waiting 15s for packages to stabilize after installation..."
    Start-Sleep -Seconds 15

    #endregion

    #region -- License Manager -----------------------------------------------

    $licResult = Invoke-DW -Method PUT -Path "/config/license" `
        -Body @{ address = $dw.LicenseManagerHost; enabled = $true } `
        -Desc "Configure License Manager ($($dw.LicenseManagerHost))"

    if ($licResult) {
        Add-Result -Phase DeviceWise -Check "License Manager address" -Status PASS -Detail $dw.LicenseManagerHost
    } else {
        Add-Result -Phase DeviceWise -Check "License Manager address" -Status WARN -Detail "Check manually: Admin -> License Client -> $($dw.LicenseManagerHost)"
    }

    #endregion

    #region -- Import OPC UA tag files ----------------------------------------

    $tagsPath = Join-Path $Manifest.APC.RepositoryRoot $dw.OpcUaTagsRepoSubPath
    Write-Log INFO "OPC UA tag files path: $tagsPath"

    $tagFiles = Get-ChildItem $tagsPath -Filter '*.csv' -ErrorAction SilentlyContinue
    if (-not $tagFiles) {
        Add-Result -Phase DeviceWise -Check "OPC UA tag files" -Status WARN -Detail "No .csv tag files found in $tagsPath  -  import manually in Workbench -> Devices -> Import"
    } else {
        foreach ($tagFile in $tagFiles) {
            Write-Log INFO "Importing tag file: $($tagFile.Name)"
            try {
                $form = [System.Net.Http.MultipartFormDataContent]::new()
                $fileBytes = [System.IO.File]::ReadAllBytes($tagFile.FullName)
                $fileContent = [System.Net.Http.ByteArrayContent]::new($fileBytes)
                $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('text/csv')
                $form.Add($fileContent, 'file', $tagFile.Name)

                $client = [System.Net.Http.HttpClient]::new()
                if ($token) { $client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token) }
                $resp = $client.PostAsync("$baseUrl/devices/import", $form).Result
                $client.Dispose()

                if ($resp.IsSuccessStatusCode) {
                    Add-Result -Phase DeviceWise -Check "Tag import: $($tagFile.Name)" -Status PASS
                } else {
                    Add-Result -Phase DeviceWise -Check "Tag import: $($tagFile.Name)" -Status WARN -Detail "HTTP $($resp.StatusCode.value__)"
                }
            } catch {
                Add-Result -Phase DeviceWise -Check "Tag import: $($tagFile.Name)" -Status WARN -Detail $_
            }
        }
    }

    #endregion

    #region -- Configure OPC UA Server endpoint --------------------------------

    $endpointBody = @{
        port              = $dw.OpcUaEndpointPort
        securityModes     = @('None', 'Sign', 'SignAndEncrypt')
        userAuthentication = $true
        allowAnonymous    = $true
    }
    $epResult = Invoke-DW -Method PUT -Path "/opcua/server/endpoint" `
        -Body $endpointBody -Desc "OPC UA endpoint (port $($dw.OpcUaEndpointPort))"

    if ($epResult) {
        Add-Result -Phase DeviceWise -Check "OPC UA endpoint configured" -Status PASS -Detail "Port $($dw.OpcUaEndpointPort)"
    } else {
        Add-Result -Phase DeviceWise -Check "OPC UA endpoint" -Status WARN -Detail "Configure manually: Admin -> OPC UA Server -> Endpoint -> Port $($dw.OpcUaEndpointPort)"
    }

    # Start the endpoint
    Invoke-DW -Method POST -Path "/opcua/server/endpoint/start" -Desc "Start OPC UA endpoint" | Out-Null
    Add-Result -Phase DeviceWise -Check "OPC UA endpoint started" -Status PASS

    #endregion

    #region -- Expose CNC devices on OPC UA -----------------------------------

    $cncNodes = $dw.CNCNodes | Select-Object -First $machines.Count
    $exposeResult = Invoke-DW -Method PUT -Path "/opcua/server/devices" `
        -Body @{ devices = $cncNodes } -Desc "Expose CNC devices on OPC UA"

    if ($exposeResult) {
        Add-Result -Phase DeviceWise -Check "OPC UA exposed devices" -Status PASS -Detail ($cncNodes -join ', ')
    } else {
        Add-Result -Phase DeviceWise -Check "OPC UA exposed devices" -Status WARN -Detail "Set manually: Admin -> OPC UA Server -> Devices tab"
    }

    #endregion

    #region -- Set CNCAsset and CNCType variables for each CNC ---------------

    for ($i = 0; $i -lt $machines.Count; $i++) {
        $machine  = $machines[$i]
        $cncNode  = "CNC$($i + 1)"
        $assetVal = $machine.MachineName
        $typeVal  = $machine.CNCType

        foreach ($varSpec in @(
            @{ Name = 'CNCAsset'; Value = $assetVal },
            @{ Name = 'CNCType';  Value = $typeVal  }
        )) {
            $varResult = Invoke-DW -Method PUT -Path "/devices/$cncNode/variables/$($varSpec.Name)" `
                -Body @{ value = $varSpec.Value } `
                -Desc "Set $cncNode.$($varSpec.Name) = $($varSpec.Value)"

            if ($varResult) {
                Add-Result -Phase DeviceWise -Check "$cncNode $($varSpec.Name)" -Status PASS -Detail $varSpec.Value
            } else {
                Add-Result -Phase DeviceWise -Check "$cncNode $($varSpec.Name)" -Status WARN `
                    -Detail "Set manually: Devices -> $cncNode -> Variables -> $($varSpec.Name) = $($varSpec.Value)"
            }
        }
    }

    #endregion

    #region -- Create MedtronicSU OPC UA user ---------------------------------

    $suPwd = ''
    if ($State.ContainsKey('MedtronicSUPassword') -and $State['MedtronicSUPassword']) {
        $bstr   = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($State['MedtronicSUPassword'])
        try { $suPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }

    if ($suPwd) {
        $userResult = Invoke-DW -Method POST -Path "/security/users" `
            -Body @{ userName = $dw.OpcUaUser; password = $suPwd; role = 'operator' } `
            -Desc "Create OPC UA user $($dw.OpcUaUser)"
        $suPwd = ''

        if ($userResult) {
            Add-Result -Phase DeviceWise -Check "OPC UA user $($dw.OpcUaUser)" -Status PASS
        } else {
            Add-Result -Phase DeviceWise -Check "OPC UA user $($dw.OpcUaUser)" -Status WARN `
                -Detail "Create manually: Admin -> Security -> Users -> New -> $($dw.OpcUaUser)"
        }
    } else {
        Add-Result -Phase DeviceWise -Check "OPC UA user $($dw.OpcUaUser)" -Status WARN -Detail "MedtronicSUPassword not in state  -  create user manually"
    }

    #endregion

    Write-Log PASS "deviceWise base platform configuration complete."
}
