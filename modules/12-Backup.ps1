#Requires -Version 5.1
<#
.SYNOPSIS
    Step 12 - Back up all configured applications to the site backup share.
.DESCRIPTION
    - deviceWise: REST API backup export -> save to backup share
    - Medtronic folder: robocopy C:\Medtronic\ -> backup share
    - CNCnetPDM: robocopy CNCnetPDM dir -> backup share
    - 800xA: Full backup through kits\800xA\Backup-800xA.ps1 (32-bit PowerShell), run first and gated
      on its exit code; backup name, folder, size and errors/warnings are logged
    - Logs all backup destination paths for the verification report
#>

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'ABB800xA.ps1')

function Invoke-Backup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [switch]$NonInteractive
    )

    Write-Log STEP "Application Backup"

    #region -- 800xA Full backup (kits\800xA\Backup-800xA.ps1) -----------------

    if ($Manifest.ABB800xA.Backup.Enabled -eq $false) {
        Write-Log INFO "800xA backup disabled in the manifest (ABB800xA.Backup.Enabled)."
    } else {
        $kit = Get-800xAKit -Manifest $Manifest
        foreach ($problem in $kit.Problems) { Add-Result -Phase Backup -Check "800xA kit" -Status FAIL -Detail $problem }
        if ($kit.Problems.Count -eq 0) {
            Write-Log INFO "Starting 800xA Full backup ($($Manifest.ABB800xA.Backup.DefPath)) - usually about 1.5 minutes..."
            $bk = Invoke-800xABackup -Manifest $Manifest -Kit $kit
            if ($bk.Ok) {
                Add-Result -Phase Backup -Check "800xA Full backup" -Status PASS `
                    -Detail "$($bk.Name)  ($($bk.Folder), $($bk.Files) files, $($bk.SizeMB) MB, errors $($bk.Errors), warnings $($bk.Warnings))"
            } else {
                Add-Result -Phase Backup -Check "800xA Full backup" -Status FAIL `
                    -Detail "Exit $($bk.ExitCode): $($bk.Message)$(if ($bk.Name) { " - backup $($bk.Name)" }). Log: $($bk.LogFile)"
            }
            $State['Backup800xA']    = @{ Ok = $bk.Ok; ExitCode = $bk.ExitCode; Name = $bk.Name; Folder = $bk.Folder; LogFile = $bk.LogFile }
            $State['BackupCHMIPath'] = $bk.Folder
        }
    }

    #endregion

    $dwPort   = $State['DeviceWisePort']
    $dwToken  = $State['DeviceWiseToken']
    $dw       = $Manifest.DeviceWise
    $cncPdm   = $Manifest.CNCnetPDM
    $share    = $Manifest.APC.BackupShare
    $vmName   = $env:COMPUTERNAME
    $ts       = Get-Date -Format 'yyyyMMdd-HHmmss'
    $destRoot = Join-Path $share "$vmName\$ts"

    Write-Log INFO "Backup destination root: $destRoot"

    try {
        New-Item -ItemType Directory -Path $destRoot -Force | Out-Null
        Add-Result -Phase Backup -Check "Backup destination" -Status PASS -Detail $destRoot
    } catch {
        Add-Result -Phase Backup -Check "Backup destination" -Status WARN `
            -Detail "Cannot create $destRoot : $_  -  check network share connectivity"
    }

    $baseUrl = "http://localhost:${dwPort}$($dw.ApiBasePath)"
    $headers = @{ 'Content-Type' = 'application/json' }
    if ($dwToken) { $headers['Authorization'] = "Bearer $dwToken" }

    function Invoke-DW {
        param([string]$Method, [string]$Path, [object]$Body = $null, [string]$Desc = '')
        $params = @{ Uri = "$baseUrl$Path"; Method = $Method; Headers = $headers; TimeoutSec = 120 }
        if ($Body) { $params['Body'] = ($Body | ConvertTo-Json -Depth 10) }
        try { return Invoke-RestMethod @params -ErrorAction Stop }
        catch { Write-Log WARN "$Desc failed: $_"; return $null }
    }

    #region -- deviceWise backup ----------------------------------------------

    Write-Log INFO "Exporting deviceWise project backup..."
    $dwBackupDir = Join-Path $destRoot 'deviceWise'
    New-Item -ItemType Directory -Path $dwBackupDir -Force | Out-Null

    # Get project list
    $projects = Invoke-DW -Method GET -Path "/projects" -Desc "Project list"
    $projectNames = if ($projects) { $projects | ForEach-Object { if ($_.name) { $_.name } else { $_ } } } else { @() }

    if ($projectNames.Count -eq 0) {
        Add-Result -Phase Backup -Check "deviceWise backup" -Status WARN -Detail "No projects found via API  -  backup manually from Workbench -> Projects -> Export"
    } else {
        foreach ($proj in $projectNames) {
            $encoded = [System.Web.HttpUtility]::UrlEncode($proj)
            try {
                $backupPath = Join-Path $dwBackupDir "$proj.dwx"
                $params = @{
                    Uri     = "$baseUrl/projects/$encoded/export?includeNetworkSettings=true"
                    Method  = 'GET'
                    Headers = $headers
                    OutFile = $backupPath
                    TimeoutSec = 120
                }
                Invoke-RestMethod @params -ErrorAction Stop
                Add-Result -Phase Backup -Check "deviceWise: $proj" -Status PASS -Detail $backupPath
            } catch {
                Add-Result -Phase Backup -Check "deviceWise: $proj" -Status WARN -Detail "Export failed: $_"
            }
        }
    }
    $State['BackupDeviceWisePath'] = $dwBackupDir

    #endregion

    #region -- Medtronic folder backup ----------------------------------------

    Write-Log INFO "Backing up C:\Medtronic\ ..."
    $medtronicSrc = 'C:\Medtronic'
    $medtronicDst = Join-Path $destRoot 'Medtronic'
    New-Item -ItemType Directory -Path $medtronicDst -Force | Out-Null

    if (Test-Path $medtronicSrc) {
        try {
            $robocopy = & robocopy.exe $medtronicSrc $medtronicDst /E /R:2 /W:5 /NP /LOG+:"$destRoot\robocopy_Medtronic.log" 2>&1
            $exitCode = $LASTEXITCODE
            # robocopy exit codes 0-7 are success/partial-success
            if ($exitCode -le 7) {
                Add-Result -Phase Backup -Check "Medtronic folder backup" -Status PASS -Detail $medtronicDst
            } else {
                Add-Result -Phase Backup -Check "Medtronic folder backup" -Status WARN `
                    -Detail "Robocopy exited $exitCode  -  check $destRoot\robocopy_Medtronic.log"
            }
        } catch {
            Add-Result -Phase Backup -Check "Medtronic folder backup" -Status WARN -Detail $_
        }
    } else {
        Add-Result -Phase Backup -Check "Medtronic folder backup" -Status WARN -Detail "Source not found: $medtronicSrc"
    }
    $State['BackupMedtronicPath'] = $medtronicDst

    #endregion

    #region -- CNCnetPDM folder backup ----------------------------------------

    Write-Log INFO "Backing up CNCnetPDM..."
    $cncPdmSrc = $null
    foreach ($candidate in @($cncPdm.InstallDir, $cncPdm.FallbackDir)) {
        if (Test-Path $candidate) { $cncPdmSrc = $candidate; break }
    }
    if (-not $cncPdmSrc) {
        $found = Get-ChildItem 'C:\' -Directory -Filter '*CNCnetPDM*' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $cncPdmSrc = $found.FullName }
    }

    if ($cncPdmSrc) {
        $cncPdmDst = Join-Path $destRoot 'CNCnetPDM'
        New-Item -ItemType Directory -Path $cncPdmDst -Force | Out-Null
        try {
            $rc = & robocopy.exe $cncPdmSrc $cncPdmDst /E /R:2 /W:5 /NP /LOG+:"$destRoot\robocopy_CNCnetPDM.log" 2>&1
            if ($LASTEXITCODE -le 7) {
                Add-Result -Phase Backup -Check "CNCnetPDM backup" -Status PASS -Detail $cncPdmDst
            } else {
                Add-Result -Phase Backup -Check "CNCnetPDM backup" -Status WARN -Detail "Robocopy exit $LASTEXITCODE"
            }
        } catch {
            Add-Result -Phase Backup -Check "CNCnetPDM backup" -Status WARN -Detail $_
        }
    } else {
        Add-Result -Phase Backup -Check "CNCnetPDM backup" -Status WARN -Detail "CNCnetPDM directory not found"
    }

    #endregion


    Write-Log PASS "Backup step complete."
    Write-Log INFO "All backup paths recorded for the verification report:"
    Write-Log INFO "  deviceWise  : $($State['BackupDeviceWisePath'])"
    Write-Log INFO "  Medtronic   : $($State['BackupMedtronicPath'])"
    Write-Log INFO "  CNCnetPDM   : $(Join-Path $destRoot 'CNCnetPDM')"
    Write-Log INFO "  800xA       : $(if ($State['Backup800xA']) { "$($State['Backup800xA'].Name)  $($State['Backup800xA'].Folder)" } else { '(not run)' })"
}
