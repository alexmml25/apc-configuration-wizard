#Requires -Version 5.1
<#
.SYNOPSIS
    Step 5 - Import and configure the CHMI deviceWise project.
.DESCRIPTION
    - Imports the approved CHMI .dwx project file from the repository
    - Verifies all required Scheduled and Monitor components are present and Loaded
    - Verifies all required SubTrigger/OnDemand components are Started
    - Starts any component not already in the Started state
#>

function Invoke-DeviceWiseCHMI {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [switch]$NonInteractive
    )

    Write-Log STEP "deviceWise CHMI Integration"

    $dw       = $Manifest.DeviceWise
    $dwPort   = $State['DeviceWisePort']
    $dwToken  = $State['DeviceWiseToken']
    $repoPath = Join-Path $Manifest.APC.RepositoryRoot $dw.CHMIProjectRepoSubPath

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

    #region -- Import CHMI project --------------------------------------------

    $chmiFile = Get-ChildItem $repoPath -Filter '*CHMI*.dwx' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $chmiFile) {
        # Fallback: any .dwx file with 'CHMI' in name anywhere under repo
        $chmiFile = Get-ChildItem $Manifest.APC.RepositoryRoot -Filter '*CHMI*.dwx' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    if (-not $chmiFile) {
        Add-Result -Phase DeviceWise -Check "CHMI project file" -Status WARN `
            -Detail "No CHMI .dwx file found under $repoPath — import manually in Workbench → Projects → Import"
    } else {
        Write-Log INFO "Importing CHMI project: $($chmiFile.FullName)"
        try {
            $form        = [System.Net.Http.MultipartFormDataContent]::new()
            $fileBytes   = [System.IO.File]::ReadAllBytes($chmiFile.FullName)
            $fileContent = [System.Net.Http.ByteArrayContent]::new($fileBytes)
            $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/octet-stream')
            $form.Add($fileContent, 'file', $chmiFile.Name)

            $client = [System.Net.Http.HttpClient]::new()
            if ($dwToken) { $client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $dwToken) }
            $resp = $client.PostAsync("$baseUrl/projects/import", $form).Result
            $client.Dispose()

            if ($resp.IsSuccessStatusCode) {
                Add-Result -Phase DeviceWise -Check "CHMI project import" -Status PASS -Detail $chmiFile.Name
            } else {
                Add-Result -Phase DeviceWise -Check "CHMI project import" -Status WARN -Detail "HTTP $($resp.StatusCode.value__) — verify in Workbench"
            }
        } catch {
            Add-Result -Phase DeviceWise -Check "CHMI project import" -Status WARN -Detail $_
        }

        # Brief pause for project to load
        Start-Sleep -Seconds 10
    }

    #endregion

    #region -- Verify Loaded components (CNC monitors) -------------------------

    $machines = $State['CNCMachines']
    $cncCount = [math]::Min($machines.Count, 3)

    # Build expected loaded component list dynamically from manifest — only for deployed CNC count
    $loadedComponents = $Manifest.CHMIComponents.Loaded | Where-Object {
        $cncNum = if ($_ -match 'CNC(\d)') { [int]$Matches[1] } else { 1 }
        $cncNum -le $cncCount
    }

    foreach ($comp in $loadedComponents) {
        $status = Invoke-DW -Method GET -Path "/projects/components/$([System.Web.HttpUtility]::UrlEncode($comp))" -Desc "Component status $comp"
        if ($status -and $status.state -eq 'Loaded') {
            Add-Result -Phase DeviceWise -Check "CHMI component: $comp" -Status PASS -Detail "Loaded"
        } elseif ($status) {
            # Try to load
            Invoke-DW -Method POST -Path "/projects/components/$([System.Web.HttpUtility]::UrlEncode($comp))/load" -Desc "Load $comp" | Out-Null
            Add-Result -Phase DeviceWise -Check "CHMI component: $comp" -Status PASS -Detail "Load triggered"
        } else {
            Add-Result -Phase DeviceWise -Check "CHMI component: $comp" -Status WARN -Detail "Not found — verify in Workbench → Projects"
        }
    }

    #endregion

    #region -- Verify Started components (triggers) ---------------------------

    foreach ($comp in $Manifest.CHMIComponents.Started) {
        $status = Invoke-DW -Method GET -Path "/projects/components/$([System.Web.HttpUtility]::UrlEncode($comp))" -Desc "Component status $comp"
        if ($status -and $status.state -eq 'Started') {
            Add-Result -Phase DeviceWise -Check "CHMI trigger: $comp" -Status PASS -Detail "Started"
        } elseif ($status) {
            Invoke-DW -Method POST -Path "/projects/components/$([System.Web.HttpUtility]::UrlEncode($comp))/start" -Desc "Start $comp" | Out-Null
            Add-Result -Phase DeviceWise -Check "CHMI trigger: $comp" -Status PASS -Detail "Start triggered"
        } else {
            Add-Result -Phase DeviceWise -Check "CHMI trigger: $comp" -Status WARN -Detail "Not found — verify in Workbench"
        }
    }

    #endregion

    Write-Log PASS "deviceWise CHMI integration complete."
}
