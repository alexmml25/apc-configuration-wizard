#Requires -Version 5.1
<#
.SYNOPSIS
    Step 8 - Configure CNCnetPDM machine entries, license, and INI files.
.DESCRIPTION
    Machines are the DOC-assigned CNCs (CNC n = DOC instance n). DeviceNr comes from Get-CNCDeviceInfo
    (Common.ps1): family digit + 3-digit machine number, e.g. CITIZEN_L20X_IV + 'Citizen 08' -> 1008;
    the driver DLL is the machine's DLL name from the Site DB.

    - License key (wizard input, else manifest DefaultLicense) -> CNCnetPDM.ini [GENERAL] License
    - CNCnetPDM.ini [RS232]: one active entry per CNC (existing active entries replaced)
        {n} = {DeviceNr};19200;8;N;1;{MachineName};{IP};{Port};0;localhost;{n};0;none;none;0;{Site DB DLL}
    - melcfg.ini: one [Machine{nn}] section per CNC (Device=TCP{n}) and TCP{n} = {IP},{Port} in [HOSTS]
    - Driver files: {dll}_CNC{n}.dll / .ini renamed to {dll}_{DeviceNr}.dll / .ini
    - Restarts the CNCnetPDM service and verifies it starts cleanly
#>

. (Join-Path $PSScriptRoot 'Common.ps1')

