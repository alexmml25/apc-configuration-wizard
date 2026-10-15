#Requires -Version 5.1
<#
.SYNOPSIS
    Shared helpers dot-sourced by step modules (not a step itself).
#>

function Get-CNCDeviceInfo {
    <#
        Derives CNCnetPDM identifiers for a Site DB machine (Manifest.CNCnetPDM.DeviceNrRules):
          DeviceNr   - <family digit><machine number, 3 digits>  (CNCnetPDM accepts 4 digits)
                       family digit from FamilyDigits, machine number = trailing digits of the name
                       e.g. CITIZEN_L20X_IV + 'Citizen 08' -> 1008, CITIZEN_L20E_V + 'Citizen 100' -> 4100
          DriverDll  - the machine's DLL name from the Site DB (f_dllname), e.g. citizenm.dll
          PdmName    - the name CNCnetPDM and the deviceWise CNCn_PATH 'machine' use: the Site DB name, or for a name
                       over MaxMachineNameLength the name with the NameShortening replacements applied
                       ('Citizen L320EA 5' -> 'Citizen L320 5'); DOC, CNCAsset and the Site DB keep the full name
        Error is set (and DeviceNr empty) when a rule cannot be applied.
    #>
    param([Parameter(Mandatory)] $Machine, [Parameter(Mandatory)] [object]$Manifest)

    $rules  = $Manifest.CNCnetPDM.DeviceNrRules
    $family = [string]$Machine.AssetFamily
    if (-not $family) { $family = [string]$Machine.CNCType }
    $key  = ($family.Trim() -replace '\s+', '_').ToUpper()
    $info = @{ Family = $key; DeviceNr = ''; DriverDll = ([string]$Machine.DLLName).Trim(); PdmName = [string]$Machine.MachineName; Error = '' }

    $digit = $rules.FamilyDigits.PSObject.Properties[$key]
    if (-not $digit) {
        $info.Error = "Asset family '$family' has no Device Nr digit (known: $(($rules.FamilyDigits.PSObject.Properties.Name) -join ', '))"
        return $info
    }
    # CNCnetPDM keeps only the first 15 characters of a device name; a cut name no longer matches
    # deviceWise / DOC and can collide with another machine (Citizen L320EA 1 / 12 -> Citizen L320EA)
    $maxLen = [int]$rules.MaxMachineNameLength
    if ($maxLen -gt 0 -and $info.PdmName.Length -gt $maxLen) {
        foreach ($r in @($rules.NameShortening)) { if ($r.Find) { $info.PdmName = $info.PdmName.Replace([string]$r.Find, [string]$r.Replace) } }
        $info.PdmName = ($info.PdmName -replace '\s+', ' ').Trim()
        if ($info.PdmName.Length -gt $maxLen) {
            $info.Error = "Machine name '$($Machine.MachineName)' is $(([string]$Machine.MachineName).Length) characters; CNCnetPDM keeps only $maxLen and no NameShortening rule makes it fit - shorten it in the Site DB / ACW or add a rule"
            return $info
        }
    }
    if ([string]$Machine.MachineName -notmatch '(\d+)\s*$') {
        $info.Error = "Machine name '$($Machine.MachineName)' does not end in a machine number"
        return $info
    }
    $num = [int]$Matches[1]
    if ($num -lt 1 -or $num -gt [int]$rules.MaxMachineNumber) {
        $info.Error = "Machine number $num from '$($Machine.MachineName)' is outside 1-$($rules.MaxMachineNumber)"
        return $info
    }
    if (-not $info.DriverDll) {
        $info.Error = "No DLL name in the Site DB (f_dllname) for '$($Machine.MachineName)'"
        return $info
    }
    $info.DeviceNr = '{0}{1:D3}' -f [int]$digit.Value, $num
    return $info
}

