#Requires -Version 5.1
<#
.SYNOPSIS
    Step 12 - Back up all configured applications to the site backup share.
.DESCRIPTION
    - deviceWise: REST API backup export → save to backup share
    - Medtronic folder: robocopy C:\Medtronic\ → backup share
    - CNCnetPDM: robocopy CNCnetPDM dir → backup share
    - CHMI/800xA: ABB COM AfwAsynchBackup (32-bit runspace) with guided fallback
    - Logs all backup destination paths for the verification report
#>

function Invoke-Backup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [switch]$NonInteractive
    )

    Write-Log STEP "Application Backup"

    $dwPort   = $State['DeviceWisePort']
    $dwToken  = $State['DeviceWiseToken']
    $dw       = $Manifest.DeviceWise
    $cncPdm   = $Manifest.CNCnetPDM
    $share    = $Manifest.BackupShare
    $vmName   = $env:COMPUTERNAME
    $ts       = Get-Date -Format 'yyyyMMdd-HHmmss'
    $destRoot = Join-Path $share "$vmName\$ts"

    Write-Log INFO "Backup destination root: $destRoot"

    try {
        New-Item -ItemType Directory -Path $destRoot -Force | Out-Null
        Add-Result -Phase Backup -Check "Backup destination" -Status PASS -Detail $destRoot
    } catch {
        Add-Result -Phase Backup -Check "Backup destination" -Status WARN `
            -Detail "Cannot create $destRoot : $_ — check network share connectivity"
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
        Add-Result -Phase Backup -Check "deviceWise backup" -Status WARN -Detail "No projects found via API — backup manually from Workbench → Projects → Export"
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
                    -Detail "Robocopy exited $exitCode — check $destRoot\robocopy_Medtronic.log"
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

    #region -- CHMI / 800xA backup -------------------------------------------

    Write-Log INFO "Attempting CHMI backup via ABB COM object (requires 32-bit process)..."
    $chmiBackupDir = Join-Path $destRoot 'CHMI'
    New-Item -ItemType Directory -Path $chmiBackupDir -Force | Out-Null

    $comSuccess = $false
    try {
        # 800xA COM must run in a 32-bit process — invoke via 32-bit powershell
        $ps32 = 'C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path $ps32) {
            $backupScript = @"
try {
    `$backup = New-Object -ComObject ABB.AfwAsynchBackup -ErrorAction Stop
    `$backup.StartBackup('$chmiBackupDir\\CHMI_backup.afw')
    `$waited = 0
    do { Start-Sleep -Seconds 5; `$waited += 5
    } while (`$backup.Status -notin @('Complete','Finished','Done','Error') -and `$waited -lt 300)
    Write-Host "STATUS:`$(`$backup.Status)"
    Write-Host "MSG:`$(`$backup.InfoMessage)"
} catch {
    Write-Host "FAILED:`$_"
}
"@
            $tmpScript = [System.IO.Path]::GetTempFileName() + '.ps1'
            [System.IO.File]::WriteAllText($tmpScript, $backupScript)
            $proc = Start-Process -FilePath $ps32 -ArgumentList "-NonInteractive -File `"$tmpScript`"" `
                -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$destRoot\chmi_backup.log" -ErrorAction Stop
            Remove-Item $tmpScript -Force -ErrorAction SilentlyContinue

            $logContent = if (Test-Path "$destRoot\chmi_backup.log") {
                [System.IO.File]::ReadAllText("$destRoot\chmi_backup.log")
            } else { '' }

            if ($logContent -match 'STATUS:(Complete|Finished|Done)') {
                $comSuccess = $true
                Add-Result -Phase Backup -Check "CHMI backup (COM)" -Status PASS -Detail $chmiBackupDir
            } else {
                Write-Log WARN "COM backup output: $logContent"
            }
        }
    } catch {
        Write-Log WARN "CHMI COM backup failed: $_"
    }

    if (-not $comSuccess) {
        Add-Result -Phase Backup -Check "CHMI backup (COM)" -Status WARN `
            -Detail "Automated backup unavailable — use guided fallback below"
        Write-Log MANUAL ""
        Write-Log MANUAL "== CHMI MANUAL BACKUP =="
        Write-Log MANUAL "1. Open ABB Engineering Workplace"
        Write-Log MANUAL "2. Tools → Backup → Full Backup"
        Write-Log MANUAL "3. Save to: $chmiBackupDir"
        Write-Log MANUAL "4. Verify .afw file appears in that folder"
    }

    $State['BackupCHMIPath'] = $chmiBackupDir

    #endregion

    Write-Log PASS "Backup step complete."
    Write-Log INFO "All backup paths recorded for the verification report:"
    Write-Log INFO "  deviceWise  : $($State['BackupDeviceWisePath'])"
    Write-Log INFO "  Medtronic   : $($State['BackupMedtronicPath'])"
    Write-Log INFO "  CNCnetPDM   : $(Join-Path $destRoot 'CNCnetPDM')"
    Write-Log INFO "  CHMI        : $($State['BackupCHMIPath'])"
}
