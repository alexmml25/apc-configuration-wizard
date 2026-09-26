#Requires -Version 5.1
<#
.SYNOPSIS
    Step 9 - Configure DOC instance XML files for each DOC installation.
.DESCRIPTION
    For each DOC instance n (1..DOCCount), paired with CNC n (the DOC-assigned machine):
      DOC_II\DocDb.xml                     verify ConnectionString (localhost / TimescaleDB / apcuser)
      DOC_II\DOC_II.xml                    CSVFileOutputPath = <SINC staging>\CNC{n}\<CSVFileNamePattern>
      DOC_II\PartLookup.xml                verify ConnectionString; LoadMatrixRevision = MAX
      DOC_II\Plugins\IQS\SpcDb.xml         verify ConnectionString
      DOC_II\Plugins\IQS\IqsDocSpcDataCollector.xml
          AssetConfiguration: DBId = machine, Name = Primary [machine], Family = asset family
          SourceDataInclusionList: 1ST_/SPC_/VER_<instrument>_<site> : <instrument>
            for the instruments selected for CNC n in Data Applications
    The <Name> of every file is set to "DOC-{n} ...". Connection strings are verified, never changed (SOP).
    Originals are backed up with a timestamp suffix.
#>

. (Join-Path $PSScriptRoot 'Common.ps1')

