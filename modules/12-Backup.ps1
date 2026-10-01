#Requires -Version 5.1
<#
.SYNOPSIS
    Step 12 - Back up the APC configuration to one timestamped folder on the VM.
.DESCRIPTION
    Everything goes to the run's Backups folder, C:\APC_Config\<type>_<yyyyMMdd-HHmmss>\Backups\ (from the wizard;
    without a run folder: <Manifest.Backup.Root>\<yyyyMMdd-HHmmss>\):
      800xA\<backup name>   800xA Full backup made by kits\800xA\Backup-800xA.ps1 (32-bit PowerShell, gated on
                            its exit code), then copied from the 800xA backup folder (C:\BACKUP\...);
                            the kit's log Backup800xA_<ts>.log and the robocopy logs go to the run's Logs
                            folder (without a run folder: the backup folder)
      Medtronic\            C:\Medtronic: DOC 1-3, File Manager, Data Collector, Data Analyzer and CNCnetPDM,
                            without the folders in Manifest.Backup.MedtronicExcludeDirs (logs, measurement data,
                            old backups)
      CNCnetPDM\            only when CNCnetPDM is installed outside C:\Medtronic
    deviceWise projects are not backed up automatically yet (no API) - back them up in Workbench.
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

    $cfg      = $Manifest.Backup
    try {
        $destRoot = Get-RunDir -State $State -Name Backups -Manifest $Manifest
        Add-Result -Phase Backup -Check "Backup folder" -Status PASS -Detail $destRoot
    } catch {
        Add-Result -Phase Backup -Check "Backup folder" -Status FAIL -Detail "Cannot create the backup folder: $($_.Exception.Message)"
        throw "Backup folder could not be created - nothing was backed up."
    }
    $State['BackupRoot'] = $destRoot
    # robocopy / 800xA kit logs: the run's Logs folder, or next to the backup when there is no run folder
    $logDir = if ($State['RunRoot']) { Get-RunDir -State $State -Name Logs } else { $destRoot }

    # robocopy exit codes 0-7 mean success (8+ = failures)
    function Copy-Tree {
        param([string]$Source, [string]$Destination, [string]$Label, [string[]]$ExcludeDirs = @())
        $log  = Join-Path $logDir "robocopy_$($Label -replace '\W', '').log"
        $argz = @($Source, $Destination, '/E', '/R:2', '/W:5', '/NP', "/LOG+:$log")
        if ($ExcludeDirs) { $argz += '/XD'; $argz += $ExcludeDirs }
        & robocopy.exe @argz | Out-Null
        $rc = $LASTEXITCODE
        if ($rc -le 7) {
            Add-Result -Phase Backup -Check "$Label backup" -Status PASS -Detail $Destination
        } else {
            Add-Result -Phase Backup -Check "$Label backup" -Status FAIL -Detail "robocopy exit $rc - see $log"
        }
        return ($rc -le 7)
    }

    #region -- 800xA Full backup (kits\800xA\Backup-800xA.ps1) -----------------

    if ($Manifest.ABB800xA.Backup.Enabled -eq $false) {
        Write-Log INFO "800xA backup disabled in the manifest (ABB800xA.Backup.Enabled)."
    } else {
        $kit = Get-800xAKit -Manifest $Manifest
        foreach ($problem in $kit.Problems) { Add-Result -Phase Backup -Check "800xA kit" -Status FAIL -Detail $problem }
        if ($kit.Problems.Count -eq 0) {
            Write-Log INFO "Starting 800xA Full backup ($($Manifest.ABB800xA.Backup.DefPath)) - usually about 1.5 minutes..."
            $bk = Invoke-800xABackup -Manifest $Manifest -Kit $kit -LogDir $logDir
            $copied = ''
            if ($bk.Ok) {
                Add-Result -Phase Backup -Check "800xA Full backup" -Status PASS `
                    -Detail "$($bk.Name)  ($($bk.Folder), $($bk.Files) files, $($bk.SizeMB) MB, errors $($bk.Errors), warnings $($bk.Warnings))"
                if ($bk.Folder -and (Test-Path -LiteralPath $bk.Folder)) {
                    $copied = Join-Path (Join-Path $destRoot '800xA') $bk.Name
                    if (-not (Copy-Tree -Source $bk.Folder -Destination $copied -Label '800xA')) { $copied = '' }
                } else {
                    Add-Result -Phase Backup -Check "800xA backup copy" -Status FAIL -Detail "800xA backup folder not found: $($bk.Folder)"
                }
            } else {
                Add-Result -Phase Backup -Check "800xA Full backup" -Status FAIL `
                    -Detail "Exit $($bk.ExitCode): $($bk.Message)$(if ($bk.Name) { " - backup $($bk.Name)" }). Log: $($bk.LogFile)"
            }
            $State['Backup800xA'] = @{ Ok = $bk.Ok; ExitCode = $bk.ExitCode; Name = $bk.Name; Folder = $bk.Folder; Copy = $copied; LogFile = $bk.LogFile }
        }
    }

    #endregion

    #region -- C:\Medtronic (DOC, data applications, CNCnetPDM) ----------------

    $medtronic = [string]$cfg.MedtronicDir
    if (Test-Path -LiteralPath $medtronic) {
        $exclude = @($cfg.MedtronicExcludeDirs | ForEach-Object { Join-Path $medtronic ($_ -replace '[\\/]', [IO.Path]::DirectorySeparatorChar) })
        if ($exclude) { Write-Log INFO "Medtronic backup leaves out: $($cfg.MedtronicExcludeDirs -join ', ')" }
        [void](Copy-Tree -Source $medtronic -Destination (Join-Path $destRoot 'Medtronic') -Label 'Medtronic' -ExcludeDirs $exclude)
    } else {
        Add-Result -Phase Backup -Check "Medtronic backup" -Status FAIL -Detail "Not found: $medtronic"
    }

    #endregion

    #region -- CNCnetPDM (only when installed outside C:\Medtronic) ------------

    $cncPdmDir = @($Manifest.CNCnetPDM.InstallDir, $Manifest.CNCnetPDM.FallbackDir) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $cncPdmDir) {
        Add-Result -Phase Backup -Check "CNCnetPDM backup" -Status WARN -Detail "CNCnetPDM folder not found"
    } elseif ((Join-Path $cncPdmDir '').StartsWith((Join-Path $medtronic ''), [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Log INFO "CNCnetPDM ($cncPdmDir) is inside $medtronic - included in the Medtronic backup."
    } else {
        [void](Copy-Tree -Source $cncPdmDir -Destination (Join-Path $destRoot 'CNCnetPDM') -Label 'CNCnetPDM' -ExcludeDirs @(Join-Path $cncPdmDir 'log'))
    }

    #endregion

    #region -- deviceWise (not automated yet) ----------------------------------

    Add-Result -Phase Backup -Check "deviceWise backup" -Status WARN `
        -Detail "Not automated yet - in Workbench: Projects -> right-click each project -> Backup (include Network Settings), save to $(Join-Path $destRoot 'deviceWise')"

    #endregion

    Write-Log PASS "Backup step complete: $destRoot"
    if ($State['Backup800xA']) { Write-Log INFO "  800xA backup: $($State['Backup800xA'].Name)  (copy: $($State['Backup800xA'].Copy))" }
}