function Invoke-CNCnetPDM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [switch]$NonInteractive
    )

    Write-Log STEP "CNCnetPDM Configuration"

    $cncPdm   = $Manifest.CNCnetPDM
    $d        = $cncPdm.Defaults
    $machines = Get-AssignedCNCs -State $State -Manifest $Manifest
    $ts       = Get-Date -Format 'yyyyMMdd-HHmmss'

    #region -- Validate machine identifiers ------------------------------------

    if ($machines.Count -eq 0) {
        Add-Result -Phase CNCnetPDM -Check "CNC assignments" -Status FAIL -Detail "No DOC-assigned machines in State"
        throw "No CNC machines assigned - run Site DB fetch and select DOC machines first."
    }
    $bad = $false
    foreach ($m in $machines) {
        if ($m.DeviceNrError) {
            Add-Result -Phase CNCnetPDM -Check "CNC$($m.CNCIndex) DeviceNr ($($m.MachineName))" -Status FAIL -Detail $m.DeviceNrError
            $bad = $true
        } else {
            Add-Result -Phase CNCnetPDM -Check "CNC$($m.CNCIndex) DeviceNr ($($m.MachineName))" -Status PASS `
                -Detail "$($m.DeviceNr) / $($m.DriverDll) ($($m.AssetFamily))"
        }
    }
    $dupes = $machines | Where-Object { $_.DeviceNr } | Group-Object { $_.DeviceNr } | Where-Object { $_.Count -gt 1 }
    foreach ($g in $dupes) {
        Add-Result -Phase CNCnetPDM -Check "DeviceNr $($g.Name) unique" -Status FAIL `
            -Detail "Used by $(($g.Group | ForEach-Object { $_.MachineName }) -join ', ')"
        $bad = $true
    }
    if ($bad) { throw "CNCnetPDM DeviceNr could not be derived for all CNCs - fix Site DB asset family / machine names." }

    #endregion

    #region -- Locate install directory ---------------------------------------

    $cncPdmDir = $null
    foreach ($candidate in @($cncPdm.InstallDir, $cncPdm.FallbackDir)) {
        if ($candidate -and (Test-Path $candidate)) { $cncPdmDir = $candidate; break }
    }
    if (-not $cncPdmDir) {
        $found = Get-ChildItem 'C:\' -Directory -Filter '*CNCnetPDM*' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $cncPdmDir = $found.FullName }
    }
    if (-not $cncPdmDir) {
        Add-Result -Phase CNCnetPDM -Check "CNCnetPDM directory" -Status FAIL -Detail "Cannot locate CNCnetPDM install directory"
        throw "CNCnetPDM directory not found. Check manifest InstallDir / FallbackDir."
    }
    Add-Result -Phase CNCnetPDM -Check "CNCnetPDM directory" -Status PASS -Detail $cncPdmDir

    $iniPath    = Join-Path $cncPdmDir $cncPdm.IniFile
    $melcfgPath = Join-Path $cncPdmDir $cncPdm.MelcfgFile
    $driverDir  = if ($cncPdm.DriverSubDir) { Join-Path $cncPdmDir $cncPdm.DriverSubDir } else { $cncPdmDir }

    #endregion

    #region -- INI helpers -----------------------------------------------------

    function Read-IniLines {
        param([string]$Path)
        $list = [System.Collections.Generic.List[string]]::new()
        $list.AddRange([string[]][System.IO.File]::ReadAllLines($Path))
        return ,$list
    }

    function Write-IniLines {
        param([string]$Path, [System.Collections.Generic.List[string]]$Lines)
        Copy-Item $Path "$Path.$ts.bak" -Force
        [System.IO.File]::WriteAllText($Path, (($Lines -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
    }

    # Returns @{ Header = <index of [Section]>; End = <index of next section header or Count> } or $null
    function Find-Section {
        param([System.Collections.Generic.List[string]]$Lines, [string]$Section)
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i].Trim() -ieq "[$Section]") {
                $end = $i + 1
                while ($end -lt $Lines.Count -and $Lines[$end].Trim() -notmatch '^\[') { $end++ }
                return @{ Header = $i; End = $end }
            }
        }
        return $null
    }

    # Removes lines matching $Pattern inside a section, then collapses repeated blank lines
    function Remove-SectionLines {
        param([System.Collections.Generic.List[string]]$Lines, [string]$Section, [string]$Pattern)
        $sec = Find-Section $Lines $Section
        if (-not $sec) { return }
        for ($i = $sec.End - 1; $i -gt $sec.Header; $i--) {
            if ($Lines[$i] -match $Pattern) { $Lines.RemoveAt($i) }
        }
        $sec = Find-Section $Lines $Section
        for ($i = $sec.End - 1; $i -gt $sec.Header + 1; $i--) {
            if (-not $Lines[$i].Trim() -and -not $Lines[$i - 1].Trim()) { $Lines.RemoveAt($i) }
        }
        if ($sec.Header + 1 -lt $Lines.Count -and -not $Lines[$sec.Header + 1].Trim()) { $Lines.RemoveAt($sec.Header + 1) }
    }

    function Set-IniKey {
        param([System.Collections.Generic.List[string]]$Lines, [string]$Section, [string]$Key, [string]$Value)
        $sec = Find-Section $Lines $Section
        if (-not $sec) { throw "[$Section] section not found" }
        for ($i = $sec.Header + 1; $i -lt $sec.End; $i++) {
            if ($Lines[$i] -match "^\s*$([regex]::Escape($Key))\s*=") { $Lines[$i] = "$Key = $Value"; return }
        }
        $Lines.Insert($sec.Header + 1, "$Key = $Value")
    }

    function Get-MachinePort {
        param($Machine)
        if ("$($Machine.Port)" -match '^\d+$') { [int]$Machine.Port } else { [int]$d.Port }
    }

    #endregion

    #region -- License key ----------------------------------------------------

    $licenseKey = if ($State['CNCnetPDMLicense']) { [string]$State['CNCnetPDMLicense'] } else { [string]$cncPdm.DefaultLicense }
    $licenseKey = $licenseKey.Trim()
    $licenseSrc = if ($State['CNCnetPDMLicense'] -and $State['CNCnetPDMLicense'] -ne $cncPdm.DefaultLicense) { 'entered in wizard' } else { 'manifest default' }

    #endregion

    #region -- CNCnetPDM.ini ---------------------------------------------------

    if (-not (Test-Path $iniPath)) {
        Add-Result -Phase CNCnetPDM -Check "CNCnetPDM.ini" -Status FAIL -Detail "Not found: $iniPath"
        throw "CNCnetPDM.ini not found at $iniPath"
    }
    $ini = Read-IniLines $iniPath

    if ($licenseKey) {
        Set-IniKey $ini 'GENERAL' 'License' $licenseKey
        Add-Result -Phase CNCnetPDM -Check "License key written to [GENERAL]" -Status PASS `
            -Detail "$($licenseKey.Substring(0, [Math]::Min(8, $licenseKey.Length)))... ($licenseSrc)"
    } else {
        Add-Result -Phase CNCnetPDM -Check "License key" -Status WARN `
            -Detail "No license supplied - apply the perpetual license via CNCnetPDM Workbench (License -> View/Edit)."
    }

    $rs = $cncPdm.RS232Section
    if (-not (Find-Section $ini $rs)) { $ini.Add(''); $ini.Add("[$rs]") }
    Remove-SectionLines $ini $rs '^\s*(;\s*)?(CNC)?\d+\s*=|^\s*;\s*For testing only'
    $insertAt = (Find-Section $ini $rs).Header + 1
    foreach ($m in $machines) {
        $n = $m.CNCIndex
        $fields = @(
            $m.DeviceNr, $d.Baud, $d.Databits, $d.Parity, $d.StopBits,
            $m.MachineName, $m.IPAddress, (Get-MachinePort $m), $d.Method, $d.DNSName,
            $n, $d.PLCAddr, $d.Share, $d.LogfileName, $d.LogfileVer, $m.DriverDll
        )
        $ini.Insert($insertAt, "$n = $($fields -join ';')")
        $insertAt++
        Add-Result -Phase CNCnetPDM -Check "CNCnetPDM.ini line $n ($($m.MachineName))" -Status PASS -Detail "DeviceNr $($m.DeviceNr), $($m.IPAddress), $($m.DriverDll)"
    }

    Write-IniLines $iniPath $ini
    Write-Log INFO "CNCnetPDM.ini saved: $iniPath"

    #endregion

    #region -- melcfg.ini ------------------------------------------------------

    if (-not (Test-Path $melcfgPath)) {
        Add-Result -Phase CNCnetPDM -Check "melcfg.ini" -Status FAIL -Detail "Not found: $melcfgPath"
    } else {
        $mel = Read-IniLines $melcfgPath

        # [MachineNN] sections: one per CNC, cloned from the first existing section
        $template = $null; $firstAt = -1
        for ($i = $mel.Count - 1; $i -ge 0; $i--) {
            if ($mel[$i].Trim() -match '^\[Machine\d+\]$') {
                $end = $i + 1
                while ($end -lt $mel.Count -and $mel[$end].Trim() -notmatch '^\[') { $end++ }
                $template = @($mel.GetRange($i + 1, $end - $i - 1))
                $mel.RemoveRange($i, $end - $i)
                $firstAt = $i
            }
        }
        if (-not $template) {
            $template = @('Controller=M7NX', 'Device=TCP1', 'CacheEnable=0')
            $chg      = Find-Section $mel 'CHGAPIVL'
            $firstAt  = if ($chg) { $chg.Header } else { $mel.Count }
        }
        while ($template.Count -gt 0 -and -not $template[-1].Trim()) { $template = @($template | Select-Object -SkipLast 1) }

        $block = [System.Collections.Generic.List[string]]::new()
        foreach ($m in $machines) {
            $n = $m.CNCIndex
            $block.Add(('[Machine{0:D2}]' -f $n))
            foreach ($l in $template) { $block.Add(($l -replace '^(\s*Device\s*=\s*)TCP\d+', "`${1}TCP$n")) }
            $block.Add('')
        }
        $mel.InsertRange($firstAt, $block)

        # [HOSTS]: TCP{n} = IP,Port
        $hs = $cncPdm.HostsSection
        if (-not (Find-Section $mel $hs)) { $mel.Add(''); $mel.Add("[$hs]") }
        Remove-SectionLines $mel $hs '^\s*(;\s*)?TCP\d+\s*='
        $sec = Find-Section $mel $hs
        $insertAt = $sec.End
        while ($insertAt -gt $sec.Header + 1 -and -not $mel[$insertAt - 1].Trim()) { $insertAt-- }
        foreach ($m in $machines) {
            $mel.Insert($insertAt, "TCP$($m.CNCIndex) = $($m.IPAddress),$(Get-MachinePort $m)")
            $insertAt++
            Add-Result -Phase CNCnetPDM -Check "melcfg.ini Machine$('{0:D2}' -f $m.CNCIndex) / TCP$($m.CNCIndex) ($($m.MachineName))" -Status PASS
        }

        Write-IniLines $melcfgPath $mel
        Write-Log INFO "melcfg.ini saved: $melcfgPath"
    }

    #endregion

    #region -- Driver files ----------------------------------------------------

    Write-Log INFO "Driver directory: $driverDir"
    if (-not (Test-Path $driverDir)) {
        Add-Result -Phase CNCnetPDM -Check "Driver directory" -Status FAIL -Detail "Not found: $driverDir"
    } else {
        foreach ($dll in @($machines | ForEach-Object { $_.DriverDll } | Select-Object -Unique)) {
            if (Test-Path (Join-Path $driverDir $dll)) {
                Add-Result -Phase CNCnetPDM -Check "Driver $dll present" -Status PASS
            } else {
                Add-Result -Phase CNCnetPDM -Check "Driver $dll present" -Status WARN -Detail "Not found in $driverDir"
            }
        }

        foreach ($m in $machines) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($m.DriverDll)
            foreach ($ext in 'dll', 'ini') {
                $srcName = "${base}_CNC$($m.CNCIndex).$ext"
                $dstName = "${base}_$($m.DeviceNr).$ext"
                $srcPath = Join-Path $driverDir $srcName
                $dstPath = Join-Path $driverDir $dstName
                if (Test-Path $dstPath) {
                    Add-Result -Phase CNCnetPDM -Check "Driver file $dstName" -Status PASS -Detail "Present"
                } elseif (Test-Path $srcPath) {
                    try {
                        Rename-Item $srcPath $dstName -ErrorAction Stop
                        Add-Result -Phase CNCnetPDM -Check "Driver file $srcName -> $dstName" -Status PASS
                    } catch {
                        Add-Result -Phase CNCnetPDM -Check "Driver file $srcName" -Status FAIL -Detail "Rename failed: $_"
                    }
                } elseif ($ext -eq 'dll') {
                    Add-Result -Phase CNCnetPDM -Check "Driver file $dstName" -Status WARN `
                        -Detail "Neither $srcName nor $dstName found in $driverDir - place/rename manually"
                } else {
                    Write-Log INFO "No $srcName / $dstName in $driverDir (driver ini optional)"
                }
            }
        }
    }

    #endregion

    #region -- Restart CNCnetPDM service and verify ---------------------------

    $svcName = $Manifest.Services.CNCnetPDM
    if ($State['SandboxRoot']) {
        Add-Result -Phase CNCnetPDM -Check "CNCnetPDM service restart" -Status PASS -Detail "Skipped in test mode"
    } else { try {
        Write-Log INFO "Restarting CNCnetPDM service ($svcName)..."
        Restart-Service -Name $svcName -Force -ErrorAction Stop
        Start-Sleep -Seconds 5

        $svc = Get-Service -Name $svcName -ErrorAction Stop
        if ($svc.Status -eq 'Running') {
            Add-Result -Phase CNCnetPDM -Check "CNCnetPDM service" -Status PASS -Detail "Running"
        } else {
            Add-Result -Phase CNCnetPDM -Check "CNCnetPDM service" -Status WARN -Detail "Status: $($svc.Status)"
        }
    } catch {
        Add-Result -Phase CNCnetPDM -Check "CNCnetPDM service restart" -Status WARN -Detail "$_"
    } }

    #endregion

    Write-Log PASS "CNCnetPDM configuration complete."
    Write-Log INFO "Backups (.$ts.bak) written next to CNCnetPDM.ini and melcfg.ini."
    Write-Log INFO "Verify: CNCnetPDM Workbench -> Machine Status should show green for each configured CNC after network connectivity is established."
}
