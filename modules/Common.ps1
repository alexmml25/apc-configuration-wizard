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
    $paths = [ordered]@{ Base = $base; IQS = $iqs }
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
