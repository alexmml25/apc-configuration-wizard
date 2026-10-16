#Requires -Version 5.1
<#
.SYNOPSIS
    File Manager -> Data Collector end-to-end test with a measurement CSV (D01555624 7.7 file routing, 8.9 file
    detection in CheckPath, 8.10 archiving), used by Step 13 and tools\Test-FileFlow.ps1. Puts everything back.
.DESCRIPTION
    How the apps work (decompiled DataCollector_FileManager.exe / DataCollector.exe, 2026-10-15):
      File Manager watches each instrument's Path. A file whose 'Machine Asset #' is one of its CNCs (CNCn.CNCAsset)
      is checked against the CNC's tags (CheckMismatchData): MeasurementUI.ProcessName contains the file's process,
      MeasurementUI.SampleNumber, DOC-CHMI.RunningPartNumber and RunningBatchNumber equal the file's. Match ->
      moved to <NewPath>\<CNC asset>\, mismatch -> <ErrorPath>\<CNC asset>\. Other assets are left alone (other VMs).
      Data Collector picks it up from <CheckPath>\<CNC asset>\ when DataCollector.DC <TYPE>.Trigger is False,
      writes Status STARTED / PROCESSING / DONE_SUCCESS|DONE_ERROR, moves it to ArchivePath, stores the sample
      (sgrp_inf, sgrp_tst, sgrp_dsc + desc_dat, part_lot; part_dat / prcs_dat / test_dat / job_dat when new) and
      sets Trigger True (CHMI clears it - this test clears it; user 2026-10-15).
    Steps: 1. save the four tags of CNC<n>, set them to the file's values, clear Trigger  2. drop the CSV with
    the asset line = CNC<n>'s asset and a unique lot APCTEST<time> (in the instrument's own format) into its Path  3. follow it
    4. restore tags, clear Trigger, remove the files, delete the test lot's rows (not with -KeepData).
    VM 2026-10-15: picked up after 65 s, DONE_SUCCESS, 1 sample / 187 values, all cleaned up.
    Needs DeviceWise.ps1 (OPC UA) and 02-TimescaleDB.ps1 (Invoke-PgSql) dot-sourced; pgpass from Step 2.
    Returns @{ Routing; Detection; Archiving = @{ Ok; Detail }; Error; Db; Lines }.
#>

