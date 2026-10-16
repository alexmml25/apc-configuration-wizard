#Requires -Version 5.1
<#
.SYNOPSIS
    Step 9 - Configure DOC instance XML files for each DOC installation.
.DESCRIPTION
    For each DOC instance n (1..DOCCount), paired with CNC n (the DOC-assigned machine):
      DOC_II\DocDb.xml                     verify ConnectionString (localhost / TimescaleDB / apcuser)
      DOC_II\DOC_II.xml                    CSVFileOutputPath = <SINC staging>\CNC{n}\<CSVFileNamePattern>
      DOC_II\Plugins\PartLookup.xml        verify ConnectionString; LoadMatrixRevision = MAX
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
        [void](Save-FileBackup -Path $Path -Stamp $ts -State $State)
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
        Write-Log INFO "DOC $n -> CNC$n ($($m.MachineName)) at $($paths.BaseDir)"

        if (-not (Test-Path $paths.BaseDir)) {
            Add-Result -Phase DOC -Check "DOC $n install folder" -Status FAIL -Detail "Not found: $($paths.BaseDir)"
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

    #region -- start each DOC and trust it in deviceWise (as Step 10 does for the data apps) ----------------
    # DOC reads its XML at start, so it is (re)started after the changes. Its OPC UA plugin (Plugins\OPC UA\
    # DocOpcUa.xml) connects to deviceWise opc.tcp://localhost:48020 and only accepts the server certificate
    # named in <CertificateSubject>; the shipped value (CN=Devicewise/UA Server ...) is not this gateway's.
    # Its client certificate 'OPC-UA-API' is per user, shared by all DOCs: %LOCALAPPDATA%\Medtronic\own|trusted
    # (VM 2026-10-15), made on the first connection - so on a first run DOC is started, trusted, then restarted.
    if ($State['SandboxRoot']) {
        Write-Log INFO "Test mode: DOC instances are not started"
    } elseif ($docCfg.PSObject.Properties['StartInstances'] -and $docCfg.StartInstances -eq $false) {
        Write-Log INFO "DOC.StartInstances is false: DOC instances are not started"
    } else {
        $pki     = ([string]$Manifest.DeviceWise.GatewayInstallDir).TrimEnd('\') + '\staging\uaserver\pkiserver'
        $wait    = if ($docCfg.PSObject.Properties['CertWaitSeconds']) { [int]$docCfg.CertWaitSeconds } else { 60 }
        # per user = the service account DOC runs as (user, 2026-10-15), resolved from its profile
        $svc     = Get-AppAccount -Manifest $Manifest -State $State
        $userDir = ([string]$docCfg.UserCertStore).Replace('%LOCALAPPDATA%', (Get-AccountLocalAppData -Account $svc))
        $userDir = [Environment]::ExpandEnvironmentVariables($userDir)
        Write-Log INFO "DOC OPC UA certificate store ($(if ($svc) { $svc } else { 'this user' })): $userDir" 
        $store   = @{ Own = (Join-Path $userDir 'own\certs'); Trusted = (Join-Path $userDir 'trusted\certs') }
        $haveCert = { [bool](Get-ChildItem -LiteralPath $store.Own -Filter '*.der' -File -ErrorAction SilentlyContinue) }

        # 1. the deviceWise server certificate subject DOC must accept
        $srvFile = Get-ChildItem -LiteralPath (Join-Path $pki 'own\certs') -Filter '*.der' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        $srvSubject = if ($srvFile) { try { (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $srvFile.FullName).Subject } catch { '' } }
        foreach ($m in $machines) {
            $n = [int]$m.CNCIndex
            $base  = ([string]$docCfg.BasePath).Replace('{N}', "$n")
            $uaXml = Join-Path $base ([string]$docCfg.OpcUaXml)
            if (-not (Test-Path -LiteralPath $uaXml)) { Add-Result -Phase DOC -Check "DOC ${n}: OPC UA server certificate subject" -Status WARN -Detail "Not found: $uaXml"; continue }
            if (-not $srvSubject) { Add-Result -Phase DOC -Check "DOC ${n}: OPC UA server certificate subject" -Status WARN -Detail "deviceWise server certificate not found in $pki\own\certs"; continue }
            $doc  = New-Object System.Xml.XmlDocument
            $doc.LoadXml([System.IO.File]::ReadAllText($uaXml))
            $node = $doc.SelectSingleNode('//CertificateSubject')
            if (-not $node) { Add-Result -Phase DOC -Check "DOC ${n}: OPC UA server certificate subject" -Status WARN -Detail "No <CertificateSubject> in $uaXml"; continue }
            if ($node.InnerText -eq $srvSubject) {
                Add-Result -Phase DOC -Check "DOC ${n}: OPC UA server certificate subject" -Status PASS -Detail "Already $srvSubject"
            } else {
                [void](Save-FileBackup -Path $uaXml -Stamp $ts -State $State)
                $old = $node.InnerText; $node.InnerText = $srvSubject
                Save-Xml $doc $uaXml
                Add-Result -Phase DOC -Check "DOC ${n}: OPC UA server certificate subject" -Status PASS -Detail "$srvSubject (was '$old')"
            }
        }

        # 2. trust both ways when DOC already has its certificate (a re-run), so the start below connects at once
        $trusted = $false
        if (& $haveCert) {
            $t = Set-DataAppDeviceWiseTrust -AppDir $userDir -PkiServer $pki -OwnCertDir $store.Own -TrustedCertDir $store.Trusted
            Add-Result -Phase DOC -Check "DOC: deviceWise OPC UA trust (OPC-UA-API, $userDir)" -Status $(if ($t.Ok) { 'PASS' } else { 'FAIL' }) -Detail $t.Detail
            $trusted = $t.Ok
        }

        # 3. (re)start every DOC; close its start-up message boxes (watched at least BoxWatchSeconds) and wait
        #    for the certificate on a first run
        $known  = @($docCfg.KnownStartupMessages)
        $titles = @($docCfg.KnownStartupDialogTitles | Where-Object { $_ })
        $boxes  = @{ 0 = @() }                  # 0: service-notification boxes (owner csrss, DOC instance unknown)
        $stuckBoxes = New-Object System.Collections.Generic.List[string]
        $minWatch = if ($docCfg.PSObject.Properties['BoxWatchSeconds']) { [int]$docCfg.BoxWatchSeconds } else { 20 }
        $watch = {
            param([int]$MinSeconds, [int]$MaxSeconds, [scriptblock]$Done)
            $t0 = Get-Date
            do {
                foreach ($mm in $machines) {
                    $p = Get-DOCProcess -Manifest $Manifest -Instance ([int]$mm.CNCIndex)
                    if ($p) { $boxes[[int]$mm.CNCIndex] += @(Close-ProcessMessageBoxes -ProcessId $p.Id) }
                }
                if ($titles) {
                    $tb = Close-TitledMessageBoxes -Titles $titles
                    $boxes[0] += @($tb.Closed) + @($tb.Stuck)    # a box still closing is retried on the next pass
                }
                $el = ((Get-Date) - $t0).TotalSeconds
                $finished = $el -ge $MinSeconds -and (& $Done)
                if (-not $finished) { Start-Sleep -Seconds 3 }
            } while (-not $finished -and $el -lt $MaxSeconds)
        }
        # every DOC holds a connection to the deviceWise OPC UA server: the goal of all this (DOC waits in its
        # PartLookup_DB box until OK, so boxes are closed until then - they come at different times per DOC)
        $opcPort = [int]$Manifest.DeviceWise.OpcUaEndpointPort
        $connectWait = if ($docCfg.PSObject.Properties['ConnectWaitSeconds']) { [int]$docCfg.ConnectWaitSeconds } else { 120 }
        $notConnected = {
            @($machines | Where-Object {
                $p = Get-DOCProcess -Manifest $Manifest -Instance ([int]$_.CNCIndex)
                -not $p -or -not @(Get-ProcessTcpConnections -ProcessId $p.Id | Where-Object { $_.RemotePort -eq $opcPort }).Count
            } | ForEach-Object { [int]$_.CNCIndex })
        }
        foreach ($m in $machines) {
            $n = [int]$m.CNCIndex
            $r = Restart-DOCInstance -Manifest $Manifest -Instance $n
            Add-Result -Phase DOC -Check "DOC ${n}: started" -Status $(if ($r.Ok) { 'PASS' } else { 'FAIL' }) -Detail $r.Detail
            $boxes[$n] = @()
        }
        if ($trusted) { & $watch $minWatch $connectWait { -not (& $notConnected).Count } }
        else          { & $watch $minWatch ([Math]::Max($wait, $minWatch)) { & $haveCert } }
        # 4. first run: DOC made its certificate on this start - trust it, then restart DOC so it connects
        if (-not $trusted) {
            if (& $haveCert) {
                $t = Set-DataAppDeviceWiseTrust -AppDir $userDir -PkiServer $pki -OwnCertDir $store.Own -TrustedCertDir $store.Trusted
                Add-Result -Phase DOC -Check "DOC: deviceWise OPC UA trust (OPC-UA-API, $userDir)" -Status $(if ($t.Ok) { 'PASS' } else { 'FAIL' }) -Detail $t.Detail
                if ($t.Ok) {
                    foreach ($m in $machines) {
                        $r = Restart-DOCInstance -Manifest $Manifest -Instance ([int]$m.CNCIndex)
                        Add-Result -Phase DOC -Check "DOC $($m.CNCIndex): restarted after trust" -Status $(if ($r.Ok) { 'PASS' } else { 'FAIL' }) -Detail $r.Detail
                    }
                    & $watch $minWatch $connectWait { -not (& $notConnected).Count }
                }
            } else {
                Add-Result -Phase DOC -Check "DOC: deviceWise OPC UA trust" -Status WARN `
                    -Detail "DOC made no OPC UA certificate in $($store.Own) within $wait s - check DOC's OPC connection, then re-run Step 9"
            }
        }
        $down = @(& $notConnected)
        foreach ($m in $machines) {
            $n = [int]$m.CNCIndex
            Add-Result -Phase DOC -Check "DOC ${n}: connected to deviceWise OPC UA" -Status $(if ($down -contains $n) { 'WARN' } else { 'PASS' }) `
                -Detail $(if ($down -contains $n) { "no connection to :$opcPort after $connectWait s - check for an open DOC message box and DOC-$n\Log" } else { "connection to :$opcPort" })
        }
        foreach ($n in @($boxes.Keys | Sort-Object)) {
            foreach ($b in ($boxes[$n] | Select-Object -Unique)) {
                $isKnown = @($known | Where-Object { $_ -and $b -like "*$_*" }).Count -gt 0
                $who = if ($n -eq 0) { 'DOC' } else { "DOC ${n}" }
                Add-Result -Phase DOC -Check "${who}: start-up message closed" -Status $(if ($isKnown) { 'PASS' } else { 'WARN' }) `
                    -Detail "$b$(if ($isKnown) { ' (expected while the database has no PartLookup data)' })"
            }
        }
        # only a box still on screen at the end counts (one closing during the 2 s check is not stuck)
        if ($titles) { $final = Close-TitledMessageBoxes -Titles $titles; foreach ($x in $final.Stuck) { $stuckBoxes.Add($x) } }
        foreach ($b in ($stuckBoxes | Select-Object -Unique)) {
            Add-Result -Phase DOC -Check "DOC: start-up message still open" -Status WARN `
                -Detail "$b - Windows did not let the wizard press OK (system-owned box); press OK on it so DOC continues"
        }

    }
    #endregion

    Write-Log PASS "DOC XML configuration complete ($($machines.Count) instance(s))."
    Write-Log INFO "Backups (.$ts.bak) created alongside each modified XML. Review and delete after validation."
}
