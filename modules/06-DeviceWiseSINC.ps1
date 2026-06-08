#Requires -Version 5.1
<#
.SYNOPSIS
    Step 6 - Import and configure the SINC deviceWise project.
.DESCRIPTION
    - Imports the approved SINC .dwx project files from the repository
    - Configures the EMAIL_TO variable on 0_DefaultConfiguration
    - Populates the CNC_ASSET_Management local DB table (CNC_NODE, CNC_ASSET, CNC_TYPE)
    - Populates the CNC_Settings local DB table (alarm parameters per CNC)
    - Verifies all SINC components and Master Reset triggers are Started
#>

function Invoke-DeviceWiseSINC {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [switch]$NonInteractive
    )

    Write-Log STEP "deviceWise SINC Integration"

    $dw       = $Manifest.DeviceWise
    $dwPort   = $State['DeviceWisePort']
    $dwToken  = $State['DeviceWiseToken']
    $machines = $State['CNCMachines']
    $repoPath = Join-Path $Manifest.APC.RepositoryRoot $dw.SINCProjectRepoSubPath

    if ($dwPort -eq 0) { throw "DeviceWisePort not set. Run Step 4 first." }

    $baseUrl = "http://localhost:${dwPort}$($dw.ApiBasePath)"
    $headers = @{ 'Content-Type' = 'application/json' }
    if ($dwToken) { $headers['Authorization'] = "Bearer $dwToken" }

    function Invoke-DW {
        param([string]$Method, [string]$Path, [object]$Body = $null, [string]$Desc = '')
        $params = @{ Uri = "$baseUrl$Path"; Method = $Method; Headers = $headers; TimeoutSec = 60 }
        if ($Body) { $params['Body'] = ($Body | ConvertTo-Json -Depth 10) }
        try { return Invoke-RestMethod @params -ErrorAction Stop }
        catch { Write-Log WARN "$Desc failed: $_"; return $null }
    }

    #region -- Import SINC project files -------------------------------------

    $sincFiles = Get-ChildItem $repoPath -Filter '*SINC*.dwx' -ErrorAction SilentlyContinue
    if (-not $sincFiles) {
        $sincFiles = Get-ChildItem $Manifest.APC.RepositoryRoot -Filter '*SINC*.dwx' -Recurse -ErrorAction SilentlyContinue
    }

    if (-not $sincFiles -or $sincFiles.Count -eq 0) {
        Add-Result -Phase DeviceWise -Check "SINC project files" -Status WARN `
            -Detail "No SINC .dwx files found — import manually in Workbench → Projects → Import"
    } else {
        foreach ($sincFile in $sincFiles) {
            Write-Log INFO "Importing SINC project: $($sincFile.Name)"
            try {
                $form        = [System.Net.Http.MultipartFormDataContent]::new()
                $fileBytes   = [System.IO.File]::ReadAllBytes($sincFile.FullName)
                $fileContent = [System.Net.Http.ByteArrayContent]::new($fileBytes)
                $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/octet-stream')
                $form.Add($fileContent, 'file', $sincFile.Name)
                $client = [System.Net.Http.HttpClient]::new()
                if ($dwToken) { $client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $dwToken) }
                $resp = $client.PostAsync("$baseUrl/projects/import", $form).Result
                $client.Dispose()
                if ($resp.IsSuccessStatusCode) {
                    Add-Result -Phase DeviceWise -Check "SINC import: $($sincFile.Name)" -Status PASS
                } else {
                    Add-Result -Phase DeviceWise -Check "SINC import: $($sincFile.Name)" -Status WARN -Detail "HTTP $($resp.StatusCode.value__)"
                }
            } catch {
                Add-Result -Phase DeviceWise -Check "SINC import: $($sincFile.Name)" -Status WARN -Detail $_
            }
        }
        Start-Sleep -Seconds 10
    }

    #endregion

    #region -- Configure EMAIL_TO on 0_DefaultConfiguration ------------------

    $emailTo  = $State['SINCEmail']
    $compName = '0_DefaultConfiguration'
    if ($emailTo) {
        $emailResult = Invoke-DW -Method PUT -Path "/projects/components/$([System.Web.HttpUtility]::UrlEncode($compName))/variables/EMAIL_TO" `
            -Body @{ value = $emailTo } -Desc "Set EMAIL_TO on $compName"
        if ($emailResult) {
            Add-Result -Phase DeviceWise -Check "SINC EMAIL_TO" -Status PASS -Detail $emailTo
        } else {
            Add-Result -Phase DeviceWise -Check "SINC EMAIL_TO" -Status WARN `
                -Detail "Set manually: $compName → Edit → Local Variables → EMAIL_TO = $emailTo"
        }
    } else {
        Add-Result -Phase DeviceWise -Check "SINC EMAIL_TO" -Status WARN -Detail "No email address provided — set manually"
    }

    #endregion

    #region -- Configure CNC_ASSET_Management table ---------------------------

    Write-Log INFO "Configuring CNC_ASSET_Management table..."
    $settings = $Manifest.SINCDefaultSettings

    for ($i = 0; $i -lt $machines.Count; $i++) {
        $machine  = $machines[$i]
        $cncNode  = "CNC$($i + 1)"
        $cncAsset = $machine.MachineName
        $cncType  = $machine.CNCType

        $row = @{
            CNC_NODE  = $cncNode
            CNC_ASSET = $cncAsset
            CNC_TYPE  = $cncType
        }
        $assetResult = Invoke-DW -Method POST `
            -Path "/localdb/tables/CNC_ASSET_Management/rows" `
            -Body $row -Desc "CNC_ASSET_Management: $cncNode"

        if ($assetResult) {
            Add-Result -Phase DeviceWise -Check "CNC_ASSET_Management: $cncNode" -Status PASS -Detail "$cncAsset | $cncType"
        } else {
            # Try PUT (update) if row exists
            $putResult = Invoke-DW -Method PUT `
                -Path "/localdb/tables/CNC_ASSET_Management/rows/$cncNode" `
                -Body $row -Desc "CNC_ASSET_Management update: $cncNode"
            if ($putResult) {
                Add-Result -Phase DeviceWise -Check "CNC_ASSET_Management: $cncNode" -Status PASS -Detail "Updated: $cncAsset | $cncType"
            } else {
                Add-Result -Phase DeviceWise -Check "CNC_ASSET_Management: $cncNode" -Status WARN `
                    -Detail "Set manually: Local Database → CNC_ASSET_Management → CNC_NODE=$cncNode, CNC_ASSET=$cncAsset, CNC_TYPE=$cncType"
            }
        }
    }

    #endregion

    #region -- Configure CNC_Settings table -----------------------------------

    Write-Log INFO "Configuring CNC_Settings table..."
    for ($i = 0; $i -lt $machines.Count; $i++) {
        $cncNode = "CNC$($i + 1)"
        $row = @{
            ASSET_NAME   = $cncNode
            ALARM_TAG    = $settings.ALARM_TAG
            ALARM_VALUE  = $settings.ALARM_VALUE
            ALARM_PATH   = $settings.ALARM_PATH
            WAIT_TIME    = $settings.WAIT_TIME
            RETRY_COUNT  = $settings.RETRY_COUNT
            NOTES        = $settings.NOTES
        }
        $settingsResult = Invoke-DW -Method POST `
            -Path "/localdb/tables/CNC_Settings/rows" `
            -Body $row -Desc "CNC_Settings: $cncNode"

        if ($settingsResult) {
            Add-Result -Phase DeviceWise -Check "CNC_Settings: $cncNode" -Status PASS
        } else {
            $putResult = Invoke-DW -Method PUT `
                -Path "/localdb/tables/CNC_Settings/rows/$cncNode" `
                -Body $row -Desc "CNC_Settings update: $cncNode"
            if ($putResult) {
                Add-Result -Phase DeviceWise -Check "CNC_Settings: $cncNode" -Status PASS -Detail "Updated"
            } else {
                Add-Result -Phase DeviceWise -Check "CNC_Settings: $cncNode" -Status WARN `
                    -Detail "Set manually: Local Database → CNC_Settings → ASSET_NAME=$cncNode"
            }
        }
    }

    #endregion

    #region -- Verify SINC components are Started -----------------------------

    $cncCount = $machines.Count
    foreach ($comp in $Manifest.SINCComponents) {
        # Skip CNC-specific components for CNC instances that don't exist
        if ($comp -match 'CNC(\d)') {
            if ([int]$Matches[1] -gt $cncCount) { continue }
        }

        $status = Invoke-DW -Method GET -Path "/projects/components/$([System.Web.HttpUtility]::UrlEncode($comp))" -Desc "Status $comp"
        if ($status -and $status.state -eq 'Started') {
            Add-Result -Phase DeviceWise -Check "SINC: $comp" -Status PASS -Detail "Started"
        } elseif ($status) {
            Invoke-DW -Method POST -Path "/projects/components/$([System.Web.HttpUtility]::UrlEncode($comp))/start" -Desc "Start $comp" | Out-Null
            Add-Result -Phase DeviceWise -Check "SINC: $comp" -Status PASS -Detail "Start triggered"
        } else {
            Add-Result -Phase DeviceWise -Check "SINC: $comp" -Status WARN -Detail "Not found — verify in Workbench"
        }
    }

    foreach ($comp in $Manifest.SINCMasterResetComponents) {
        if ($comp -match 'CNC(\d)' -and [int]$Matches[1] -gt $cncCount) { continue }
        $status = Invoke-DW -Method GET -Path "/projects/components/$([System.Web.HttpUtility]::UrlEncode($comp))" -Desc "Status $comp"
        if ($status -and $status.state -eq 'Started') {
            Add-Result -Phase DeviceWise -Check "SINC MasterReset: $comp" -Status PASS
        } elseif ($status) {
            Invoke-DW -Method POST -Path "/projects/components/$([System.Web.HttpUtility]::UrlEncode($comp))/start" -Desc "Start $comp" | Out-Null
            Add-Result -Phase DeviceWise -Check "SINC MasterReset: $comp" -Status PASS -Detail "Start triggered"
        } else {
            Add-Result -Phase DeviceWise -Check "SINC MasterReset: $comp" -Status WARN -Detail "Not found"
        }
    }

    #endregion

    Write-Log PASS "deviceWise SINC integration complete."
}