function Invoke-DOCConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [switch]$NonInteractive
    )

    Write-Log STEP "DOC Instance XML Configuration"

    $docCfg   = $Manifest.DOC
    $machines = Get-AssignedCNCs -State $State -Manifest $Manifest
    $ts       = Get-Date -Format 'yyyyMMdd-HHmmss'

    if ($machines.Count -eq 0) {
        Add-Result -Phase DOC -Check "DOC assignments" -Status FAIL -Detail "No DOC-assigned machines in State"
        throw "No DOC-assigned machines - run Site DB fetch and select DOC machines first."
    }

    function Backup-AndLoad {
        param([string]$Path)
        if (-not (Test-Path $Path)) { return $null }
        Copy-Item $Path "$Path.$ts.bak" -Force
        $xml = New-Object System.Xml.XmlDocument
        $xml.LoadXml([System.IO.File]::ReadAllText($Path))
        return $xml
    }

    function Save-Xml {
        param([System.Xml.XmlDocument]$Xml, [string]$Path)
        $s = [System.Xml.XmlWriterSettings]::new()
        $s.Indent   = $true
        $s.Encoding = [System.Text.UTF8Encoding]::new($true)
        $w = [System.Xml.XmlWriter]::Create($Path, $s)
        try { $Xml.Save($w) } finally { $w.Close() }
    }

    function Set-Text {
        param([System.Xml.XmlNode]$Parent, [string]$Name, [string]$Value)
        $node = $Parent.SelectSingleNode($Name)
        if (-not $node) {
            $node = $Parent.OwnerDocument.CreateElement($Name)
            $Parent.AppendChild($node) | Out-Null
        }
        $node.InnerText = $Value
    }

    # Top-level <Name> "DOC-1 DocDb" -> "DOC-{n} DocDb"
    function Set-InstanceName {
        param([System.Xml.XmlDocument]$Xml, [int]$N)
        $node = $Xml.SelectSingleNode('/Configuration/Name')
        if ($node -and $node.InnerText -match '^DOC-\d+') { $node.InnerText = $node.InnerText -replace '^DOC-\d+', "DOC-$N" }
    }

    function Test-ConnString {
        param([System.Xml.XmlDocument]$Xml, [string]$Label, [int]$N)
        $cs = $Xml.SelectSingleNode('/Configuration/ConnectionString')
        $v  = if ($cs) { $cs.InnerText } else { '' }
        if ($v -match 'Server=localhost' -and $v -match 'Database=TimescaleDB' -and $v -match 'User Id=apcuser') {
            Add-Result -Phase DOC -Check "DOC ${N}: $Label connection" -Status PASS
        } else {
            Add-Result -Phase DOC -Check "DOC ${N}: $Label connection" -Status WARN `
                -Detail "ConnectionString does not point at localhost/TimescaleDB as apcuser - confirm with APC Team (not modified)"
        }
    }

    foreach ($m in $machines) {
        $n     = $m.CNCIndex
        $paths = Get-DOCFilePaths -Manifest $Manifest -N $n
        Write-Log INFO "DOC $n -> CNC$n ($($m.MachineName)) at $($paths.Base)"

        if (-not (Test-Path $paths.Base)) {
            Add-Result -Phase DOC -Check "DOC $n install folder" -Status FAIL -Detail "Not found: $($paths.Base)"
            continue
        }

        #region DocDb.xml
        $xml = Backup-AndLoad $paths.DocDb
        if ($xml) {
            Set-InstanceName $xml $n
            Test-ConnString $xml 'DocDb.xml' $n
            Save-Xml $xml $paths.DocDb
        } else {
            Add-Result -Phase DOC -Check "DOC ${n}: DocDb.xml" -Status FAIL -Detail "Not found: $($paths.DocDb)"
        }
        #endregion

        #region DOC_II.xml
        $xml = Backup-AndLoad $paths.DocII
        if ($xml) {
            Set-InstanceName $xml $n
            $csvPath = Get-DOCCsvOutputPath -Manifest $Manifest -N $n
            Set-Text $xml.DocumentElement 'CSVFileOutputPath' $csvPath
            Save-Xml $xml $paths.DocII
            Add-Result -Phase DOC -Check "DOC ${n}: DOC_II.xml CSVFileOutputPath" -Status PASS -Detail $csvPath
            $sincDir = Split-Path $csvPath -Parent
            if (-not (Test-Path $sincDir)) {
                Add-Result -Phase DOC -Check "DOC ${n}: SINC folder" -Status WARN -Detail "$sincDir does not exist - run Step 3"
            }
        } else {
            Add-Result -Phase DOC -Check "DOC ${n}: DOC_II.xml" -Status FAIL -Detail "Not found: $($paths.DocII)"
        }
        #endregion

        #region PartLookup.xml
        $xml = Backup-AndLoad $paths.PartLookup
        if ($xml) {
            Set-InstanceName $xml $n
            Test-ConnString $xml 'PartLookup.xml' $n
            Set-Text $xml.DocumentElement 'LoadMatrixRevision' $docCfg.LoadMatrixRevision
            Save-Xml $xml $paths.PartLookup
            Add-Result -Phase DOC -Check "DOC ${n}: PartLookup.xml LoadMatrixRevision" -Status PASS -Detail $docCfg.LoadMatrixRevision
        } else {
            Add-Result -Phase DOC -Check "DOC ${n}: PartLookup.xml" -Status FAIL -Detail "Not found: $($paths.PartLookup)"
        }
        #endregion

        #region SpcDb.xml
        $xml = Backup-AndLoad $paths.SpcDb
        if ($xml) {
            Set-InstanceName $xml $n
            Test-ConnString $xml 'SpcDb.xml' $n
            Save-Xml $xml $paths.SpcDb
        } else {
            Add-Result -Phase DOC -Check "DOC ${n}: SpcDb.xml" -Status FAIL -Detail "Not found: $($paths.SpcDb)"
        }
        #endregion

        #region IqsDocSpcDataCollector.xml
        $xml = Backup-AndLoad $paths.Iqs
        if ($xml) {
            Set-InstanceName $xml $n
            $root   = $xml.DocumentElement
            $assets = $root.SelectSingleNode('Assets')
            if (-not $assets) { $assets = $xml.CreateElement('Assets'); $root.AppendChild($assets) | Out-Null }
            $asset = $assets.SelectSingleNode('AssetConfiguration')
            if (-not $asset) { $asset = $xml.CreateElement('AssetConfiguration'); $assets.AppendChild($asset) | Out-Null }
            foreach ($extra in @($assets.SelectNodes('AssetConfiguration') | Select-Object -Skip 1)) { $assets.RemoveChild($extra) | Out-Null }
            $family = if ($m.AssetFamily) { $m.AssetFamily } else { $m.CNCType }
            Set-Text $asset 'DBId'   $m.MachineName
            Set-Text $asset 'Name'   "Primary [$($m.MachineName)]"
            Set-Text $asset 'Family' $family
            Add-Result -Phase DOC -Check "DOC ${n}: Iqs asset" -Status PASS -Detail "DBId=$($m.MachineName) Family=$family"

            $entries = Get-DOCInclusionList -Manifest $Manifest -State $State -Cnc $n
            $incl = $root.SelectSingleNode('SourceDataInclusionList')
            if (-not $incl) { $incl = $xml.CreateElement('SourceDataInclusionList'); $root.AppendChild($incl) | Out-Null }
            foreach ($c in @($incl.ChildNodes)) { $incl.RemoveChild($c) | Out-Null }
            foreach ($e in $entries) {
                $el = $xml.CreateElement('string'); $el.InnerText = $e
                $incl.AppendChild($el) | Out-Null
            }
            if ($entries.Count -eq 0) {
                Add-Result -Phase DOC -Check "DOC ${n}: Iqs SourceDataInclusionList" -Status WARN -Detail "No instruments selected for CNC$n - list is empty"
            } else {
                $names = ($entries | ForEach-Object { ($_ -split ' : ')[1] } | Select-Object -Unique) -join ', '
                Add-Result -Phase DOC -Check "DOC ${n}: Iqs SourceDataInclusionList" -Status PASS -Detail "$($entries.Count) entries ($names, site $($State['SiteCode']))"
            }

            Save-Xml $xml $paths.Iqs
        } else {
            Add-Result -Phase DOC -Check "DOC ${n}: IqsDocSpcDataCollector.xml" -Status FAIL -Detail "Not found: $($paths.Iqs)"
        }
        #endregion
    }

    Write-Log PASS "DOC XML configuration complete ($($machines.Count) instance(s))."
    Write-Log INFO "Backups (.$ts.bak) created alongside each modified XML. Review and delete after validation."
}
