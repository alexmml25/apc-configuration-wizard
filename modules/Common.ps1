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
        Error is set (and DeviceNr empty) when a rule cannot be applied.
    #>
    param([Parameter(Mandatory)] $Machine, [Parameter(Mandatory)] [object]$Manifest)

    $rules  = $Manifest.CNCnetPDM.DeviceNrRules
    $family = [string]$Machine.AssetFamily
    if (-not $family) { $family = [string]$Machine.CNCType }
    $key  = ($family.Trim() -replace '\s+', '_').ToUpper()
    $info = @{ Family = $key; DeviceNr = ''; DriverDll = ([string]$Machine.DLLName).Trim(); Error = '' }

    $digit = $rules.FamilyDigits.PSObject.Properties[$key]
    if (-not $digit) {
        $info.Error = "Asset family '$family' has no Device Nr digit (known: $(($rules.FamilyDigits.PSObject.Properties.Name) -join ', '))"
        return $info
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
        the manifest whose paths point there, so Steps 3, 8, 9 and 10 change only the copies.
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

function Test-SandboxPath {
    # True when not in test mode, or when $Path is inside the sandbox root (test mode must not create
    # folders outside the sandbox, e.g. on instrument shares)
    param([hashtable]$State, [string]$Path)
    $root = $State['SandboxRoot']
    if (-not $root) { return $true }
    $full = [System.IO.Path]::GetFullPath($Path)
    return $full.StartsWith([System.IO.Path]::GetFullPath($root), [System.StringComparison]::OrdinalIgnoreCase)
}
