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
$lines = [System.Collections.Generic.List[string]]::new()
function W([string]$Text = '') { $lines.Add("$(Get-Date -Format 'HH:mm:ss') $Text"); Write-Host $Text }
function Write-Log { param($Level, $Message) }
function Add-Result { param($Phase, $Check, $Status, $Detail) }
. (Join-Path $root 'modules\Common.ps1')
. (Join-Path $root 'modules\DeviceWise.ps1')
. (Join-Path $root 'modules\02-TimescaleDB.ps1')

$inst = Find-MedtronicInstall -Manifest $m
if (-not $inst.Error) { $m = Set-ManifestMedtronicDrive -Manifest $m -Drive $inst.Drive }
$ns = $m.DeviceWise.OpcUaClient.Namespace
W "File flow test  $(Get-Date -Format s)  on $env:COMPUTERNAME as $env:USERDOMAIN\$env:USERNAME  CNC$Cnc  file $CsvPath"

# -- the CSV ---------------------------------------------------------------------------------------------
$src = [System.IO.File]::ReadAllLines((Resolve-Path $CsvPath))
function Get-Field([string]$Prefix) { foreach ($l in $src) { if ($l.StartsWith($Prefix)) { return $l.Substring($Prefix.Length).Trim().Trim(',') } }; '' }

# -- File Manager / Data Collector configs: which instrument, where it goes ---------------------------------
$fm = [xml][System.IO.File]::ReadAllText($m.DataApps.FileManagerConfig)
$dc = [xml][System.IO.File]::ReadAllText($m.DataApps.DataCollectorConfig)
$process = ''
foreach ($l in $src) { if ($l -match '^Process Name\s*,\s*([^,]+)') { $process = $Matches[1].Trim() } }
$dataType = ($process -split '_')[1]                       # 1ST_CTSCAN1_MPR -> CTSCAN1 (DataTypeSplit _, DataTypePos 1)
function Child($n, [string]$c) { $x = $n.SelectSingleNode($c); if ($x) { $x.InnerText.Trim() } else { '' } }   # (.Name on an XmlElement is its tag name)
$fmPath = $fm.SelectNodes('//Paths/*') | Where-Object { (Child $_ 'Name') -eq $dataType } | Select-Object -First 1
if (-not $fmPath) { W "FAIL: no File Manager path named '$dataType' (from Process Name '$process')"; $lines | Set-Content $out; exit 2 }
$dcBlock = $dc.SelectNodes('//DataTypeSettings/*') | Where-Object { (Child $_ 'Asset') -eq "CNC$Cnc" -and (Child $_ 'Name') -eq $dataType } | Select-Object -First 1
if (-not $dcBlock) { W "FAIL: no Data Collector block for CNC$Cnc / $dataType"; $lines | Set-Content $out; exit 2 }
$tagBase = (Child $dcBlock 'OPCTags/TagPath') -replace '^ns=\d+;s=', ''           # CNC1.DataCollector.DC CTSCAN.
$assetTags = $fm.SelectSingleNode("//CNCSettings/CNC$Cnc.Asset")
$tagOf = { param($p) ([string]$p) -replace '^ns=\d+;s=', '' }
W "Instrument $dataType : source $((Child $fmPath 'Path')) -> $((Child $fmPath 'NewPath'))\<asset> (error $((Child $fmPath 'ErrorPath'))\<asset>); Data Collector CNC$Cnc block '$(Child $dcBlock 'Name')' archive $((Child $dcBlock 'ArchivePath')); tags $tagBase*"

$session = Open-DwUaSession -Manifest $m
function Read-Tag([string]$Path) { try { (Get-DwUaValue -Session $session -Namespace $ns -Path $Path).Value } catch { $null } }
function Write-Tag([string]$Path, $Value) {
    # write with the node's own type (the MeasurementUI / DOC-CHMI tags are not all strings)
    $cur = Read-Tag $Path
    $v = if ($null -eq $cur -or $cur -is [string]) { [string]$Value } else { [Convert]::ChangeType($Value, $cur.GetType()) }
    $wvc = New-Object Opc.Ua.WriteValueCollection
    $w = New-Object Opc.Ua.WriteValue
    $w.NodeId = Get-DwUaNodeId -Session $session -Namespace $ns -Path $Path
    $w.AttributeId = [Opc.Ua.Attributes]::Value
    $w.Value = New-Object Opc.Ua.DataValue(New-Object Opc.Ua.Variant($v))
    $wvc.Add($w); $res = $null; $diag = $null
    [void]$session.Write($null, $wvc, [ref]$res, [ref]$diag)
    [string]$res[0]
}

$asset = [string](Read-Tag "CNC$Cnc.CNCAsset")
if (-not $asset) { W "FAIL: CNC$Cnc.CNCAsset is empty - File Manager would not know this CNC (run Step 8 / 11)"; $session.Close(); $lines | Set-Content $out; exit 2 }
$lot = "APCTEST$((Get-Date).ToString('MMddHHmmss'))"
$part = Get-Field 'Part Name,'; $sample = Get-Field 'Sample #,'
W "CNC$Cnc asset '$asset'; test lot '$lot'; part '$part'; process '$process'; sample '$sample'"

