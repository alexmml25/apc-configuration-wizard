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
        if (Test-Path $Path) { return }
        if (-not (Test-SandboxPath $State $Path)) {
            Write-Log INFO "Test mode: not creating $Path (outside sandbox)"
            return
        }
        $qualifier = if ($Path -match '^([A-Za-z]:)') { $Matches[1] } else { '' }
        if ($qualifier -and -not (Test-Path "$qualifier\")) {
            Add-Result -Phase DataApps -Check "Directory: $Label" -Status WARN -Detail "Drive $qualifier not available - create $Path manually"
            return
        }
        try {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            Write-Log INFO "Created directory $Path"
        } catch {
            Add-Result -Phase DataApps -Check "Directory: $Label" -Status WARN -Detail "Could not create ${Path}: $($_.Exception.Message)"
        }
    }

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

                # create local folders first: a source can be one of them (e.g. BENCH uses its local folder)
                Ensure-Dir $newPath "$($ins.Type) NewPath"
                Ensure-Dir $errPath "$($ins.Type) ErrorPath"
                if (-not $ins.SourcePath) {
                    Add-Result -Phase DataApps -Check "File Manager: $($ins.Type) source" -Status WARN -Detail "No source share entered - template path kept, update <Path> manually"
                } elseif (-not (Test-Path $ins.SourcePath)) {
                    Add-Result -Phase DataApps -Check "File Manager: $($ins.Type) source" -Status WARN -Detail "Source not reachable from VM: $($ins.SourcePath)"
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

    if ($fmFailed -or $dcFailed) {
        Write-Log WARN "Data applications configuration finished with errors - review results above."
    } else {
        Write-Log PASS "Data applications configuration complete."
    }
    Write-Log INFO "Backup files (.$ts.bak) created alongside each modified config. Review and delete after validation."
    Write-Log INFO "Restart File Manager, Data Collector and Data Analyzer to load the new configuration."
}
