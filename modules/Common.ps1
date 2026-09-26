#Requires -Version 5.1
<#
.SYNOPSIS
    Shared helpers dot-sourced by step modules (not a step itself).
#>

function Get-CNCDeviceInfo {
    <#
        Derives CNCnetPDM identifiers for a Site DB machine using Manifest.CNCnetPDM.DeviceNrRules:
          Generation  - from the asset family suffix (_IV / _V)
          DeviceNr    - <generation prefix><last digits of machine name, 2 digits>
                        e.g. CITIZEN_L20X_IV + Humacao_L20X_8 -> 1008, CITIZEN_L20E_V + MCR-CNC-0004 -> 1104
          DriverDll   - RS232 DLL field for the generation (citizenm.dll / mitsubishim.dll)
        Error is set (and DeviceNr empty) when a rule cannot be applied.
    #>
    param([Parameter(Mandatory)] $Machine, [Parameter(Mandatory)] [object]$Manifest)

    $rules  = $Manifest.CNCnetPDM.DeviceNrRules
    $family = [string]$Machine.AssetFamily
    if (-not $family) { $family = [string]$Machine.CNCType }
    $info = @{ Generation = ''; DeviceNr = ''; DriverDll = ''; Error = '' }

    if ($family -notmatch '(?i)[_\s](IV|V)\s*$') {
        $info.Error = "Asset family '$family' does not end in _IV or _V"
        return $info
    }
    $info.Generation = $Matches[1].ToUpper()
    $gen = $rules.Generations.($info.Generation)
    $info.DriverDll = $gen.DriverDll

    if ([string]$Machine.MachineName -notmatch '(\d+)\s*$') {
        $info.Error = "Machine name '$($Machine.MachineName)' does not end in a CNC number"
        return $info
    }
    $num = [int]$Matches[1]
    if ($num -lt 1 -or $num -gt 99) {
        $info.Error = "CNC number $num from '$($Machine.MachineName)' is outside 1-99"
        return $info
    }
    $info.DeviceNr = '{0}{1:D2}' -f $gen.Prefix, $num
    return $info
}

function Get-AssignedCNCs {
    <#
        Returns the machines assigned to CNC1..CNC{DOCCount} (CNC n = DOC instance n), as hashtables
        with CNCIndex, DeviceNr, DriverDll, Generation and DeviceNrError added.
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
        $h['Generation']    = $info.Generation
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
        Paths of the five DOC XML files for DOC instance $N. DocDb, DOC_II and PartLookup live in
        DOC_II\, SpcDb and IqsDocSpcDataCollector in DOC_II\Plugins\IQS\ (SOP); if a file is not in its
        expected folder the other folder is used when the file exists there.
    #>
    param([Parameter(Mandatory)] [object]$Manifest, [Parameter(Mandatory)] [int]$N)
    $doc  = $Manifest.DOC
    $base = $doc.BasePath       -replace '\{N\}', $N
    $iqs  = $doc.PluginsIQSPath -replace '\{N\}', $N
    $paths = [ordered]@{ BaseDir = $base; IqsDir = $iqs }   # keys are case-insensitive: not 'Iqs'
    foreach ($f in @(
        @{ Key = 'DocDb';      File = $doc.DocDBXml;        Dir = $base; Alt = $iqs  },
        @{ Key = 'DocII';      File = $doc.DocIIXml;        Dir = $base; Alt = $iqs  },
        @{ Key = 'PartLookup'; File = $doc.PartLookupXml;   Dir = $base; Alt = $iqs  },
        @{ Key = 'SpcDb';      File = $doc.SpcDBXml;        Dir = $iqs;  Alt = $base },
        @{ Key = 'Iqs';        File = $doc.IqsCollectorXml; Dir = $iqs;  Alt = $base })) {
        $p   = Join-Path $f.Dir $f.File
        $alt = Join-Path $f.Alt $f.File
        $paths[$f.Key] = if (-not (Test-Path $p) -and (Test-Path $alt)) { $alt } else { $p }
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
          <Root>\DOC-{n}\DOC_II\  DOC XMLs (SpcDb / Iqs under Plugins\IQS)
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
        $bases  = @($Manifest.CNCnetPDM.DeviceNrRules.Generations.PSObject.Properties | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Value.DriverDll) })
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
        foreach ($key in 'DocDb', 'DocII', 'PartLookup') { Copy-Into $src[$key] $dst.BaseDir }
        foreach ($key in 'SpcDb', 'Iqs')                 { Copy-Into $src[$key] $dst.IqsDir }
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
