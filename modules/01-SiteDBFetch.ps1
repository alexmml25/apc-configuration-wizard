#Requires -Version 5.1
<#
.SYNOPSIS
    Step 1 - Query the Site-level TSDB to retrieve CNC machine configurations.
.DESCRIPTION
    Connects to the site PostgreSQL database using psql.exe and fetches all
    CNC machine records where f_cncnetpdm_required = true.

    Site DB schema (table: machine_info):
      f_cnc_asset           - machine name (MachineName)
      f_ip_address          - CNC IP address
      f_port                - CNC port (varchar, converted to string)
      f_cnc_type            - CNC type string (e.g. "CITIZEN M32")
      f_dllname             - CNCnetPDM DLL filename
      f_cncnetpdm_required  - boolean; only machines with TRUE are fetched

    Server is looked up from manifest SiteServers[SiteCode].
    If State['SiteDBPassword'] is set it takes priority; otherwise the
    manifest PasswordB64 is decoded and used.
#>

function Invoke-SiteDBFetch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [switch]$NonInteractive
    )

    Write-Log STEP "Site DB Fetch - CNC Machine Configurations"

    $db       = $Manifest.SiteDB
    $cols     = $db.Columns
    $siteCode = $State['SiteCode']
    $pgBin    = $Manifest.PostgreSQL.BinDir
    $psqlExe  = Join-Path $pgBin 'psql.exe'

    if (-not $siteCode) { throw "SiteCode not set in State." }

    #region -- Resolve server from manifest SiteServers -----------------------

    $srvEntry = $null
    if ($Manifest.SiteServers -and $Manifest.SiteServers.PSObject.Properties[$siteCode]) {
        $srvEntry = $Manifest.SiteServers.($siteCode)
    }

    $dbHost = if ($srvEntry -and $srvEntry.Host) { $srvEntry.Host } else { $State['SiteDBHost'] }
    $dbUser = if ($srvEntry -and $srvEntry.User) { $srvEntry.User } else { $State['SiteDBUser'] }
    $dbPort = if ($srvEntry -and $srvEntry.Port) { $srvEntry.Port } else { $db.Port }
    $dbName = if ($srvEntry -and $srvEntry.Database) { $srvEntry.Database } else { $db.Database }

    if (-not $dbHost) { throw "No Site DB host configured for site '$siteCode'. Set in manifest SiteServers or enter manually." }
    if (-not $dbUser) { throw "No Site DB user configured." }

    #endregion

    #region -- Validate prerequisites -----------------------------------------

    if (-not (Test-Path $psqlExe)) {
        Add-Result -Phase SiteDB -Check "psql.exe present" -Status FAIL -Detail "Not found: $psqlExe"
        throw "psql.exe not found. Ensure PostgreSQL is installed."
    }
    Add-Result -Phase SiteDB -Check "psql.exe present" -Status PASS -Detail $psqlExe

    #endregion

    #region -- Resolve password -----------------------------------------------

    $plainPwd = ''

    # 1) Prefer password from UI (SecureString in State)
    if ($State.ContainsKey('SiteDBPassword') -and $State['SiteDBPassword']) {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($State['SiteDBPassword'])
        try { $plainPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }

    # 2) Fall back to manifest PasswordB64 for this site
    if (-not $plainPwd -and $srvEntry -and $srvEntry.PasswordB64) {
        try {
            $plainPwd = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($srvEntry.PasswordB64))
        } catch {
            Write-Log WARN "Could not decode manifest PasswordB64 for site $siteCode: $_"
        }
    }

    if (-not $plainPwd) { throw "SiteDB password not available. Enter it in the Site Database panel." }

    #endregion

    #region -- Query Site DB --------------------------------------------------

    $sql = @"
SELECT $($cols.MachineName),
       $($cols.IPAddress),
       $($cols.Port),
       $($cols.CNCType),
       $($cols.DLLName)