function Get-AssignedCNCs {
    <#
        Returns the machines assigned to CNC1..CNC{DOCCount} (CNC n = DOC instance n), as hashtables
        with CNCIndex, DeviceNr, DriverDll and DeviceNrError added.
        Falls back to Site DB order when no DOC assignment is recorded for a slot.
    #>
    param([Parameter(Mandatory)] [hashtable]$State, [Parameter(Mandatory)] [object]$Manifest)

    $all         = @($State['CNCMachines'])
    $assignments = @($State['DOCMachineAssignments'])
    $count       = [int]$State['DOCCount']
    if ($count -lt 1) { $count = $all.Count }

    $result = @()
    for ($i = 0; $i -lt $count; $i++) {
        $name = if ($i -lt $assignments.Count) { $assignments[$i] } else { '' }
        $m = $all | Where-Object { $_.MachineName -eq $name } | Select-Object -First 1
        if (-not $m -and -not $name -and $i -lt $all.Count) { $m = $all[$i] }
        if (-not $m) { continue }

        $h = @{}
        if ($m -is [System.Collections.IDictionary]) { foreach ($k in $m.Keys) { $h[$k] = $m[$k] } }
        else { foreach ($p in $m.PSObject.Properties) { $h[$p.Name] = $p.Value } }

        $info = Get-CNCDeviceInfo -Machine $h -Manifest $Manifest
        $h['CNCIndex']      = $i + 1
        $h['DeviceNr']      = $info.DeviceNr
        $h['DriverDll']     = $info.DriverDll
        $h['PdmName']       = $info.PdmName
        $h['DeviceNrError'] = $info.Error
        $result += $h
    }
    return ,$result
}

function Get-DataAppsInstrumentPlan {
    <#
        Returns the instrument selection as a list of hashtables:
        Type, Count, CNCs (int[]), SourcePath, ErrorPath, BroadcastPath, Names (string[]), Suffixes (string[])
    #>
    param([object]$Manifest, [hashtable]$State)

    $da = $Manifest.DataApps
    $selection = $State['DataAppsInstruments']
    if (-not $selection) {
        $site     = $State['SiteCode']
        $defaults = if ($site -and $da.SiteDefaults.PSObject.Properties[$site]) { $da.SiteDefaults.$site } else { $da.SiteDefaults.Default }
        $selection = foreach ($def in $da.Instruments) {
            $d = $defaults.($def.Type)
            if (-not $d) { continue }
            @{ Type = $def.Type; Count = $d.Count; CNCs = @($d.CNCs)
               SourcePath = $d.SourcePath; ErrorPath = $d.ErrorPath; BroadcastPath = $d.BroadcastPath }
        }
    }

    $plan = foreach ($sel in $selection) {
        $def   = $da.Instruments | Where-Object { $_.Type -eq $sel.Type } | Select-Object -First 1
        $count = [math]::Max(1, [int]$sel.Count)
        $cncs  = @($sel.CNCs | ForEach-Object { [int]$_ })
        if ($cncs.Count -eq 0) { continue }
        $names    = @(if ($count -eq 1) { $def.SingleName } else { 1..$count | ForEach-Object { "$($sel.Type)$_" } })
        $suffixes = @(if ($count -eq 1) { $sel.Type }       else { 1..$count | ForEach-Object { "$($sel.Type)$_" } })
        @{
            Type          = $sel.Type
            Count         = $count
            CNCs          = $cncs
            SourcePath    = [string]$sel.SourcePath
            ErrorPath     = [string]$sel.ErrorPath
            BroadcastPath = [string]$sel.BroadcastPath
            Names         = [string[]]$names
            Suffixes      = [string[]]$suffixes
        }
    }
    return @($plan)
}

