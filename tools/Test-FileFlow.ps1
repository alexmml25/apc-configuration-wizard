#Requires -Version 5.1
<#
.SYNOPSIS
    File Manager -> Data Collector end-to-end test with a measurement CSV (D01555624 7.7 file routing, 8.9 file
    detection in CheckPath, 8.10 archiving). Puts everything back afterwards.
.DESCRIPTION
    How the apps work (decompiled DataCollector_FileManager.exe / DataCollector.exe, 2026-10-15):
      File Manager watches each instrument's Path. A file whose 'Machine Asset #' is one of its CNCs (CNCn.CNCAsset)
      is checked against the CNC's tags (CheckMismatchData): MeasurementUI.ProcessName contains the file's process,
      MeasurementUI.SampleNumber, DOC-CHMI.RunningPartNumber and RunningBatchNumber equal the file's. Match ->
      moved to <NewPath>\<CNC asset>\, mismatch -> <ErrorPath>\<CNC asset>\. Other assets are left alone (other VMs).
      Data Collector picks it up from <CheckPath>\<CNC asset>\ when DataCollector.DC <TYPE>.Trigger is False,
      writes Status STARTED / PROCESSING / DONE_SUCCESS|DONE_ERROR, moves it to ArchivePath, stores the sample
      (sgrp_inf, sgrp_tst, sgrp_dsc + desc_dat, part_lot; part_dat / prcs_dat / test_dat / job_dat when new) and
      sets Trigger True (CHMI clears it - this test clears it).
    Steps:
      1. CNC<n>: save the four tags, set them to the file's values; clear DC <TYPE>.Trigger if set
      2. copy the CSV with Machine Asset # = CNC<n>'s asset and a unique lot APCTEST<time> into the instrument Path
      3. follow it: picked up, routed (NewPath\<asset> or ErrorPath), Data Collector status, archived, rows in the DB
      4. clean up: tags restored, Trigger cleared, archived copy removed, the test lot's rows deleted (not with -KeepData)
    Report: C:\APC_Config\Logs\fileflow-test_<ts>.txt. 64-bit PowerShell, service account (pgpass from Step 2).
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Test-FileFlow.ps1 -CsvPath .\1st_TestFile.csv
#>
param(
    [Parameter(Mandatory)] [string]$CsvPath,
    [int]$Cnc = 1,
    [string]$ManifestPath,      # default set below: $PSScriptRoot is empty in param defaults of an advanced script (PS 5.1)
    [string]$OutDir = 'C:\APC_Config\Logs',
    [int]$TimeoutSeconds = 180,
    [switch]$KeepData
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
if (-not $ManifestPath) { $ManifestPath = Join-Path $root 'APC_ConfigManifest.json' }
$m    = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$ts    = Get-Date -Format 'yyyyMMdd_HHmmss'
$out   = Join-Path $OutDir "fileflow-test_$ts.txt"
function Write-Log { param($Level, $Message) }
function Add-Result { param($Phase, $Check, $Status, $Detail) }
. (Join-Path $root 'modules\Common.ps1')
. (Join-Path $root 'modules\DeviceWise.ps1')
. (Join-Path $root 'modules\02-TimescaleDB.ps1')
. (Join-Path $root 'modules\FileFlowTest.ps1')

$r = Invoke-FileFlowTest -Manifest $m -CsvPath (Resolve-Path $CsvPath).Path -Cnc $Cnc -TimeoutSeconds $TimeoutSeconds -KeepData:$KeepData -Log { param($t) Write-Host $t }
$r.Lines | Set-Content -Path $out
Write-Host ''; Write-Host "Written: $out"
