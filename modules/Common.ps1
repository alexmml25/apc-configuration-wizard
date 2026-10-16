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

function Get-CurrentDOCAssignment {
    <#
        What this VM has configured now: DOC-n's machine = DBId of the AssetConfiguration in its
        IqsDocSpcDataCollector.xml (Step 9 writes it). Counted from DOC-1 up while the name is one of $MachineNames
        (the Site DB machines), so a fresh install's template value does not count. Returns @{ 1 = 'Citizen 08'; ... }.
    #>
    param([Parameter(Mandatory)] [object]$Manifest, [string[]]$MachineNames = @())
    $cur = @{}
    for ($n = 1; $n -le [int]$Manifest.DOC.MaxInstances; $n++) {
        $iqs = (Get-DOCFilePaths -Manifest $Manifest -N $n).Iqs
        if (-not (Test-Path -LiteralPath $iqs)) { break }
        $name = ''
        try {
            $x = New-Object System.Xml.XmlDocument
            $x.LoadXml([System.IO.File]::ReadAllText($iqs))
            $node = $x.SelectSingleNode('/Configuration/Assets/AssetConfiguration/DBId')
            if ($node) { $name = $node.InnerText.Trim() }
        } catch { }
        if (-not $name -or ($MachineNames.Count -gt 0 -and $name -notin $MachineNames)) { break }
        $cur[$n] = $name
    }
    $cur
}

# DOC timeouts on the Machines & DOC page (seconds; one value for every DOC instance). Step 9 writes a changed value.
$Script:DOCTimeoutDefs = @(
    @{ Key = 'MaxTimeToWaitForAllInspectionGroups'; File = 'DocII';      Label = 'Wait for all measurement results of a part' }
    @{ Key = 'MaxTimeToWaitForAllCalculationGroups'; File = 'DocII';     Label = 'Wait for all offset calculations' }
    @{ Key = 'MaxTimeToWaitForOperatorResponse';    File = 'CompactHmi'; Label = 'Wait for the operator to respond' }
)

function Get-DOCTimeoutFile {
    # DOC_II.xml or Plugins\CompactHMI\CompactHMIOperatorInterface.xml of DOC instance $N
    param([Parameter(Mandatory)] [object]$Manifest, [Parameter(Mandatory)] [int]$N, [Parameter(Mandatory)] [string]$File)
    $paths = Get-DOCFilePaths -Manifest $Manifest -N $N
    if ($File -eq 'DocII') { return $paths.DocII }
    $rel = if ($Manifest.DOC.PSObject.Properties['CompactHmiXml']) { [string]$Manifest.DOC.CompactHmiXml } else { 'Plugins\CompactHMI\CompactHMIOperatorInterface.xml' }
    Join-Path $paths.BaseDir $rel
}