function Invoke-FileFlowTest {
    param([Parameter(Mandatory)] [object]$Manifest, [Parameter(Mandatory)] [string]$CsvPath, [int]$Cnc = 1,
          [int]$TimeoutSeconds = 180, [switch]$KeepData, [scriptblock]$Log)
    $m = $Manifest
    $lines = [System.Collections.Generic.List[string]]::new()
    $res = @{ Routing = @{ Ok = $false; Detail = 'not run' }; Detection = @{ Ok = $false; Detail = 'not run' }; Archiving = @{ Ok = $false; Detail = 'not run' }; Error = ''; Db = ''; Lines = $lines }
    function W([string]$Text = '') { $lines.Add("$(Get-Date -Format 'HH:mm:ss') $Text"); if ($Log) { & $Log $Text } }
    if (-not (Test-Path -LiteralPath $CsvPath)) { $res.Error = "test file not found: $CsvPath"; W "FAIL: $($res.Error)"; return $res }

    $inst = Find-MedtronicInstall -Manifest $m
    if (-not $inst.Error) { $m = Set-ManifestMedtronicDrive -Manifest $m -Drive $inst.Drive }
    $ns = $m.DeviceWise.OpcUaClient.Namespace
    W "File flow test  $(Get-Date -Format s)  on $env:COMPUTERNAME as $env:USERDOMAIN\$env:USERNAME  CNC$Cnc  file $CsvPath"

    # -- the CSV and the File Manager instrument it belongs to ------------------------------------------------
    # Each instrument (File Manager <Paths>) has its own line format: <X>Keyword marks the line, <X>Prefix and
    # <X>Postfix are removed with a plain replace (no trim) - CTSCAN 'Lot Number ,Test1', CMM '"Desc,Lot Number: Test1",,,,'.
    # The data type is the DataTypePos-th part of the process name (1ST_CTSCAN1_MPR -> CTSCAN1).
    # Latin-1 in and out: every byte stays as it was (the CMM file has 'TEMP deg C' in Windows-1252; UTF-8 would change it)
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    $src = [System.IO.File]::ReadAllLines((Resolve-Path $CsvPath), $latin1)
    function Child($n, [string]$c) { $x = $n.SelectSingleNode($c); if ($x) { $x.InnerText } else { '' } }   # (.Name on an XmlElement is its tag name)
    function Get-Value($node, [string]$What) {
        $kw = Child $node "${What}Keyword"
        if (-not $kw) { return '' }
        foreach ($l in $src) {
            if ($l.Contains($kw)) {
                $v = $l
                $pre = Child $node "${What}Prefix";  if ($pre)  { $v = $v.Replace($pre, '') }
                $post = Child $node "${What}Postfix"; if ($post) { $v = $v.Replace($post, '') }
                return $v
            }
        }
        ''
    }
    $fm = [xml][System.IO.File]::ReadAllText($m.DataApps.FileManagerConfig)
    $dc = [xml][System.IO.File]::ReadAllText($m.DataApps.DataCollectorConfig)
    $fmPath = $null; $process = ''; $dataType = ''
    foreach ($node in $fm.SelectNodes('//Paths/*')) {
        $pv = Get-Value $node 'DataType'
        $split = Child $node 'DataTypeSplit'; $pos = [int](Child $node 'DataTypePos')
        $parts = if ($split) { $pv -split [regex]::Escape($split) } else { @($pv) }
        if ($parts.Count -gt $pos -and $parts[$pos] -eq (Child $node 'Name')) { $fmPath = $node; $process = $pv; $dataType = $parts[$pos]; break }
    }
    if (-not $fmPath) { $res.Error = "the file matches no File Manager instrument (process name line not found or its type is not a configured <Name>)"; W "FAIL: $($res.Error)"; return $res }
    $dcBlock = $dc.SelectNodes('//DataTypeSettings/*') | Where-Object { (Child $_ 'Asset') -eq "CNC$Cnc" -and (Child $_ 'Name') -eq $dataType } | Select-Object -First 1
    if (-not $dcBlock) { $res.Error = "no Data Collector block for CNC$Cnc / $dataType"; W "FAIL: $($res.Error)"; return $res }
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
    if (-not $asset) { $res.Error = "CNC$Cnc.CNCAsset is empty - File Manager would not know this CNC (run Step 8)"; W "FAIL: $($res.Error)"; [void]$session.Close(); return $res }
    $lot = "APCTEST$((Get-Date).ToString('MMddHHmmss'))"
    $part = Get-Value $fmPath 'PartNumber'; $sample = Get-Value $fmPath 'SampleNumber'
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
    # Data Collector's result tags as they were: the CHMI (800xA Corrections 'DC <TYPE> Calculation') answers the
    # raised Trigger by comparing the result with its own order (Order0 Batch/Part, Sample GP) and writes
    # ErrorCode -1 / 'Data Mistmatch' when they differ - always for a test lot - so they are put back afterwards
    $dcSaved = [ordered]@{}
    foreach ($t in 'ErrorCode', 'Message') { $dcSaved["$($tagBase)$t"] = Read-Tag "$($tagBase)$t" }
    $trig = Read-Tag "$($tagBase)Trigger"
    if ($trig -eq $true) { W "  $($tagBase)Trigger was True (unconsumed result) -> False : $(Write-Tag "$($tagBase)Trigger" $false)" }

    # -- 2. the file ------------------------------------------------------------------------------------------
    # File Manager reads a line as part, else lot, else sample, else asset (first keyword that matches)
    $kwPart = Child $fmPath 'PartNumberKeyword'; $kwLot = Child $fmPath 'BatchNumberKeyword'
    $kwSample = Child $fmPath 'SampleNumberKeyword'; $kwAsset = Child $fmPath 'AssetKeyword'
    $name = "$asset`_$lot.csv"
    $fileLines = foreach ($l in $src) {
        if ($kwPart -and $l.Contains($kwPart)) { $l }
        elseif ($kwLot -and $l.Contains($kwLot)) { (Child $fmPath 'BatchNumberPrefix') + $lot + (Child $fmPath 'BatchNumberPostfix') }
        elseif ($kwSample -and $l.Contains($kwSample)) { $l }
        elseif ($kwAsset -and $l.Contains($kwAsset)) { (Child $fmPath 'AssetPrefix') + $asset + (Child $fmPath 'AssetPostfix') }
        else { $l }
    }
    $srcFile = Join-Path (Child $fmPath 'Path') $name
    $tmp = Join-Path $env:TEMP $name
    [System.IO.File]::WriteAllLines($tmp, [string[]]$fileLines, $latin1)
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
    if ([string](Read-Tag "$($tagBase)Message") -eq 'Data Mistmatch') {
        W "  (ErrorCode -1 / 'Data Mistmatch' is the CHMI's own order check of the result - expected for a test lot that is no 800xA order; put back below)"
    }

    # -- DB rows of the test lot --------------------------------------------------------------------------------
    $pg = $m.PostgreSQL
    $conn = @{ Exe = (Join-Path $pg.BinDir 'psql.exe'); Port = $pg.DefaultPort; User = $pg.LocalUser; Database = $pg.LocalDB; PassFile = (Join-Path $env:APPDATA 'postgresql\pgpass.conf') }
    $lotSql = $lot.Replace("'", "''")
    $q = Invoke-PgSql -Conn $conn -Sql @"
    SELECT (SELECT count(*) FROM sgrp_inf i JOIN part_lot l ON l.f_lot = i.f_lot WHERE l.f_name = '$lotSql'),
           (SELECT count(*) FROM sgrp_tst t JOIN sgrp_inf i ON i.f_sgrp = t.f_sgrp JOIN part_lot l ON l.f_lot = i.f_lot WHERE l.f_name = '$lotSql');
"@
    W "  DB: $(if ($q.Ok) { $p = $q.Output -split '\|'; "$($p[0]) sample(s), $($p[1]) measurement value(s) for lot $lot" } else { "query failed: $($q.Output)" })"

    $res.Routing   = @{ Ok = [bool]($stage.Routed -or ($stage.Archived -and -not $stage.Error)); Detail = $(if ($stage.Error) { "mismatch: File Manager moved it to $errDir" } elseif ($stage.PickedUp) { "picked up after $($stage.PickedUp) s from $(Child $fmPath 'Path'), routed to $routeDir" } else { "not picked up from $(Child $fmPath 'Path') within $TimeoutSeconds s" }) }
    $res.Detection = @{ Ok = [bool](($stage.Started -or $stage.Archived) -and $status -ne 'DONE_ERROR'); Detail = "Data Collector status $(if ($status) { $status } else { '(none)' }) on $($tagBase)Status" }
    $res.Archiving = @{ Ok = [bool]$stage.Archived; Detail = $(if ($archivedFile) { "archived to $archive" } else { "not in $archive" }) }
    $res.Db = $(if ($q.Ok) { $q.Output } else { '' })
    W ''; W '== Result =='
    W "  7.7  file routing (File Manager)   : $(if ($stage.Routed -or ($stage.Archived -and -not $stage.Error)) { 'PASS' } elseif ($stage.Error) { 'FAIL (mismatch -> error folder)' } else { 'FAIL' })"
    W "  8.9  file detection in CheckPath   : $(if ($stage.Started -or $stage.Archived) { 'PASS' } else { 'FAIL' })"
    W "  8.10 file archiving to ArchivePath : $(if ($stage.Archived) { 'PASS' } else { 'FAIL' })   Data Collector: $status"

    # -- 4. clean up -------------------------------------------------------------------------------------------
    W ''; W '== 4. Clean up =='
    foreach ($k in $saved.Keys) { W "  $k back to '$($saved[$k])' : $(Write-Tag $k $(if ($null -eq $saved[$k]) { '' } else { $saved[$k] }))" }
    if ((Read-Tag "$($tagBase)Trigger") -eq $true) { W "  $($tagBase)Trigger -> False : $(Write-Tag "$($tagBase)Trigger" $false)" }
    foreach ($k in $dcSaved.Keys) { if ($null -ne $dcSaved[$k]) { W "  $k back to '$($dcSaved[$k])' : $(Write-Tag $k $dcSaved[$k])" } }
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
    return $res
}
