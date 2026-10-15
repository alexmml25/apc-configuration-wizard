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
. (Join-Path $PSScriptRoot 'ABB800xA.ps1')
. (Join-Path $PSScriptRoot 'DeviceWise.ps1')
. (Join-Path $PSScriptRoot '02-TimescaleDB.ps1')   # pgAdmin / pgpass helpers for T4 items 7-8

function Invoke-Verification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [switch]$NonInteractive
    )

    Write-Log STEP "System Verification and Report Generation"

    $machines  = Get-AssignedCNCs -State $State -Manifest $Manifest   # CNC n = DOC instance n
    $dw        = $Manifest.DeviceWise
    $pg        = $Manifest.PostgreSQL
    $da        = $Manifest.DataApps
    $docCfg    = $Manifest.DOC
    $cncPdm    = $Manifest.CNCnetPDM
    $siteCode  = $State['SiteCode']
    $docCount  = [int]$State['DOCCount']

    $reportDir  = Get-RunDir -State $State -Name Reports
    $ts         = Get-Date -Format 'yyyyMMdd-HHmmss'
    $reportPath = Join-Path $reportDir "APC_ConfigReport_$ts.html"

    $checks = [System.Collections.Generic.List[hashtable]]::new()

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

    function PsqlQuery {
        param([string]$Query, [string]$Db = 'TimescaleDB')
        $bin = Join-Path $pg.BinDir 'psql.exe'
        if (-not (Test-Path $bin)) { throw "psql.exe not found at $bin" }
        # -w: never prompt. Without a password psql waited for one on the console and Step 13 hung
        # (wizard run 2026-10-14). Logs in as apcuser (a superuser, so the catalog queries work) with
        # this run's apcuser password.
        $pgPwd = ''
        if ($State.ContainsKey('APCUserPassword') -and $State['APCUserPassword'] -is [System.Security.SecureString]) {
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($State['APCUserPassword'])
            try { $pgPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        }
        $env:PGPASSWORD = $pgPwd
        try { $result = & $bin -h localhost -p $pg.DefaultPort -U $pg.LocalUser -d $Db -w -t -A -c $Query 2>&1 }
        finally { $env:PGPASSWORD = ''; $pgPwd = '' }
        $text = ($result -join "`n").Trim()
        if ($text -match 'no password supplied|password authentication failed') {
            throw "psql could not log in as $($pg.LocalUser): $(if ($text -match 'no password') { 'no password in this run (enter the apcuser password in the wizard)' } else { 'password rejected' })"
        }
        return $text
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
    # No API: the checks read the gateway's own files and databases (DeviceWise.ps1, read-only), its OPC UA
    # server (CNCAsset / CNCType) and the dwcore TCP connection to CNCnetPDM - the same sources Steps 4-8 use.

    $paths   = Get-DwPaths -Manifest $Manifest
    $nodes   = @(1..[Math]::Max(1, $machines.Count) | ForEach-Object { "CNC$_" } | Select-Object -First $machines.Count)
    $pdmDir  = @($cncPdm.InstallDir, $cncPdm.FallbackDir) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    $pdmIni  = if ($pdmDir) { Join-Path $pdmDir $cncPdm.IniFile } else { $null }
    $clean   = { param($v) ([string]$v) -replace '[\x00-\x1F]', '' }   # persistence values carry a leading marker byte
    $devStates = $null; $uaSet = @{}; $licSet = @{}
    try { $devStates = Get-DwDeviceStates -Paths $paths } catch { }
    try { $uaSet  = Get-DwPersistence -Paths $paths -Group 'opcua_server_v3' } catch { }
    try { $licSet = Get-DwPersistence -Paths $paths -Group 'license.pool' } catch { }

    # Item 1 - Required packages installed (an installed package leaves dwcore\packages\<key>.xml)
    Check 'deviceWise' 'Required packages installed' {
        $missing = @($dw.Packages | Where-Object { -not (Test-Path (Join-Path $paths.Packages "$_.xml")) })
        if ($missing.Count) { throw "Not installed: $($missing -join ', ')" }
        "Installed: $($dw.Packages -join ', ')"
    } '' 3 1

    # Item 2 - License Client configured (DWUSER.db license.pool; a voucher = licence received)
    Check 'deviceWise' 'License Client configured' {
        if (-not $licSet.Count) { throw 'Cannot read the licence client settings (DWUSER.db)' }
        $addr = & $clean $licSet['client_server_addr']
        if ($addr -ne $dw.LicenseManagerHost) { throw "License Manager '$addr', expected $($dw.LicenseManagerHost)" }
        if ((& $clean $licSet['client_enabled']) -ne 'True') { throw 'License client not enabled' }
        if (-not (& $clean $licSet['voucher'])) { throw "No licence received from $addr yet" }
        "$($addr):$(& $clean $licSet['client_server_port']) - licence received"
    } '' 3 2

    # Item 3 - OPC UA tag definitions imported (the CNCn devices with their structures)
    Check 'deviceWise' 'OPC UA tag definitions imported' {
        if ($null -eq $devStates) { throw 'Cannot read the gateway devices (DWCORE.db)' }
        $missing = @($nodes | Where-Object { -not $devStates.ContainsKey($_) })
        if ($missing.Count) { throw "Devices missing: $($missing -join ', ')" }
        "Devices: $($nodes -join ', ')"
    } '' 3 3

    # Item 4 - OPC UA exposed devices
    Check 'deviceWise' "OPC UA exposed devices ($($nodes -join ', '))" {
        $list = @((& $clean $uaSet['device_list']) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $missing = @($nodes | Where-Object { $list -notcontains $_ })
        if ($missing.Count) { throw "Not exposed: $($missing -join ', ') (device_list: $($list -join ', '))" }
        "Exposed: $($list -join ', ')"
    } '' 3 4

    # Item 5 - OPC UA endpoint configuration (running, port, SOP security policies)
    Check 'deviceWise' 'OPC UA endpoint configuration' {
        $port = [int]$dw.OpcUaEndpointPort
        if ((& $clean $uaSet['bind_port']) -ne [string]$port) { throw "Port $(& $clean $uaSet['bind_port']), expected $port" }
        if ((& $clean $uaSet['enable']) -ne 'Yes' -or (& $clean $uaSet['status']) -ne 'Started') { throw 'OPC UA server not switched on' }
        if (-not (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)) { throw "Nothing listening on port $port" }
        $keys = @{ Basic128Rsa15 = 'security_basic128rsa15'; Basic256 = 'security_basic256'; Basic256Sha256 = 'security_basic256sha256'
                   Aes128Sha256RsaOeap = 'security_aes128sha256'; Aes256Sha256RsaPss = 'security_aes256sha256' }
        $wrong = @($keys.Keys | Where-Object { ((& $clean $uaSet[$keys[$_]]) -eq 'true') -ne (@($dw.OpcUaSecurityPolicies) -contains $_) })
        if ($wrong.Count) { throw "Security policies differ from the SOP: $($wrong -join ', ')" }
        "opc.tcp://$($env:COMPUTERNAME):$port listening; policies: $(@($dw.OpcUaSecurityPolicies) -join ', ')"
    } '' 3 5

    # Items 6-8 - CNCAsset and CNCType per CNC, read from the gateway's OPC UA server
    $uaSession = $null; $uaError = ''
    if ($machines.Count) { try { $uaSession = Open-DwUaSession -Manifest $Manifest } catch { $uaError = $_.Exception.Message } }
    try {
        for ($ci = 0; $ci -lt 3; $ci++) {
            $item = 6 + $ci
            $node = "CNC$($ci + 1)"
            if ($ci -lt $machines.Count) {
                $m = $machines[$ci]
                Check 'deviceWise' "CNCAsset / CNCType for $node" {
                    if (-not $uaSession) { throw "OPC UA read not possible: $uaError" }
                    $a = [string](Get-DwUaValue -Session $uaSession -Namespace $dw.OpcUaClient.Namespace -Path "$node.CNCAsset").Value
                    $t = [string](Get-DwUaValue -Session $uaSession -Namespace $dw.OpcUaClient.Namespace -Path "$node.CNCType").Value
                    if (-not $a -and -not $t) { throw 'Empty - the values are lost at every dwcore restart (known limitation); Steps 4-8 write them' }
                    if ($a -ne $m.MachineName -or $t -ne $m.CNCType) { throw "CNCAsset='$a', CNCType='$t'; expected '$($m.MachineName)' / '$($m.CNCType)'" }
                    "CNCAsset=$a, CNCType=$t"
                } '' 3 $item
            } else {
                NA 'deviceWise' "CNCAsset / CNCType for $node" "Machine $node not configured for this site" 3 $item
            }
        }
    } finally { if ($uaSession) { [void]$uaSession.Close() } }

    # Items 9-12 - CHMI / SINC projects and their triggers (DWCORE.db triggers.state 1 = Started / Loaded)
    $trig = @{}
    foreach ($proj in 'CHMI', 'SINC') { try { $trig[$proj] = Get-DwTriggerStates -Paths $paths -Project $proj } catch { $trig[$proj] = $null } }
    $projCheck = {
        param([string]$Proj)
        if ($null -eq $trig[$Proj]) { throw 'Cannot read the gateway triggers (DWCORE.db)' }
        if (-not $trig[$Proj].Count) { throw "No $Proj project / triggers in the gateway" }
        "$Proj project: $($trig[$Proj].Count) trigger(s)"
    }
    $startedCheck = {
        param([string]$Proj, [string[]]$Names)
        if ($null -eq $trig[$Proj]) { throw 'Cannot read the gateway triggers (DWCORE.db)' }
        $bad = @($Names | Where-Object { -not $trig[$Proj].ContainsKey($_) -or $trig[$Proj][$_] -ne 1 })
        if ($bad.Count) { throw "Not started: $(($bad | Select-Object -First 3) -join ', ')$(if ($bad.Count -gt 3) { " (+$($bad.Count - 3))" })" }
        "All $($Names.Count) $Proj components Started / Loaded"
    }
    Check 'deviceWise' 'CHMI project imported' { & $projCheck 'CHMI' } '' 3 9
    Check 'deviceWise' 'CHMI components Loaded and Started' {
        & $startedCheck 'CHMI' @(@($Manifest.CHMIComponents.Loaded) + @($Manifest.CHMIComponents.Started))
    } '' 3 10
    Check 'deviceWise' 'SINC project imported' { & $projCheck 'SINC' } '' 3 11
    Check 'deviceWise' 'SINC triggers Loaded and Started' {
        & $startedCheck 'SINC' @(@($Manifest.SINCComponents) + @($Manifest.SINCMasterResetComponents))
    } '' 3 12

    # Item 13 - SINC EMAIL_TO configured (default of the EMAIL_TO local variable of 0_DefaultConfiguration)
    Check 'deviceWise' 'SINC EMAIL_TO configured' {
        $x = Get-DwXml -Paths $paths -Table triggers -Name '0_DefaultConfiguration' -Project 'SINC'
        if (-not $x) { throw 'SINC/0_DefaultConfiguration not found' }
        $v = $x.SelectSingleNode("//VariableInfo[@name='EMAIL_TO']")
        $email = if ($v) { $v.GetAttribute('default') } else { '' }
        if (-not $email) { throw 'EMAIL_TO empty' }
        "EMAIL_TO: $email"
    } '' 3 13

    # Items 14-15 - CNC asset mapping and SINC settings. On the gateways the SOP's CNC_ASSET_Management and
    # CNC_Settings are one local table, CNC_SETTING (ASSET_NAME, alarm settings, CNC_ASSET, CNC_TYPE).
    $cncSetting = $null; $cncSettingError = ''
    try { $cncSetting = Get-DwLocalTable -Paths $paths -Table 'CNC_SETTING' } catch { $cncSettingError = $_.Exception.Message }
    $rowFor = { param($n) @($cncSetting.Rows | Where-Object { $_.ASSET_NAME -eq $n }) | Select-Object -First 1 }
    Check 'deviceWise' 'CNC asset mapping (CNC_SETTING: CNC_ASSET / CNC_TYPE)' {
        if (-not $cncSetting) { throw "CNC_SETTING not found$(if ($cncSettingError) { ": $cncSettingError" })" }
        $bad = foreach ($c in $machines) {
            $r = & $rowFor "CNC$($c.CNCIndex)"
            if (-not $r) { "CNC$($c.CNCIndex) has no row" }
            elseif ($r.CNC_ASSET -ne $c.MachineName -or $r.CNC_TYPE -ne $c.CNCType) { "CNC$($c.CNCIndex) = $($r.CNC_ASSET) / $($r.CNC_TYPE)" }
        }
        if (@($bad).Count) { throw "$(@($bad) -join '; ') (expected the Site DB machine name / type)" }
        "$(@($cncSetting.Rows).Count) row(s) in CNC_SETTING ($($cncSetting.Db))"
    } '' 3 14
    Check 'deviceWise' 'SINC alarm settings (CNC_SETTING)' {
        if (-not $cncSetting) { throw "CNC_SETTING not found$(if ($cncSettingError) { ": $cncSettingError" })" }
        $set = $Manifest.SINCDefaultSettings
        $bad = foreach ($c in $machines) {
            $r = & $rowFor "CNC$($c.CNCIndex)"
            if (-not $r) { continue }
            foreach ($k in 'ALARM_TAG', 'ALARM_PATH', 'WAIT_TIME', 'RETRY_COUNT') {
                if ([string]$r.$k -ne [string]$set.$k) { "CNC$($c.CNCIndex) $k = $($r.$k) (expected $($set.$k))" }
            }
            if ([double]$r.ALARM_VALUE -ne [double]$set.ALARM_VALUE) { "CNC$($c.CNCIndex) ALARM_VALUE = $($r.ALARM_VALUE)" }
        }
        if (@($bad).Count) { throw (@($bad) | Select-Object -First 3) -join '; ' }
        "Alarm $($set.ALARM_TAG) / $($set.ALARM_PATH), wait $($set.WAIT_TIME) ms, retry $($set.RETRY_COUNT)"
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
    $appAccount = Get-AppAccount -Manifest $Manifest -State $State
    $aclCheck   = $appAccount -and ($IsWindows -ne $false) -and (Get-Command Get-Acl -ErrorAction SilentlyContinue)
    if ($aclCheck) {
        foreach ($m in $machines) {
            $p = Join-Path $sincRoot "CNC$($m.CNCIndex)"
            if ((Test-Path $p) -and -not (Test-AppAccountModify $p $appAccount)) { $sincOk = $false; $sincMiss += "CNC$($m.CNCIndex) ($appAccount has no Modify)" }
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

    # Item 17 - CNCnetPDM Connected in deviceWise (dwcore's connection to CNCnetPDM's MTC Adapter port)
    $mtc = Test-DwCncnetpdmConnected -IniPath $pdmIni -WaitSec 30
    Check 'deviceWise' 'CNCnetPDM Connected in deviceWise' {
        if (-not $mtc.Connected) { throw "dwcore has no connection to CNCnetPDM (port $($mtc.Port)) - CNCnetPDM running? Step 8 run?" }
        "Connected (CNCnetPDM MTC Adapter port $($mtc.Port))"
    } '' 3 17

    # Item 18 - CNCnetPDM to deviceWise path mapping (CNCn_PATH: instance + '<DeviceNr> - <name>')
    Check 'deviceWise' 'CNCnetPDM to deviceWise path mapping' {
        $instance = if ($pdmDir) { Split-Path $pdmDir -Leaf } else { '' }
        $bad = foreach ($c in $machines) {
            $n = "CNC$($c.CNCIndex)_PATH"
            $x = Get-DwXml -Paths $paths -Table devices -Name $n
            if (-not $x) { "$n missing"; continue }
            $prop = { param($p) $node = $x.SelectSingleNode("//Property[@name='$p']"); if ($node) { $node.GetAttribute('value') } }
            $want = "$($c.DeviceNr) - $($c.PdmName)"
            if ((& $prop 'machine') -ne $want -or (& $prop 'instance') -ne $instance) { "$n = $(& $prop 'instance') / $(& $prop 'machine') (expected $instance / $want)" }
        }
        if (@($bad).Count) { throw @($bad) -join '; ' }
        "$($machines.Count) CNC path(s) mapped to $instance"
    } '' 3 18

    # Item 19 - MedtronicSU user exists (DWUSER.db users)
    Check 'deviceWise' "OPC UA user $($dw.OpcUaUser) exists" {
        $u = Invoke-DwDbQuery -Paths $paths -Database 'DWUSER.db' -Sql 'SELECT name FROM users WHERE name = ?' -Arguments @($dw.OpcUaUser)
        if (-not $u.Count) { throw "User $($dw.OpcUaUser) not found" }
        "User $($dw.OpcUaUser) present"
    } '' 3 19

    # Item 20 - External client certificate trusted (SOP 2.1.2.5). The gateway's OPC UA server keeps client
    # certificates as files: staging\uaserver\pkiserver\trusted\certs and ...\rejected (pending a Trust).
    $pki      = Join-Path $paths.Root 'staging\uaserver\pkiserver'
    $trusted  = @(Get-ChildItem (Join-Path $pki 'trusted\certs') -File -ErrorAction SilentlyContinue)
    $rejected = @(Get-ChildItem (Join-Path $pki 'rejected') -Recurse -File -ErrorAction SilentlyContinue)
    if ($rejected.Count) {
        $d = "Waiting for Trust (Workbench > OPC UA Server > Certificates): $(($rejected | ForEach-Object { $_.BaseName }) -join ', ')"
        Add-Result -Phase Verification -Check 'deviceWise: External client certificate trusted' -Status FAIL -Detail $d
        $checks.Add(@{ Cat='deviceWise'; Name='External client certificate trusted'; Status='FAIL'; Detail=$d; Note=''; T=3; I=20 })
    } elseif ($trusted.Count) {
        $d = "Trusted: $(($trusted | ForEach-Object { $_.BaseName }) -join ', ')"
        Add-Result -Phase Verification -Check 'deviceWise: External client certificate trusted' -Status PASS -Detail $d
        $checks.Add(@{ Cat='deviceWise'; Name='External client certificate trusted'; Status='PASS'; Detail=$d; Note=''; T=3; I=20 })
    } else {
        $d = 'No external client (DOC) has connected to the OPC UA server yet - check again after DOC has run'
        Add-Result -Phase Verification -Check 'deviceWise: External client certificate trusted' -Status WARN -Detail $d
        $checks.Add(@{ Cat='deviceWise'; Name='External client certificate trusted'; Status='BLANK'; Detail=$d; Note='Complete manually'; T=3; I=20 })
    }

    # Item 21 - CNCx and CNCx_PATH devices Started (DWCORE.db devices.state 1), plus SINC's OPC UA client
    Check 'deviceWise' 'CNCx / CNCx_Path devices State=Started' {
        if ($null -eq $devStates) { throw 'Cannot read the gateway devices (DWCORE.db)' }
        $want = @($machines | ForEach-Object { "CNC$($_.CNCIndex)", "CNC$($_.CNCIndex)_PATH" }) + @($paths.KeepStarted)
        $bad = @($want | Where-Object { -not $devStates.ContainsKey($_) -or $devStates[$_] -ne 1 })
        if ($bad.Count) { throw "Not Started: $($bad -join ', ')" }
        "Started: $($want -join ', ')"
    } '' 3 21

    #endregion

    #region T4 - TSDB ---------------------------------------------------------

    # Item 1 - pg_hba.conf host entry
    Check 'TSDB' 'pg_hba.conf host connection entry' {
        # Whitespace-insensitive: Step 2 writes the entry in the file's column layout
        $want  = ($pg.HbaEntry.Trim() -split '\s+') -join ' '
        $lines = [System.IO.File]::ReadAllLines($pg.PgHbaFile)
        $found = $lines | Where-Object { (($_.Trim() -split '\s+') -join ' ') -eq $want }
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
        $r = PsqlQuery "SELECT usename FROM pg_user WHERE usename='apcuser';"
        if ($r -ne 'apcuser') { throw "User 'apcuser' not found in pg_user" }
        "User apcuser exists"
    } '' 4 3

    # Item 4 - apcuser privileges
    Check 'TSDB' 'apcuser privileges (superuser, createdb)' {
        $r = PsqlQuery "SELECT usesuper,usecreatedb FROM pg_user WHERE usename='apcuser';"
        if ($r -notmatch 't\|t') { throw "Missing required privileges: $r" }
        "superuser=t, createdb=t"
    } '' 4 4

    # Item 5 - TimescaleDB database exists, owner = apcuser
    Check 'TSDB' 'TimescaleDB database exists (owner=apcuser)' {
        $r = PsqlQuery "SELECT pg_catalog.pg_get_userbyid(d.datdba) FROM pg_catalog.pg_database d WHERE d.datname='TimescaleDB';"
        if (-not $r) { throw "Database 'TimescaleDB' not found" }
        if ($r -ne 'apcuser') { throw "Owner: $r  expected: apcuser" }
        "Database TimescaleDB owner: apcuser"
    } '' 4 5

    # Item 6 - TimescaleDB extension
    Check 'TSDB' 'TimescaleDB extension installed' {
        $r = PsqlQuery "SELECT extname FROM pg_extension WHERE extname='timescaledb';" 'TimescaleDB'
        if ($r -notmatch 'timescaledb') { throw "Extension not found" }
        "timescaledb extension present"
    } '' 4 6

    # Items 7-8 - pgAdmin, for the Windows user running the wizard (Step 2 registers the server with a PassFile)
    Check 'TSDB' 'pgAdmin server registration' {
        $vm  = $env:COMPUTERNAME
        $srv = Get-PgAdminServer -PgAdminDir $pg.PgAdminDir -Name $vm
        if (-not $srv) { throw "No server '$vm' in pgAdmin for $env:USERDOMAIN\$env:USERNAME" }
        $bad = @()
        if ($srv.Host -ne $vm)                   { $bad += "host $($srv.Host)" }
        if ([int]$srv.Port -ne $pg.DefaultPort)  { $bad += "port $($srv.Port)" }
        if ($srv.MaintenanceDB -ne $pg.LocalDB)  { $bad += "maintenance DB $($srv.MaintenanceDB)" }
        if ($srv.Username -ne $pg.LocalUser)     { $bad += "user $($srv.Username)" }
        if (-not $srv.PassFile)                  { $bad += 'no saved password (PassFile)' }
        if ($bad) { throw "Server '$vm' differs from the SOP: $($bad -join ', ')" }
        $script:pgaServer = $srv
        "Server $vm`: host $vm, port $($srv.Port), maintenance DB $($srv.MaintenanceDB), user $($srv.Username), password from $($srv.PassFile)"
    } '' 4 7
    Check 'TSDB' 'pgAdmin connection to TimescaleDB' {
        $vm = $env:COMPUTERNAME
        $pf = if ($script:pgaServer) { $script:pgaServer.PassFile } else { Get-PgPassFilePath }
        if (-not (Test-Path -LiteralPath $pf)) { throw "Password file not found: $pf" }
        # As pgAdmin connects: by VM name, password only from the pgpass file
        $conn = @{ Exe = (Join-Path $pg.BinDir 'psql.exe'); Port = $pg.DefaultPort; User = $pg.LocalUser; Database = $pg.LocalDB; Host = $vm; PassFile = $pf }
        $r = Invoke-PgSql -Conn $conn -Sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';"
        if (-not $r.Ok) { throw (Get-PgError $r.Output) }
        "$($pg.LocalUser)@$vm`:$($pg.DefaultPort)/$($pg.LocalDB) connected with the saved password: $($r.Output) table(s)/view(s) in public"
    } '' 4 8

    # Item 9 - APC schema executed (check for any APC tables)
    Check 'TSDB' 'APC schema tables present' {
        # 'conditions' is the SOP's validation hypertable, not part of the APC schema
        $r = PsqlQuery "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name <> 'conditions';"
        $n = [int]$r
        if ($n -eq 0) { throw "No APC tables in public schema" }
        "$n APC table(s)/view(s) in public schema"
    } '' 4 9

    # Item 10 - Schema tables (ODBC DSN also validates DB access)
    Check 'TSDB' 'ODBC DSN PostgreSQL30 configured' {
        # 32-bit System DSN (SOP: PostgreSQL ANSI (x86)), written by Step 2
        $dsnPath = "HKLM:\SOFTWARE\WOW6432Node\ODBC\ODBC.INI\$($pg.OdbcDsn)"
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
        if (-not (Test-Path $p.BaseDir)) { $docItems.Dirs += "DOC$d missing: $($p.BaseDir)"; continue }

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

    # Item 10 - each assigned DOC instance running (DynamicOffsetCalculation.exe from its DOC-n folder)
    $docProcs = @{}
    foreach ($mm in $machines) { $pp = Get-DOCProcess -Manifest $Manifest -Instance $mm.CNCIndex; if ($pp) { $docProcs[[int]$mm.CNCIndex] = $pp } }
    Check 'DOC' 'DOC application launch' {
        if ($machines.Count -eq 0) { throw "No DOC-assigned machines" }
        $down = @($machines | Where-Object { -not $docProcs.ContainsKey([int]$_.CNCIndex) } | ForEach-Object { "DOC$($_.CNCIndex)" })
        if ($down) { throw "Not running: $($down -join ', ') (DynamicOffsetCalculation.exe in DOC-n\DOC_II)" }
        ($machines | ForEach-Object { "DOC$($_.CNCIndex) PID $($docProcs[[int]$_.CNCIndex].Id)" }) -join ', '
    } '' 5 10

    # Item 11 - the DB/SPC and OPC indicators: the DOC process holds a connection to PostgreSQL and to the
    # deviceWise OPC UA server (the indicators turn green on those connections)
    Check 'DOC' 'DOC connectivity indicators (DB/SPC/OPC green)' {
        if ($machines.Count -eq 0) { throw "No DOC-assigned machines" }
        $opcPort = [int]$dw.OpcUaEndpointPort
        $issues = @(); $ok = @()
        foreach ($mm in $machines) {
            $n = [int]$mm.CNCIndex
            if (-not $docProcs.ContainsKey($n)) { $issues += "DOC$n not running"; continue }
            $ports = @(Get-ProcessTcpConnections -ProcessId $docProcs[$n].Id | ForEach-Object { $_.RemotePort })
            $miss = @()
            if ($ports -notcontains [int]$pg.DefaultPort) { $miss += "DB/SPC (no connection to PostgreSQL :$($pg.DefaultPort))" }
            if ($ports -notcontains $opcPort)              { $miss += "OPC (no connection to deviceWise :$opcPort)" }
            if ($miss) { $issues += "DOC$n $($miss -join ', ')" } else { $ok += "DOC$n" }
        }
        if ($issues) { throw ($issues -join '; ') }
        "DB/SPC and OPC connected: $($ok -join ', ')"
    } '' 5 11

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
                if ($p[5]  -ne $m.PdmName)     { $errs += "MachineName=$($p[5]) expected $($m.PdmName)" }
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

    # Item 6 - per-device driver files: <dll>_<DeviceNr>.ini (renamed by Step 7) and .dll (created by CNCnetPDM)
    Check 'CNCnetPDM' 'Driver DLL files renamed correctly' {
        if (-not $driverDir) { throw "Directory unknown" }
        $files = @($pdmCNCs | ForEach-Object {
            $b = "$([System.IO.Path]::GetFileNameWithoutExtension($_.DriverDll))_$($_.DeviceNr)"
            "$b.ini"; "$b.dll"
        })
        $missing = @($files | Where-Object { -not (Test-Path (Join-Path $driverDir $_)) })
        if ($missing) { throw "Missing: $($missing -join ', ') (.dll files are created when the CNCnetPDM service starts)" }
        "Present: $($files -join ', ')"
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
    Check 'CNCnetPDM' 'CNCnetPDM devices Connected in deviceWise' {
        if (-not $mtc.Connected) { throw "dwcore has no connection to CNCnetPDM (port $($mtc.Port))" }
        "Connected (port $($mtc.Port))"
    } '' 6 10

    # Items 11-12 - read / write a CNC tag through deviceWise the CHMI way (Invoke-DwCncTag: the CHMI trigger
    # methods over OPC UA reach CNCn_PATH -> CNCnetPDM -> CNC). Write: TestValue, read back, then RestoreValue
    # (#597: 10 means nothing to the CNC logic, 0 is idle - user 2026-10-15). CNCnetPDM.ReadWriteTest.
    $rwt = $cncPdm.ReadWriteTest
    $rwRead = @(); $rwWrite = @(); $rwErr = ''
    if ($rwt -and $pdmCNCs.Count) {
        $rwSession = $null
        try {
            $rwSession = Open-DwUaSession -Manifest $Manifest
            $ns = $dw.OpcUaClient.Namespace
            foreach ($c in $pdmCNCs) {
                $dev = "CNC$($c.CNCIndex)_PATH"
                $r = Invoke-DwCncTag -Session $rwSession -Namespace $ns -Device $dev -Tag $rwt.Tag
                $rwRead += @{ Dev = $dev; Ok = $r.Ok; Text = $(if ($r.Ok) { "$dev $($rwt.Tag)=$($r.Value)" } else { "$dev $($r.Error)" }) }
                if (-not $r.Ok -or -not $rwt.Write) { continue }
                $steps = @()
                foreach ($v in @($rwt.TestValue, $rwt.RestoreValue)) {
                    $w = Invoke-DwCncTag -Session $rwSession -Namespace $ns -Device $dev -Tag $rwt.Tag -WriteValue "$v"
                    if (-not $w.Ok) { $steps += "write $v failed: $($w.Error)"; break }
                    Start-Sleep -Seconds ([int]$rwt.ReadBackDelaySeconds)
                    $b = Invoke-DwCncTag -Session $rwSession -Namespace $ns -Device $dev -Tag $rwt.Tag
                    if (-not $b.Ok) { $steps += "read back after $v failed: $($b.Error)"; break }
                    if ([double]$b.Value -ne [double]$v) { $steps += "wrote $v, read back $($b.Value)"; break }
                    $steps += "$v ok"
                }
                $rwWrite += @{ Dev = $dev; Ok = ($steps.Count -eq 2 -and $steps[-1] -like '* ok'); Text = "$dev $($rwt.Tag): $($steps -join ', ')" }
            }
        } catch { $rwErr = $_.Exception.Message }
        finally { if ($rwSession) { try { [void]$rwSession.Close() } catch { } } }
    }
    if (-not $rwt) {
        Blank 'CNCnetPDM' 'Read access verified via deviceWise' 6 11
        Blank 'CNCnetPDM' 'Write access verified via deviceWise' 6 12
    } else {
        Check 'CNCnetPDM' 'Read access verified via deviceWise' {
            if ($rwErr) { throw $rwErr }
            if (-not $rwRead) { throw 'No CNC to read' }
            $bad = @($rwRead | Where-Object { -not $_.Ok })
            if ($bad) { throw (($bad | ForEach-Object { $_.Text }) -join '; ') }
            ($rwRead | ForEach-Object { $_.Text }) -join ', '
        } '' 6 11
        if (-not $rwt.Write) {
            Blank 'CNCnetPDM' 'Write access verified via deviceWise' 6 12
        } else {
            Check 'CNCnetPDM' 'Write access verified via deviceWise' {
                if ($rwErr) { throw $rwErr }
                if (-not $rwWrite) { throw 'Not written: the read failed first' }
                $bad = @($rwWrite | Where-Object { -not $_.Ok })
                if ($bad) { throw (($bad | ForEach-Object { $_.Text }) -join '; ') }
                "wrote $($rwt.TestValue), read back, restored $($rwt.RestoreValue): " + (($rwWrite | ForEach-Object { $_.Dev }) -join ', ')
            } '' 6 12
        }
    }

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
        # shares: an administrator session can only confirm the server answers (Unverified counts as OK)
        $unreach = @($fmPaths | ForEach-Object { FmChild $_ 'Path' } | Select-Object -Unique | Where-Object {
            if ($_ -match '^[\\/]{2}') { (Get-NetworkPathStatus $_).Status -notin 'OK', 'Unverified' } else { -not (Test-Path $_) }
        })
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
        $account = Get-AppAccount -Manifest $Manifest -State $State
        if ($account -and ($IsWindows -ne $false) -and (Get-Command Get-Acl -ErrorAction SilentlyContinue)) {
            $noAccess = @($fmPaths | ForEach-Object { FmChild $_ 'NewPath'; FmChild $_ 'ErrorPath' } | Select-Object -Unique |
                          Where-Object { $_ -and $_ -ne 'NA' -and (Test-LocalFixedPath $_) -and -not (Test-AppAccountModify $_ $account) })
            if ($noAccess) { throw "$account has no Modify on: $($noAccess -join ', ')" }
        }
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
        $account = Get-AppAccount -Manifest $Manifest -State $State
        if ($account -and ($IsWindows -ne $false) -and (Get-Command Get-Acl -ErrorAction SilentlyContinue)) {
            $noAccess = @($dirs | Where-Object { (Test-LocalFixedPath $_) -and -not (Test-AppAccountModify $_ $account) })
            if ($noAccess) { throw "$account has no Modify on: $($noAccess -join ', ')" }
        }
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

    # Item 4 - TSDB connectivity: Data Analyzer holds connections to PostgreSQL (it opens them at start)
    Check 'DataAnalyzer' 'TSDB connectivity confirmed in app' {
        $procs = @(Get-Process -Name 'DataAnalyzer' -ErrorAction SilentlyContinue)
        if (-not $procs) { throw "Data Analyzer not running" }
        $c = @(Get-ProcessTcpConnections -ProcessId ($procs | ForEach-Object { $_.Id }) | Where-Object { $_.RemotePort -eq [int]$pg.DefaultPort })
        if (-not $c) { throw "Data Analyzer has no connection to PostgreSQL :$($pg.DefaultPort) - check logs\DBManager.log" }
        "$($c.Count) connection(s) to PostgreSQL :$($pg.DefaultPort)"
    } '' 9 4

    #endregion

    #region T10 - CHMI --------------------------------------------------------

    # Read-only: certificate files under CHMI.PkiRoot and the deviceWise OPC UA server status as seen by 800xA
    $chmiCerts = @(Get-800xAOpcUaCertificates -Manifest $Manifest)
    $rootName  = [string]$Manifest.CHMI.RootCertName

    # Item 1 - Root certificate
    Check 'CHMI' '800xA OPC UA root certificate exists' {
        $c = $chmiCerts | Where-Object Name -eq $rootName
        if (-not $c.Found) { throw "Root certificate not found: $($c.Path)" }
        "$($c.Thumbprint), created $($c.NotBefore)"
    } '' 10 1

    # Item 2 - Application certificates updated (present and issued by the root)
    Check 'CHMI' 'Application certificates updated' {
        $apps = @($chmiCerts | Where-Object Name -ne $rootName)
        $missing = @($apps | Where-Object { -not $_.Found } | ForEach-Object Name)
        if ($missing) { throw "Not found: $($missing -join ', ')" }
        ($apps | ForEach-Object { $_.Name }) -join ', '
    } '' 10 2

    # Item 3 - Issuer verification
    Check 'CHMI' "Issuer verified ($rootName)" {
        $wrong = @($chmiCerts | Where-Object { $_.Name -ne $rootName -and -not $_.IssuedByRoot } | ForEach-Object { "$($_.Name): $(if ($_.Found) { $_.Issuer } else { 'not found' })" })
        if ($wrong) { throw "Not signed by the current root - $($wrong -join '; ')" }
        "800xAOpcUaConnect and 800xAOpcUaManagementPortal issued by $rootName"
    } '' 10 3

    # Item 4 - OPC UA Server URL configured: the URL is aspect data (not readable); a Running deviceWise server proves it
    Check 'CHMI' '800xA services in normal state (D01558132 1.4)' {
        $states = @(Get-800xAServiceStates -Manifest $Manifest | Where-Object { -not $_.Missing })
        $bad = @($states | Where-Object { -not $_.Ok } | ForEach-Object { "$($_.Name): $($_.Detail)" })
        if ($bad) { throw "Not normal - $($bad -join '; ')" }
        "In service, no faults: $(($states | ForEach-Object { $_.Name }) -join ', ')"
    }

    if ([bool]$Manifest.CHMI.CheckCalculations) {
        Check 'CHMI' '800xA calculations enabled (Calculation Status Viewer)' {
            $c = Invoke-800xACalculationCheck -Manifest $Manifest -LogDir $reportDir
            if ($c.Code -eq 1) { throw "Disabled or in error - see $($c.Report) (Step 11 enables them again)" }
            if ($c.Code -ne 0) { throw "Could not check (exit $($c.Code)) - see $($c.Report)" }
            (@($c.Lines | Where-Object { $_ -match '^(All |No calculations|  \d+ running )' }) -join '; ')
        }
    }

    Check 'CHMI' 'OPC UA Server URL configured in 800xA' {
        Test-800xAOpcUaServer -Manifest $Manifest -Throw
    } '' 10 4

    # Items 5-7 - manual
    # Item 5 - placements uploaded (OPC UA Server Info aspect, read by tools\Set-800xADeviceWiseServer.ps1 -CheckOnly)
    Check 'CHMI' 'OPC UA placements added (Node Status=Uploaded)' {
        $tool = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools\Set-800xADeviceWiseServer.ps1'
        $ps32 = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
        $out  = @(& $ps32 -NoProfile -STA -ExecutionPolicy Bypass -File $tool -CheckOnly -OutDir $reportDir 2>&1 | ForEach-Object { "$_" })
        $pl   = @($out | Where-Object { $_ -match '^Upload placements: ' } | Select-Object -Last 1) -replace '^Upload placements: ', ''
        if (-not $pl) { throw "Could not read the placements: $(($out | Select-Object -Last 3) -join ' ')" }
        if ($pl -notmatch 'all Uploaded') { throw $pl }
        $pl
    } '' 10 5

    # Items 6-7 - each cell's 'OPC' child exists, is named OPC and shows its CNC live (CNCAsset / CNCType from deviceWise)
    $cellOpc = @(Get-800xACellOpcStates -Manifest $Manifest -State $State)
    Check 'CHMI' 'CNC OPC object naming verified' {
        $missing = @($cellOpc | Where-Object { -not $_.Exists } | ForEach-Object { "$($_.Cell): $($_.Detail)" })
        if ($missing) { throw ($missing -join '; ') }
        "OPC child present: $(($cellOpc | ForEach-Object { "$($_.Cell)/OPC" }) -join ', ')"
    } '' 10 6
    Check 'CHMI' 'OPC UA connectivity readiness confirmed' {
        $bad = @($cellOpc | Where-Object { -not $_.Ok } | ForEach-Object { "$($_.Cell): $($_.Detail)" })
        if ($bad) { throw ($bad -join '; ') }
        "Live from deviceWise: $(($cellOpc | ForEach-Object { "$($_.Cell)=$($_.Asset) ($($_.Type))" }) -join ', ')"
    } '' 10 7

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
            if (-not (Test-TcpPort $m.IPAddress 683 ([int]$cncPdm.PortCheckTimeoutMs))) { $failed += "$($m.MachineName)($($m.IPAddress))" }
        }
        if ($failed) { throw "TCP 683 unreachable: $($failed -join ', ')" }
        "TCP 683 reachable: $($machines.MachineName -join ', ')"
    } '' 11 6

    #endregion

    #region deviceWise backup (Step 12 file-level backup; a Workbench backup saved there also counts) ------

    $bkRoot = [string]$State['BackupRoot']
    if ($bkRoot -and (Test-Path -LiteralPath $bkRoot)) {
        $dwDir   = Join-Path $bkRoot 'deviceWise'
        $dwFiles = @(Get-ChildItem -LiteralPath $dwDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object Name -ne 'NOT_BACKED_UP.txt')
        if ($dwFiles.Count -eq 0) {
            Warn 'Backup' 'deviceWise backup NOT done' "Run Step 12 again, or back up each project in Workbench (include Network Settings) into $dwDir - the backup is incomplete until then"
        } else {
            Add-Result -Phase Verification -Check 'Backup: deviceWise backup' -Status PASS -Detail "$($dwFiles.Count) file(s) in $dwDir"
            $checks.Add(@{ Cat='Backup'; Name='deviceWise backup'; Status='PASS'; Detail="$($dwFiles.Count) file(s) in $dwDir"; Note=''; T=-1; I=-1 })
        }
    }

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
<title>APC Configuration Verification Report (draft)</title>
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
</style>
</head><body>
<div class='header'>
  <h1>APC Configuration Verification Report (draft)</h1>
  <p>VM: $($env:COMPUTERNAME) | Site: $siteCode | Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')$(if ($State['ChangeID']) { " | Change ID: $([System.Web.HttpUtility]::HtmlEncode([string]$State['ChangeID']))" })</p>
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
  <h2>Draft for review</h2>
  <p>This report and the filled D01555624 checklist are a draft produced by the wizard. Review and QA check and sign the checklist independently.</p>
</div>
</body></html>
"@

    [System.IO.File]::WriteAllText($reportPath, $html)
    $State['VerificationReportPath'] = $reportPath
    Add-Result -Phase Verification -Check 'HTML Report' -Status PASS -Detail $reportPath

    #endregion

    #region Fill D01555624 Word document --------------------------------------

    $wizardRoot    = Split-Path $PSScriptRoot -Parent
    $templatePath  = Join-Path $wizardRoot 'templates\D01555624_A_EN.docx'
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

    # Load by full name: Add-Type -AssemblyName failed in the wizard's step runspace with
    # "Invalid pointer (E_POINTER)" (VM run 2026-10-15)
    foreach ($asm in 'System.IO.Compression', 'System.IO.Compression.FileSystem') {
        if (-not ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq $asm })) {
            [void][Reflection.Assembly]::Load("$asm, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089")
        }
    }

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
        $siteNames = @{ MCR='Medtronic Costa Rica'; MPR='Medtronic Puerto Rico' }
        $siteFull  = $siteNames[$State['SiteCode']]
        if (-not $siteFull) { $siteFull = $State['SiteCode'] }

        $sysValues = @(
            $env:COMPUTERNAME,                                    # Row 0: VM Name
            "APC System V$($Manifest.APC.Version)",               # Row 1: Version
            'Closed-Loop Correction (CLC)',                       # Row 2: Solution
            $siteFull,                                            # Row 3: Site
            'D01555624',                                          # Row 4: Doc ID
            $null,                                                # Row 5: Reason (checkboxes, below)
            $null                                                 # Row 6: Change ID (below)
        )

        for ($ri = 0; $ri -lt $sysValues.Count; $ri++) {
            if ($null -eq $sysValues[$ri]) { continue }
            if ($ri -ge $sysRows.Count) { break }
            $row   = $sysRows[$ri]
            $cells = $row.SelectNodes('w:tc', $ns)
            if ($cells.Count -lt 2) { continue }
            Set-DocCellText -Cell $cells[1] -Text $sysValues[$ri] -Ns $ns
        }

        # Row 5: tick the Reason for Configuration box (one paragraph per option; 5 = Other)
        $reason = if ($State.ContainsKey('ConfigReason') -and $null -ne $State['ConfigReason']) { [int]$State['ConfigReason'] } else { -1 }
        if ($reason -ge 0 -and $sysRows.Count -gt 5) {
            $cells = $sysRows[5].SelectNodes('w:tc', $ns)
            $paras = if ($cells.Count -ge 2) { $cells[1].SelectNodes('w:p', $ns) } else { @() }
            if ($reason -lt $paras.Count) {
                Set-DocCheckbox -Para $paras[$reason] -Ns $ns
                $other = if ($State.ContainsKey('ConfigReasonOther')) { [string]$State['ConfigReasonOther'] } else { '' }
                if ($reason -eq 5 -and $other) {
                    $label = $paras[$reason].SelectSingleNode('w:r/w:t[contains(., "Other")]', $ns)
                    if ($label) { $label.InnerText = " Other: $other" }
                }
            }
        }

        # Row 6: Change ID
        $changeId = if ($State.ContainsKey('ChangeID')) { [string]$State['ChangeID'] } else { '' }
        if ($changeId -and $sysRows.Count -gt 6) {
            $cells = $sysRows[6].SelectNodes('w:tc', $ns)
            if ($cells.Count -ge 2) { Set-DocCellText -Cell $cells[1] -Text "Change ID: $changeId" -Ns $ns }
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
            if ($paraIdx -lt $paras.Count) { Set-DocCheckbox -Para $paras[$paraIdx] -Ns $ns }
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
# Helper: tick the checkbox content control at the start of a paragraph
# -------------------------------------------------------------------------
function Set-DocCheckbox {
    param(
        [System.Xml.XmlNode]            $Para,
        [System.Xml.XmlNamespaceManager]$Ns
    )
    $checkedNode = $Para.SelectSingleNode('w:sdt/w:sdtPr/w14:checkbox/w14:checked', $Ns)
    if ($checkedNode) {
        $checkedNode.SetAttribute('val', 'http://schemas.microsoft.com/office/word/2010/wordml', '1')
    }
    # Swap the empty box for a ticked one inside sdtContent
    $tNode = $Para.SelectSingleNode('w:sdt/w:sdtContent/w:r/w:t', $Ns)
    if ($tNode) { $tNode.InnerText = [char]0x2612 }
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
