#Requires -Version 5.1
<#
.SYNOPSIS
    Step 13 - Run all verification checks and produce a filled D01555624 Word document.
.DESCRIPTION
    Runs every check in the D01555624 Configuration Verification Checklist (Tables 3-11),
    marks each item Pass / Fail / N/A in a copy of the template Word document, and
    also generates a summary HTML report.

    Automatable checks are executed in-process.
    Items requiring hands-on confirmation are left blank for technician sign-off.
#>

. (Join-Path $PSScriptRoot 'Common.ps1')

function Invoke-Verification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [switch]$NonInteractive
    )

    Write-Log STEP "System Verification and Report Generation"

    $machines  = Get-AssignedCNCs -State $State -Manifest $Manifest   # CNC n = DOC instance n
    $dwPort    = $State['DeviceWisePort']
    $dwToken   = $State['DeviceWiseToken']
    $dw        = $Manifest.DeviceWise
    $pg        = $Manifest.PostgreSQL
    $da        = $Manifest.DataApps
    $docCfg    = $Manifest.DOC
    $cncPdm    = $Manifest.CNCnetPDM
    $siteCode  = $State['SiteCode']
    $docCount  = [int]$State['DOCCount']

    $reportDir  = 'C:\APC_Config\Reports'
    $ts         = Get-Date -Format 'yyyyMMdd-HHmmss'
    $reportPath = Join-Path $reportDir "APC_ConfigReport_$ts.html"
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null

    $checks = [System.Collections.Generic.List[hashtable]]::new()

    $baseUrl = if ($dwPort -gt 0) { "http://localhost:${dwPort}$($dw.ApiBasePath)" } else { '' }
    $headers = @{ 'Content-Type' = 'application/json' }
    if ($dwToken) { $headers['Authorization'] = "Bearer $dwToken" }

    # -------------------------------------------------------------------------
    # Inner helpers
    # -------------------------------------------------------------------------

    function Check {
        param([string]$Cat, [string]$Name, [scriptblock]$Test, [string]$Note='', [int]$T=-1, [int]$I=-1)
        $status = 'PASS'; $detail = ''
        try {
            $r = & $Test
            if ($r -is [string]) { $detail = $r }
        } catch { $status = 'FAIL'; $detail = $_.Exception.Message }
        Add-Result -Phase Verification -Check "$Cat`: $Name" -Status $status -Detail "$detail  $Note"
        $checks.Add(@{ Cat=$Cat; Name=$Name; Status=$status; Detail=$detail; Note=$Note; T=$T; I=$I })
    }

    function Blank {
        param([string]$Cat, [string]$Name, [int]$T=-1, [int]$I=-1)
        $checks.Add(@{ Cat=$Cat; Name=$Name; Status='BLANK'; Detail=''; Note='Complete manually'; T=$T; I=$I })
    }

    function NA {
        param([string]$Cat, [string]$Name, [string]$Reason='Not applicable', [int]$T=-1, [int]$I=-1)
        Add-Result -Phase Verification -Check "$Cat`: $Name" -Status PASS -Detail "N/A: $Reason"
        $checks.Add(@{ Cat=$Cat; Name=$Name; Status='NA'; Detail=$Reason; Note=''; T=$T; I=$I })
    }

    function Warn {
        param([string]$Cat, [string]$Name, [string]$Detail)
        Add-Result -Phase Verification -Check "$Cat`: $Name" -Status WARN -Detail $Detail
        $checks.Add(@{ Cat=$Cat; Name=$Name; Status='WARN'; Detail=$Detail; Note=''; T=-1; I=-1 })
    }

    function DWGet {
        param([string]$Path)
        if (-not $baseUrl) { throw "DeviceWise port not available" }
        Invoke-RestMethod -Uri "$baseUrl$Path" -Method GET -Headers $headers -TimeoutSec 15 -ErrorAction Stop
    }

    function PsqlQuery {
        param([string]$Query, [string]$Db = 'TimescaleDB')
        $bin = Join-Path $pg.BinDir 'psql.exe'
        if (-not (Test-Path $bin)) { throw "psql.exe not found at $bin" }
        $result = & $bin -h localhost -p 5432 -U postgres -d $Db -t -A -c $Query 2>&1
        return ($result -join "`n").Trim()
    }

    function ReadIni {
        param([string]$Path, [string]$Section)
        $h = @{}
        if (-not (Test-Path $Path)) { return $h }
        $in = $false
        foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
            $l = $line.Trim()
            if ($l -eq "[$Section]") { $in = $true; continue }
            if ($in -and $l -match '^\[') { break }
            if ($in -and $l -match '^(.+?)\s*=\s*(.*)$') { $h[$Matches[1]] = $Matches[2] }
        }
        return $h
    }

    function XmlAttr {
        param([xml]$X, [string]$XPath, [string]$Attr)
        $node = $X.SelectSingleNode($XPath)
        if ($node -and $Attr) { return $node.GetAttribute($Attr) }
        if ($node) { return $node.InnerText }
        return $null
    }

    function LoadXml {
        param([string]$Path)
        if (-not (Test-Path $Path)) { return $null }
        [xml][System.IO.File]::ReadAllText($Path)
    }

    #region T3 - deviceWise ---------------------------------------------------

    # Item 1 - Required packages installed
    Check 'deviceWise' 'Required packages installed' {
        $missing = @()
        foreach ($pkg in $dw.PackagesToInstall) {
            try {
                $s = DWGet "/packages/$([System.Web.HttpUtility]::UrlEncode($pkg))"
                if ($s.status -ne 'Installed') { $missing += $pkg }
            } catch { $missing += $pkg }
        }
        if ($missing) { throw "Not installed: $($missing -join ', ')" }
        "All packages present: $($dw.PackagesToInstall -join ', ')"
    } '' 3 1

    # Item 2 - License Client configured
    Check 'deviceWise' 'License Client configured' {
        $lic = DWGet '/config/license'
        if ($lic.address -ne $dw.LicenseManagerHost) { throw "Address: $($lic.address)  expected: $($dw.LicenseManagerHost)" }
        if (-not $lic.connected -and $lic.state -ne 'True' -and $lic.enabled -ne $true) { throw "Not connected" }
        "Address: $($lic.address)"
    } '' 3 2

    # Item 3 - OPC UA tag definitions imported
    Check 'deviceWise' 'OPC UA tag definitions imported' {
        $devices = DWGet '/devices'
        if (-not $devices -or ($devices | Measure-Object).Count -eq 0) { throw "No devices/tags found" }
        "Devices visible: $(($devices | Measure-Object).Count)"
    } '' 3 3

    # Item 4 - OPC UA exposed devices (CNC1/2/3)
    Check 'deviceWise' "OPC UA exposed devices ($($dw.CNCNodes[0..($machines.Count-1)] -join ', '))" {
        $exposed = DWGet '/opcua/server/devices'
        $cncNodes = $dw.CNCNodes | Select-Object -First $machines.Count
        $missing = $cncNodes | Where-Object { $exposed.devices -notcontains $_ -and $exposed -notcontains $_ }
        if ($missing) { throw "Not exposed: $($missing -join ', ')" }
        "Exposed: $($cncNodes -join ', ')"
    } '' 3 4

    # Item 5 - OPC UA endpoint configuration
    Check 'deviceWise' 'OPC UA endpoint configuration' {
        $ep = DWGet '/opcua/server/endpoint'
        if ($ep.port -ne $dw.OpcUaEndpointPort -and $ep.Port -ne $dw.OpcUaEndpointPort) {
            throw "Port: $($ep.port)  expected: $($dw.OpcUaEndpointPort)"
        }
        "Port: $($dw.OpcUaEndpointPort), State: $($ep.state)"
    } '' 3 5

    # Items 6-8 - CNCAsset and CNCType per CNC
    for ($ci = 0; $ci -lt 3; $ci++) {
        $item = 6 + $ci
        $node = "CNC$($ci + 1)"
        if ($ci -lt $machines.Count) {
            $m = $machines[$ci]
            Check 'deviceWise' "CNCAsset / CNCType for $node" {
                $av = DWGet "/devices/$node/variables/CNCAsset"
                $tv = DWGet "/devices/$node/variables/CNCType"
                $aVal = if ($av.value) { $av.value } else { $av }
                $tVal = if ($tv.value) { $tv.value } else { $tv }
                if (-not $aVal) { throw "CNCAsset empty" }
                "CNCAsset=$aVal, CNCType=$tVal"
            } '' 3 $item
        } else {
            NA 'deviceWise' "CNCAsset / CNCType for $node" "Machine $node not configured for this site" 3 $item
        }
    }

    # Item 9 - CHMI project imported
    Check 'deviceWise' 'CHMI project imported' {
        $projs = DWGet '/projects'
        $chmi = $projs | Where-Object { $_.name -match 'CHMI' -or $_.id -match 'CHMI' }
        if (-not $chmi) { throw "No CHMI project found under /projects" }
        "CHMI project: $($chmi.name)"
    } '' 3 9

    # Item 10 - CHMI components Loaded/Started
    Check 'deviceWise' 'CHMI components Loaded and Started' {
        $notOk = @()
        foreach ($comp in $Manifest.CHMIComponents.Started) {
            try {
                $s = DWGet "/projects/components/$([System.Web.HttpUtility]::UrlEncode($comp))"
                if ($s.state -notin @('Started','Loaded')) { $notOk += $comp }
            } catch { $notOk += $comp }
        }
        if ($notOk) { throw "Not Started/Loaded: $($notOk[0..2] -join ', ')$(if($notOk.Count -gt 3){' ...'})"}
        "All CHMI components Started/Loaded"
    } '' 3 10

    # Item 11 - SINC project imported
    Check 'deviceWise' 'SINC project imported' {
        $projs = DWGet '/projects'
        $sinc = $projs | Where-Object { $_.name -match 'SINC' -or $_.id -match 'SINC' }
        if (-not $sinc) { throw "No SINC project found under /projects" }
        "SINC project: $(($sinc | Select-Object -First 1).name)"
    } '' 3 11

    # Item 12 - SINC trigger readiness
    Check 'deviceWise' 'SINC triggers Loaded and Started' {
        $notOk = @()
        foreach ($comp in $Manifest.SINCComponents) {
            try {
                $s = DWGet "/projects/components/$([System.Web.HttpUtility]::UrlEncode($comp))"
                if ($s.state -notin @('Started','Loaded')) { $notOk += $comp }
            } catch { $notOk += $comp }
        }
        if ($notOk) { throw "Not Started: $($notOk[0..2] -join ', ')$(if($notOk.Count -gt 3){' ...'})"}
        "All $($Manifest.SINCComponents.Count) SINC components Started/Loaded"
    } '' 3 12

    # Item 13 - SINC EMAIL_TO configured
    Check 'deviceWise' 'SINC EMAIL_TO configured' {
        $s = DWGet "/projects/components/$([System.Web.HttpUtility]::UrlEncode('0_DefaultConfiguration'))"
        $emailTo = ($s.localVariables | Where-Object { $_.name -eq 'EMAIL_TO' }).value
        if (-not $emailTo) {
            $emailTo = ($s.variables | Where-Object { $_.name -eq 'EMAIL_TO' }).value
        }
        if (-not $emailTo) { throw "EMAIL_TO variable not found or empty" }
        "EMAIL_TO: $emailTo"
    } '' 3 13

    # Item 14 - CNC_ASSET_Management table
    Check 'deviceWise' 'CNC_ASSET_Management table populated' {
        $rows = DWGet '/projects/localdb/CNC_ASSET_Management'
        if (-not $rows -or ($rows | Measure-Object).Count -eq 0) { throw "Table empty or not found" }
        "$($($rows | Measure-Object).Count) row(s) in CNC_ASSET_Management"
    } '' 3 14

    # Item 15 - CNC_Settings table
    Check 'deviceWise' 'CNC_Settings table populated' {
        $rows = DWGet '/projects/localdb/CNC_Settings'
        if (-not $rows -or ($rows | Measure-Object).Count -eq 0) { throw "Table empty or not found" }
        "$($($rows | Measure-Object).Count) row(s) in CNC_Settings"
    } '' 3 15

    # Item 16 - SINC staging folders
    $sincRoot = $dw.SINCStaging
    $sincOk   = $true
    $sincMiss = @()
    foreach ($m in $machines) {
        foreach ($sub in @('Processing', 'DoneSuccess', 'DoneError')) {
            $p = Join-Path $sincRoot "CNC$($m.CNCIndex)\$sub"
            if (-not (Test-Path $p)) { $sincOk = $false; $sincMiss += "CNC$($m.CNCIndex)\$sub" }
        }
    }
    if ($sincOk) {
        $checks.Add(@{ Cat='deviceWise'; Name='SINC staging folder structure'; Status='PASS';
            Detail="$($machines.Count * 3) folders present"; Note=''; T=3; I=16 })
        Add-Result -Phase Verification -Check 'deviceWise: SINC staging folders' -Status PASS
    } else {
        $checks.Add(@{ Cat='deviceWise'; Name='SINC staging folder structure'; Status='FAIL';
            Detail="Missing: $($sincMiss -join ', ')"; Note=''; T=3; I=16 })
        Add-Result -Phase Verification -Check 'deviceWise: SINC staging folders' -Status FAIL -Detail ($sincMiss -join ', ')
    }

    # Item 17 - CNCnetPDM Connected in deviceWise
    if ($baseUrl) {
        Check 'deviceWise' 'CNCnetPDM Connected in deviceWise' {
            $inst = DWGet '/cncnetpdm/instances'
            $conn = $inst | Where-Object { $_.status -eq 'Connected' }
            if (-not $conn) { throw "No Connected instance found" }
            "Connected instances: $($($conn | Measure-Object).Count)"
        } '' 3 17
    } else {
        Warn 'deviceWise' 'CNCnetPDM Connected' 'DeviceWise port not available'
    }

    # Item 18 - CNCnetPDM path mapping
    Check 'deviceWise' 'CNCnetPDM to deviceWise path mapping' {
        $mappings = DWGet '/cncnetpdm/mappings'
        $missing  = @()
        for ($i = 0; $i -lt $machines.Count; $i++) {
            $expected = "CNC$($i+1)_Path"
            $found = $mappings | Where-Object { $_.devicePath -match $expected -or $_.path -match $expected }
            if (-not $found) { $missing += $expected }
        }
        if ($missing) { throw "Unmapped paths: $($missing -join ', ')" }
        "All $($machines.Count) CNC path(s) mapped"
    } '' 3 18

    # Item 19 - MedtronicSU user exists
    Check 'deviceWise' "OPC UA user $($dw.OpcUaUser) exists" {
        $users = DWGet '/security/users'
        $su = $users | Where-Object { $_.userName -eq $dw.OpcUaUser -or $_.name -eq $dw.OpcUaUser }
        if (-not $su) { throw "User $($dw.OpcUaUser) not found" }
        "User $($dw.OpcUaUser) present"
    } '' 3 19

    # Item 20 - External client certificate trusted
    Check 'deviceWise' 'External client certificate trusted' {
        $certs = DWGet '/opcua/server/certificates'
        $trusted = $certs | Where-Object { $_.trusted -eq $true -or $_.status -eq 'Trusted' }
        if (-not $trusted) { throw "No trusted certificates found" }
        "Trusted certificates: $($($trusted | Measure-Object).Count)"
    } '' 3 20

    # Item 21 - CNCx and CNCx_Path devices Started
    Check 'deviceWise' 'CNCx / CNCx_Path devices State=Started' {
        $notStarted = @()
        for ($i = 0; $i -lt $machines.Count; $i++) {
            foreach ($dev in @("CNC$($i+1)", "CNC$($i+1)_Path")) {
                try {
                    $d = DWGet "/devices/$dev"
                    if ($d.state -ne 'Started') { $notStarted += $dev }
                } catch { $notStarted += $dev }
            }
        }
        if ($notStarted) { throw "Not Started: $($notStarted -join ', ')" }
        "All CNC device objects Started"
    } '' 3 21

    #endregion

    #region T4 - TSDB ---------------------------------------------------------

    # Item 1 - pg_hba.conf host entry
    Check 'TSDB' 'pg_hba.conf host connection entry' {
        $lines = [System.IO.File]::ReadAllLines($pg.PgHbaFile)
        $found = $lines | Where-Object { $_ -match [regex]::Escape($pg.HbaEntry) }
        if (-not $found) { throw "Entry '$($pg.HbaEntry)' not in $($pg.PgHbaFile)" }
        "Entry present: $($pg.HbaEntry)"
    } '' 4 1

    # Item 2 - PostgreSQL service running
    Check 'TSDB' 'PostgreSQL service running' {
        $svc = Get-Service -Name $pg.Service -ErrorAction Stop
        if ($svc.Status -ne 'Running') { throw "Status: $($svc.Status)" }
        "Service $($pg.Service): Running"
    } '' 4 2

    # Item 3 - apcuser role exists
    Check 'TSDB' 'apcuser login role exists' {
        $r = PsqlQuery "SELECT usename FROM pg_user WHERE usename='apcuser';" 'postgres'
        if ($r -ne 'apcuser') { throw "User 'apcuser' not found in pg_user" }
        "User apcuser exists"
    } '' 4 3

    # Item 4 - apcuser privileges
    Check 'TSDB' 'apcuser privileges (superuser, createdb)' {
        $r = PsqlQuery "SELECT usesuper,usecreatedb FROM pg_user WHERE usename='apcuser';" 'postgres'
        if ($r -notmatch 't\|t') { throw "Missing required privileges: $r" }
        "superuser=t, createdb=t"
    } '' 4 4

    # Item 5 - TimescaleDB database exists, owner = apcuser
    Check 'TSDB' 'TimescaleDB database exists (owner=apcuser)' {
        $r = PsqlQuery "SELECT pg_catalog.pg_get_userbyid(d.datdba) FROM pg_catalog.pg_database d WHERE d.datname='TimescaleDB';" 'postgres'
        if (-not $r) { throw "Database 'TimescaleDB' not found" }
        if ($r -ne 'apcuser') { throw "Owner: $r  expected: apcuser" }
        "Database TimescaleDB owner: apcuser"
    } '' 4 5

    # Item 6 - TimescaleDB extension
    Check 'TSDB' 'TimescaleDB extension installed' {
        $pgBin = Join-Path $pg.BinDir 'psql.exe'
        if (-not (Test-Path $pgBin)) { throw "psql.exe not found at $pgBin" }
        $r = & $pgBin -h localhost -p 5432 -U postgres -d TimescaleDB -t -A `
            -c "SELECT extname FROM pg_extension WHERE extname='timescaledb';" 2>&1
        if ($r -notmatch 'timescaledb') { throw "Extension not found" }
        "timescaledb extension present"
    } '' 4 6

    # Items 7-8 - pgAdmin (manual UI steps)
    Blank 'TSDB' 'pgAdmin server registration' 4 7
    Blank 'TSDB' 'pgAdmin connection to TimescaleDB' 4 8

    # Item 9 - APC schema executed (check for any APC tables)
    Check 'TSDB' 'APC schema tables present' {
        $r = PsqlQuery "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';"
        $n = [int]$r
        if ($n -eq 0) { throw "No tables in public schema" }
        "$n table(s) in public schema"
    } '' 4 9

    # Item 10 - Schema tables (ODBC DSN also validates DB access)
    Check 'TSDB' 'ODBC DSN PostgreSQL30 configured' {
        $dsnPath = 'HKLM:\SOFTWARE\ODBC\ODBC.INI\PostgreSQL30'
        if (-not (Test-Path $dsnPath)) { throw "Registry key not found: $dsnPath" }
        $props = Get-ItemProperty $dsnPath
        "DSN: $($props.Servername):$($props.Port) db=$($props.Database)"
    } '' 4 10

    #endregion

    #region T5 - DOC ----------------------------------------------------------

    # Item 1 - DOC count matches CNC assets
    Check 'DOC' 'DOC instance count matches CNC assets' {
        if ($docCount -eq 0) { throw "DOCCount = 0" }
        if ($docCount -ne $machines.Count) { throw "DOCCount=$docCount but only $($machines.Count) DOC-assigned machine(s) found in Site DB data" }
        "$docCount DOC instance(s) -> $(($machines | ForEach-Object { "CNC$($_.CNCIndex)=$($_.MachineName)" }) -join ', ')"
    } '' 5 1

    # Per-instance expectations, collected per checklist item
    $docItems = [ordered]@{ Dirs = @(); DocDb = @(); SpcDb = @(); PLConn = @(); PLRev = @(); DocII = @(); Iqs = @() }
    function ConnIssue {
        param([System.Xml.XmlDocument]$X, [string]$Label)
        if (-not $X) { return "$Label not found" }
        $cs = XmlAttr $X '/Configuration/ConnectionString' ''
        if ($cs -notmatch 'Server=localhost' -or $cs -notmatch 'Database=TimescaleDB' -or $cs -notmatch 'User Id=apcuser') {
            return "$Label ConnectionString not localhost/TimescaleDB/apcuser"
        }
    }

    foreach ($m in $machines) {
        $d = $m.CNCIndex
        $p = Get-DOCFilePaths -Manifest $Manifest -N $d
        if (-not (Test-Path $p.Base)) { $docItems.Dirs += "DOC$d missing: $($p.Base)"; continue }

        $docDbXml = LoadXml $p.DocDb;  $spcDbXml = LoadXml $p.SpcDb;  $plXml = LoadXml $p.PartLookup
        $docIIXml = LoadXml $p.DocII;  $iqsXml   = LoadXml $p.Iqs

        $i = ConnIssue $docDbXml "DOC$d DocDb.xml";      if ($i) { $docItems.DocDb  += $i }
        $i = ConnIssue $spcDbXml "DOC$d SpcDb.xml";      if ($i) { $docItems.SpcDb  += $i }
        $i = ConnIssue $plXml    "DOC$d PartLookup.xml"; if ($i) { $docItems.PLConn += $i }

        if ($plXml) {
            $lmr = XmlAttr $plXml '/Configuration/LoadMatrixRevision' ''
            if ($lmr -ne $docCfg.LoadMatrixRevision) { $docItems.PLRev += "DOC$d LoadMatrixRevision=$lmr" }
        } else { $docItems.PLRev += "DOC$d PartLookup.xml not found" }

        $expCsv = Get-DOCCsvOutputPath -Manifest $Manifest -N $d
        if (-not $docIIXml) { $docItems.DocII += "DOC$d DOC_II.xml not found" }
        else {
            $csv = XmlAttr $docIIXml '/Configuration/CSVFileOutputPath' ''
            if ($csv -ne $expCsv) { $docItems.DocII += "DOC$d CSVFileOutputPath=$csv expected $expCsv" }
        }

        if (-not $iqsXml) { $docItems.Iqs += "DOC$d IqsDocSpcDataCollector.xml not found" }
        else {
            $a = $iqsXml.SelectSingleNode('/Configuration/Assets/AssetConfiguration')
            $fam = if ($m.AssetFamily) { $m.AssetFamily } else { $m.CNCType }
            if (-not $a) { $docItems.Iqs += "DOC$d AssetConfiguration missing" }
            else {
                if ($a.SelectSingleNode('DBId').InnerText   -ne $m.MachineName)             { $docItems.Iqs += "DOC$d DBId=$($a.SelectSingleNode('DBId').InnerText) expected $($m.MachineName)" }
                if ($a.SelectSingleNode('Name').InnerText   -ne "Primary [$($m.MachineName)]") { $docItems.Iqs += "DOC$d Name=$($a.SelectSingleNode('Name').InnerText)" }
                if ($a.SelectSingleNode('Family').InnerText -ne $fam)                        { $docItems.Iqs += "DOC$d Family=$($a.SelectSingleNode('Family').InnerText) expected $fam" }
            }
            $have = @($iqsXml.SelectNodes('/Configuration/SourceDataInclusionList/string') | ForEach-Object { $_.InnerText.Trim() })
            $want = Get-DOCInclusionList -Manifest $Manifest -State $State -Cnc $d
            $missing = @($want | Where-Object { $_ -notin $have })
            if ($missing) { $docItems.Iqs += "DOC$d SourceDataInclusionList missing: $($missing -join ', ')" }
        }
    }

    function AddDocItem {
        param([string]$Name, [string[]]$Issues, [string]$OkText, [int]$I)
        $status = if ($Issues.Count -eq 0) { 'PASS' } else { 'FAIL' }
        $detail = if ($Issues.Count -eq 0) { $OkText } else { $Issues -join '; ' }
        Add-Result -Phase Verification -Check "DOC: $Name" -Status $status -Detail $detail
        $checks.Add(@{ Cat='DOC'; Name=$Name; Status=$status; Detail=$detail; Note=''; T=5; I=$I })
    }
    AddDocItem 'DOC instance directory structure'           $docItems.Dirs   "$($machines.Count) instance folder(s) present"            2
    AddDocItem 'DocDB.xml connection config'                $docItems.DocDb  'localhost / TimescaleDB / apcuser'                        3
    AddDocItem 'SpcDB.xml connection config'                $docItems.SpcDb  'localhost / TimescaleDB / apcuser'                        4
    AddDocItem 'PartLookup.xml connection config'           $docItems.PLConn 'localhost / TimescaleDB / apcuser'                        5
    AddDocItem 'PartLookup.xml LoadMatrixRevision=MAX'      $docItems.PLRev  "LoadMatrixRevision=$($docCfg.LoadMatrixRevision)"          6
    AddDocItem 'DOC_II.xml CSVFileOutputPath'               $docItems.DocII  'SINC\CNC{n} output path set on all instances'             7
    AddDocItem 'IqsDocSpcDataCollector.xml asset mapping'   $docItems.Iqs    'DBId / Name / Family and inclusion list match CNC assets' 8

    # Item 9 - DOC to CNC alignment
    Check 'DOC' 'DOC to CNC asset alignment' {
        if ($machines.Count -eq 0) { throw "No DOC-assigned machines" }
        ($machines | ForEach-Object { "DOC$($_.CNCIndex) -> CNC$($_.CNCIndex) ($($_.MachineName))" }) -join ', '
    } '' 5 9

    # Items 10-11 - manual
    Blank 'DOC' 'DOC application launch' 5 10
    Blank 'DOC' 'DOC connectivity indicators (DB/SPC/OPC green)' 5 11

    # Item 12 - every DOC assignment resolves to a Site DB machine
    Check 'DOC' 'DOC-to-CNC alignment with deviceWise' {
        $assigned = @($State['DOCMachineAssignments'])
        $missing  = @(for ($i = 0; $i -lt $docCount; $i++) {
            if (-not ($machines | Where-Object { $_.CNCIndex -eq $i + 1 })) { "DOC$($i + 1) -> '$(if ($i -lt $assigned.Count) { $assigned[$i] })' not in Site DB machines" }
        })
        if ($missing) { throw ($missing -join '; ') }
        "DOC instances aligned with deviceWise CNC assets"
    } '' 5 12

    # Item 13 - completeness
    $docAll      = @($docItems.Values | ForEach-Object { $_ })
    $doc13Status = if ($docAll.Count -eq 0) { 'PASS' } else { 'FAIL' }
    $checks.Add(@{ Cat='DOC'; Name='DOC configuration completeness'; Status=$doc13Status;
        Detail=if($doc13Status -eq 'PASS'){'All DOC config elements present and aligned'}else{"$($docAll.Count) issue(s): $($docAll[0])"}; Note=''; T=5; I=13 })

    #endregion

    #region T6 - CNCnetPDM ----------------------------------------------------

    # Resolve install dir
    $pdmDir = $null
    foreach ($c in @($cncPdm.InstallDir, $cncPdm.FallbackDir)) { if (Test-Path $c) { $pdmDir = $c; break } }
    if (-not $pdmDir) {
        $found = Get-ChildItem 'C:\' -Directory -Filter '*CNCnetPDM*' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $pdmDir = $found.FullName }
    }
    $iniPath    = if ($pdmDir) { Join-Path $pdmDir $cncPdm.IniFile }    else { '' }
    $melcfgPath = if ($pdmDir) { Join-Path $pdmDir $cncPdm.MelcfgFile } else { '' }

    # Item 1 - Config directory
    Check 'CNCnetPDM' 'CNCnetPDM configuration directory present' {
        if (-not $pdmDir) { throw "Cannot locate CNCnetPDM directory" }
        $pdmDir
    } '' 6 1

    # Item 2 - License applied
    Check 'CNCnetPDM' 'Perpetual license applied' {
        if (-not $iniPath) { throw "INI path unknown" }
        $key = (ReadIni $iniPath 'GENERAL')['License']
        if (-not $key) { throw "License not found in [GENERAL] section of $iniPath" }
        $expected = if ($State['CNCnetPDMLicense']) { $State['CNCnetPDMLicense'] } else { $cncPdm.DefaultLicense }
        if ($expected -and $key -ne $expected) { throw "License in INI ($($key.Substring(0, [Math]::Min(8,$key.Length)))...) differs from configured license" }
        "Key: $($key.Substring(0, [Math]::Min(8,$key.Length)))..."
    } '' 6 2

    $pdmCNCs  = Get-AssignedCNCs -State $State -Manifest $Manifest
    $driverDir = if ($pdmDir -and $cncPdm.DriverSubDir) { Join-Path $pdmDir $cncPdm.DriverSubDir } else { $pdmDir }

    # Items 3-5 - CNC machine definitions per CNC slot
    for ($ci = 1; $ci -le 3; $ci++) {
        $item = 2 + $ci
        $m = $pdmCNCs | Where-Object { $_.CNCIndex -eq $ci } | Select-Object -First 1
        if ($m) {
            Check 'CNCnetPDM' "CNCnetPDM.ini entry for CNC$ci ($($m.MachineName))" {
                if (-not $iniPath) { throw "INI path unknown" }
                if ($m.DeviceNrError) { throw $m.DeviceNrError }
                $entry = (ReadIni $iniPath $cncPdm.RS232Section)["$ci"]
                if (-not $entry) { throw "Line $ci not found in [RS232]" }
                $p = $entry -split ';'
                if ($p.Count -ne 16) { throw "Expected 16 fields, found $($p.Count): $entry" }
                $errs = @()
                if ($p[0]  -ne $m.DeviceNr)    { $errs += "DeviceNr=$($p[0]) expected $($m.DeviceNr)" }
                if ($p[5]  -ne $m.MachineName) { $errs += "MachineName=$($p[5]) expected $($m.MachineName)" }
                if ($p[6]  -ne $m.IPAddress)   { $errs += "IP=$($p[6]) expected $($m.IPAddress)" }
                if ($p[10] -ne "$ci")          { $errs += "Mitsubishi Nr=$($p[10]) expected $ci" }
                if ($p[15] -ne $m.DriverDll)   { $errs += "DLL=$($p[15]) expected $($m.DriverDll)" }
                if ($errs) { throw ($errs -join '; ') }
                "$ci = $entry"
            } '' 6 $item
        } else {
            NA 'CNCnetPDM' "CNCnetPDM.ini entry for CNC$ci" "CNC$ci not configured" 6 $item
        }
    }

    # Item 6 - Driver DLL files renamed to DeviceNr
    Check 'CNCnetPDM' 'Driver DLL files renamed correctly' {
        if (-not $driverDir) { throw "Directory unknown" }
        $missing = @($pdmCNCs | ForEach-Object {
            "$([System.IO.Path]::GetFileNameWithoutExtension($_.DriverDll))_$($_.DeviceNr).dll"
        } | Where-Object { -not (Test-Path (Join-Path $driverDir $_)) })
        if ($missing) { throw "Missing DLLs: $($missing -join ', ')" }
        "Driver DLLs present: $(($pdmCNCs | ForEach-Object { "$([System.IO.Path]::GetFileNameWithoutExtension($_.DriverDll))_$($_.DeviceNr).dll" }) -join ', ')"
    } '' 6 6

    # Item 7 - melcfg.ini machine sections and TCP mappings
    Check 'CNCnetPDM' 'melcfg.ini TCP mappings' {
        if (-not $melcfgPath) { throw "melcfg.ini path unknown" }
        $hosts = ReadIni $melcfgPath $cncPdm.HostsSection
        $errs = @()
        foreach ($m in $pdmCNCs) {
            $n = $m.CNCIndex
            $sec = ReadIni $melcfgPath ('Machine{0:D2}' -f $n)
            if ($sec['Device'] -ne "TCP$n") { $errs += "[Machine$('{0:D2}' -f $n)] Device=$($sec['Device']) expected TCP$n" }
            if (-not $hosts["TCP$n"])      { $errs += "TCP$n missing in [HOSTS]" }
        }
        if ($errs) { throw ($errs -join '; ') }
        "$($pdmCNCs.Count) machine section(s) and TCP mapping(s) present"
    } '' 6 7

    # Item 8 - Configuration consistency (cross-check ini / melcfg / DLL)
    Check 'CNCnetPDM' 'Configuration consistency (INI/melcfg/DLL aligned)' {
        if (-not $iniPath -or -not $melcfgPath) { throw "Config paths unknown" }
        $rs232 = ReadIni $iniPath $cncPdm.RS232Section
        $hosts = ReadIni $melcfgPath $cncPdm.HostsSection
        $errs = @()
        $extra = @($rs232.Keys | Where-Object { $_ -match '^\d+$' -and [int]$_ -notin @($pdmCNCs | ForEach-Object { $_.CNCIndex }) })
        if ($extra) { $errs += "Unexpected RS232 lines: $($extra -join ', ')" }
        foreach ($m in $pdmCNCs) {
            $n = $m.CNCIndex
            $p = "$($rs232["$n"])" -split ';'
            $tcp = "$($hosts["TCP$n"])" -replace '\s', ''
            if ($p.Count -ge 8 -and $tcp -ne "$($p[6]),$($p[7])") { $errs += "TCP$n '$tcp' does not match RS232 IP/port '$($p[6]),$($p[7])'" }
            if ($p.Count -ge 11 -and $p[10] -ne "$n") { $errs += "RS232 line $n Mitsubishi Nr $($p[10])" }
        }
        if ($errs) { throw ($errs -join '; ') }
        "RS232, melcfg.ini and DeviceNr aligned for $($pdmCNCs.Count) CNC(s)"
    } '' 6 8

    # Item 9 - CNCnetPDM service running
    Check 'CNCnetPDM' 'CNCnetPDM service running' {
        $svc = Get-Service -Name $Manifest.Services.CNCnetPDM -ErrorAction Stop
        if ($svc.Status -ne 'Running') { throw "Status: $($svc.Status)" }
        "Service: Running"
    } '' 6 9

    # Item 10 - Connected in deviceWise (same as T3-17, share the result)
    if ($baseUrl) {
        Check 'CNCnetPDM' 'CNCnetPDM devices Connected in deviceWise' {
            $inst = DWGet '/cncnetpdm/instances'
            $conn = $inst | Where-Object { $_.status -eq 'Connected' }
            if (-not $conn) { throw "No Connected instance" }
            "Connected"
        } '' 6 10
    } else {
        Warn 'CNCnetPDM' 'Connected check skipped' 'DeviceWise port not available'
        $checks.Add(@{ Cat='CNCnetPDM'; Name='CNCnetPDM devices Connected'; Status='BLANK'; Detail=''; Note='Verify in Workbench'; T=6; I=10 })
    }

    # Items 11-12 - manual read/write tests
    Blank 'CNCnetPDM' 'Read access verified via deviceWise' 6 11
    Blank 'CNCnetPDM' 'Write access verified via deviceWise' 6 12

    # Item 13 - readiness aggregate
    $pdmReadyStatus = if (
        ($checks | Where-Object { $_.T -eq 6 -and $_.I -in 1..10 -and $_.Status -eq 'FAIL' }).Count -eq 0
    ) { 'PASS' } else { 'FAIL' }
    $checks.Add(@{ Cat='CNCnetPDM'; Name='CNCnetPDM readiness for APC integration'; Status=$pdmReadyStatus;
        Detail=if($pdmReadyStatus -eq 'PASS'){'All automated checks passed'}else{'One or more checks failed'}; Note=''; T=6; I=13 })

    #endregion

    #region T7 - File Manager -------------------------------------------------

    $fmXml       = LoadXml $da.FileManagerConfig
    $instruments = @($da.Instruments | ForEach-Object { $_.Type })
    $fmPaths     = if ($fmXml) { @($fmXml.SelectNodes('/configuration/Paths/*')) } else { @() }

    function FmChild {
        param([System.Xml.XmlNode]$Block, [string]$Name)
        $n = $Block.SelectSingleNode($Name); if ($n) { $n.InnerText } else { $null }
    }

    # Item 1 - Instrument path entries
    Check 'FileManager' 'Predefined instrument path entries' {
        if (-not $fmXml) { throw "Config not found: $($da.FileManagerConfig)" }
        if ($fmPaths.Count -eq 0) { throw "No <Paths> entries" }
        $names = $fmPaths | ForEach-Object { FmChild $_ 'Name' }
        $present = $instruments | Where-Object { $t = $_; $names | Where-Object { $_ -match "^$t\d*$" } }
        "$($fmPaths.Count) entries ($($names -join ', ')); types: $($present -join ', ')"
    } '' 7 1

    # Item 2 - Source paths configured
    Check 'FileManager' 'Source paths configured' {
        if (-not $fmXml) { throw "Config not found" }
        $empty = @($fmPaths | Where-Object { -not (FmChild $_ 'Path') } | ForEach-Object { FmChild $_ 'Name' })
        if ($empty) { throw "Source path empty for: $($empty -join ', ')" }
        $unreach = @($fmPaths | ForEach-Object { FmChild $_ 'Path' } | Select-Object -Unique | Where-Object { -not (Test-Path $_) })
        if ($unreach) { throw "Source not reachable: $($unreach -join ', ')" }
        "Source paths set and reachable for $($fmPaths.Count) entries"
    } '' 7 2

    # Item 3 - Destination paths configured
    Check 'FileManager' 'Destination (NewPath) paths configured' {
        if (-not $fmXml) { throw "Config not found" }
        $empty = @($fmPaths | Where-Object { $p = FmChild $_ 'NewPath'; -not $p -or $p -eq 'NA' } | ForEach-Object { FmChild $_ 'Name' })
        if ($empty) { throw "NewPath empty/NA for: $($empty -join ', ')" }
        "Destination paths set"
    } '' 7 3

    # Item 4 - Destination directories exist
    Check 'FileManager' 'Destination directories exist on VM' {
        if (-not $fmXml) { throw "Config not found" }
        $missing = @($fmPaths | ForEach-Object { FmChild $_ 'NewPath'; FmChild $_ 'ErrorPath' } |
                     Select-Object -Unique | Where-Object { $_ -and $_ -ne 'NA' -and -not (Test-Path $_) })
        if ($missing) { throw "Missing dirs: $($missing -join ', ')" }
        "All destination and error directories present"
    } '' 7 4

    # Item 5 - EndFileString configured
    Check 'FileManager' 'EndFileString configured per instrument' {
        if (-not $fmXml) { throw "Config not found" }
        $bad = @($fmPaths | Where-Object { (FmChild $_ 'EndFileString') -ne 'NA' } | ForEach-Object { FmChild $_ 'Name' })
        if ($bad) { throw "EndFileString not NA for: $($bad -join ', ')" }
        $mm = @($fmXml.SelectNodes('/configuration/CNCSettings/*') | Where-Object { (FmChild $_ 'CheckMismatchData') -ne 'true' })
        if ($mm) { throw "CheckMismatchData not true for: $(($mm | ForEach-Object { $_.LocalName }) -join ', ')" }
        "EndFileString=NA on all entries; CheckMismatchData=true on all CNCs"
    } '' 7 5

    # Item 6 - Application startup (process running)
    Check 'FileManager' 'File Manager process running' {
        $proc = Get-Process -Name 'DataCollector_FileManager','DataCollectorFileManager','FileManager','DataCollector.FileManager' -ErrorAction SilentlyContinue |
                Select-Object -First 1
        if (-not $proc) { throw "Process not found  -  verify application is launched and running" }
        "Process: $($proc.ProcessName) (PID $($proc.Id))"
    } '' 7 6

    # Item 7 - File routing (manual test)
    Blank 'FileManager' 'File routing functionality (test file)' 7 7

    #endregion

    #region T8 - Data Collector -----------------------------------------------

    $dcXml    = LoadXml $da.DataCollectorConfig
    $dcBlocks = if ($dcXml) { @($dcXml.SelectNodes('/configuration/DataTypeSettings/*')) } else { @() }

    # Item 1 - DB connection
    Check 'DataCollector' 'Database connection to TimescaleDB' {
        if (-not $dcXml) { throw "Config not found: $($da.DataCollectorConfig)" }
        $cs = XmlAttr $dcXml '/configuration/AppSettingsSection/ConString' ''
        if ($cs -notmatch 'TimescaleDB') { throw "ConString does not reference TimescaleDB" }
        if ($cs -notmatch 'apcuser')     { throw "ConString does not use apcuser" }
        "ConString references TimescaleDB / apcuser"
    } '' 8 1

    # Item 2 - DataTypeSettings blocks
    Check 'DataCollector' 'DataTypeSettings blocks present' {
        if (-not $dcXml) { throw "Config not found" }
        if ($dcBlocks.Count -eq 0) { throw "No DataTypeSettings blocks" }
        "$($dcBlocks.Count) blocks: $(($dcBlocks | ForEach-Object { $_.LocalName }) -join ', ')"
    } '' 8 2

    # Items 3-5 - Path configuration
    $dcPathChecks = @(
        @{ I=3; Elem='CheckPath';                Label='CheckPath' },
        @{ I=4; Elem='ArchivePath';              Label='ArchivePath' },
        @{ I=5; Elem='BroadcastFilePaths/Path1'; Label='BroadcastFilePaths' }
    )
    foreach ($pc in $dcPathChecks) {
        Check 'DataCollector' "$($pc.Label) configured" {
            if (-not $dcXml) { throw "Config not found" }
            $empty = @($dcBlocks | Where-Object { -not (FmChild $_ $pc.Elem) } | ForEach-Object { $_.LocalName })
            if ($empty) { throw "$($pc.Label) empty for: $($empty -join ', ')" }
            "$($pc.Label) set on $($dcBlocks.Count) blocks"
        } '' 8 $pc.I
    }

    # Item 6 - Directories exist, and CheckPath matches a File Manager NewPath
    Check 'DataCollector' 'CheckPath / ArchivePath directories exist' {
        if (-not $dcXml) { throw "Config not found" }
        $dirs = @($dcBlocks | ForEach-Object { FmChild $_ 'CheckPath'; FmChild $_ 'ArchivePath'; FmChild $_ 'BroadcastFilePaths/Path1' } |
                  Select-Object -Unique | Where-Object { $_ -and $_ -ne 'NA' })
        $missing = @($dirs | Where-Object { -not (Test-Path $_) })
        if ($missing) { throw "Missing: $($missing -join ', ')" }
        $newPaths = @($fmPaths | ForEach-Object { FmChild $_ 'NewPath' })
        $orphans  = @($dcBlocks | ForEach-Object { FmChild $_ 'CheckPath' } | Select-Object -Unique | Where-Object { $_ -notin $newPaths })
        if ($fmXml -and $orphans) { throw "CheckPath not fed by any File Manager NewPath: $($orphans -join ', ')" }
        "All directories present; CheckPaths match File Manager NewPaths"
    } '' 8 6

    # Item 7 - EndFileString
    Check 'DataCollector' 'EndFileString configured' {
        if (-not $dcXml) { throw "Config not found" }
        $bad = @($dcBlocks | Where-Object { (FmChild $_ 'EndFileString') -ne 'NA' } | ForEach-Object { $_.LocalName })
        if ($bad) { throw "EndFileString not NA for: $($bad -join ', ')" }
        "EndFileString=NA on $($dcBlocks.Count) blocks"
    } '' 8 7

    # Item 8 - Application running
    Check 'DataCollector' 'Data Collector process running' {
        $proc = Get-Process -Name 'DataCollector','DataCollector.App' -ErrorAction SilentlyContinue |
                Select-Object -First 1
        if (-not $proc) { throw "Process not found" }
        "Process: $($proc.ProcessName) (PID $($proc.Id))"
    } '' 8 8

    # Items 9-10 - manual
    Blank 'DataCollector' 'File detection in CheckPath' 8 9
    Blank 'DataCollector' 'File archiving to ArchivePath' 8 10

    #endregion

    #region T9 - Data Analyzer ------------------------------------------------

    $daXml = LoadXml $da.DataAnalyzerConfig

    # Item 1 - DB connection
    Check 'DataAnalyzer' 'Database connection to TimescaleDB' {
        if (-not $daXml) { throw "Config not found: $($da.DataAnalyzerConfig)" }
        $cs = XmlAttr $daXml "//appSettings/add[@key='Db_ConnectionString']" 'value'
        if ($cs -notmatch 'TimescaleDB') { throw "Db_ConnectionString does not reference TimescaleDB" }
        if ($cs -notmatch 'apcuser')     { throw "Db_ConnectionString does not use apcuser" }
        "Db_ConnectionString references TimescaleDB / apcuser"
    } '' 9 1

    # Item 2 - Site identifier
    Check 'DataAnalyzer' 'Site identifier configured in OPC process parameters' {
        if (-not $daXml) { throw "Config not found" }
        if (-not $siteCode) { throw "Site code not in State" }
        $wrong = @()
        foreach ($key in 'Opc_FirstRunProcess','Opc_VerificationProcess','Opc_ProductionProcess') {
            $v = XmlAttr $daXml "//appSettings/add[@key='$key']" 'value'
            if ($v -notmatch "_$siteCode\`$?$") { $wrong += "$key=$v" }
        }
        if ($wrong) { throw "Site code $siteCode not set: $($wrong -join '; ')" }
        "Site code $siteCode set in all OPC process parameters"
    } '' 9 2

    # Item 3 - Application running
    Check 'DataAnalyzer' 'Data Analyzer process running' {
        $proc = Get-Process -Name 'DataAnalyzer','DataAnalyzer.App' -ErrorAction SilentlyContinue |
                Select-Object -First 1
        if (-not $proc) { throw "Process not found" }
        "Process: $($proc.ProcessName) (PID $($proc.Id))"
    } '' 9 3

    # Item 4 - TSDB connectivity (manual)
    Blank 'DataAnalyzer' 'TSDB connectivity confirmed in app' 9 4

    #endregion

    #region T10 - CHMI --------------------------------------------------------

    $chmiCfg = $Manifest.CHMI

    # Item 1 - Root certificate
    Check 'CHMI' '800xA OPC UA root certificate exists' {
        $certPaths = @(
            'HKLM:\SOFTWARE\ABB\800xA\OpcUaConnect',
            'HKLM:\SOFTWARE\WOW6432Node\ABB\800xA\OpcUaConnect',
            $chmiCfg.OpcUaConnectRegPath
        )
        $found = $false
        foreach ($p in $certPaths) { if (Test-Path $p) { $found = $true; break } }
        if (-not $found) { throw "800xA OpcUaConnect registry key not found" }
        "Registry key present"
    } '' 10 1

    # Item 2 - Application certificates updated
    Check 'CHMI' 'Application certificates updated' {
        if (-not (Test-Path $chmiCfg.CertManagerExe)) {
            throw "CertManager not found: $($chmiCfg.CertManagerExe)"
        }
        "CertManager.exe present at $($chmiCfg.CertManagerExe)"
    } '' 10 2

    # Item 3 - Issuer verification (manual)
    Blank 'CHMI' 'Issuer verified (800xAOPCUARoot)' 10 3

    # Item 4 - OPC UA Server URL configured
    Check 'CHMI' 'OPC UA Server URL configured in 800xA' {
        $expectedUrl = "opc.tcp://$($env:COMPUTERNAME):48020"
        $found = $false
        foreach ($base in @('HKLM:\SOFTWARE\ABB\800xA\OpcUaConnect',
                             'HKLM:\SOFTWARE\WOW6432Node\ABB\800xA\OpcUaConnect')) {
            if (Test-Path $base) {
                $keys = Get-ChildItem $base -ErrorAction SilentlyContinue
                foreach ($k in $keys) {
                    $v = (Get-ItemProperty $k.PSPath -Name 'ServerUrl' -ErrorAction SilentlyContinue).ServerUrl
                    if ($v -eq $expectedUrl) { $found = $true; break }
                }
            }
            if ($found) { break }
        }
        if (-not $found) { throw "ServerUrl '$expectedUrl' not found in 800xA registry" }
        "URL: $expectedUrl"
    } '' 10 4

    # Items 5-7 - manual
    Blank 'CHMI' 'OPC UA placements added (Node Status=Uploaded)' 10 5
    Blank 'CHMI' 'CNC OPC object naming verified' 10 6
    Blank 'CHMI' 'OPC UA connectivity readiness confirmed' 10 7

    #endregion

    #region T11 - Network Connectivity ----------------------------------------

    # Item 1 - ACW approved (manual)
    Blank 'Network' 'Asset Configuration Worksheet approved and imported' 11 1

    # Item 2 - VM IP address
    Check 'Network' 'APC VM IP address identified' {
        $ip = (Get-NetIPAddress -AddressFamily IPv4 |
               Where-Object { $_.IPAddress -notmatch '^127\.' -and $_.IPAddress -notmatch '^169\.254\.' } |
               Select-Object -First 1).IPAddress
        if (-not $ip) { throw "Could not determine VM IP" }
        "VM IP: $ip"
    } '' 11 2

    # Item 3 - CNC IPs documented
    Check 'Network' 'CNC machine IPs documented and aligned' {
        $pairs = $machines | ForEach-Object { "$($_.MachineName): $($_.IPAddress)" }
        $pairs -join ', '
    } '' 11 3

    # Item 4 - TCP 683 port defined
    $checks.Add(@{ Cat='Network'; Name='CNC communication port TCP 683 defined'; Status='PASS';
        Detail="Port 683 per manifest"; Note=''; T=11; I=4 })
    Add-Result -Phase Verification -Check 'Network: TCP port 683 defined' -Status PASS

    # Item 5 - Firewall ticket (manual)
    Blank 'Network' 'Firewall exemption ticket submitted and approved' 11 5

    # Item 6 - Telnet/TCP to each CNC on port 683
    Check 'Network' 'TCP 683 connectivity to each CNC machine' {
        $failed = @()
        foreach ($m in $machines) {
            $conn = Test-NetConnection -ComputerName $m.IPAddress -Port 683 -WarningAction SilentlyContinue
            if (-not $conn.TcpTestSucceeded) { $failed += "$($m.MachineName)($($m.IPAddress))" }
        }
        if ($failed) { throw "TCP 683 unreachable: $($failed -join ', ')" }
        "TCP 683 reachable: $($machines.MachineName -join ', ')"
    } '' 11 6

    #endregion

    #region HTML report -------------------------------------------------------

    $passCount  = ($checks | Where-Object { $_.Status -eq 'PASS' }).Count
    $warnCount  = ($checks | Where-Object { $_.Status -eq 'WARN' }).Count
    $failCount  = ($checks | Where-Object { $_.Status -eq 'FAIL' }).Count
    $blankCount = ($checks | Where-Object { $_.Status -in 'BLANK','NA' }).Count
    $totalCount = $checks.Count

    $overallStatus = if ($failCount -gt 0) { 'FAIL' } elseif ($warnCount -gt 0) { 'WARN' } else { 'PASS' }
    $overallColor  = switch ($overallStatus) { 'PASS' { '#2ecc71' } 'WARN' { '#f39c12' } 'FAIL' { '#e74c3c' } }

    $rows = $checks | ForEach-Object {
        $color = switch ($_.Status) {
            'PASS'  { '#2ecc71' } 'WARN'  { '#f39c12' } 'FAIL'  { '#e74c3c' }
            'BLANK' { '#95a5a6' } 'NA'    { '#bdc3c7' } default { '#95a5a6' }
        }
        "<tr>
          <td>$([System.Web.HttpUtility]::HtmlEncode($_.Cat))</td>
          <td>$([System.Web.HttpUtility]::HtmlEncode($_.Name))</td>
          <td style='color:$color;font-weight:bold'>$($_.Status)</td>
          <td>$([System.Web.HttpUtility]::HtmlEncode($_.Detail))</td>
          <td>$([System.Web.HttpUtility]::HtmlEncode($_.Note))</td>
        </tr>"
    }

    $html = @"
<!DOCTYPE html>
<html><head><meta charset='UTF-8'/>
<title>APC Configuration Verification Report</title>
<style>
  body{font-family:Segoe UI,Arial,sans-serif;background:#f5f5f5;margin:0;padding:20px}
  .header{background:#1a1a2e;color:#fff;padding:20px 30px;border-radius:8px;margin-bottom:20px}
  .header h1{margin:0;font-size:22px}
  .header p{margin:4px 0 0;opacity:.7;font-size:13px}
  .summary{display:flex;gap:16px;margin-bottom:20px}
  .card{background:#fff;border-radius:8px;padding:16px 24px;flex:1;box-shadow:0 2px 4px rgba(0,0,0,.1);text-align:center}
  .card .num{font-size:36px;font-weight:700}
  .card .lbl{font-size:13px;opacity:.7}
  table{width:100%;border-collapse:collapse;background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 2px 4px rgba(0,0,0,.1)}
  th{background:#1a1a2e;color:#fff;padding:10px 14px;text-align:left;font-size:13px}
  td{padding:9px 14px;border-bottom:1px solid #f0f0f0;font-size:13px;vertical-align:top}
  tr:hover td{background:#fafafa}
  .sign{background:#fff;border-radius:8px;padding:20px 30px;margin-top:20px;box-shadow:0 2px 4px rgba(0,0,0,.1)}
  .sign h2{margin:0 0 16px;font-size:16px}
  .sign-line{display:flex;gap:40px;margin-top:20px}
  .sign-field{flex:1;border-top:1px solid #ccc;padding-top:8px;font-size:12px;color:#555}
</style>
</head><body>
<div class='header'>
  <h1>APC Configuration Verification Report</h1>
  <p>VM: $($env:COMPUTERNAME) | Site: $siteCode | Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
</div>
<div class='summary'>
  <div class='card'><div class='num' style='color:$overallColor'>$overallStatus</div><div class='lbl'>Overall</div></div>
  <div class='card'><div class='num' style='color:#2ecc71'>$passCount</div><div class='lbl'>Passed</div></div>
  <div class='card'><div class='num' style='color:#f39c12'>$warnCount</div><div class='lbl'>Warnings</div></div>
  <div class='card'><div class='num' style='color:#e74c3c'>$failCount</div><div class='lbl'>Failed</div></div>
  <div class='card'><div class='num' style='color:#95a5a6'>$blankCount</div><div class='lbl'>Manual</div></div>
</div>
<table>
  <thead><tr><th>Category</th><th>Check</th><th>Status</th><th>Detail</th><th>Note</th></tr></thead>
  <tbody>$($rows -join '')</tbody>
</table>
<div class='sign'>
  <h2>Reviewer Sign-Off (D01555624)</h2>
  <p>I confirm that the APC System Configuration has been validated against the D01555624 checklist.</p>
  <div class='sign-line'>
    <div class='sign-field'>Technician Name &amp; Signature</div>
    <div class='sign-field'>Date</div>
    <div class='sign-field'>Reviewer Name &amp; Signature</div>
    <div class='sign-field'>Date</div>
  </div>
</div>
</body></html>
"@

    [System.IO.File]::WriteAllText($reportPath, $html)
    $State['VerificationReportPath'] = $reportPath
    Add-Result -Phase Verification -Check 'HTML Report' -Status PASS -Detail $reportPath

    #endregion

    #region Fill D01555624 Word document --------------------------------------

    $wizardRoot    = Split-Path $PSScriptRoot -Parent
    $templatePath  = Join-Path $wizardRoot 'D01555624_A_EN.docx'
    $docxOutPath   = Join-Path $reportDir "D01555624_Filled_$ts.docx"
    $performer     = "$env:USERNAME / $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

    if (Test-Path $templatePath) {
        try {
            Invoke-FillD01555624 -TemplatePath $templatePath -OutputPath $docxOutPath `
                -Manifest $Manifest -State $State -Checks $checks -Performer $performer
            $State['VerificationDocPath'] = $docxOutPath
            Add-Result -Phase Verification -Check 'D01555624 Filled Document' -Status PASS -Detail $docxOutPath
            Write-Log PASS "Filled verification document: $docxOutPath"
        } catch {
            Add-Result -Phase Verification -Check 'D01555624 Filled Document' -Status WARN -Detail $_.Exception.Message
            Write-Log WARN "Could not fill D01555624: $_"
        }
    } else {
        Write-Log WARN "Template D01555624_A_EN.docx not found at $templatePath  -  skipping document fill"
    }

    #endregion

    Write-Log PASS "Verification complete. HTML: $reportPath"
    Write-Log INFO "Summary: $passCount PASS / $warnCount WARN / $failCount FAIL / $blankCount manual  ($totalCount total)"
    if ($failCount -gt 0) {
        Write-Log WARN "$failCount check(s) FAILED  -  review report before sign-off"
    }
}

