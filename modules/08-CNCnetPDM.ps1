#Requires -Version 5.1
<#
.SYNOPSIS
    Step 8 - Configure CNCnetPDM machine entries, license, and INI files.
.DESCRIPTION
    - Reads the license key from the Excel file in the repository
    - Writes the license key to CNCnetPDM.ini [License] section
    - For each CNC machine: appends a Line{N} entry in CNCnetPDM.ini [RS232]
    - For each CNC machine: appends TCP{N} entry in melcfg.ini [HOSTS]
    - Renames CNC DLL files to their device-number-based names
    - Restarts the CNCnetPDM service and verifies it starts cleanly
#>

function Invoke-CNCnetPDM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [switch]$NonInteractive
    )

    Write-Log STEP "CNCnetPDM Configuration"

    $machines  = $State['CNCMachines']
    $cncPdm    = $Manifest.CNCnetPDM
    $defaults  = $cncPdm.Defaults

    # Resolve CNCnetPDM install directory
    $cncPdmDir = $null
    foreach ($candidate in @($cncPdm.InstallDir, $cncPdm.FallbackDir)) {
        if (Test-Path $candidate) { $cncPdmDir = $candidate; break }
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

    #region -- Read license key from Excel ------------------------------------

    $licenseKey = ''
    $repoRoot   = $Manifest.APC.RepositoryRoot

    # Search for license Excel file
    $xlFile = Get-ChildItem $repoRoot -Filter $cncPdm.LicenseExcelFile -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $xlFile) {
        # Try any .xlsx with 'License' in name
        $xlFile = Get-ChildItem $repoRoot -Filter '*License*.xlsx' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    if ($xlFile) {
        Write-Log INFO "Reading license key from: $($xlFile.FullName)"
        try {
            $xl = New-Object -ComObject Excel.Application
            $xl.Visible = $false
            $xl.DisplayAlerts = $false
            try {
                $wb   = $xl.Workbooks.Open($xlFile.FullName, 0, $true)
                $ws   = $wb.Sheets.Item(1)
                $licenseKey = [string]$ws.Cells.Item(1, 1).Value2
                $wb.Close($false)
                if ($licenseKey) {
                    Write-Log INFO "License key read from Excel (A1)"
                    Add-Result -Phase CNCnetPDM -Check "License key (Excel)" -Status PASS -Detail "Key: $($licenseKey.Substring(0, [Math]::Min(8,$licenseKey.Length)))..."
                } else {
                    throw "Cell A1 is empty"
                }
            } finally {
                $xl.Quit()
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($xl) | Out-Null
            }
        } catch {
            Write-Log WARN "Excel COM read failed: $_. Trying XLSX XML fallback..."
            # XLSX is a ZIP  -  read xl/worksheets/sheet1.xml directly
            try {
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $zip    = [System.IO.Compression.ZipFile]::OpenRead($xlFile.FullName)
                $entry  = $zip.Entries | Where-Object { $_.FullName -eq 'xl/worksheets/sheet1.xml' } | Select-Object -First 1
                if (-not $entry) { throw "sheet1.xml not in XLSX" }
                $sr     = [System.IO.StreamReader]::new($entry.Open())
                $xmlStr = $sr.ReadToEnd()
                $sr.Close()
                $zip.Dispose()
                [xml]$sheetXml = $xmlStr
                # First <v> element inside first <c> element
                $vNode = $sheetXml.SelectSingleNode('//ns:worksheet/ns:sheetData/ns:row[1]/ns:c[1]/ns:v',
                    (New-Object System.Xml.XmlNamespaceManager($sheetXml.NameTable)).tap({
                        $_.AddNamespace('ns','http://schemas.openxmlformats.org/spreadsheetml/2006/main')
                    }))
                if ($vNode) { $licenseKey = $vNode.InnerText }
                if ($licenseKey) {
                    Write-Log INFO "License key read via XLSX XML fallback"
                    Add-Result -Phase CNCnetPDM -Check "License key (XLSX)" -Status PASS
                }
            } catch {
                Add-Result -Phase CNCnetPDM -Check "License key" -Status WARN `
                    -Detail "Could not read Excel: $_. Enter license key manually in CNCnetPDM.ini [License] section."
            }
        }
    } else {
        Add-Result -Phase CNCnetPDM -Check "License Excel file" -Status WARN `
            -Detail "No license .xlsx found under $repoRoot  -  enter license manually in CNCnetPDM.ini"
    }

    #endregion

    #region -- Edit CNCnetPDM.ini --------------------------------------------

    if (-not (Test-Path $iniPath)) {
        Add-Result -Phase CNCnetPDM -Check "CNCnetPDM.ini" -Status FAIL -Detail "Not found: $iniPath"
        throw "CNCnetPDM.ini not found at $iniPath"
    }

    $iniLines = [System.IO.File]::ReadAllLines($iniPath)

    # Helper: upsert a key in a section
    function Set-IniValue {
        param([ref][string[]]$lines, [string]$section, [string]$key, [string]$value)
        $sectionIdx = -1
        $keyIdx     = -1
        for ($idx = 0; $idx -lt $lines.Value.Count; $idx++) {
            $l = $lines.Value[$idx].Trim()
            if ($l -eq "[$section]") { $sectionIdx = $idx }
            if ($sectionIdx -ge 0 -and $l -match "^$key\s*=") { $keyIdx = $idx; break }
        }
        if ($keyIdx -ge 0) {
            $lines.Value[$keyIdx] = "$key=$value"
        } elseif ($sectionIdx -ge 0) {
            $newLines = New-Object System.Collections.Generic.List[string]
            $newLines.AddRange($lines.Value)
            $newLines.Insert($sectionIdx + 1, "$key=$value")
            $lines.Value = $newLines.ToArray()
        } else {
            # Section doesn't exist  -  append
            $newLines = New-Object System.Collections.Generic.List[string]
            $newLines.AddRange($lines.Value)
            $newLines.Add("")
            $newLines.Add("[$section]")
            $newLines.Add("$key=$value")
            $lines.Value = $newLines.ToArray()
        }
    }

    # Helper: get next available Line{N} index in [RS232]
    function Get-NextRS232Index {
        param([string[]]$lines)
        $maxIdx = 0
        $inRS232 = $false
        foreach ($l in $lines) {
            if ($l.Trim() -eq '[RS232]') { $inRS232 = $true; continue }
            if ($inRS232 -and $l.Trim() -match '^\[') { break }
            if ($inRS232 -and $l.Trim() -match '^Line(\d+)\s*=') {
                $n = [int]$Matches[1]
                if ($n -gt $maxIdx) { $maxIdx = $n }
            }
        }
        return $maxIdx + 1
    }

    # License key
    if ($licenseKey) {
        Set-IniValue -lines ([ref]$iniLines) -section 'License' -key 'LicenseKey' -value $licenseKey
        Add-Result -Phase CNCnetPDM -Check "License key written to INI" -Status PASS
    }

    # RS232 entries  -  remove any existing Line{N} entries for our machines first
    $iniList = [System.Collections.Generic.List[string]]::new()
    $iniList.AddRange($iniLines)

    # Remove existing Line entries that belong to our IP addresses (clean slate per-machine)
    $machineIPs = $machines | ForEach-Object { $_.IPAddress }
    $toRemove   = @()
    for ($idx = 0; $idx -lt $iniList.Count; $idx++) {
        $l = $iniList[$idx]
        if ($l -match '^Line\d+\s*=') {
            foreach ($ip in $machineIPs) {
                if ($l -contains $ip) { $toRemove += $idx; break }
            }
        }
    }
    for ($r = $toRemove.Count - 1; $r -ge 0; $r--) { $iniList.RemoveAt($toRemove[$r]) }

    $iniLines = $iniList.ToArray()

    # Find or create [RS232] section end insertion point
    $rs232SectionEnd = -1
    $inRS232 = $false
    for ($idx = 0; $idx -lt $iniLines.Count; $idx++) {
        $l = $iniLines[$idx].Trim()
        if ($l -eq '[RS232]') { $inRS232 = $true; $rs232SectionEnd = $idx + 1; continue }
        if ($inRS232 -and $l -match '^\[' -and $l -ne '[RS232]') { break }
        if ($inRS232) { $rs232SectionEnd = $idx + 1 }
    }

    $d = $defaults
    $insertIdx = $rs232SectionEnd
    for ($i = 0; $i -lt $machines.Count; $i++) {
        $m       = $machines[$i]
        $lineNum = $i + 1
        # Line format: {DevNr}; {Baud}; {Databits}; {Parity}; {StopBits}; {Name}; {IP}; {Port}; 0; localhost; {Idx}; none; none; none; 0; {DLL}
        $lineVal = "$($m.DeviceNr); $($d.Baud); $($d.Databits); $($d.Parity); $($d.StopBits); $($m.MachineName); $($m.IPAddress); $($d.Port); $($d.Method); localhost; $lineNum; none; none; none; 0; $($m.DLLName)"
        $entry   = "Line${lineNum}=$lineVal"

        $iniList2 = [System.Collections.Generic.List[string]]::new()
        $iniList2.AddRange($iniLines)
        if ($insertIdx -ge 0) {
            $iniList2.Insert($insertIdx, $entry)
            $insertIdx++
        } else {
            $iniList2.Add(''); $iniList2.Add('[RS232]'); $iniList2.Add($entry)
        }
        $iniLines = $iniList2.ToArray()

        Add-Result -Phase CNCnetPDM -Check "CNCnetPDM.ini Line$lineNum ($($m.MachineName))" -Status PASS
    }

    [System.IO.File]::WriteAllLines($iniPath, $iniLines)
    Write-Log INFO "CNCnetPDM.ini saved: $iniPath"

    #endregion

    #region -- Edit melcfg.ini -----------------------------------------------

    if (-not (Test-Path $melcfgPath)) {
        Add-Result -Phase CNCnetPDM -Check "melcfg.ini" -Status WARN -Detail "Not found: $melcfgPath  -  skipping TCP host entries"
    } else {
        $melLines = [System.IO.File]::ReadAllLines($melcfgPath)

        # Remove existing TCP{N} entries for our IPs
        $melList = [System.Collections.Generic.List[string]]::new()
        $melList.AddRange($melLines)
        $toRemove2 = @()
        for ($idx = 0; $idx -lt $melList.Count; $idx++) {
            $l = $melList[$idx]
            if ($l -match '^TCP\d+\s*=') {
                foreach ($ip in $machineIPs) { if ($l -contains $ip) { $toRemove2 += $idx; break } }
            }
        }
        for ($r = $toRemove2.Count - 1; $r -ge 0; $r--) { $melList.RemoveAt($toRemove2[$r]) }
        $melLines = $melList.ToArray()

        # Find [HOSTS] section end
        $hostsSectionEnd = -1
        $inHosts = $false
        for ($idx = 0; $idx -lt $melLines.Count; $idx++) {
            $l = $melLines[$idx].Trim()
            if ($l -eq '[HOSTS]') { $inHosts = $true; $hostsSectionEnd = $idx + 1; continue }
            if ($inHosts -and $l -match '^\[' -and $l -ne '[HOSTS]') { break }
            if ($inHosts) { $hostsSectionEnd = $idx + 1 }
        }

        $insertIdx = $hostsSectionEnd
        for ($i = 0; $i -lt $machines.Count; $i++) {
            $m   = $machines[$i]
            $n   = $i + 1
            $entry = "TCP${n}=$($m.IPAddress),$($m.Port)"

            $mel2 = [System.Collections.Generic.List[string]]::new()
            $mel2.AddRange($melLines)
            if ($insertIdx -ge 0) {
                $mel2.Insert($insertIdx, $entry)
                $insertIdx++
            } else {
                $mel2.Add(''); $mel2.Add('[HOSTS]'); $mel2.Add($entry)
            }
            $melLines = $mel2.ToArray()

            Add-Result -Phase CNCnetPDM -Check "melcfg.ini TCP$n ($($m.MachineName))" -Status PASS
        }

        [System.IO.File]::WriteAllLines($melcfgPath, $melLines)
        Write-Log INFO "melcfg.ini saved: $melcfgPath"
    }

    #endregion

    #region -- Rename DLL files -----------------------------------------------

    $dllDir = Join-Path $cncPdmDir $cncPdm.DllSubDir
    Write-Log INFO "DLL directory: $dllDir"

    if (Test-Path $dllDir) {
        for ($i = 0; $i -lt $machines.Count; $i++) {
            $m        = $machines[$i]
            $n        = $i + 1
            $dllBase  = [System.IO.Path]::GetFileNameWithoutExtension($m.DLLName) # e.g. citizenm or mitsubishim
            $srcName  = "${dllBase}_CNC${n}.dll"
            $dstName  = "${dllBase}_$($m.DeviceNr).dll"
            $srcPath  = Join-Path $dllDir $srcName
            $dstPath  = Join-Path $dllDir $dstName

            if ($srcPath -eq $dstPath) {
                Add-Result -Phase CNCnetPDM -Check "DLL rename: $srcName" -Status PASS -Detail "No rename needed (names match)"
            } elseif (Test-Path $srcPath) {
                try {
                    if (Test-Path $dstPath) { Remove-Item $dstPath -Force }
                    Rename-Item $srcPath $dstName
                    Add-Result -Phase CNCnetPDM -Check "DLL rename: $srcName -> $dstName" -Status PASS
                } catch {
                    Add-Result -Phase CNCnetPDM -Check "DLL rename: $srcName" -Status WARN -Detail "Rename failed: $_"
                }
            } elseif (Test-Path $dstPath) {
                Add-Result -Phase CNCnetPDM -Check "DLL: $dstName" -Status PASS -Detail "Already renamed"
            } else {
                Add-Result -Phase CNCnetPDM -Check "DLL: $srcName" -Status WARN `
                    -Detail "Neither $srcName nor $dstName found in $dllDir  -  verify DLL placement manually"
            }
        }
    } else {
        Add-Result -Phase CNCnetPDM -Check "DLL directory" -Status WARN -Detail "Directory not found: $dllDir  -  skipping DLL rename"
    }

    #endregion

    #region -- Restart CNCnetPDM service and verify ---------------------------

    $svcName = $Manifest.Services.CNCnetPDM
    try {
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
    }

    #endregion

    Write-Log PASS "CNCnetPDM configuration complete."
    Write-Log INFO "Verify: CNCnetPDM Workbench -> Machine Status should show green for each configured CNC after network connectivity is established."
}