FROM   $($db.AssetTable)
WHERE  $($cols.CNCnetPDMRequired) = true
ORDER  BY $($cols.MachineName)
"@

    Write-Log INFO "Site DB: $dbHost:$dbPort / $dbName"
    Write-Log INFO "Table  : $($db.AssetTable) | Filter: $($cols.CNCnetPDMRequired) = true"

    $env:PGPASSWORD = $plainPwd
    try {
        $rawOutput = & $psqlExe `
            -h $dbHost -p $dbPort -U $dbUser -d $dbName `
            -t -A -F '|' -c $sql 2>&1
    } finally {
        $env:PGPASSWORD = ''
        $plainPwd = ''
    }

    $errorLines = $rawOutput | Where-Object { $_ -match '^(psql:|ERROR:|FATAL:|could not connect)' }
    if ($errorLines) {
        $errMsg = $errorLines -join '; '
        Add-Result -Phase SiteDB -Check "Site DB connection" -Status FAIL -Detail $errMsg
        throw "Site DB query failed: $errMsg"
    }
    Add-Result -Phase SiteDB -Check "Site DB connection" -Status PASS -Detail "$dbHost / $dbName"

    #endregion

    #region -- Parse results --------------------------------------------------

    $machines = @()
    foreach ($line in ($rawOutput | Where-Object { $_ -and $_ -notmatch '^\s*$' -and $_ -notmatch '^\(\d+ rows?\)' })) {
        $parts = $line -split '\|'
        if ($parts.Count -lt 4) { continue }

        $cncType = $parts[3].Trim()

        $machine = @{
            MachineName = $parts[0].Trim()
            IPAddress   = $parts[1].Trim()
            Port        = $parts[2].Trim()
            CNCType     = $cncType
            AssetFamily = $cncType    # kept for backward compat with downstream modules
            DLLName     = if ($parts.Count -ge 5) { $parts[4].Trim() } else { '' }
        }

        $machines += $machine
        Write-Log INFO "  Found: $($machine.MachineName) | $($machine.IPAddress):$($machine.Port) | $cncType | $($machine.DLLName)"
    }

    if ($machines.Count -eq 0) {
        Add-Result -Phase SiteDB -Check "Machines found" -Status FAIL `
            -Detail "No rows returned from '$($db.AssetTable)' WHERE $($cols.CNCnetPDMRequired) = true. Verify the Site DB data."
        throw "No CNC machines found in Site DB for site '$siteCode'."
    }

    Add-Result -Phase SiteDB -Check "Machines found" -Status PASS `
        -Detail "$($machines.Count) machine(s): $(($machines | ForEach-Object { $_.MachineName }) -join ', ')"

    #endregion

    #region -- Validate and assign device numbers ----------------------------

    $index = 1
    foreach ($machine in $machines) {
        $name = $machine.MachineName

        # DeviceNr is sequential (no device_nr column in schema)
        $machine['DeviceNr']  = $index
        $machine['CNCIndex']  = $index

        if (-not $machine.IPAddress -or $machine.IPAddress -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
            Add-Result -Phase SiteDB -Check "$name IP address" -Status WARN `
                -Detail "IP '$($machine.IPAddress)' may be invalid — verify before CNCnetPDM configuration"
        } else {
            Add-Result -Phase SiteDB -Check "$name IP address" -Status PASS -Detail $machine.IPAddress
        }

        if (-not $machine.DLLName) {
            Add-Result -Phase SiteDB -Check "$name DLL name" -Status WARN -Detail "DLL name empty — defaulting to CitizenM.dll"
            $machine['DLLName'] = 'CitizenM.dll'
        } else {
            Add-Result -Phase SiteDB -Check "$name DLL name" -Status PASS -Detail $machine.DLLName
        }

        $index++
    }

    #endregion

    $State['CNCMachines'] = $machines
    Write-Log PASS "Site DB fetch complete. $($machines.Count) CNC machine(s) loaded into configuration state."
    Add-Result -Phase SiteDB -Check "State populated" -Status PASS -Detail "$($machines.Count) machines ready for configuration"
}