# -- 1. tags ------------------------------------------------------------------------------------------------
$tags = [ordered]@{
    (& $tagOf (Child $assetTags 'ProcessNamePath'))  = $process
    (& $tagOf (Child $assetTags 'SampleNumberPath')) = $sample
    (& $tagOf (Child $assetTags 'PartNumberPath'))   = $part
    (& $tagOf (Child $assetTags 'BatchNumberPath'))  = $lot
}
$saved = [ordered]@{}
W ''; W '== 1. CNC tags File Manager compares =='
foreach ($k in $tags.Keys) { $saved[$k] = Read-Tag $k; W "  $k : '$($saved[$k])' -> '$($tags[$k])' : $(Write-Tag $k $tags[$k])" }
$trig = Read-Tag "$($tagBase)Trigger"
if ($trig -eq $true) { W "  $($tagBase)Trigger was True (unconsumed result) -> False : $(Write-Tag "$($tagBase)Trigger" $false)" }

# -- 2. the file ------------------------------------------------------------------------------------------
$msid = Get-Field 'MSID#,'
$name = "$asset`_$($msid)_$lot.csv"
$fileLines = foreach ($l in $src) {
    if ($l.StartsWith('Machine Asset #,')) { "Machine Asset #,$asset" }
    elseif ($l -match '^Lot Number\s*,') { ($l -replace '^(Lot Number\s*,).*$', "`${1}$lot") }
    else { $l }
}
$srcFile = Join-Path (Child $fmPath 'Path') $name
$tmp = Join-Path $env:TEMP $name
[System.IO.File]::WriteAllLines($tmp, [string[]]$fileLines)
Move-Item -LiteralPath $tmp -Destination $srcFile -Force      # whole file at once (File Manager may read a half-copied file)
W ''; W "== 2. File dropped: $srcFile =="

# -- 3. follow it ----------------------------------------------------------------------------------------
$routeDir = Join-Path (Child $fmPath 'NewPath') $asset
$errDir   = Join-Path (Child $fmPath 'ErrorPath') $asset
$archive  = (Child $dcBlock 'ArchivePath')
$stage = [ordered]@{ PickedUp = $null; Routed = $null; Error = $null; Started = $null; Archived = $null; Done = $null }
$base = [IO.Path]::GetFileNameWithoutExtension($name)
$t0 = Get-Date; $status = ''; $archivedFile = $null
W ''; W "== 3. Following (up to $TimeoutSeconds s) =="
do {
    $el = [int]((Get-Date) - $t0).TotalSeconds
    if (-not $stage.PickedUp -and -not (Test-Path -LiteralPath $srcFile)) { $stage.PickedUp = $el; W "  +$el s picked up by File Manager (left $((Child $fmPath 'Path')))" }
    if (-not $stage.Routed -and (Get-ChildItem -LiteralPath $routeDir -Filter "$base*" -File -ErrorAction SilentlyContinue)) { $stage.Routed = $el; W "  +$el s routed to $routeDir" }
    $e = Get-ChildItem -LiteralPath $errDir -Filter "$base*" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $stage.Error -and $e) { $stage.Error = $el; W "  +$el s MISMATCH: File Manager moved it to $errDir - FileManager log has the detail" }
    $s = [string](Read-Tag "$($tagBase)Status")
    if ($s -ne $status) { $status = $s; W "  +$el s $($tagBase)Status = '$s'"; if ($s -in 'STARTED', 'PROCESSING' -and -not $stage.Started) { $stage.Started = $el } }
    $a = Get-ChildItem -LiteralPath $archive -Filter "$base*" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $stage.Archived -and $a) { $stage.Archived = $el; $archivedFile = $a.FullName; W "  +$el s archived: $archivedFile" }
    if ($s -in 'DONE_SUCCESS', 'DONE_ERROR' -and $stage.Archived) { $stage.Done = $el; break }
    if ($stage.Error) { break }
    Start-Sleep -Seconds 1
} while ($el -lt $TimeoutSeconds)
foreach ($t in 'ErrorCode', 'Message', 'Trigger', 'PartNumber', 'BatchNumber', 'CNCAsset', 'ProcessName', 'DataType') { W "  $($tagBase)$t = '$(Read-Tag "$($tagBase)$t")'" }

# -- DB rows of the test lot --------------------------------------------------------------------------------
$pg = $m.PostgreSQL
$conn = @{ Exe = (Join-Path $pg.BinDir 'psql.exe'); Port = $pg.DefaultPort; User = $pg.LocalUser; Database = $pg.LocalDB; PassFile = (Join-Path $env:APPDATA 'postgresql\pgpass.conf') }
$lotSql = $lot.Replace("'", "''")
$q = Invoke-PgSql -Conn $conn -Sql @"
SELECT (SELECT count(*) FROM sgrp_inf i JOIN part_lot l ON l.f_lot = i.f_lot WHERE l.f_name = '$lotSql'),
       (SELECT count(*) FROM sgrp_tst t JOIN sgrp_inf i ON i.f_sgrp = t.f_sgrp JOIN part_lot l ON l.f_lot = i.f_lot WHERE l.f_name = '$lotSql');
