#Requires -Version 5.1
<#
.SYNOPSIS
    Step 9 - Configure DOC instance XML files for each DOC installation.
.DESCRIPTION
    For each DOC instance (1 to State.DOCCount):
    - DocDB.xml          -> connection string -> TimescaleDB / apcuser
    - DOC_II.xml         -> CSVFileOutputPath -> SINC staging path for this CNC
    - PartLookup.xml     -> connection string; LoadMatrixRevision = MAX
    - SpcDB.xml          -> connection string
    - IqsDocSpcDataCollector.xml -> DBId = CNCAsset; Name prefix = Primary; Family = CNCType
    All files are edited in-place; originals are backed up with a .bak timestamp suffix.
#>

function Invoke-DOCConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [switch]$NonInteractive
    )

    Write-Log STEP "DOC Instance XML Configuration"

    $machines = $State['CNCMachines']
    $docCount = [int]$State['DOCCount']
    $docCfg   = $Manifest.DOC
    $pg       = $Manifest.PostgreSQL
    $sinc     = $Manifest.DeviceWise.SINCStaging
    $ts       = "2025-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

    if ($docCount -le 0 -or $docCount -gt 3) { $docCount = 1 }

    # TSDB connection string (odb format for .xml apps)
    $connString = "Server=localhost;Port=5432;Database=TimescaleDB;User Id=apcuser;Password=;"

    function Backup-AndLoad {
        param([string]$Path)
        if (-not (Test-Path $Path)) { return $null }
        Copy-Item $Path "$Path.$ts.bak" -Force
        [xml]$xml = [System.IO.File]::ReadAllText($Path)
        return $xml
    }

    function Save-Xml {
        param([xml]$Xml, [string]$Path)
        $settings           = [System.Xml.XmlWriterSettings]::new()
        $settings.Indent    = $true
        $settings.Encoding  = [System.Text.UTF8Encoding]::new($false)
        $writer = [System.Xml.XmlWriter]::Create($Path, $settings)
        $Xml.Save($writer)
        $writer.Close()
    }

    function Set-XmlConnectionString {
        param([xml]$Xml, [string]$NewConnStr)
        $nodes = $Xml.SelectNodes('//*[local-name()="connectionStrings"]/*[@name]')
        foreach ($n in $nodes) {
            if ($n.Attributes['connectionString']) {
                $n.Attributes['connectionString'].Value = $NewConnStr
            }
        }
        # Also try <add key="..." value="..." /> style
        $kv = $Xml.SelectNodes('//*[local-name()="add"][@key]')
        foreach ($n in $kv) {
            $key = $n.Attributes['key'].Value
            if ($key -like '*Connect*' -or $key -like '*Connection*') {
                $n.Attributes['value'].Value = $NewConnStr
            }
        }
    }

    for ($d = 1; $d -le $docCount; $d++) {
        # Machine pairing: DOC instance N maps to CNC machine N (0-indexed)
        $machineIdx = $d - 1
        $machine    = if ($machineIdx -lt $machines.Count) { $machines[$machineIdx] } else { $machines[0] }
        $cncNode    = "CNC$d"
        $basePath   = $docCfg.BasePath -replace '\{N\}', $d

        Write-Log INFO "Configuring DOC instance $d at: $basePath"

        if (-not (Test-Path $basePath)) {
            Add-Result -Phase DOC -Check "DOC $d base path" -Status WARN -Detail "Path not found: $basePath"
            continue
        }

        #region DocDB.xml -------------------------------------------------------
        $docDbPath = Join-Path $basePath $docCfg.DocDBXml
        $docDbXml  = Backup-AndLoad $docDbPath
        if ($docDbXml) {
            Set-XmlConnectionString -Xml $docDbXml -NewConnStr $connString
            Save-Xml -Xml $docDbXml -Path $docDbPath
            Add-Result -Phase DOC -Check "DOC $d: DocDB.xml" -Status PASS -Detail "Connection string updated"
        } else {
            Add-Result -Phase DOC -Check "DOC $d: DocDB.xml" -Status WARN -Detail "File not found: $docDbPath"
        }
        #endregion

        #region DOC_II.xml ------------------------------------------------------
        $docIIPath = Join-Path $basePath $docCfg.DocIIXml
        $docIIXml  = Backup-AndLoad $docIIPath
        if ($docIIXml) {
            $sincMachinePath = Join-Path $sinc $machine.MachineName

            # Update CSVFileOutputPath
            $csvNode = $docIIXml.SelectSingleNode('//*[local-name()="CSVFileOutputPath"]')
            if (-not $csvNode) {
                $csvNode = $docIIXml.SelectSingleNode('//*[local-name()="add"][@key="CSVFileOutputPath"]')
            }
            if ($csvNode) {
                if ($csvNode.InnerText -ne $null) { $csvNode.InnerText = $sincMachinePath }
                elseif ($csvNode.Attributes['value']) { $csvNode.Attributes['value'].Value = $sincMachinePath }
                Add-Result -Phase DOC -Check "DOC $d: DOC_II.xml CSVPath" -Status PASS -Detail $sincMachinePath
            } else {
                Add-Result -Phase DOC -Check "DOC $d: DOC_II.xml CSVPath" -Status WARN -Detail "CSVFileOutputPath node not found  -  set manually"
            }

            Save-Xml -Xml $docIIXml -Path $docIIPath
        } else {
            Add-Result -Phase DOC -Check "DOC $d: DOC_II.xml" -Status WARN -Detail "File not found: $docIIPath"
        }
        #endregion

        #region PartLookup.xml --------------------------------------------------
        $plPath = Join-Path $basePath $docCfg.PartLookupXml
        $plXml  = Backup-AndLoad $plPath
        if ($plXml) {
            Set-XmlConnectionString -Xml $plXml -NewConnStr $connString

            # Ensure LoadMatrixRevision = MAX
            $lmrNode = $plXml.SelectSingleNode('//*[local-name()="LoadMatrixRevision"]')
            if ($lmrNode) { $lmrNode.InnerText = 'MAX' }

            Save-Xml -Xml $plXml -Path $plPath
            Add-Result -Phase DOC -Check "DOC $d: PartLookup.xml" -Status PASS
        } else {
            Add-Result -Phase DOC -Check "DOC $d: PartLookup.xml" -Status WARN -Detail "File not found: $plPath"
        }
        #endregion

        #region SpcDB.xml -------------------------------------------------------
        $spcPath = Join-Path $basePath $docCfg.SpcDBXml
        $spcXml  = Backup-AndLoad $spcPath
        if ($spcXml) {
            Set-XmlConnectionString -Xml $spcXml -NewConnStr $connString
            Save-Xml -Xml $spcXml -Path $spcPath
            Add-Result -Phase DOC -Check "DOC $d: SpcDB.xml" -Status PASS
        } else {
            Add-Result -Phase DOC -Check "DOC $d: SpcDB.xml" -Status WARN -Detail "File not found: $spcPath"
        }
        #endregion

        #region IqsDocSpcDataCollector.xml ---------------------------------------
        $iqsPath = Join-Path $basePath $docCfg.IqsCollectorXml
        $iqsXml  = Backup-AndLoad $iqsPath
        if ($iqsXml) {
            # DBId = CNCAsset (machine name)
            $dbIdNode = $iqsXml.SelectSingleNode('//*[local-name()="DBId"]')
            if ($dbIdNode) { $dbIdNode.InnerText = $machine.MachineName }

            # Name = "Primary" (or "Primary {MachineName}" if a prefix is expected)
            $nameNode = $iqsXml.SelectSingleNode('//*[local-name()="Name"]')
            if ($nameNode) { $nameNode.InnerText = "Primary" }

            # Family = CNCType
            $famNode = $iqsXml.SelectSingleNode('//*[local-name()="Family"]')
            if ($famNode) { $famNode.InnerText = $machine.CNCType }

            Save-Xml -Xml $iqsXml -Path $iqsPath
            Add-Result -Phase DOC -Check "DOC $d: IqsDocSpcDataCollector.xml" -Status PASS `
                -Detail "DBId=$($machine.MachineName) Family=$($machine.CNCType)"
        } else {
            Add-Result -Phase DOC -Check "DOC $d: IqsDocSpcDataCollector.xml" -Status WARN -Detail "File not found: $iqsPath"
        }
        #endregion
    }

    Write-Log PASS "DOC XML configuration complete ($docCount instance(s))."
    Write-Log INFO "Backup files (.bak) created alongside each modified XML. Review and delete after validation."
}