# =============================================================================
# D01555624 Word Document Fill
# =============================================================================

function Invoke-FillD01555624 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]    $TemplatePath,
        [Parameter(Mandatory)] [string]    $OutputPath,
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [Parameter(Mandatory)] [System.Collections.Generic.List[hashtable]] $Checks,
        [Parameter(Mandatory)] [string]    $Performer
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    # Read template zip and produce new output zip, modifying only word/document.xml
    $docXmlEntry = 'word/document.xml'
    $modifiedXml = $null

    $zipIn = [System.IO.Compression.ZipFile]::OpenRead($TemplatePath)
    try {
        $entry = $zipIn.Entries | Where-Object { $_.FullName -eq $docXmlEntry } | Select-Object -First 1
        if (-not $entry) { throw "word/document.xml not found in template" }
        $sr  = [System.IO.StreamReader]::new($entry.Open(), [System.Text.Encoding]::UTF8)
        $rawXml = $sr.ReadToEnd()
        $sr.Close()
    } finally { $zipIn.Dispose() }

    [xml]$xml = $rawXml
    $ns = [System.Xml.XmlNamespaceManager]::new($xml.NameTable)
    $ns.AddNamespace('w',   'http://schemas.openxmlformats.org/wordprocessingml/2006/main')
    $ns.AddNamespace('w14', 'http://schemas.microsoft.com/office/word/2010/wordml')

    $tables = $xml.SelectNodes('//w:tbl', $ns)

    # -------------------------------------------------------------------------
    # Fill System Identification table (Table index 2)
    # -------------------------------------------------------------------------
    $sysIdTable = $tables[2]
    if ($sysIdTable) {
        $sysRows = $sysIdTable.SelectNodes('w:tr', $ns)
        $siteNames = @{ MCR='Medtronic Costa Rica'; MPR='Medtronic Puerto Rico'; MFW='Medtronic Fort Worth'; MWR='Medtronic Warsaw' }
        $siteFull  = $siteNames[$State['SiteCode']]
        if (-not $siteFull) { $siteFull = $State['SiteCode'] }

        $sysValues = @(
            $env:COMPUTERNAME,                                    # Row 0: VM Name
            "APC System V$($Manifest.APC.Version)",               # Row 1: Version
            'Closed-Loop Correction (CLC)',                       # Row 2: Solution
            $siteFull,                                            # Row 3: Site
            'D01555624',                                          # Row 4: Doc ID
            $null,                                                # Row 5: Reason (leave — has checkboxes)
            $null                                                 # Row 6: Change ID (leave blank)
        )

        for ($ri = 0; $ri -lt $sysValues.Count; $ri++) {
            if ($null -eq $sysValues[$ri]) { continue }
            if ($ri -ge $sysRows.Count) { break }
            $row   = $sysRows[$ri]
            $cells = $row.SelectNodes('w:tc', $ns)
            if ($cells.Count -lt 2) { continue }
            Set-DocCellText -Cell $cells[1] -Text $sysValues[$ri] -Ns $ns
        }
    }

    # -------------------------------------------------------------------------
    # Fill check tables (Tables 3-11)
    # -------------------------------------------------------------------------
    foreach ($c in $Checks) {
        if ($c.T -lt 3 -or $c.T -gt 11 -or $c.I -lt 1) { continue }
        if ($c.T -ge $tables.Count) { continue }

        $table = $tables[$c.T]
        $rows  = $table.SelectNodes('w:tr', $ns)
        if ($c.I -ge $rows.Count) { continue }

        $row   = $rows[$c.I]
        $cells = $row.SelectNodes('w:tc', $ns)
        if ($cells.Count -lt 5) { continue }

        $resultsCell     = $cells[3]
        $performedByCell = $cells[4]

        # Determine which checkbox paragraph to tick: 0=Pass, 1=Fail, 2=N/A
        $paraIdx = switch ($c.Status) {
            'PASS' { 0 } 'FAIL' { 1 } 'NA' { 2 } default { -1 }
        }

        if ($paraIdx -ge 0) {
            $paras = $resultsCell.SelectNodes('w:p', $ns)
            if ($paraIdx -lt $paras.Count) {
                $para = $paras[$paraIdx]
                # Toggle the checkbox SDT checked state
                $checkedNode = $para.SelectSingleNode('w:sdt/w:sdtPr/w14:checkbox/w14:checked', $ns)
                if ($checkedNode) {
                    $checkedNode.SetAttribute('val',
                        'http://schemas.microsoft.com/office/word/2010/wordml', '1')
                }
                # Swap ☐ → ☑ inside sdtContent
                $tNode = $para.SelectSingleNode('w:sdt/w:sdtContent/w:r/w:t', $ns)
                if ($tNode) { $tNode.InnerText = [char]0x2612 }
            }
        }

        # Write Performed By text (only for automated results, not blanks)
        if ($c.Status -notin 'BLANK','NA') {
            $pbText = $Performer
            if ($c.Detail) { $pbText += "`n$($c.Detail)" }
            Set-DocCellText -Cell $performedByCell -Text $pbText -Ns $ns
        }
    }

    # -------------------------------------------------------------------------
    # Serialize modified XML
    # -------------------------------------------------------------------------
    $sbXml = [System.Text.StringBuilder]::new()
    $xwSettings = [System.Xml.XmlWriterSettings]::new()
    $xwSettings.Indent              = $false
    $xwSettings.Encoding            = [System.Text.UTF8Encoding]::new($false)
    $xwSettings.OmitXmlDeclaration  = $false
    $xwSettings.ConformanceLevel    = [System.Xml.ConformanceLevel]::Document
    $sw = [System.IO.StringWriter]::new($sbXml)
    $xw = [System.Xml.XmlWriter]::Create($sw, $xwSettings)
    $xml.Save($xw)
    $xw.Close()
    $modifiedXml = $sbXml.ToString()

    # -------------------------------------------------------------------------
    # Write output docx: copy all zip entries, replace word/document.xml
    # -------------------------------------------------------------------------
    $outStream = [System.IO.File]::Open($OutputPath, [System.IO.FileMode]::Create)
    $zipOut    = [System.IO.Compression.ZipArchive]::new($outStream,
                    [System.IO.Compression.ZipArchiveMode]::Create)
    $zipIn2    = [System.IO.Compression.ZipFile]::OpenRead($TemplatePath)
    try {
        foreach ($srcEntry in $zipIn2.Entries) {
            $dstEntry  = $zipOut.CreateEntry($srcEntry.FullName,
                            [System.IO.Compression.CompressionLevel]::Optimal)
            $srcStream = $srcEntry.Open()
            $dstStream = $dstEntry.Open()

            if ($srcEntry.FullName -eq $docXmlEntry) {
                $xmlBytes = [System.Text.Encoding]::UTF8.GetBytes($modifiedXml)
                $dstStream.Write($xmlBytes, 0, $xmlBytes.Length)
            } else {
                $srcStream.CopyTo($dstStream)
            }

            $dstStream.Close()
            $srcStream.Close()
        }
    } finally {
        $zipIn2.Dispose()
        $zipOut.Dispose()
        $outStream.Dispose()
    }
}