function Get-DOCFilePaths {
    <#
        Paths of the five DOC XML files for DOC instance $N, as installed on the APC VM:
          DOC_II\                DocDb.xml, DOC_II.xml
          DOC_II\Plugins\        PartLookup.xml
          DOC_II\Plugins\IQS\    SpcDb.xml, IqsDocSpcDataCollector.xml
        A file not found in its expected folder is looked for in the other two; if it is nowhere,
        the expected path is returned (the caller reports it as missing).
    #>
    param([Parameter(Mandatory)] [object]$Manifest, [Parameter(Mandatory)] [int]$N)
    $doc     = $Manifest.DOC
    $base    = $doc.BasePath       -replace '\{N\}', $N
    $plugins = Join-Path $base 'Plugins'
    $iqs     = $doc.PluginsIQSPath -replace '\{N\}', $N
    $paths = [ordered]@{ BaseDir = $base; PluginsDir = $plugins; IqsDir = $iqs }   # keys are case-insensitive: not 'Iqs'
    foreach ($f in @(
        @{ Key = 'DocDb';      File = $doc.DocDBXml;        Dirs = @($base, $plugins, $iqs) },
        @{ Key = 'DocII';      File = $doc.DocIIXml;        Dirs = @($base, $plugins, $iqs) },
        @{ Key = 'PartLookup'; File = $doc.PartLookupXml;   Dirs = @($plugins, $base, $iqs) },
        @{ Key = 'SpcDb';      File = $doc.SpcDBXml;        Dirs = @($iqs, $plugins, $base) },
        @{ Key = 'Iqs';        File = $doc.IqsCollectorXml; Dirs = @($iqs, $plugins, $base) })) {
        $found = $f.Dirs | ForEach-Object { Join-Path $_ $f.File } | Where-Object { Test-Path $_ } | Select-Object -First 1
        $paths[$f.Key] = if ($found) { $found } else { Join-Path $f.Dirs[0] $f.File }
    }
    return $paths
}

function Get-DOCCsvOutputPath {
    # DOC_II.xml CSVFileOutputPath for CNC $N: <SINC staging>\CNC{N}\<pattern>
    param([Parameter(Mandatory)] [object]$Manifest, [Parameter(Mandatory)] [int]$N)
    '{0}\CNC{1}\{2}' -f $Manifest.DeviceWise.SINCStaging.TrimEnd('\'), $N, $Manifest.DOC.CSVFileNamePattern
}

function Get-DOCInclusionList {
    <#
        IqsDocSpcDataCollector.xml SourceDataInclusionList entries for CNC $Cnc:
        one 1ST_/SPC_/VER_<Name>_<Site> : <Name> triple per instrument instance selected for that CNC
        (names as in the Data Collector: CMM1, CTSCAN1, BENCH, CONTRACER1..3).
    #>
    param([Parameter(Mandatory)] [object]$Manifest, [Parameter(Mandatory)] [hashtable]$State, [Parameter(Mandatory)] [int]$Cnc)
    $site = $State['SiteCode']
    $list = @()
    foreach ($ins in (Get-DataAppsInstrumentPlan -Manifest $Manifest -State $State)) {
        if ($Cnc -notin $ins.CNCs) { continue }
        foreach ($name in $ins.Names) {
            foreach ($prefix in $Manifest.DOC.ProcessPrefixes) { $list += "${prefix}_${name}_${site} : $name" }
        }
    }
    return ,$list
}

function New-SandboxManifest {
    <#
        Test mode: copies the installed config files the wizard edits into $Root and returns a copy of
        the manifest whose paths point there, so Steps 3, 7, 9 and 10 change only the copies.
          <Root>\DataApps\        File Manager / Data Collector / Data Analyzer configs
          <Root>\CNCnetPDM\       CNCnetPDM.ini, melcfg.ini, citizenm*/mitsubishim* driver .dll/.ini
          <Root>\DOC-{n}\DOC_II\  DOC XMLs (PartLookup under Plugins, SpcDb / Iqs under Plugins\IQS)
          <Root>\SINC\            SINC staging folders
          <Root>\DataCollector_Data\  local data root
        Returns @{ Manifest; Copied = [string[]]; Missing = [string[]] }.
    #>
    param([Parameter(Mandatory)] [object]$Manifest, [Parameter(Mandatory)] [string]$Root)

    $m = $Manifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $copied = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    New-Item -ItemType Directory -Path $Root -Force | Out-Null

    function Copy-Into {
        param([string]$Source, [string]$DestDir)
        if (-not (Test-Path $Source)) { $missing.Add($Source); return }
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
        Copy-Item $Source $DestDir -Force
        $copied.Add($Source)
    }

    # Data applications
    $daDir = Join-Path $Root 'DataApps'
    foreach ($key in 'FileManagerConfig', 'DataCollectorConfig', 'DataAnalyzerConfig') {
        $src = $Manifest.DataApps.$key
        Copy-Into $src $daDir
        $m.DataApps.$key = Join-Path $daDir (Split-Path $src -Leaf)
    }
    $m.DataApps.LocalDataRoot = Join-Path $Root 'DataCollector_Data'

    # CNCnetPDM
    $pdmSrc = @($Manifest.CNCnetPDM.InstallDir, $Manifest.CNCnetPDM.FallbackDir) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    $pdmDst = Join-Path $Root 'CNCnetPDM'
    if ($pdmSrc) {
        Copy-Into (Join-Path $pdmSrc $Manifest.CNCnetPDM.IniFile)    $pdmDst
        Copy-Into (Join-Path $pdmSrc $Manifest.CNCnetPDM.MelcfgFile) $pdmDst
        $drvSrc = if ($Manifest.CNCnetPDM.DriverSubDir) { Join-Path $pdmSrc $Manifest.CNCnetPDM.DriverSubDir } else { $pdmSrc }
        $drvDst = if ($Manifest.CNCnetPDM.DriverSubDir) { Join-Path $pdmDst $Manifest.CNCnetPDM.DriverSubDir } else { $pdmDst }
        $bases  = @($Manifest.CNCnetPDM.DriverDlls | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) })
        Get-ChildItem $drvSrc -File -ErrorAction SilentlyContinue |
            Where-Object { $n = $_.Name; $_.Extension -in '.dll', '.ini' -and ($bases | Where-Object { $n -like "$_*" }) } |
            ForEach-Object { Copy-Into $_.FullName $drvDst }
    } else {
        $missing.Add("CNCnetPDM install folder ($($Manifest.CNCnetPDM.InstallDir))")
    }
    New-Item -ItemType Directory -Path $pdmDst -Force | Out-Null
    $m.CNCnetPDM.InstallDir  = $pdmDst
    $m.CNCnetPDM.FallbackDir = $pdmDst

    # DOC instances
    $m.DOC.BasePath       = Join-Path $Root 'DOC-{N}\DOC_II'
    $m.DOC.PluginsIQSPath = Join-Path $Root 'DOC-{N}\DOC_II\Plugins\IQS'
    for ($n = 1; $n -le [int]$Manifest.DOC.MaxInstances; $n++) {
        $src = Get-DOCFilePaths -Manifest $Manifest -N $n
        if (-not (Test-Path $src.BaseDir)) { continue }
        $dst = Get-DOCFilePaths -Manifest $m -N $n
        foreach ($key in 'DocDb', 'DocII', 'PartLookup', 'SpcDb', 'Iqs') {
            # keep each file in the same sub-folder it was found in
            $from = Split-Path $src[$key] -Parent
            $to   = if ($from -eq $src.IqsDir) { $dst.IqsDir } elseif ($from -eq $src.PluginsDir) { $dst.PluginsDir } else { $dst.BaseDir }
            Copy-Into $src[$key] $to
        }
    }

    # SINC staging
    $m.DeviceWise.SINCStaging = Join-Path $Root 'SINC'

    return @{ Manifest = $m; Copied = [string[]]$copied; Missing = [string[]]$missing }
}

