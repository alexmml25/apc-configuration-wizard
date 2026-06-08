#Requires -Version 5.1
<#
.SYNOPSIS
    Step 10 - Configure FileManager, DataCollector, and DataAnalyzer XML config files.
.DESCRIPTION
    FileManager.exe.config:
    - Set CheckMismatchData = true for each CNC
    - Set source, archive, and error paths for each instrument (CMM, CTSCAN, BENCH, CONTRACER)
    - EndFileString = NA per entry
    - Create destination directories that don't exist

    DataCollector.exe.config:
    - Set CheckPath, ArchivePath, BroadcastFilePaths = NA per data source
    - EndFileString = NA per entry; create directories

    DataAnalyzer.exe.config:
    - Update site code in OPC process parameter names
    - Verify DB connection string points to local TSDB
#>

function Invoke-DataApps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [switch]$NonInteractive
    )

    Write-Log STEP "Data Applications Configuration"

    $machines   = $State['CNCMachines']
    $siteCode   = $State['SiteCode']
    $da         = $Manifest.DataApps
    $instruments = $Manifest.InstrumentPaths
    $ts         = Get-Date -Format 'yyyyMMdd-HHmmss'

    function Backup-AndLoad {
        param([string]$Path)
        if (-not (Test-Path $Path)) { return $null }
        Copy-Item $Path "$Path.$ts.bak" -Force
        [xml]$xml = [System.IO.File]::ReadAllText($Path)
        return $xml
    }

    function Save-Xml {
        param([xml]$Xml, [string]$Path)
        $s = [System.Xml.XmlWriterSettings]::new()
        $s.Indent   = $true
        $s.Encoding = [System.Text.UTF8Encoding]::new($false)
        $w = [System.Xml.XmlWriter]::Create($Path, $s)
        $Xml.Save($w); $w.Close()
    }

    function Ensure-Dir {
        param([string]$Path)
        if ($Path -and $Path -ne 'NA' -and -not (Test-Path $Path)) {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
        }
    }

    #region -- FileManager.exe.config ----------------------------------------

    $fmPath = $da.FileManagerConfig
    $fmXml  = Backup-AndLoad $fmPath
    if (-not $fmXml) {
        Add-Result -Phase DataApps -Check "FileManager config" -Status WARN -Detail "Not found: $fmPath"
    } else {
        # CheckMismatchData per CNC
        for ($i = 0; $i -lt $machines.Count; $i++) {
            $m = $machines[$i]
            $cncNode = "CNC$($i+1)"

            # Try to find a CNCSettings element referencing this CNC
            $settingNode = $fmXml.SelectSingleNode("//CNCSettings[@name='$cncNode']")
            if (-not $settingNode) {
                $settingNode = $fmXml.SelectSingleNode("//CNCSettings[@id='$cncNode']")
            }
            if ($settingNode) {
                $cmd = $settingNode.SelectSingleNode('CheckMismatchData')
                if ($cmd) { $cmd.InnerText = 'true' }
                else {
                    $newEl = $fmXml.CreateElement('CheckMismatchData')
                    $newEl.InnerText = 'true'
                    $settingNode.AppendChild($newEl) | Out-Null
                }
                Add-Result -Phase DataApps -Check "FileManager: $cncNode CheckMismatchData" -Status PASS
            } else {
                Add-Result -Phase DataApps -Check "FileManager: $cncNode CheckMismatchData" -Status WARN `
                    -Detail "CNCSettings[@name='$cncNode'] not found — set CheckMismatchData=true manually"
            }
        }

        # Instrument paths
        foreach ($instr in $instruments) {
            $instrNode = $fmXml.SelectSingleNode("//Instrument[@name='$instr']")
            if (-not $instrNode) { $instrNode = $fmXml.SelectSingleNode("//$instr") }
            if ($instrNode) {
                $pathNode    = $instrNode.SelectSingleNode('Path');         if ($pathNode)    { Ensure-Dir $pathNode.InnerText }
                $newPathNode = $instrNode.SelectSingleNode('NewPath');      if ($newPathNode) { Ensure-Dir $newPathNode.InnerText }
                $errPathNode = $instrNode.SelectSingleNode('ErrorPath');    if ($errPathNode) { Ensure-Dir $errPathNode.InnerText }
                $efsNode     = $instrNode.SelectSingleNode('EndFileString')
                if ($efsNode) { $efsNode.InnerText = 'NA' }
                else {
                    $efsEl = $fmXml.CreateElement('EndFileString')
                    $efsEl.InnerText = 'NA'
                    $instrNode.AppendChild($efsEl) | Out-Null
                }
                Add-Result -Phase DataApps -Check "FileManager: $instr" -Status PASS
            } else {
                Add-Result -Phase DataApps -Check "FileManager: $instr" -Status WARN `
                    -Detail "Instrument section '$instr' not found — configure manually"
            }
        }

        Save-Xml -Xml $fmXml -Path $fmPath
        Write-Log INFO "FileManager.exe.config saved"
    }

    #endregion

    #region -- DataCollector.exe.config ---------------------------------------

    $dcPath = $da.DataCollectorConfig
    $dcXml  = Backup-AndLoad $dcPath
    if (-not $dcXml) {
        Add-Result -Phase DataApps -Check "DataCollector config" -Status WARN -Detail "Not found: $dcPath"
    } else {
        # For each data source entry: set paths, EndFileString = NA
        $dsNodes = $dcXml.SelectNodes('//DataSource')
        if (-not $dsNodes -or $dsNodes.Count -eq 0) {
            $dsNodes = $dcXml.SelectNodes('//add[@key]')
        }

        foreach ($ds in $dsNodes) {
            $name = if ($ds.name) { $ds.name } elseif ($ds.Attributes['name']) { $ds.Attributes['name'].Value } else { '' }

            $chkNode = $ds.SelectSingleNode('CheckPath')
            $arcNode = $ds.SelectSingleNode('ArchivePath')
            $bfpNode = $ds.SelectSingleNode('BroadcastFilePaths')
            $efsNode = $ds.SelectSingleNode('EndFileString')

            if ($chkNode) { Ensure-Dir $chkNode.InnerText }
            if ($arcNode) { Ensure-Dir $arcNode.InnerText }
            if ($bfpNode) { $bfpNode.InnerText = 'NA' }
            if ($efsNode) { $efsNode.InnerText  = 'NA' }
            else {
                $efsEl = $dcXml.CreateElement('EndFileString')
                $efsEl.InnerText = 'NA'
                $ds.AppendChild($efsEl) | Out-Null
            }
        }

        Save-Xml -Xml $dcXml -Path $dcPath
        Add-Result -Phase DataApps -Check "DataCollector config" -Status PASS -Detail "$($dsNodes.Count) data source(s) configured"
    }

    #endregion

    #region -- DataAnalyzer.exe.config ----------------------------------------

    $daPath = $da.DataAnalyzerConfig
    $daXml  = Backup-AndLoad $daPath
    if (-not $daXml) {
        Add-Result -Phase DataApps -Check "DataAnalyzer config" -Status WARN -Detail "Not found: $daPath"
    } else {
        $sitePattern = $Manifest.SiteOpcProcessCodes[$siteCode]

        # Update OPC process parameters that contain site code suffixes
        foreach ($paramName in @('Opc_FirstRunProces', 'Opc_VerificationProcess', 'Opc_ProductionProcess')) {
            $node = $daXml.SelectSingleNode("//add[@key='$paramName']")
            if ($node -and $siteCode) {
                $curVal = $node.Attributes['value'].Value
                # Replace trailing site code with the correct one
                $newVal = $curVal -replace '_(?:MCR|MFW|MPR|MWR)$', "_$siteCode"
                $node.Attributes['value'].Value = $newVal
                Add-Result -Phase DataApps -Check "DataAnalyzer: $paramName" -Status PASS -Detail $newVal
            } elseif (-not $node) {
                Add-Result -Phase DataApps -Check "DataAnalyzer: $paramName" -Status WARN -Detail "Key not found — set site code manually"
            }
        }

        # Verify DB connection string
        $connNode = $daXml.SelectSingleNode("//add[@key='ConnectionString']")
        if (-not $connNode) {
            $connNode = $daXml.SelectSingleNode("//connectionStrings/*[@name='DefaultConnection']")
        }
        if ($connNode) {
            $connVal = if ($connNode.Attributes['value']) { $connNode.Attributes['value'].Value } else { $connNode.Attributes['connectionString'].Value }
            if ($connVal -notlike '*TimescaleDB*' -and $connVal -notlike '*localhost*') {
                Add-Result -Phase DataApps -Check "DataAnalyzer: DB connection" -Status WARN `
                    -Detail "Connection string does not reference localhost/TimescaleDB — update manually"
            } else {
                Add-Result -Phase DataApps -Check "DataAnalyzer: DB connection" -Status PASS
            }
        }

        Save-Xml -Xml $daXml -Path $daPath
        Write-Log INFO "DataAnalyzer.exe.config saved"
    }

    #endregion

    Write-Log PASS "Data applications configuration complete."
    Write-Log INFO "Backup files (.bak) created alongside each modified config. Review and delete after validation."
}