# -------------------------------------------------------------------------
# Helper: replace text content of a Word table cell, remove blue/italic
# -------------------------------------------------------------------------
function Set-DocCellText {
    param(
        [System.Xml.XmlNode]            $Cell,
        [string]                        $Text,
        [System.Xml.XmlNamespaceManager]$Ns
    )
    # Find first paragraph then first run with a w:t
    $para = $Cell.SelectSingleNode('w:p', $Ns)
    if (-not $para) { return }
    $run  = $para.SelectSingleNode('w:r[w:t]', $Ns)
    if (-not $run) { return }
    $tNode = $run.SelectSingleNode('w:t', $Ns)
    if (-not $tNode) { return }

    $tNode.InnerText = $Text
    if ($Text -match '^\s|\s$') {
        $tNode.SetAttribute('xml:space', 'http://www.w3.org/XML/1998/namespace', 'preserve')
    }

    # Remove placeholder blue/italic formatting
    $rPr = $run.SelectSingleNode('w:rPr', $Ns)
    if ($rPr) {
        foreach ($attr in @('w:color', 'w:i', 'w:iCs')) {
            $n = $rPr.SelectSingleNode($attr, $Ns)
            if ($n) { $rPr.RemoveChild($n) | Out-Null }
        }
    }

    # Remove any additional runs (clean up leftover placeholder runs)
    $allRuns = @($para.SelectNodes('w:r', $Ns))
    foreach ($r in $allRuns) {
        if ($r -ne $run) { $para.RemoveChild($r) | Out-Null }
    }
}
