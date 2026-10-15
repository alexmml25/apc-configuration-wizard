#Requires -Version 5.1
<#
.SYNOPSIS
    Step 10 - Configure File Manager, Data Collector, and Data Analyzer config files.
.DESCRIPTION
    Rebuilds the per-CNC and per-instrument sections of each config from the
    instrument selection made in the wizard (State['DataAppsInstruments']), falling
    back to Manifest.DataApps.SiteDefaults for the site when no selection is present.

    CNC numbering follows DOC instances: CNC{n} = DOC instance n (1..DOCCount).

    DataCollector_FileManager.exe.config:
    - <CNCSettings>: one CNC{n}.Asset block per CNC, CheckMismatchData = true
    - <Paths>: one Path{k} block per instrument instance (e.g. CONTRACER1..3)
      Path = instrument share, NewPath = <LocalDataRoot>\<TYPE>, ErrorPath, EndFileString = NA

    DataCollector.exe.config:
    - <CNCSettings>: one CNC{n}.Asset block per CNC
    - <DataTypeSettings>: one CNC{n}.<TYPE> block per CNC per selected instrument instance
      CheckPath = File Manager NewPath, ArchivePath = CheckPath\Backup,
      BroadcastFilePaths/Path1 = broadcast path or NA (BroadcastFile true/false to match),
      EndFileString = NA

    DataAnalyzer.exe.config:
    - Site code in Opc_FirstRunProcess / Opc_VerificationProcess / Opc_ProductionProcess
    - Opc_CNCAssets / Opc_DOCCHMIs / Opc_DataAnalyzers sized to the CNC count
    - Verify Db_ConnectionString points at local TimescaleDB as apcuser

    Blocks are cloned from the installed config (the application installer provides one
    block per instrument type); a type with no block there is reported as FAIL.

    deviceWise OPC UA trust (SOP 2.1.2.5, External Client Enablement): the three apps are OPC UA clients of
    the deviceWise server (opc.tcp://localhost:48020). Each keeps its certificates in <app folder>\CertificateStores
    (App = its own, Trusted = servers it trusts); deviceWise keeps them in staging\uaserver\pkiserver (own,
    trusted, rejected). Step 10 puts each app's certificate in deviceWise's trusted folder (and out of rejected)
    and deviceWise's certificate in the app's Trusted folder - no dwcore restart needed (VM test 2026-10-15).
    Then the apps are restarted (or started) so they load the new config (Manifest.DataApps.RestartApps).
    An app makes its certificate on its first connection: Step 10 starts it, waits for the certificate and
    trusts it. Data Analyzer only connects after a login + Start Monitoring, so when it has no certificate yet
    Step 10 makes it the way Data Analyzer would (tools\Test-DataAnalyzerCert.ps1 -StoreDir: same Traeger
    library, licence and application name, no window; proven identical on SJUM7AAPPS0048 2026-10-15).
    Logging in and Start Monitoring stay with the operator (Data Analyzer has no auto-start).
#>

. (Join-Path $PSScriptRoot 'Common.ps1')

function Invoke-DataApps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [switch]$NonInteractive
    )

    Write-Log STEP "Data Applications Configuration"

    $siteCode  = $State['SiteCode']
    $cncCount  = [int]$State['DOCCount']
    if ($cncCount -lt 1) { $cncCount = 1 }
    $da        = $Manifest.DataApps
    $localRoot = if ($State['DataAppsLocalRoot']) { $State['DataAppsLocalRoot'] } else { $da.LocalDataRoot }
    $plan      = Get-DataAppsInstrumentPlan -Manifest $Manifest -State $State
    $ts        = Get-Date -Format 'yyyyMMdd-HHmmss'

    # Drop CNC assignments beyond the configured CNC count
    foreach ($ins in $plan) { $ins.CNCs = @($ins.CNCs | Where-Object { $_ -ge 1 -and $_ -le $cncCount }) }
    $plan = @($plan | Where-Object { $_.CNCs.Count -gt 0 })

    Write-Log INFO "CNC count: $cncCount  |  Local data root: $localRoot"
    foreach ($ins in $plan) {
        Write-Log INFO ("  {0,-10} x{1}  CNC {2}  source: {3}" -f $ins.Type, $ins.Count, ($ins.CNCs -join ','), $ins.SourcePath)
    }
    if ($plan.Count -eq 0) {
        Add-Result -Phase DataApps -Check "Instrument selection" -Status FAIL -Detail "No instruments selected for any CNC"
        return
    }

    #region -- Helpers --------------------------------------------------------

    function Backup-AndLoad {
        param([string]$Path)
        if (-not (Test-Path $Path)) { return $null }
        Copy-Item $Path "$Path.$ts.bak" -Force
        $xml = New-Object System.Xml.XmlDocument
        $xml.PreserveWhitespace = $false
        $xml.LoadXml([System.IO.File]::ReadAllText($Path))
        return $xml
    }

    function Save-Xml {
        param([System.Xml.XmlDocument]$Xml, [string]$Path)
        $s = [System.Xml.XmlWriterSettings]::new()
        $s.Indent      = $true
        $s.IndentChars = "`t"
        $s.Encoding    = [System.Text.UTF8Encoding]::new($true)
        $w = [System.Xml.XmlWriter]::Create($Path, $s)
        try { $Xml.Save($w) } finally { $w.Close() }
    }

    function Ensure-Dir {
        param([string]$Path, [string]$Label)
        if (-not $Path -or $Path -eq 'NA') { return }
        if ($Path -match '^[\\/]{2}') {
            # network share: never created; checked as far as an administrator session can
            $st = Get-NetworkPathStatus $Path
            if ($st.Status -eq 'Unverified') { Write-Log INFO "$Label - $($st.Detail)" }
            elseif ($st.Status -ne 'OK') { Add-Result -Phase DataApps -Check "Directory: $Label" -Status WARN -Detail $st.Detail }
            return
        }
        if (Test-Path $Path) { if (Test-LocalFixedPath $Path) { $localDirs.Add($Path) }; return }
        # only folders on this VM's local disks are created; shares and mapped drives are only checked
        if (-not (Test-LocalFixedPath $Path)) {
            $qualifier = if ($Path -match '^([A-Za-z]:)') { $Matches[1] } else { '' }
            $detail = if ($qualifier -and -not (Test-Path "$qualifier\")) { "Drive $qualifier not available - create $Path manually" }
                      else { "$Path is on a network share and was not found - create it on the share or check access" }
            Add-Result -Phase DataApps -Check "Directory: $Label" -Status WARN -Detail $detail
            return
        }
        if (-not (Test-SandboxPath $State $Path)) {
            Write-Log INFO "Test mode: not creating $Path (outside sandbox)"
            return
        }
        try {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            $localDirs.Add($Path)
            Write-Log INFO "Created directory $Path"
        } catch {
            Add-Result -Phase DataApps -Check "Directory: $Label" -Status WARN -Detail "Could not create ${Path}: $($_.Exception.Message)"
        }
    }

    $localDirs = [System.Collections.Generic.List[string]]::new()   # local folders created or configured (for the app account grant)

    function Set-ChildText {
        param([System.Xml.XmlElement]$Parent, [string]$Name, [string]$Value)
        $node = $Parent.SelectSingleNode($Name)
        if (-not $node) {
            $node = $Parent.OwnerDocument.CreateElement($Name)
            $Parent.AppendChild($node) | Out-Null
        }
        $node.InnerText = $Value
    }

    # Clone $Template into $Doc under a new element name, rewriting CNC{x} references to CNC{n}
    function Copy-Block {
        param([System.Xml.XmlDocument]$Doc, [System.Xml.XmlElement]$Template, [string]$NewName, [int]$Cnc = 0)
        $src = $Template.CloneNode($true)
        $el  = $Doc.CreateElement($NewName)
        foreach ($child in @($src.ChildNodes)) { $el.AppendChild($child) | Out-Null }
        if ($Cnc -gt 0) {
            foreach ($t in @($el.SelectNodes('.//text()'))) {
                $t.Value = [regex]::Replace($t.Value, '\bCNC\d+\b', "CNC$Cnc")
            }
        }
        return $el
    }

    # First child element of $Section in the installed config that satisfies $Match
    function Find-Template {
        param([System.Xml.XmlDocument]$Doc, [string]$Section, [scriptblock]$Match)
        $sec = $Doc.SelectSingleNode("/configuration/$Section")
        if (-not $sec) { return $null }
        @($sec.ChildNodes) | Where-Object { $_.NodeType -eq 'Element' -and (& $Match $_) } | Select-Object -First 1
    }

    function Clear-Section {
        param([System.Xml.XmlDocument]$Doc, [string]$Section)
        $sec = $Doc.SelectSingleNode("/configuration/$Section")
        if (-not $sec) {
            $sec = $Doc.CreateElement($Section)
            $Doc.DocumentElement.AppendChild($sec) | Out-Null
        }
        foreach ($c in @($sec.ChildNodes)) { $sec.RemoveChild($c) | Out-Null }
        return $sec
    }

    function Rebuild-CNCSettings {
        param([System.Xml.XmlDocument]$Doc, [switch]$CheckMismatch)
        $tpl = Find-Template $Doc 'CNCSettings' { param($e) $e.LocalName -match '^CNC\d+\.Asset$' }
        if (-not $tpl) { throw "No CNC{n}.Asset template found in CNCSettings" }
        $sec = Clear-Section $Doc 'CNCSettings'
        for ($n = 1; $n -le $cncCount; $n++) {
            $blk = Copy-Block $Doc $tpl "CNC$n.Asset" $n
            if ($CheckMismatch) { Set-ChildText $blk 'CheckMismatchData' 'true' }
            $sec.AppendChild($blk) | Out-Null
        }
    }

    function Get-NewPath { param([string]$Type) [System.IO.Path]::Combine($localRoot, $Type) }

    #endregion

    $fmFailed = $false; $dcFailed = $false

    #region -- File Manager ---------------------------------------------------

    $fmPath = $da.FileManagerConfig
    $fmXml  = Backup-AndLoad $fmPath
    if (-not $fmXml) {
        Add-Result -Phase DataApps -Check "File Manager config" -Status FAIL -Detail "Not found: $fmPath"
        $fmFailed = $true
    } else {
        try {
            Rebuild-CNCSettings -Doc $fmXml -CheckMismatch
            Add-Result -Phase DataApps -Check "File Manager: CNCSettings" -Status PASS -Detail "CNC1..CNC$cncCount, CheckMismatchData=true"

            # Collect templates before clearing <Paths>
            $pathTemplates = @{}
            foreach ($ins in $plan) {
                $type = $ins.Type
                $pathTemplates[$type] = Find-Template $fmXml 'Paths' {
                    param($e) $n = $e.SelectSingleNode('Name'); $n -and $n.InnerText -match "^$type\d*$"
                }
            }
            $paths = Clear-Section $fmXml 'Paths'
            $k = 0
            foreach ($ins in $plan) {
                $tpl = $pathTemplates[$ins.Type]
                if (-not $tpl) {
                    Add-Result -Phase DataApps -Check "File Manager: $($ins.Type)" -Status FAIL -Detail "No <Paths> entry for $($ins.Type) in installed config to copy from"
                    $fmFailed = $true; continue
                }
                $newPath = Get-NewPath $ins.Type
                $errPath = if ($ins.ErrorPath) { $ins.ErrorPath } else { [System.IO.Path]::Combine($newPath, 'DoneError') }
                foreach ($name in $ins.Names) {
                    $k++
                    $blk = Copy-Block $fmXml $tpl "Path$k"
                    Set-ChildText $blk 'Name' $name
                    if ($ins.SourcePath) { Set-ChildText $blk 'Path' $ins.SourcePath }
                    Set-ChildText $blk 'NewPath'       $newPath
                    Set-ChildText $blk 'ErrorPath'     $errPath
                    Set-ChildText $blk 'EndFileString' 'NA'
                    $paths.AppendChild($blk) | Out-Null
                }

                # create local folders first, including a source on this VM's own disks (e.g. D:\..._Measurement_Reports)
                Ensure-Dir $newPath "$($ins.Type) NewPath"
                Ensure-Dir $errPath "$($ins.Type) ErrorPath"
                if ($ins.SourcePath -and (Test-LocalFixedPath $ins.SourcePath)) { Ensure-Dir $ins.SourcePath "$($ins.Type) source" }
                if (-not $ins.SourcePath) {
                    Add-Result -Phase DataApps -Check "File Manager: $($ins.Type) source" -Status WARN -Detail "No source share entered - template path kept, update <Path> manually"
                } elseif ($ins.SourcePath -match '^[\\/]{2}') {
                    $st = Get-NetworkPathStatus $ins.SourcePath
                    if ($st.Status -eq 'Unverified') { Add-Result -Phase DataApps -Check "File Manager: $($ins.Type) source" -Status PASS -Detail $st.Detail }
                    elseif ($st.Status -ne 'OK') { Add-Result -Phase DataApps -Check "File Manager: $($ins.Type) source" -Status WARN -Detail $st.Detail }
                } elseif (-not (Test-Path $ins.SourcePath)) {
                    Add-Result -Phase DataApps -Check "File Manager: $($ins.Type) source" -Status WARN -Detail "Source not found: $($ins.SourcePath)"
                }
                Add-Result -Phase DataApps -Check "File Manager: $($ins.Type)" -Status PASS -Detail "$($ins.Names -join ', ') -> $newPath"
            }

            Save-Xml -Xml $fmXml -Path $fmPath
            Write-Log INFO "File Manager config saved ($k Path entries)"
        } catch {
            Add-Result -Phase DataApps -Check "File Manager config" -Status FAIL -Detail $_.Exception.Message
            $fmFailed = $true
        }
    }

    #endregion

    #region -- Data Collector -------------------------------------------------

    $dcPath = $da.DataCollectorConfig
    $dcXml  = Backup-AndLoad $dcPath
    if (-not $dcXml) {
        Add-Result -Phase DataApps -Check "Data Collector config" -Status FAIL -Detail "Not found: $dcPath"
        $dcFailed = $true
    } else {
        try {
            $con = $dcXml.SelectSingleNode('/configuration/AppSettingsSection/ConString')
            if ($con -and $con.InnerText -match 'Database=TimescaleDB' -and $con.InnerText -match 'User Id=apcuser' -and $con.InnerText -match 'Server=localhost') {
                Add-Result -Phase DataApps -Check "Data Collector: DB connection" -Status PASS
            } else {
                Add-Result -Phase DataApps -Check "Data Collector: DB connection" -Status WARN -Detail "ConString does not point at localhost/TimescaleDB as apcuser - confirm with APC Team"
            }

            Rebuild-CNCSettings -Doc $dcXml
            Add-Result -Phase DataApps -Check "Data Collector: CNCSettings" -Status PASS -Detail "CNC1..CNC$cncCount"

            $dtTemplates = @{}
            foreach ($ins in $plan) {
                $type = $ins.Type
                $dtTemplates[$type] = Find-Template $dcXml 'DataTypeSettings' {
                    param($e) $e.LocalName -match "^CNC\d+\.$type\d*$"
                }
            }
            $dts = Clear-Section $dcXml 'DataTypeSettings'
            $blocks = 0
            for ($n = 1; $n -le $cncCount; $n++) {
                foreach ($ins in $plan) {
                    if ($n -notin $ins.CNCs) { continue }
                    $tpl = $dtTemplates[$ins.Type]
                    if (-not $tpl) { continue }
                    $checkPath   = Get-NewPath $ins.Type
                    $archivePath = [System.IO.Path]::Combine($checkPath, 'Backup')
                    $broadcast   = if ($ins.BroadcastPath) { $ins.BroadcastPath } else { 'NA' }
                    for ($i = 0; $i -lt $ins.Names.Count; $i++) {
                        $blk = Copy-Block $dcXml $tpl "CNC$n.$($ins.Suffixes[$i])" $n
                        Set-ChildText $blk 'Name'        $ins.Names[$i]
                        Set-ChildText $blk 'Asset'       "CNC$n"
                        Set-ChildText $blk 'CheckPath'   $checkPath
                        Set-ChildText $blk 'ArchivePath' $archivePath
                        $bfp = $blk.SelectSingleNode('BroadcastFilePaths')
                        if (-not $bfp) { $bfp = $dcXml.CreateElement('BroadcastFilePaths'); $blk.AppendChild($bfp) | Out-Null }
                        foreach ($c in @($bfp.ChildNodes)) { $bfp.RemoveChild($c) | Out-Null }
                        Set-ChildText $bfp 'Path1' $broadcast
                        Set-ChildText $blk 'BroadcastFile' $(if ($broadcast -ne 'NA') { 'true' } else { 'false' })
                        Set-ChildText $blk 'EndFileString' 'NA'
                        $dts.AppendChild($blk) | Out-Null
                        $blocks++
                    }
                }
            }
            foreach ($ins in $plan) {
                if (-not $dtTemplates[$ins.Type]) {
                    Add-Result -Phase DataApps -Check "Data Collector: $($ins.Type)" -Status FAIL -Detail "No DataTypeSettings block for $($ins.Type) in installed config to copy from"
                    $dcFailed = $true; continue
                }
                $checkPath = Get-NewPath $ins.Type
                Ensure-Dir $checkPath                         "$($ins.Type) CheckPath"
                Ensure-Dir ([System.IO.Path]::Combine($checkPath, 'Backup'))    "$($ins.Type) ArchivePath"
                if ($ins.BroadcastPath) { Ensure-Dir $ins.BroadcastPath "$($ins.Type) BroadcastFilePath" }
                Add-Result -Phase DataApps -Check "Data Collector: $($ins.Type)" -Status PASS `
                    -Detail "CNC $($ins.CNCs -join ',') x$($ins.Count), broadcast: $(if ($ins.BroadcastPath) { $ins.BroadcastPath } else { 'NA' })"
            }

            Save-Xml -Xml $dcXml -Path $dcPath
            Write-Log INFO "Data Collector config saved ($blocks DataTypeSettings blocks)"
        } catch {
            Add-Result -Phase DataApps -Check "Data Collector config" -Status FAIL -Detail $_.Exception.Message
            $dcFailed = $true
        }
    }

    #endregion

    #region -- Data Analyzer --------------------------------------------------

    $daPath = $da.DataAnalyzerConfig
    $daXml  = Backup-AndLoad $daPath
    if (-not $daXml) {
        Add-Result -Phase DataApps -Check "Data Analyzer config" -Status FAIL -Detail "Not found: $daPath"
    } else {
        $siteAlt = ($Manifest.Sites | ForEach-Object { [regex]::Escape($_) }) -join '|'

        # Site code in OPC process name patterns, e.g. ^SPC_(.*)_MPR$
        foreach ($key in @('Opc_FirstRunProcess', 'Opc_VerificationProcess', 'Opc_ProductionProcess')) {
            $node = $daXml.SelectSingleNode("//appSettings/add[@key='$key']")
            if (-not $node -and $key -eq 'Opc_FirstRunProcess') {
                $node = $daXml.SelectSingleNode("//appSettings/add[@key='Opc_FirstRunProces']")
            }
            if (-not $node) {
                Add-Result -Phase DataApps -Check "Data Analyzer: $key" -Status WARN -Detail "Key not found - set site code manually"
                continue
            }
            $cur    = $node.GetAttribute('value')
            $newVal = [regex]::Replace($cur, "_(?:$siteAlt)(?=\`$?$)", "_$siteCode")
            if ($newVal -notmatch "_$siteCode\`$?$") {
                Add-Result -Phase DataApps -Check "Data Analyzer: $key" -Status WARN -Detail "Unexpected value '$cur' - set site code manually"
                continue
            }
            $node.SetAttribute('value', $newVal)
            Add-Result -Phase DataApps -Check "Data Analyzer: $key" -Status PASS -Detail $newVal
        }

        # Per-CNC OPC lists (pipe-separated, one entry per CNC)
        $cncList = @(1..$cncCount | ForEach-Object { "CNC$_" }) -join '|'
        foreach ($key in @('Opc_CNCAssets', 'Opc_DOCCHMIs', 'Opc_DataAnalyzers')) {
            $node = $daXml.SelectSingleNode("//appSettings/add[@key='$key']")
            if (-not $node) {
                Add-Result -Phase DataApps -Check "Data Analyzer: $key" -Status WARN -Detail "Key not found"
                continue
            }
            $newVal = if ($key -eq 'Opc_CNCAssets') { $cncList } else {
                $first = ($node.GetAttribute('value') -split '\|')[0]
                @(1..$cncCount | ForEach-Object { $first }) -join '|'
            }
            $node.SetAttribute('value', $newVal)
            Add-Result -Phase DataApps -Check "Data Analyzer: $key" -Status PASS -Detail $newVal
        }

        # DB connection (verify only)
        $conn = $daXml.SelectSingleNode("//appSettings/add[@key='Db_ConnectionString']")
        $connVal = if ($conn) { $conn.GetAttribute('value') } else { '' }
        if ($connVal -match 'Server=localhost' -and $connVal -match 'Database=TimescaleDB' -and $connVal -match 'User Id=apcuser') {
            Add-Result -Phase DataApps -Check "Data Analyzer: DB connection" -Status PASS
        } else {
            Add-Result -Phase DataApps -Check "Data Analyzer: DB connection" -Status WARN -Detail "Db_ConnectionString does not point at localhost/TimescaleDB as apcuser - confirm with APC Team"
        }

        Save-Xml -Xml $daXml -Path $daPath
        Write-Log INFO "Data Analyzer config saved"
    }

    #endregion

    #region -- App account access ---------------------------------------------

    # The applications run as the site service account (e.g. ENT\SVC-APC-MPR); it needs Modify on the local folders
    $account = Get-AppAccount -Manifest $Manifest -State $State
    if ($State['SandboxRoot']) {
        Write-Log INFO "Test mode: folder permissions not changed"
    } elseif ($account) {
        foreach ($dir in (Get-TopFolders $localDirs)) {
            $g = Grant-AppAccountModify -Path $dir -Account $account
            Add-Result -Phase DataApps -Check "Access: $dir" -Status $(if ($g.Ok) { 'PASS' } else { 'WARN' }) -Detail $g.Detail
        }
    }

    #endregion

    #region -- deviceWise OPC UA trust and app restart ---------------------------

    if ($State['SandboxRoot']) {
        Write-Log INFO "Test mode: deviceWise certificates and the applications are left alone"
    } else {
        $apps = @(
            @{ Name = 'File Manager';   Config = $da.FileManagerConfig;   Login = $false }
            @{ Name = 'Data Collector'; Config = $da.DataCollectorConfig; Login = $false }
            @{ Name = 'Data Analyzer';  Config = $da.DataAnalyzerConfig;  Login = $true }
        )
        $pki     = ([string]$Manifest.DeviceWise.GatewayInstallDir).TrimEnd('\') + '\staging\uaserver\pkiserver'
        $restart = -not ($da.PSObject.Properties['RestartApps'] -and $da.RestartApps -eq $false)
        foreach ($app in $apps) {
            $dir = Split-Path ([string]$app.Config) -Parent
            $exe = ([string]$app.Config) -replace '\.config$', ''
            if (-not (Test-Path -LiteralPath $exe)) {
                Add-Result -Phase DataApps -Check "$($app.Name): deviceWise OPC UA trust" -Status WARN -Detail "Not installed: $exe"
                continue
            }
            if ($restart) {
                $r = Restart-DataApp -Exe $exe
                Add-Result -Phase DataApps -Check "$($app.Name): restarted" -Status $(if ($r.Ok) { 'PASS' } else { 'WARN' }) -Detail $r.Detail
            }
            if ($app.Login -and -not (Get-ChildItem -LiteralPath (Join-Path $dir 'CertificateStores\App\certs') -Filter '*.der' -ErrorAction SilentlyContinue)) {
                $mk = New-DataAnalyzerCertificate -DaDir $dir
                Add-Result -Phase DataApps -Check "$($app.Name): application certificate" -Status $(if ($mk.Ok) { 'PASS' } else { 'WARN' }) -Detail $mk.Detail
            }
            # The app makes its certificate on its first connection attempt; give a just-started app time for it
            $t = Set-DataAppDeviceWiseTrust -AppDir $dir -PkiServer $pki -WaitSeconds $(if ($restart -and -not $app.Login) { 30 } else { 0 })
            if ($t.Status -eq 'NoCertificate') {
                $how = if ($app.Login) { 'log in to Data Analyzer and press Start Monitoring once, then re-run Step 10' } else { "open $($app.Name) once, then re-run Step 10" }   # only when making it failed
                Add-Result -Phase DataApps -Check "$($app.Name): deviceWise OPC UA trust" -Status MANUAL -Detail "No application certificate yet ($dir\CertificateStores\App\certs): $how"
            } else {
                Add-Result -Phase DataApps -Check "$($app.Name): deviceWise OPC UA trust" -Status $(if ($t.Ok) { 'PASS' } else { 'FAIL' }) -Detail $t.Detail
            }
        }
    }

    #endregion

    if ($fmFailed -or $dcFailed) {
        Write-Log WARN "Data applications configuration finished with errors - review results above."
    } else {
        Write-Log PASS "Data applications configuration complete."
    }
    Write-Log INFO "Backup files (.$ts.bak) created alongside each modified config. Review and delete after validation."
    if ($State['SandboxRoot']) { Write-Log INFO "Restart File Manager, Data Collector and Data Analyzer to load the new configuration." }
}

function Set-DataAppDeviceWiseTrust {
    <#
        Two-way OPC UA trust between one data app and the deviceWise server (file stores, no restart needed):
          app  <AppDir>\CertificateStores\App\certs\*.der  -> <PkiServer>\trusted\certs  (and out of <PkiServer>\rejected)
          deviceWise <PkiServer>\own\certs\*.der        -> <AppDir>\CertificateStores\Trusted\certs
        Waits up to WaitSeconds for the app certificate (an app makes it on its first connection).
        Returns @{ Ok; Status = Done | NoCertificate | Failed; Detail }.
    #>
    param([string]$AppDir, [string]$PkiServer, [int]$WaitSeconds = 0)
    $X509   = 'System.Security.Cryptography.X509Certificates.X509Certificate2'
    $appOwn = Join-Path $AppDir 'CertificateStores\App\certs'
    $appTr  = Join-Path $AppDir 'CertificateStores\Trusted\certs'
    $dwOwn  = Join-Path $PkiServer 'own\certs'
    $dwTr   = Join-Path $PkiServer 'trusted\certs'
    $dwRej  = Join-Path $PkiServer 'rejected'
    $load   = { param($f) try { New-Object $X509 $f.FullName } catch { $null } }

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        $mine = @(Get-ChildItem -LiteralPath $appOwn -Filter '*.der' -File -ErrorAction SilentlyContinue)
        if ($mine) { break }
        if ((Get-Date) -lt $deadline) { Start-Sleep -Seconds 3 }
    } while ((Get-Date) -lt $deadline)
    if (-not $mine) { return @{ Ok = $false; Status = 'NoCertificate'; Detail = '' } }
    $server = @(Get-ChildItem -LiteralPath $dwOwn -Filter '*.der' -File -ErrorAction SilentlyContinue)
    if (-not $server) { return @{ Ok = $false; Status = 'Failed'; Detail = "deviceWise OPC UA server certificate not found in $dwOwn" } }

    try {
        $notes = @()
        New-Item -ItemType Directory -Path $dwTr, $appTr -Force | Out-Null
        $trustedThumbs = @(Get-ChildItem -LiteralPath $dwTr -File -ErrorAction SilentlyContinue | ForEach-Object { (& $load $_).Thumbprint })
        foreach ($f in $mine) {
            $c = & $load $f
            if (-not $c) { continue }
            if ($c.Thumbprint -notin $trustedThumbs) {
                Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dwTr $f.Name) -Force
                $notes += "$($c.GetNameInfo('SimpleName', $false)) trusted by deviceWise"
            } else { $notes += "$($c.GetNameInfo('SimpleName', $false)) already trusted by deviceWise" }
            # the same certificate waiting in rejected would keep Step 13's client-certificate check failing
            Get-ChildItem -LiteralPath $dwRej -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { (& $load $_).Thumbprint -eq $c.Thumbprint } | Remove-Item -Force -ErrorAction SilentlyContinue
        }
        $appThumbs = @(Get-ChildItem -LiteralPath $appTr -File -ErrorAction SilentlyContinue | ForEach-Object { (& $load $_).Thumbprint })
        foreach ($f in $server) {
            $c = & $load $f
            if ($c -and $c.Thumbprint -notin $appThumbs) {
                Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $appTr $f.Name) -Force
                $notes += 'deviceWise server certificate trusted by the app'
            } elseif ($c) { $notes += 'deviceWise server certificate already trusted' }
        }
        return @{ Ok = $true; Status = 'Done'; Detail = $notes -join '; ' }
    } catch {
        return @{ Ok = $false; Status = 'Failed'; Detail = "$_" }
    }
}

function New-DataAnalyzerCertificate {
    # Makes Data Analyzer's OPC UA certificate in its own CertificateStores without opening it (32-bit helper
    # tools\Test-DataAnalyzerCert.ps1 -StoreDir; connects to an unused port, so deviceWise sees nothing).
    param([string]$DaDir)
    $tool = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools\Test-DataAnalyzerCert.ps1'
    if (-not (Test-Path -LiteralPath $tool)) { return @{ Ok = $false; Detail = "Helper not found: $tool" } }
    $ps32 = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    $out  = & $ps32 -NoProfile -ExecutionPolicy Bypass -File $tool -DaDir $DaDir -StoreDir (Join-Path $DaDir 'CertificateStores') 2>&1
    $code = $LASTEXITCODE
    $made = @(Get-ChildItem -LiteralPath (Join-Path $DaDir 'CertificateStores\App\certs') -Filter '*.der' -ErrorAction SilentlyContinue)
    if ($code -eq 0 -and $made) { return @{ Ok = $true; Detail = "Made without opening Data Analyzer: $($made[0].Name)" } }
    return @{ Ok = $false; Detail = "Could not make it (exit $code): $((@($out) | Select-Object -Last 3) -join ' ') - log in to Data Analyzer and press Start Monitoring once, then re-run Step 10" }
}

function Restart-DataApp {
    # Closes a running data app (window close, then kill after 20 s) and starts it again from its folder,
    # so it loads the new config. Started from the wizard it runs as the wizard's account (the SVC account).
    param([string]$Exe)
    $name = [IO.Path]::GetFileNameWithoutExtension($Exe)
    $was  = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    try {
        foreach ($p in $was) { [void]$p.CloseMainWindow() }
        foreach ($p in $was) { if (-not $p.WaitForExit(20000)) { $p.Kill(); [void]$p.WaitForExit(10000) } }
        $new = Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe -Parent) -PassThru
        Start-Sleep -Seconds 3
        if ($new.HasExited) { return @{ Ok = $false; Detail = "$name exited right after starting (exit code $($new.ExitCode))" } }
        return @{ Ok = $true; Detail = "$(if ($was) { 'Restarted' } else { 'Started' }) $name (PID $($new.Id))" }
    } catch {
        return @{ Ok = $false; Detail = "$name could not be restarted: $_" }
    }
}