function Get-DOCTimeouts {
    <#
        Current DOC timeouts read from the first DOC instance that has the file: @{ <Key> = '2400'; ... }.
        A missing element in CompactHMIOperatorInterface.xml means the plugin default (1800 s); '' = not readable.
    #>
    param([Parameter(Mandatory)] [object]$Manifest)
    $res = @{}
    foreach ($d in $Script:DOCTimeoutDefs) {
        $res[$d.Key] = ''
        for ($n = 1; $n -le [int]$Manifest.DOC.MaxInstances; $n++) {
            $f = Get-DOCTimeoutFile -Manifest $Manifest -N $n -File $d.File
            if (-not (Test-Path -LiteralPath $f)) { continue }
            try {
                $x = New-Object System.Xml.XmlDocument
                $x.LoadXml([System.IO.File]::ReadAllText($f))
                $node = $x.SelectSingleNode("//$($d.Key)")   # DOC_II.xml nests them
                $res[$d.Key] = if ($node) { $node.InnerText.Trim() } elseif ($d.File -eq 'CompactHmi') { '1800' } else { '' }
            } catch { }
            break
        }
    }
    $res
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

function Get-ApcRoot {
    <#
        The Configuration Manager's work folder: Manifest.APC.InstallRoot (D:\APC_Config), or the same folder on C:
        when that drive is not a ready fixed disk (no D:, or D: is a DVD drive). Runs, state, logs and the work
        files (OPC UA stack copy, client pki) all go under it.
    #>
    param([object]$Manifest)
    $cfg = 'D:\APC_Config'
    if ($Manifest -and $Manifest.PSObject.Properties['APC'] -and $Manifest.APC.PSObject.Properties['InstallRoot'] -and $Manifest.APC.InstallRoot) {
        $cfg = [Environment]::ExpandEnvironmentVariables([string]$Manifest.APC.InstallRoot)
    }
    if ($cfg -notmatch '^[A-Za-z]:') { return $cfg }
    $drive = $cfg.Substring(0, 2).ToUpper()
    $ok = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.Name.TrimEnd('\', '/').ToUpper() -eq $drive -and $_.DriveType -eq 'Fixed' -and $_.IsReady }).Count
    if ($ok) { return $cfg }
    return 'C:' + $cfg.Substring(2)
}

function Resolve-ApcPath {
    # '{APCROOT}\Backups' -> '<work folder>\Backups' (manifest paths under the work folder)
    param([string]$Path, [object]$Manifest)
    if (-not $Path) { return $Path }
    return $Path.Replace('{APCROOT}', (Get-ApcRoot $Manifest))
}

function Get-RunDir {
    <#
        Folder for this run's Logs / Backups / Reports. The wizard gives each run its own folder,
        State.RunRoot = <work folder>\<Type>_<yyyyMMdd-HHmmss>, with Logs, Backups and Reports inside.
        Without RunRoot (a step run on its own) the shared folders are used: <work folder>\Logs,
        <Manifest.Backup.Root>\<yyyyMMdd-HHmmss> and <work folder>\Reports. The folder is created.
    #>
    param([Parameter(Mandatory)] [hashtable]$State, [Parameter(Mandatory)] [ValidateSet('Logs', 'Backups', 'Reports')] [string]$Name,
          [object]$Manifest)
    $dir = if ($State['RunRoot']) { Join-Path ([string]$State['RunRoot']) $Name }
           elseif ($Name -eq 'Backups') {
               $broot = if ($Manifest -and $Manifest.Backup.Root) { Resolve-ApcPath ([string]$Manifest.Backup.Root) $Manifest } else { Join-Path (Get-ApcRoot $Manifest) 'Backups' }
               Join-Path $broot (Get-Date -Format 'yyyyMMdd-HHmmss') }
           else { Join-Path (Get-ApcRoot $Manifest) $Name }
    New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    return $dir
}

function Save-FileBackup {
    <#
        Before a step changes a file: "<file>.<Stamp>.bak" next to it (as always), and the same original into this
        run's Backups\Files\<drive>\<path> (State.RunRoot), so one run folder holds everything the run changed.
        Returns the .bak path.
    #>
    param([Parameter(Mandatory)] [string]$Path, [Parameter(Mandatory)] [string]$Stamp, [hashtable]$State)
    $bak = "$Path.$Stamp.bak"
    Copy-Item -LiteralPath $Path -Destination $bak -Force
    if ($State -and $State['RunRoot']) {
        try {
            $full = [IO.Path]::GetFullPath($Path)
            $rel  = if ($full -match '^([A-Za-z]):\\(.*)$') { Join-Path $Matches[1] $Matches[2] } else { $full.TrimStart('\', '/') }
            $dest = Join-Path (Join-Path (Join-Path ([string]$State['RunRoot']) 'Backups') 'Files') $rel
            New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
            if (-not (Test-Path -LiteralPath $dest)) { Copy-Item -LiteralPath $Path -Destination $dest -Force }   # first original of the run
        } catch { }
    }
    return $bak
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

function Close-ProcessMessageBoxes {
    <#
        Closes the message boxes (dialog class #32770) that one process shows, by pressing their OK/Cancel/Close,
        and returns their texts as "<title>: <text>". Only that process's dialogs are touched (no other UI).
        DOC shows "PartLookup revision in configuration (MAX) does not exist or is unreachable" at start while the
        database has no PartLookup data yet (VM 2026-10-15); left open it can hold DOC up.
    #>
    param([Parameter(Mandatory)] [int]$ProcessId)
    if (-not ('ApcMsgBox' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class ApcMsgBox {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern IntPtr GetDlgItem(IntPtr h, int id);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    static string Cls(IntPtr h) { var s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }
    static string Txt(IntPtr h) { var s = new StringBuilder(1024); GetWindowText(h, s, 1024); return s.ToString(); }
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    // pid > 0: that process's dialogs. pid = 0: dialogs with one of the given titles, whoever owns them - a
    // service-notification MessageBox (DOC's PartLookup_DB) is drawn by csrss, not by the app (VM 2026-10-15)
    public static List<string> CloseAll(uint pid) { return Close(pid, null); }
    public static List<string> CloseTitled(string[] titles) { return Close(0, titles); }
    public static List<IntPtr> LastClosed = new List<IntPtr>();
    static List<string> Close(uint pid, string[] titles) {
        var found = new List<IntPtr>();
        EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p);
            if (!IsWindowVisible(h) || Cls(h) != "#32770") return true;
            if (pid > 0 && p == pid) found.Add(h);
            else if (pid == 0 && titles != null && Array.IndexOf(titles, Txt(h)) >= 0) found.Add(h);
            return true; }, IntPtr.Zero);
        LastClosed = found;
        var texts = new List<string>();
        foreach (var h in found) {
            var parts = new List<string>();
            EnumChildWindows(h, (c, l) => { if (Cls(c) == "Static") { var t = Txt(c).Trim(); if (t.Length > 0) parts.Add(t); } return true; }, IntPtr.Zero);
            texts.Add(Txt(h) + ": " + string.Join(" ", parts));
            // BM_CLICK on OK (1), else Cancel (2), else WM_CLOSE
            IntPtr b = GetDlgItem(h, 1); if (b == IntPtr.Zero) b = GetDlgItem(h, 2);
            if (b != IntPtr.Zero) PostMessage(b, 0x00F5, IntPtr.Zero, IntPtr.Zero); else PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero);
        }
        return texts;
    }
}
'@
    }
    return @([ApcMsgBox]::CloseAll([uint32]$ProcessId))
}

function Close-TitledMessageBoxes {
    <#
        Closes message boxes with one of the given titles whoever draws them (DOC's PartLookup_DB comes from csrss:
        a service-notification box, so Close-ProcessMessageBoxes does not see it). Only the listed titles are
        touched. Returns @{ Closed = "<title>: <text>"...; Stuck = ... } - Stuck when the box is still there 2 s
        later (Windows can block clicks on system-owned windows).
    #>
    param([Parameter(Mandatory)] [string[]]$Titles)
    [void](Close-ProcessMessageBoxes -ProcessId 0 -ErrorAction SilentlyContinue)   # loads the type
    $texts = @([ApcMsgBox]::CloseTitled($Titles))
    $hwnds = @([ApcMsgBox]::LastClosed)
    if (-not $texts) { return @{ Closed = @(); Stuck = @() } }
    Start-Sleep -Seconds 2
    $stuck = @(); $closed = @()
    for ($i = 0; $i -lt $texts.Count; $i++) { if ([ApcMsgBox]::IsWindow($hwnds[$i])) { $stuck += $texts[$i] } else { $closed += $texts[$i] } }
    return @{ Closed = $closed; Stuck = $stuck }
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

function Start-MissingApps {
    <#
        Before Step 13 checks: starts whatever should be running and is not (user 2026-10-16: "Verification opens
        anything that needs to be opened"). Never restarts anything that runs.
          services   PostgreSQL, deviceWise dwcore + dwts, CNCnetPDM (Manifest.Services, dwts as Step 4 needs it)
          data apps  File Manager, Data Collector, Data Analyzer (the exe next to each Manifest.DataApps.*Config)
          DOC        each assigned DOC-n (DynamicOffsetCalculation.exe); its PartLookup_DB box is closed until it holds
                     its deviceWise OPC UA connection (DOC.KnownStartupDialogTitles, DOC.ConnectWaitSeconds), as Step 9
        Returns a list of @{ Name; Status = PASS|WARN|FAIL; Detail } - only for what had to be started.
    #>
    param([Parameter(Mandatory)] [object]$Manifest, [Parameter(Mandatory)] [hashtable]$State)
    $out = New-Object System.Collections.Generic.List[object]

    # -- services --------------------------------------------------------------------------------------------
    $svcs = @($Manifest.Services.PostgreSQL, $Manifest.Services.DeviceWise, 'dwts', $Manifest.Services.CNCnetPDM) | Where-Object { $_ }
    foreach ($n in $svcs) {
        $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
        if (-not $svc -or $svc.Status -eq 'Running') { continue }
        try {
            Start-Service -Name $n -ErrorAction Stop
            $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds(60))
            $note = if ($n -eq $Manifest.Services.DeviceWise) { ' - CNCAsset / CNCType are empty after a dwcore start (known limitation): re-run Step 8 if the CNCAsset checks fail' } else { '' }
            $out.Add(@{ Name = "service $n"; Status = $(if ($note) { 'WARN' } else { 'PASS' }); Detail = "was $($svc.Status) before; started$note" })
        } catch { $out.Add(@{ Name = "service $n"; Status = 'FAIL'; Detail = "could not be started: $($_.Exception.Message)" }) }
    }

    # -- data applications ---------------------------------------------------------------------------------
    $da = $Manifest.DataApps
    foreach ($cfg in @($da.FileManagerConfig, $da.DataCollectorConfig, $da.DataAnalyzerConfig)) {
        $exe  = ([string]$cfg) -replace '\.config$', ''
        $name = [IO.Path]::GetFileNameWithoutExtension($exe)
        if (-not (Test-Path -LiteralPath $exe) -or (Get-Process -Name $name -ErrorAction SilentlyContinue)) { continue }
        try {
            $p = Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe -Parent) -PassThru
            Start-Sleep -Seconds 5
            $out.Add(@{ Name = $name; Status = $(if ($p.HasExited) { 'FAIL' } else { 'PASS' }); Detail = $(if ($p.HasExited) { "exited right after starting (exit code $($p.ExitCode))" } else { "was not running; started (PID $($p.Id))" }) })
        } catch { $out.Add(@{ Name = $name; Status = 'FAIL'; Detail = "could not be started: $($_.Exception.Message)" }) }
    }

    # -- DOC instances -------------------------------------------------------------------------------------
    $docCfg = $Manifest.DOC
    $started = @()
    $assigned = Get-AssignedCNCs -State $State -Manifest $Manifest     # assignment unrolls its ,$result (@() would nest it)
    foreach ($m in $assigned) {
        $n = [int]$m.CNCIndex
        if (Get-DOCProcess -Manifest $Manifest -Instance $n) { continue }
        $exe = Join-Path (([string]$docCfg.BasePath).Replace('{N}', "$n")) 'DynamicOffsetCalculation.exe'
        if (-not (Test-Path -LiteralPath $exe)) { continue }
        try { [void](Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe -Parent) -PassThru); $started += $n }
        catch { $out.Add(@{ Name = "DOC-$n"; Status = 'FAIL'; Detail = "could not be started: $($_.Exception.Message)" }) }
    }
    if ($started) {
        $titles  = @($docCfg.KnownStartupDialogTitles | Where-Object { $_ })
        $opcPort = [int]$Manifest.DeviceWise.OpcUaEndpointPort
        $wait    = if ($docCfg.PSObject.Properties['ConnectWaitSeconds']) { [int]$docCfg.ConnectWaitSeconds } else { 120 }
        $closed  = @()
        $deadline = (Get-Date).AddSeconds($wait)
        do {
            if ($titles) { $closed += @((Close-TitledMessageBoxes -Titles $titles).Closed) }
            $down = @($started | Where-Object {
                $p = Get-DOCProcess -Manifest $Manifest -Instance $_
                -not $p -or -not @(Get-ProcessTcpConnections -ProcessId $p.Id | Where-Object { $_.RemotePort -eq $opcPort }).Count })
            if ($down) { Start-Sleep -Seconds 3 }
        } while ($down -and (Get-Date) -lt $deadline)
        if ($titles) { $closed += @((Close-TitledMessageBoxes -Titles $titles).Closed) }
        foreach ($n in $started) {
            $ok = $down -notcontains $n
            $out.Add(@{ Name = "DOC-$n"; Status = $(if ($ok) { 'PASS' } else { 'WARN' })
                        Detail = "was not running; started$(if ($ok) { ', connected to deviceWise OPC UA' } else { ", no deviceWise connection after $wait s" })$(if ($closed) { "; closed start-up message: $(@($closed | Select-Object -Unique) -join ' | ')" })" })
        }
    }
    return ,$out
}

function Get-OperatorAdInfo {
    # AD employee number, mail and first name of DOMAIN\account (DirectorySearcher: no RSAT needed); empty when not found.
    # Performed By on the draft checklist and the 'draft ready' e-mail (as the APC Installation Manager reads them at sign-in)
    param([string]$Account)
    $info = @{ EmployeeNumber = ''; Mail = ''; GivenName = '' }
    $sam = ([string]$Account -split '\\')[-1].Trim()
    if (-not $sam -or $sam -notmatch '^[A-Za-z0-9._-]+$') { return $info }
    try {
        $s = New-Object System.DirectoryServices.DirectorySearcher
        $s.Filter = "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$sam))"
        $s.ClientTimeout = [TimeSpan]::FromSeconds(15)
        foreach ($p in 'employeeNumber', 'mail', 'givenName') { [void]$s.PropertiesToLoad.Add($p) }
        $f = $s.FindOne()
        if ($f) {
            if ($f.Properties['employeenumber'].Count) { $info.EmployeeNumber = [string]$f.Properties['employeenumber'][0] }
            if ($f.Properties['mail'].Count)           { $info.Mail           = [string]$f.Properties['mail'][0] }
            if ($f.Properties['givenname'].Count)      { $info.GivenName      = [string]$f.Properties['givenname'][0] }
        }
    } catch { }
    return $info
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

function Get-AccountLocalAppData {
    <#
        %LOCALAPPDATA% of an account (e.g. the service account DOC runs as), from its profile in ProfileList,
        so a per-user store is found whichever account runs the wizard. Falls back to this user's LOCALAPPDATA
        when the account is this user, empty, or has no profile on this machine.
    #>
    param([string]$Account)
    $me = "$env:USERDOMAIN\$env:USERNAME"
    if (-not $Account -or $Account -ieq $me) { return $env:LOCALAPPDATA }
    try {
        $sid = (New-Object System.Security.Principal.NTAccount($Account)).Translate([System.Security.Principal.SecurityIdentifier]).Value
        $img = (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction Stop).ProfileImagePath
        if ($img) { return (Join-Path ([Environment]::ExpandEnvironmentVariables($img)) 'AppData\Local') }
    } catch { }
    return $env:LOCALAPPDATA
}

function Convert-MedtronicPath {
    # 'C:\Medtronic\...' -> '<Drive>\Medtronic\...' (any drive letter); other paths unchanged
    param([string]$Path, [Parameter(Mandatory)] [string]$Drive)
    if (-not $Path) { return $Path }
    return [regex]::Replace($Path, '^[A-Za-z]:(?=\\Medtronic(\\|$))', $Drive.TrimEnd('\').Substring(0, 2), 'IgnoreCase')
}

function Find-MedtronicInstall {
    <#
        Where the Installation Manager put the Medtronic apps (C: or D:, HANDOFF-InstallDrive.md). Per app in
        Manifest.MedtronicInstall.Apps, first match wins:
          1. Programs and Features InstallLocation (DisplayName regex), 2. the service's ImagePath (CNCnetPDM),
          3. <drive>\Medtronic\<Folder>\<Exe> on each of Manifest.MedtronicInstall.Drives.
        Only folders under <drive>\Medtronic count. Returns @{ Drive; Apps = @(@{ Name; Folder; Source }); Missing; Error }:
        Error when no app is found or the apps are on different drives (never a silent C:).
    #>
    param([Parameter(Mandatory)] [object]$Manifest)
    $cfg   = $Manifest.MedtronicInstall
    $keys  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    # (PSObject.Properties: most uninstall entries have no InstallLocation, and APC_Config.ps1 runs in StrictMode)
    $uninst = @(Get-ItemProperty $keys -ErrorAction SilentlyContinue |
                Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.PSObject.Properties['InstallLocation'] -and $_.DisplayName -and $_.InstallLocation })
    $apps = @(); $missing = @()
    foreach ($a in @($cfg.Apps)) {
        $count = if ($a.PSObject.Properties['Instances']) { [int]$a.Instances } else { 1 }
        for ($i = 1; $i -le $count; $i++) {
            $name   = ([string]$a.Name).Replace('{N}', "$i")
            $folder = ([string]$a.Folder).Replace('{N}', "$i")
            $found  = $null
            $u = $uninst | Where-Object { $_.DisplayName -match ([string]$a.DisplayName).Replace('{N}', "$i") } | Select-Object -First 1
            if ($u) {
                $loc = ([string]$u.InstallLocation).Trim('"').TrimEnd('\')
                if ($loc -match '^[A-Za-z]:\\Medtronic\\') { $found = @{ Name = $name; Folder = $loc; Source = "Programs and Features ($($u.DisplayName))" } }
            }
            if (-not $found -and $a.PSObject.Properties['Service'] -and $a.Service) {
                $svcKey = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$($a.Service)" -ErrorAction SilentlyContinue
                $img = if ($svcKey -and $svcKey.PSObject.Properties['ImagePath']) { $svcKey.ImagePath } else { $null }
                if ($img) {
                    $exe = ([Environment]::ExpandEnvironmentVariables([string]$img) -replace '^"([^"]+)".*$', '$1') -replace '\s+[-/].*$', ''
                    $dir = Split-Path $exe -Parent
                    if ($dir -match '^[A-Za-z]:\\Medtronic\\') { $found = @{ Name = $name; Folder = $dir; Source = "service $($a.Service)" } }
                }
            }
            if (-not $found) {
                foreach ($d in @($cfg.Drives)) {
                    $dir = "$d\Medtronic\$folder"
                    # plain string: Join-Path fails on a drive that does not exist (a VM without D:)
                    if (Test-Path -LiteralPath "$dir\$($a.Exe)" -ErrorAction SilentlyContinue) { $found = @{ Name = $name; Folder = $dir; Source = "$($a.Exe) on $d" }; break }
                }
            }
            if ($found) { $apps += $found } else { $missing += $name }
        }
    }
    $drives = @($apps | ForEach-Object { $_.Folder.Substring(0, 2).ToUpper() } | Select-Object -Unique)
    $err = if (-not $apps) { 'No Medtronic app found in Programs and Features, the CNCnetPDM service or ' + ((@($cfg.Drives) | ForEach-Object { "$_\Medtronic" }) -join ' / ') }
           elseif ($drives.Count -gt 1) { 'The Medtronic apps are on different drives: ' + (($apps | ForEach-Object { "$($_.Name) $($_.Folder)" }) -join '; ') }
           else { '' }
    return @{ Drive = $(if ($drives.Count -eq 1) { $drives[0] } else { '' }); Apps = $apps; Missing = $missing; Error = $err }
}

function Set-ManifestMedtronicDrive {
    # A copy of the manifest with every '<X>:\Medtronic\...' value moved to $Drive (the run uses the copy)
    param([Parameter(Mandatory)] [object]$Manifest, [Parameter(Mandatory)] [string]$Drive)
    $copy = $Manifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $walk = {
        param($o)
        foreach ($p in @($o.PSObject.Properties)) {
            $v = $p.Value
            if ($v -is [string]) { $p.Value = Convert-MedtronicPath -Path $v -Drive $Drive }
            elseif ($v -is [System.Management.Automation.PSCustomObject]) { & $walk $v }
            elseif ($v -is [System.Array]) {
                for ($i = 0; $i -lt $v.Count; $i++) {
                    if ($v[$i] -is [string]) { $v[$i] = Convert-MedtronicPath -Path $v[$i] -Drive $Drive }
                    elseif ($v[$i] -is [System.Management.Automation.PSCustomObject]) { & $walk $v[$i] }
                }
            }
        }
    }
    & $walk $copy
    return $copy
}

function Set-StateMedtronicDrive {
    # The page values that hold Medtronic paths (local data root, instrument Broadcast / local Source paths)
    param([Parameter(Mandatory)] [hashtable]$State, [Parameter(Mandatory)] [string]$Drive)
    if ($State['DataAppsLocalRoot']) { $State['DataAppsLocalRoot'] = Convert-MedtronicPath -Path ([string]$State['DataAppsLocalRoot']) -Drive $Drive }
    foreach ($inst in @($State['DataAppsInstruments'])) {
        if ($inst -isnot [System.Collections.IDictionary]) { continue }
        foreach ($k in 'SourcePath', 'ErrorPath', 'BroadcastPath') { if ($inst[$k]) { $inst[$k] = Convert-MedtronicPath -Path ([string]$inst[$k]) -Drive $Drive } }
    }
    $State['MedtronicDrive'] = $Drive
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