function Get-PasswordHash {
    <#
        PBKDF2-SHA256 of a password (string or SecureString) with the given salt; returns base64.
        Used to check that a typed password is the standard one without storing the password itself
        (manifest PostgreSQL.LocalUserPasswordCheck, made with tools\New-PasswordCheck.ps1).
    #>
    param([Parameter(Mandatory)] $Password, [Parameter(Mandatory)] [byte[]]$Salt, [int]$Iterations = 200000)
    $plain = $Password
    if ($Password -is [Security.SecureString]) {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes([string]$plain, $Salt, $Iterations, [Security.Cryptography.HashAlgorithmName]::SHA256)
    try { return [Convert]::ToBase64String($kdf.GetBytes(32)) } finally { $kdf.Dispose() }
}

function Test-StandardPassword {
    # $true / $false against a { Salt, Hash, Iterations } check; $null when no check is configured
    param([Parameter(Mandatory)] $Password, $Check)
    if (-not $Check -or -not $Check.PSObject.Properties['Hash'] -or -not $Check.Hash -or -not $Check.Salt) { return $null }
    $iter = if ($Check.PSObject.Properties['Iterations'] -and $Check.Iterations) { [int]$Check.Iterations } else { 200000 }
    $hash = Get-PasswordHash -Password $Password -Salt ([Convert]::FromBase64String($Check.Salt)) -Iterations $iter
    return ($hash -ceq [string]$Check.Hash)
}

function Get-RunDir {
    <#
        Folder for this run's Logs / Backups / Reports. The wizard gives each run its own folder,
        State.RunRoot = C:\APC_Config\<Type>_<yyyyMMdd-HHmmss>, with Logs, Backups and Reports inside.
        Without RunRoot (e.g. APC_Config.ps1) the shared folders are used: C:\APC_Config\Logs,
        <Manifest.Backup.Root>\<yyyyMMdd-HHmmss> and C:\APC_Config\Reports. The folder is created.
    #>
    param([Parameter(Mandatory)] [hashtable]$State, [Parameter(Mandatory)] [ValidateSet('Logs', 'Backups', 'Reports')] [string]$Name,
          [object]$Manifest)
    $dir = if ($State['RunRoot']) { Join-Path ([string]$State['RunRoot']) $Name }
           elseif ($Name -eq 'Backups') { Join-Path ([string]$Manifest.Backup.Root) (Get-Date -Format 'yyyyMMdd-HHmmss') }
           else { Join-Path 'C:\APC_Config' $Name }
    New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    return $dir
}

function Test-SandboxPath {
    # True when not in test mode, or when $Path is inside the sandbox root (test mode must not create
    # folders outside the sandbox, e.g. on instrument shares)
    param([hashtable]$State, [string]$Path)
    $root = $State['SandboxRoot']
    if (-not $root) { return $true }
    $full = [System.IO.Path]::GetFullPath($Path)
    return $full.StartsWith([System.IO.Path]::GetFullPath($root), [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-RunModeSkipSteps {
    <#
        Steps the wizard skips for a run mode:
          Full      - none (all 13 steps, real system)
          Reviewed  - every step not in Manifest.RunModes.ReviewedSteps (real system)
          Test      - Manifest.TestMode.SkipSteps (sandbox copies)
    #>
    param([Parameter(Mandatory)] [object]$Manifest, [Parameter(Mandatory)] [ValidateSet('Full', 'Reviewed', 'Test')] [string]$Mode)
    switch ($Mode) {
        'Full'     { return }
        'Reviewed' { return 1..13 | Where-Object { $_ -notin @($Manifest.RunModes.ReviewedSteps) } }
        'Test'     { return $Manifest.TestMode.SkipSteps | ForEach-Object { [int]$_ } }
    }
}

function Test-LocalFixedPath {
    <#
        True when $Path is on a local fixed disk of this machine (C:, D:, ...), so the wizard may create it.
        False for UNC shares (\\server\share), mapped network drives, removable/CD drives and drive letters
        that do not exist - those are only checked, never created.
    #>
    param([string]$Path)
    if ($Path -match '^[\\/]{2}') { return $false }
    if ($Path -match '^([A-Za-z]):') {
        try { return ([System.IO.DriveInfo]::new($Matches[1])).DriveType -eq [System.IO.DriveType]::Fixed } catch { return $false }
    }
    return $true   # a path without a drive letter (relative, or a non-Windows test path)
}

function Test-ShareServerReachable {
    <#
        For a UNC path (\\server\share\...), quickly checks the server answers on SMB (TCP 445), so an
        unreachable server is reported in seconds instead of Test-Path hanging for minutes.
        Always true for non-UNC paths.
    #>
    param([string]$Path, [int]$TimeoutMs = 1500)
    if ($Path -notmatch '^[\\/]{2}([^\\/]+)') { return $true }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($Matches[1], 445, $null, $null)
        return ($ar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $client.Connected)
    } catch { return $false } finally { $client.Close() }
}

function Test-TcpPort {
    # True when Address:Port accepts a TCP connection within TimeoutMs. Plain TcpClient: Test-NetConnection
    # needs CimCmdlets, which does not load in the wizard's step runspace (VM run 2026-10-15)
    param([string]$Address, [int]$Port, [int]$TimeoutMs = 2000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($Address, $Port, $null, $null)
        return ($ar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $client.Connected)
    } catch { return $false } finally { $client.Close() }
}

function Get-ProcessTcpConnections {
    <#
        Established TCP connections of the given process IDs, from netstat -ano (no NetTCPIP / CimCmdlets in the
        step runspace): objects ProcessId, Local, Remote, RemotePort. An app's DB or OPC UA connection shows here
        while it is running (probe on SJUM7AAPPS0048 2026-10-15: DataAnalyzer -> [::1]:5432 x3, DataCollector ->
        :5432 and :48020).
    #>
    param([int[]]$ProcessId)
    $ids = @($ProcessId | ForEach-Object { [string]$_ })
    foreach ($l in @(netstat -ano -p TCP 2>$null) + @(netstat -ano -p TCPv6 2>$null)) {
        $f = "$l".Trim() -split '\s+'
        if ($f.Count -lt 5 -or $f[0] -ne 'TCP' -or $f[3] -ne 'ESTABLISHED' -or $ids -notcontains $f[4]) { continue }
        [pscustomobject]@{ ProcessId = [int]$f[4]; Local = $f[1]; Remote = $f[2]; RemotePort = [int]($f[2] -replace '^.*:', '') }
    }
}

function Get-DOCProcess {
    # The running DOC (DynamicOffsetCalculation.exe) of instance N, found by its folder (Manifest.DOC.BasePath); $null if not running
    param([Parameter(Mandatory)] [object]$Manifest, [Parameter(Mandatory)] [int]$Instance)
    $dir = ([string]$Manifest.DOC.BasePath).Replace('{N}', "$Instance").TrimEnd('\') + '\'
    Get-Process -Name 'DynamicOffsetCalculation' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
}

function Set-DataAppDeviceWiseTrust {
    <#
        Two-way OPC UA trust between one OPC UA client app and the deviceWise server (file stores, no restart needed):
          app  <OwnCertDir>\*.der            -> <PkiServer>\trusted\certs  (and out of <PkiServer>\rejected)
          deviceWise <PkiServer>\own\certs\*.der -> <TrustedCertDir>
        Defaults (the data apps): <AppDir>\CertificateStores\App\certs and <AppDir>\CertificateStores\Trusted\certs.
        Waits up to WaitSeconds for the app certificate (an app makes it on its first connection).
        Returns @{ Ok; Status = Done | NoCertificate | Failed; Detail }.
    #>
    param([string]$AppDir, [string]$PkiServer, [int]$WaitSeconds = 0, [string]$OwnCertDir, [string]$TrustedCertDir)
    $X509   = 'System.Security.Cryptography.X509Certificates.X509Certificate2'
    $appOwn = if ($OwnCertDir)     { $OwnCertDir }     else { Join-Path $AppDir 'CertificateStores\App\certs' }
    $appTr  = if ($TrustedCertDir) { $TrustedCertDir } else { Join-Path $AppDir 'CertificateStores\Trusted\certs' }
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

function Find-DOCCertStore {
    <#
        The OPC UA certificate store of one DOC instance (its OPC UA plugin makes it on the first connection):
        a 'CertificateStores' folder (App / Trusted, as the data apps) or a 'pki' folder (own / trusted) under
        DOC_II. Returns @{ Own; Trusted } (the certs folders) or $null when DOC has made none yet.
    #>
    param([Parameter(Mandatory)] [string]$DocDir)
    $roots = @(Get-ChildItem -LiteralPath $DocDir -Directory -Recurse -Depth 4 -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -in 'CertificateStores', 'pki' })
    foreach ($r in $roots) {
        foreach ($pair in @(@('App', 'Trusted'), @('own', 'trusted'))) {
            $own = Join-Path $r.FullName "$($pair[0])\certs"
            if (Get-ChildItem -LiteralPath $own -Filter '*.der' -File -ErrorAction SilentlyContinue) {
                return @{ Own = $own; Trusted = (Join-Path $r.FullName "$($pair[1])\certs") }
            }
        }
    }
    return $null
}

function Restart-DOCInstance {
    # Closes DOC instance N if it runs (window close, then kill after 20 s) and starts it from its folder, like the
    # data apps (Restart-DataApp). Only that instance: all DOCs share the process name DynamicOffsetCalculation.
    param([Parameter(Mandatory)] [object]$Manifest, [Parameter(Mandatory)] [int]$Instance)
    $dir = ([string]$Manifest.DOC.BasePath).Replace('{N}', "$Instance")
    $exe = Join-Path $dir 'DynamicOffsetCalculation.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return @{ Ok = $false; Detail = "Not installed: $exe" } }
    $was = Get-DOCProcess -Manifest $Manifest -Instance $Instance
    try {
        if ($was) {
            [void]$was.CloseMainWindow()
            if (-not $was.WaitForExit(20000)) { $was.Kill(); [void]$was.WaitForExit(10000) }
        }
        $new = Start-Process -FilePath $exe -WorkingDirectory $dir -PassThru
        Start-Sleep -Seconds 5
        if ($new.HasExited) { return @{ Ok = $false; Detail = "DOC-$Instance exited right after starting (exit code $($new.ExitCode)) - see $(Split-Path $dir -Parent)\Log" } }
        return @{ Ok = $true; Detail = "$(if ($was) { 'Restarted' } else { 'Started' }) DOC-$Instance (PID $($new.Id))" }
    } catch {
        return @{ Ok = $false; Detail = "DOC-$Instance could not be started: $_" }
    }
}

function Test-IsElevated {
    # True when running as administrator (the wizard always does). Administrator sessions may not see
    # network shares that the normal session can.
    try {
        $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-NetworkPathStatus {
    <#
        Status of a UNC path as far as the wizard can tell:
          OK          - server reachable and the folder exists
          Unverified  - server reachable, but the folder cannot be checked from an administrator session
                        (on the APC VM the elevated session cannot see into the shares the apps use)
          NotFound    - server reachable, folder not found (non-elevated session only)
          Unreachable - server does not answer on SMB (445)
    #>
    param([string]$Path)
    if (-not (Test-ShareServerReachable $Path)) {
        return @{ Status = 'Unreachable'; Detail = "Server for $Path not reachable (SMB port 445) - check network/VPN" }
    }
    if (Test-IsElevated) {
        return @{ Status = 'Unverified'; Detail = "Server reachable; $Path cannot be checked from the wizard (runs as administrator) - confirm in File Manager that it is found" }
    }
    if (Test-Path -LiteralPath $Path) { return @{ Status = 'OK'; Detail = '' } }
    return @{ Status = 'NotFound'; Detail = "$Path not found on the share, or no access" }
}

function Get-AppAccount {
    # Account the APC applications run as, from Manifest.AppAccount with {SITE} replaced, e.g. ENT\SVC-APC-MPR
    param([object]$Manifest, [hashtable]$State)
    $template = [string]$Manifest.AppAccount
    if (-not $template -or -not $State['SiteCode']) { return '' }
    return $template -replace '\{SITE\}', $State['SiteCode']
}

function Get-TopFolders {
    # The paths that are not inside another path of the list (a grant on those covers the rest by inheritance)
    param([string[]]$Paths)
    $norm = @($Paths | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\', '/') } | Select-Object -Unique)
    return @($norm | Where-Object { $p = $_; -not ($norm | Where-Object { $_ -ne $p -and ($p.StartsWith("$_\", 'OrdinalIgnoreCase') -or $p.StartsWith("$_/", 'OrdinalIgnoreCase')) }) })
}

function Grant-AppAccountModify {
    # Gives $Account Modify on $Path, inherited by everything below it. Returns @{ Ok; Detail }.
    param([string]$Path, [string]$Account)
    if (-not (Get-Command icacls.exe -ErrorAction SilentlyContinue)) { return @{ Ok = $false; Detail = 'icacls.exe not available on this machine' } }
    $out = & icacls.exe $Path /grant "${Account}:(OI)(CI)M" /C 2>&1
    if ($LASTEXITCODE -eq 0) { return @{ Ok = $true; Detail = "$Account : Modify" } }
    return @{ Ok = $false; Detail = (($out | Out-String).Trim() -replace '\s+', ' ') }
}

function Test-AppAccountModify {
    # True when $Account has an Allow ACE including Modify on $Path
    param([string]$Path, [string]$Account)
    try { $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop } catch { return $false }
    $modify = [System.Security.AccessControl.FileSystemRights]::Modify
    return [bool]($acl.Access | Where-Object {
        $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -ieq $Account -and (($_.FileSystemRights -band $modify) -eq $modify)
    })
}
