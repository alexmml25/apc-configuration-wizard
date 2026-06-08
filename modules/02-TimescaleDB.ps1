#Requires -Version 5.1
<#
.SYNOPSIS
    Step 2 - Configure TimescaleDB on the APC VM.
.DESCRIPTION
    - Edits pg_hba.conf to allow remote connections (0.0.0.0/0 md5)
    - Restarts the PostgreSQL service
    - Creates the apcuser role with required privileges
    - Creates the TimescaleDB database
    - Enables the timescaledb extension and creates the validation hypertable
    - Runs all approved schema SQL scripts from the repository
    - Configures the PostgreSQL ODBC DSN (PostgreSQL30) via registry
#>

function Invoke-TimescaleDBSetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [switch]$NonInteractive
    )

    Write-Log STEP "TimescaleDB VM Setup"

    $pg      = $Manifest.PostgreSQL
    $psqlExe = Join-Path $pg.BinDir 'psql.exe'
    $svcName = $pg.Service
    $dbName  = $pg.LocalDB
    $dbUser  = $pg.LocalUser
    $repoRoot= $Manifest.APC.RepositoryRoot

    #region -- Resolve apcuser password ---------------------------------------

    $apcPwd = ''
    if ($State.ContainsKey('APCUserPassword') -and $State['APCUserPassword']) {
        $bstr   = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($State['APCUserPassword'])
        try { $apcPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    if (-not $apcPwd) { throw "APCUserPassword not available in session state." }

    #endregion

    #region -- Validate prerequisites -----------------------------------------

    if (-not (Test-Path $psqlExe)) {
        Add-Result -Phase TSDB -Check "psql.exe present" -Status FAIL -Detail "Not found: $psqlExe"
        throw "psql.exe not found. Confirm PostgreSQL installation completed."
    }
    Add-Result -Phase TSDB -Check "psql.exe present" -Status PASS

    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Add-Result -Phase TSDB -Check "PostgreSQL service exists" -Status FAIL -Detail "Service '$svcName' not found"
        throw "PostgreSQL service not found: $svcName"
    }

    #endregion

    #region -- pg_hba.conf update ---------------------------------------------

    $hbaPath  = $pg.PgHbaFile
    $hbaEntry = $pg.HbaEntry

    if (-not (Test-Path $hbaPath)) {
        Add-Result -Phase TSDB -Check "pg_hba.conf" -Status FAIL -Detail "Not found: $hbaPath"
        throw "pg_hba.conf not found at $hbaPath"
    }

    $hbaContent = Get-Content $hbaPath -Raw -Encoding UTF8
    if ($hbaContent -notmatch [regex]::Escape($hbaEntry)) {
        # Insert before the first "local" line
        $hbaContent = $hbaContent -replace '(# TYPE\s+DATABASE\s+USER\s+ADDRESS\s+METHOD[^\r\n]*[\r\n]+)', "`$1$hbaEntry`n"
        Set-Content -Path $hbaPath -Value $hbaContent -Encoding UTF8
        Add-Result -Phase TSDB -Check "pg_hba.conf updated" -Status PASS -Detail "Added: $hbaEntry"
    } else {
        Add-Result -Phase TSDB -Check "pg_hba.conf entry present" -Status PASS -Detail "Already configured"
    }

    #endregion

    #region -- Restart PostgreSQL service -------------------------------------

    Write-Log INFO "Restarting $svcName to apply pg_hba.conf changes..."
    try {
        Restart-Service -Name $svcName -Force -ErrorAction Stop
        Start-Sleep -Seconds 5
        $svc.Refresh()
        if ($svc.Status -eq 'Running') {
            Add-Result -Phase TSDB -Check "PostgreSQL restarted" -Status PASS
        } else {
            Add-Result -Phase TSDB -Check "PostgreSQL restarted" -Status WARN -Detail "Service status: $($svc.Status)"
        }
    } catch {
        Add-Result -Phase TSDB -Check "PostgreSQL restart" -Status FAIL -Detail $_
        throw "Failed to restart $svcName: $_"
    }

    #endregion

    #region -- Helper: run psql command as postgres superuser -----------------

    function Invoke-Psql {
        param([string]$Sql, [string]$Database = 'postgres', [string]$Description = '')
        $env:PGPASSWORD = $apcPwd
        try {
            $out = & $psqlExe -h localhost -p $pg.DefaultPort -U postgres -d $Database -c $Sql 2>&1
        } finally { $env:PGPASSWORD = '' }
        $err = $out | Where-Object { $_ -match '^(ERROR|FATAL|psql:)' }
        if ($err -and $out -notmatch 'already exists') {
            Write-Log WARN "psql output: $($out -join ' ')"
            return $false
        }
        if ($Description) { Write-Log INFO "$Description : OK" }
        return $true
    }

    #endregion

    #region -- Create apcuser role --------------------------------------------

    $createRole = @"
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$dbUser') THEN
    CREATE ROLE $dbUser WITH LOGIN SUPERUSER CREATEROLE CREATEDB INHERIT BYPASSRLS PASSWORD '$apcPwd';
  ELSE
    ALTER ROLE $dbUser WITH SUPERUSER CREATEROLE CREATEDB INHERIT BYPASSRLS PASSWORD '$apcPwd';
  END IF;
END
\$\$;
"@
    if (Invoke-Psql -Sql $createRole -Description "Create/update role $dbUser") {
        Add-Result -Phase TSDB -Check "apcuser role" -Status PASS
    } else {
        Add-Result -Phase TSDB -Check "apcuser role" -Status FAIL
        throw "Failed to create apcuser role."
    }

    #endregion

    #region -- Create TimescaleDB database ------------------------------------

    $createDb = "SELECT 'CREATE DATABASE \"$dbName\" OWNER $dbUser' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$dbName')\gexec"
    if (Invoke-Psql -Sql $createDb -Description "Create database $dbName") {
        Add-Result -Phase TSDB -Check "$dbName database" -Status PASS
    } else {
        Add-Result -Phase TSDB -Check "$dbName database" -Status WARN -Detail "Already exists or error — continuing"
    }

    #endregion

    #region -- Enable TimescaleDB extension -----------------------------------

    $extSql = @"
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE TABLE IF NOT EXISTS conditions (
    time        TIMESTAMPTZ     NOT NULL,
    location    TEXT            NOT NULL,
    temperature DOUBLE PRECISION NULL
);
SELECT create_hypertable('conditions', by_range('time'), if_not_exists => TRUE);
"@
    if (Invoke-Psql -Sql $extSql -Database $dbName -Description "Enable timescaledb extension") {
        Add-Result -Phase TSDB -Check "timescaledb extension" -Status PASS
    } else {
        Add-Result -Phase TSDB -Check "timescaledb extension" -Status FAIL
        throw "Failed to enable TimescaleDB extension."
    }

    #endregion

    #region -- Run schema scripts ---------------------------------------------

    $scriptsPath = Join-Path $repoRoot $Manifest.SchemaScriptsRepoSubPath
    Write-Log INFO "Schema scripts path: $scriptsPath"

    foreach ($scriptName in $Manifest.SchemaScripts) {
        $scriptPath = Join-Path $scriptsPath $scriptName
        if (-not (Test-Path $scriptPath)) {
            Add-Result -Phase TSDB -Check "Schema: $scriptName" -Status WARN -Detail "File not found: $scriptPath — skipped"
            continue
        }
        Write-Log INFO "Running schema script: $scriptName"
        $env:PGPASSWORD = $apcPwd
        try {
            $out = & $psqlExe -h localhost -p $pg.DefaultPort -U $dbUser -d $dbName -f $scriptPath 2>&1
        } finally { $env:PGPASSWORD = '' }

        $err = $out | Where-Object { $_ -match '^(ERROR|FATAL)' }
        if ($err) {
            Add-Result -Phase TSDB -Check "Schema: $scriptName" -Status FAIL -Detail ($err -join '; ')
        } else {
            Add-Result -Phase TSDB -Check "Schema: $scriptName" -Status PASS
        }
    }

    #endregion

    #region -- Configure ODBC DSN via registry --------------------------------

    $odbcDsn    = $pg.OdbcDsn
    $odbcDriver = $pg.OdbcDriver
    $odbcKey    = "HKLM:\SOFTWARE\ODBC\ODBC.INI\$odbcDsn"
    $odbcSrcKey = "HKLM:\SOFTWARE\ODBC\ODBC.INI\ODBC Data Sources"

    try {
        if (-not (Test-Path $odbcKey)) { New-Item -Path $odbcKey -Force | Out-Null }
        Set-ItemProperty -Path $odbcKey -Name 'Driver'     -Value (Get-OdbcDriverPath -DriverName $odbcDriver)
        Set-ItemProperty -Path $odbcKey -Name 'Database'   -Value $dbName
        Set-ItemProperty -Path $odbcKey -Name 'Servername' -Value 'localhost'
        Set-ItemProperty -Path $odbcKey -Name 'Port'       -Value "$($pg.DefaultPort)"
        Set-ItemProperty -Path $odbcKey -Name 'UserName'   -Value $dbUser
        Set-ItemProperty -Path $odbcKey -Name 'SSLmode'    -Value 'disable'

        if (-not (Test-Path $odbcSrcKey)) { New-Item -Path $odbcSrcKey -Force | Out-Null }
        Set-ItemProperty -Path $odbcSrcKey -Name $odbcDsn -Value $odbcDriver

        Add-Result -Phase TSDB -Check "ODBC DSN $odbcDsn" -Status PASS -Detail "Configured in HKLM ODBC.INI"
    } catch {
        Add-Result -Phase TSDB -Check "ODBC DSN $odbcDsn" -Status WARN -Detail "Registry write failed: $_ — configure ODBC DSN manually if needed"
    } finally {
        $apcPwd = ''
    }

    #endregion

    Write-Log PASS "TimescaleDB VM setup complete."
}

function Get-OdbcDriverPath {
    param([string]$DriverName)
    $drvKey = "HKLM:\SOFTWARE\ODBC\ODBCINST.INI\$DriverName"
    if (Test-Path $drvKey) {
        return (Get-ItemPropertyValue -Path $drvKey -Name 'Driver' -ErrorAction SilentlyContinue)
    }
    # Fallback: scan 32-bit hive
    $drvKey32 = "HKLM:\SOFTWARE\WOW6432Node\ODBC\ODBCINST.INI\$DriverName"
    if (Test-Path $drvKey32) {
        return (Get-ItemPropertyValue -Path $drvKey32 -Name 'Driver' -ErrorAction SilentlyContinue)
    }
    return $DriverName
}