"@
W "  DB: $(if ($q.Ok) { $p = $q.Output -split '\|'; "$($p[0]) sample(s), $($p[1]) measurement value(s) for lot $lot" } else { "query failed: $($q.Output)" })"

W ''; W '== Result =='
W "  7.7  file routing (File Manager)   : $(if ($stage.Routed -or ($stage.Archived -and -not $stage.Error)) { 'PASS' } elseif ($stage.Error) { 'FAIL (mismatch -> error folder)' } else { 'FAIL' })"
W "  8.9  file detection in CheckPath   : $(if ($stage.Started -or $stage.Archived) { 'PASS' } else { 'FAIL' })"
W "  8.10 file archiving to ArchivePath : $(if ($stage.Archived) { 'PASS' } else { 'FAIL' })   Data Collector: $status"

# -- 4. clean up -------------------------------------------------------------------------------------------
W ''; W '== 4. Clean up =='
foreach ($k in $saved.Keys) { W "  $k back to '$($saved[$k])' : $(Write-Tag $k $(if ($null -eq $saved[$k]) { '' } else { $saved[$k] }))" }
if ((Read-Tag "$($tagBase)Trigger") -eq $true) { W "  $($tagBase)Trigger -> False : $(Write-Tag "$($tagBase)Trigger" $false)" }
foreach ($f in @($archivedFile, $srcFile) + @(Get-ChildItem -LiteralPath $errDir, $routeDir -Filter "$base*" -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })) {
    if ($f -and (Test-Path -LiteralPath $f)) { Remove-Item -LiteralPath $f -Force; W "  removed $f" }
}
if ($KeepData) { W "  -KeepData: rows of lot $lot left in the database" }
else {
    # the test lot's samples and everything only they use; part/process/test/job names only when this test made them
    $del = Invoke-PgSql -Conn $conn -SingleTransaction -Sql @"
CREATE TEMP TABLE t_sg AS SELECT i.f_sgrp FROM sgrp_inf i JOIN part_lot l ON l.f_lot = i.f_lot WHERE l.f_name = '$lotSql';
CREATE TEMP TABLE t_ds AS SELECT DISTINCT f_desc FROM sgrp_dsc WHERE f_sgrp IN (SELECT f_sgrp FROM t_sg);
CREATE TEMP TABLE t_ids AS SELECT DISTINCT i.f_part, i.f_prcs, i.f_job FROM sgrp_inf i WHERE i.f_sgrp IN (SELECT f_sgrp FROM t_sg);
CREATE TEMP TABLE t_ts AS SELECT DISTINCT f_test FROM sgrp_tst WHERE f_sgrp IN (SELECT f_sgrp FROM t_sg);
DELETE FROM sgrp_tst WHERE f_sgrp IN (SELECT f_sgrp FROM t_sg);
DELETE FROM sgrp_dsc WHERE f_sgrp IN (SELECT f_sgrp FROM t_sg);
DELETE FROM desc_dat WHERE f_desc IN (SELECT f_desc FROM t_ds) AND f_desc NOT IN (SELECT f_desc FROM sgrp_dsc);
DELETE FROM sgrp_inf WHERE f_sgrp IN (SELECT f_sgrp FROM t_sg);
DELETE FROM part_lot WHERE f_name = '$lotSql' AND f_lot NOT IN (SELECT f_lot FROM sgrp_inf);
DELETE FROM test_dat WHERE f_test IN (SELECT f_test FROM t_ts) AND f_test NOT IN (SELECT f_test FROM sgrp_tst) AND f_crtm >= '$($t0.ToString('yyyy-MM-dd HH:mm:ss'))';
DELETE FROM job_dat  WHERE f_job  IN (SELECT f_job  FROM t_ids) AND f_job  NOT IN (SELECT f_job  FROM sgrp_inf) AND f_crtm >= '$($t0.ToString('yyyy-MM-dd HH:mm:ss'))';
DELETE FROM prcs_dat WHERE f_prcs IN (SELECT f_prcs FROM t_ids) AND f_prcs NOT IN (SELECT f_prcs FROM sgrp_inf) AND f_prcs NOT IN (SELECT f_prcs FROM part_lot) AND f_crtm >= '$($t0.ToString('yyyy-MM-dd HH:mm:ss'))';
DELETE FROM part_dat WHERE f_part IN (SELECT f_part FROM t_ids) AND f_part NOT IN (SELECT f_part FROM sgrp_inf) AND f_part NOT IN (SELECT f_part FROM part_lot) AND f_crtm >= '$($t0.ToString('yyyy-MM-dd HH:mm:ss'))';
SELECT (SELECT count(*) FROM t_sg) || ' sample(s) deleted';
"@
    W "  DB: $(if ($del.Ok) { $del.Output } else { "clean-up failed (nothing deleted, rolled back): $($del.Output)" })"
}
try { [void]$session.Close() } catch { }
$lines | Set-Content -Path $out
W ''; W "Written: $out"
