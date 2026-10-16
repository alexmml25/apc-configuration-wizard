#Requires -Version 5.1
<#
.SYNOPSIS
    Step 2 - Configure TimescaleDB on the APC VM (SOP D01555607, Timescale Database (TSDB)).
.DESCRIPTION
    Each part checks first and changes only what is missing, so the step can be re-run:
    - apcuser password checked against the standard one (PostgreSQL.LocalUserPasswordCheck), postgres
      login and the timescaledb preload checked - all before anything is changed
    - pg_hba.conf: PostgreSQL.HbaEntry added under "# IPv4 local connections" (.bak kept, no BOM);
      the service is restarted only when the file changed
    - role apcuser (SOP privileges, the entered password), database TimescaleDB owned by apcuser
    - timescaledb extension and the SOP validation hypertable 'conditions' (as apcuser)
    - schema: PostgreSQL.SchemaScripts from the share, run once in one transaction, only while the
      database has no APC tables yet (the scripts use plain CREATE TABLE / INSERT and are not re-runnable)
    - PostgreSQL ODBC driver (psqlodbc-setup.exe from the share when no 32-bit PostgreSQL ANSI driver is
      installed) and the 32-bit System DSN PostgreSQL30, tested from a 32-bit process
    - the schema checked against the tables/views the scripts create
    - pgAdmin: the VM's server registered for the Windows user running the wizard (pgAdmin setup.py
      load-servers) with its password in that user's %APPDATA%\postgresql\pgpass.conf (PassFile), then a
      login the way pgAdmin connects (by VM name, password only from that file)
    Logs in as postgres with State.PostgresPassword (entered on the Sign in page).
#>

. (Join-Path $PSScriptRoot 'Common.ps1')

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
    $failed  = $false

    #region -- Passwords ------------------------------------------------------

    $apcPwd = ConvertTo-PlainPassword $State['APCUserPassword']
    $suPwd  = ConvertTo-PlainPassword $State['PostgresPassword']
    if (-not $apcPwd) { throw "APCUserPassword not available in session state." }
    if (-not $suPwd)  { throw "The postgres (superuser) password is not available. Enter it on the Sign in page." }

    # The deviceWise baseline's TimescaleDB connection (Step 5) stores the standard apcuser password
    # encrypted, so a different password here would break it: check against the standard one's hash
    $std = Test-StandardPassword -Password $apcPwd -Check $pg.LocalUserPasswordCheck
    $State['APCUserPasswordStandard'] = $std   # Step 5 reports the deviceWise TimescaleDB connection from this
    if ($std -eq $false) {
        Add-Result -Phase TSDB -Check 'apcuser password is the standard one' -Status FAIL `
            -Detail 'The entered apcuser password is not the standard APC password; the deviceWise TimescaleDB connection (Step 5) would not work.'
        throw 'The apcuser password is not the standard APC password. Re-enter it on the Sign in page.'
    }
    Add-Result -Phase TSDB -Check 'apcuser password is the standard one' -Status $(if ($std) { 'PASS' } else { 'WARN' }) `
        -Detail $(if ($std) { 'matches the standard password check' } else { 'not checked: manifest PostgreSQL.LocalUserPasswordCheck is empty (tools\New-PasswordCheck.ps1)' })

    $su  = @{ Exe = $psqlExe; Port = $pg.DefaultPort; User = 'postgres'; Password = $suPwd }
    $apc = @{ Exe = $psqlExe; Port = $pg.DefaultPort; User = $dbUser;    Password = $apcPwd }

    #endregion

    #region -- Prerequisites (nothing is changed before these pass) -----------

    if (-not (Test-Path $psqlExe)) {
        Add-Result -Phase TSDB -Check "psql.exe present" -Status FAIL -Detail "Not found: $psqlExe"
        throw "psql.exe not found. Confirm the PostgreSQL installation completed."
    }

    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Add-Result -Phase TSDB -Check "PostgreSQL service" -Status FAIL -Detail "Service '$svcName' not found"
        throw "PostgreSQL service not found: $svcName"
    }
    if ($svc.Status -ne 'Running') {
        Write-Log INFO "$svcName is $($svc.Status) - starting it"
        Start-Service -Name $svcName -ErrorAction Stop
    }
    if (-not (Wait-PgReady -Conn $su)) {
        $r = Invoke-PgSql -Conn $su -Sql 'SELECT 1;'
        Add-Result -Phase TSDB -Check "postgres login" -Status FAIL -Detail (Get-PgLoginError $r.Output 'postgres')
        throw "Could not log in to PostgreSQL as postgres: $(Get-PgLoginError $r.Output 'postgres')"
    }
    Add-Result -Phase TSDB -Check "PostgreSQL running, postgres login" -Status PASS -Detail "$svcName, psql $((& $psqlExe --version) -replace '^psql \(PostgreSQL\) ', '')"

    $preload = (Invoke-PgSql -Conn $su -Sql 'SHOW shared_preload_libraries;').Output
    $avail   = (Invoke-PgSql -Conn $su -Sql "SELECT default_version FROM pg_available_extensions WHERE name = 'timescaledb';").Output
    if (-not $avail -or $preload -notmatch 'timescaledb') {
        $why = if (-not $avail) { 'the timescaledb extension is not installed' } else { "shared_preload_libraries = '$preload' (timescaledb missing; run timescaledb-tune or add it in postgresql.conf, then restart $svcName)" }
        Add-Result -Phase TSDB -Check "TimescaleDB installed and preloaded" -Status FAIL -Detail $why
        throw "TimescaleDB is not ready: $why"
    }
    Add-Result -Phase TSDB -Check "TimescaleDB installed and preloaded" -Status PASS -Detail "timescaledb $avail"

    #endregion

    #region -- pg_hba.conf ----------------------------------------------------

    $hba = Set-PgHbaEntry -Path $pg.PgHbaFile -Entry $pg.HbaEntry -State $State
    if ($hba -eq 'Present') {
        Add-Result -Phase TSDB -Check "pg_hba.conf entry" -Status PASS -Detail "Already present: $($pg.HbaEntry)"
    } else {
        Add-Result -Phase TSDB -Check "pg_hba.conf entry" -Status PASS -Detail "Added under IPv4 local connections: $($pg.HbaEntry) (backup $hba)"
        # SOP: restart the service to apply the change
        Write-Log INFO "Restarting $svcName to apply pg_hba.conf..."
        try { Restart-Service -Name $svcName -Force -ErrorAction Stop } catch {
            Add-Result -Phase TSDB -Check "PostgreSQL restarted" -Status FAIL -Detail "$_"
            throw "Failed to restart ${svcName}: $_"
        }
        if (Wait-PgReady -Conn $su) { Add-Result -Phase TSDB -Check "PostgreSQL restarted" -Status PASS }
        else {
            Add-Result -Phase TSDB -Check "PostgreSQL restarted" -Status FAIL -Detail "No connection within 60 s after the restart"
            throw "PostgreSQL did not accept connections after the restart."
        }
    }

    $listen = (Invoke-PgSql -Conn $su -Sql 'SHOW listen_addresses;').Output
    if ($listen -notmatch '\*|0\.0\.0\.0') {
        Add-Result -Phase TSDB -Check "PostgreSQL listens on the network" -Status WARN `
            -Detail "listen_addresses = '$listen': remote clients (and pgAdmin by VM name) cannot connect; set listen_addresses = '*' in postgresql.conf"
    }

    #endregion

    #region -- apcuser role ---------------------------------------------------

    # SOP privileges: login, superuser, create roles, create databases, inherit, no replication, bypass RLS
    $attrs  = 'LOGIN SUPERUSER CREATEROLE CREATEDB INHERIT NOREPLICATION BYPASSRLS'
    $exists = (Invoke-PgSql -Conn $su -Sql "SELECT 1 FROM pg_roles WHERE rolname = '$dbUser';").Output -eq '1'
    $verb   = if ($exists) { 'ALTER' } else { 'CREATE' }
    $r = Invoke-PgSql -Conn $su -Sql "$verb ROLE `"$dbUser`" WITH $attrs PASSWORD '$($apcPwd.Replace("'", "''"))';"
    if ($r.Ok) {
        Add-Result -Phase TSDB -Check "$dbUser role" -Status PASS -Detail "$(if ($exists) { 'Existed - privileges and password set' } else { 'Created' }): $attrs"
    } else {
        Add-Result -Phase TSDB -Check "$dbUser role" -Status FAIL -Detail (Get-PgError $r.Output)
        throw "Failed to $($verb.ToLower()) role ${dbUser}: $(Get-PgError $r.Output)"
    }

    #endregion

    #region -- TimescaleDB database -------------------------------------------

    $owner = (Invoke-PgSql -Conn $su -Sql "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '$dbName';").Output
    if (-not $owner) {
        $r = Invoke-PgSql -Conn $su -Sql "CREATE DATABASE `"$dbName`" OWNER `"$dbUser`";"
        if (-not $r.Ok) {
            Add-Result -Phase TSDB -Check "$dbName database" -Status FAIL -Detail (Get-PgError $r.Output)
            throw "Failed to create database ${dbName}: $(Get-PgError $r.Output)"
        }
        Add-Result -Phase TSDB -Check "$dbName database" -Status PASS -Detail "Created, owner $dbUser"
    } elseif ($owner -eq $dbUser) {
        Add-Result -Phase TSDB -Check "$dbName database" -Status PASS -Detail "Already exists, owner $dbUser"
    } else {
        Add-Result -Phase TSDB -Check "$dbName database" -Status WARN -Detail "Already exists, owner is $owner (SOP: $dbUser) - not changed"
    }

    #endregion

    #region -- Extension and validation hypertable (as apcuser) ---------------

    $apc.Database = $dbName
    $r = Invoke-PgSql -Conn $apc -Sql @"
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE TABLE IF NOT EXISTS conditions (
    time        TIMESTAMPTZ      NOT NULL,
    location    TEXT             NOT NULL,
    temperature DOUBLE PRECISION NULL
);
SELECT create_hypertable('conditions', by_range('time'), if_not_exists => TRUE);
"@
    if ($r.Ok) {
        Add-Result -Phase TSDB -Check "timescaledb extension, hypertable conditions" -Status PASS -Detail "As $dbUser in $dbName"
    } else {
        Add-Result -Phase TSDB -Check "timescaledb extension, hypertable conditions" -Status FAIL -Detail (Get-PgError $r.Output)
        throw "Failed to enable TimescaleDB as ${dbUser}: $(Get-PgError $r.Output)"
    }

    #endregion

    #region -- Schema scripts -------------------------------------------------

    $countSql = "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name <> 'conditions';"
    $before   = [int](Invoke-PgSql -Conn $apc -Sql $countSql).Output
    $scriptsDir = Get-RepoPath -Manifest $Manifest -SubPath $Manifest.SchemaScriptsRepoSubPath
    if ($before -gt 0) {
        Add-Result -Phase TSDB -Check "Schema scripts" -Status PASS `
            -Detail "Not run: $dbName already has $before APC table(s)/view(s) (the scripts are not re-runnable)"
    } elseif (-not (Test-ShareServerReachable $scriptsDir) -or -not (Test-Path -LiteralPath $scriptsDir)) {
        $failed = $true
        Add-Result -Phase TSDB -Check "Schema scripts" -Status FAIL -Detail "Folder not reachable: $scriptsDir"
    } else {
        $logDir = Get-RunDir -State $State -Name Logs -Manifest $Manifest
        foreach ($name in @($Manifest.SchemaScripts)) {
            $src = Join-Path $scriptsDir $name
            if (-not (Test-Path -LiteralPath $src)) {
                $failed = $true
                Add-Result -Phase TSDB -Check "Schema: $name" -Status FAIL -Detail "Not found: $src"
                continue
            }
            # Local copy without a UTF-8 BOM (psql would read the BOM as part of the first statement)
            $tmp   = Join-Path $env:TEMP ("apc-$([guid]::NewGuid().ToString('N'))-$name")
            $bytes = [IO.File]::ReadAllBytes($src)
            $skip  = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
            $out   = New-Object IO.FileStream($tmp, [IO.FileMode]::Create)
            try { $out.Write($bytes, $skip, $bytes.Length - $skip) } finally { $out.Close() }
            Write-Log INFO "Running schema script $name ($([math]::Round($bytes.Length / 1KB)) KB) as $dbUser in one transaction"
            try { $r = Invoke-PgSql -Conn $apc -File $tmp -SingleTransaction } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
            $log = Join-Path $logDir ("tsdb-schema_{0}_{1}.log" -f [IO.Path]::GetFileNameWithoutExtension($name), (Get-Date -Format 'yyyyMMdd-HHmmss'))
            [IO.File]::WriteAllText($log, $r.Output, (New-Object Text.UTF8Encoding $false))
            if ($r.Ok) {
                Add-Result -Phase TSDB -Check "Schema: $name" -Status PASS -Detail "psql output: $log"
            } else {
                $failed = $true
                Add-Result -Phase TSDB -Check "Schema: $name" -Status FAIL -Detail "$(Get-PgError $r.Output) - rolled back; psql output: $log"
            }
        }
        $after = [int](Invoke-PgSql -Conn $apc -Sql $countSql).Output
        Add-Result -Phase TSDB -Check "APC schema objects" -Status $(if ($after -gt 0) { 'PASS' } else { 'FAIL' }) -Detail "$after table(s)/view(s) in $dbName.public besides conditions"
        if ($after -eq 0) { $failed = $true }
    }

    # SOP: "verify that all required tables, views, and database objects are created in the public schema"
    if (Test-ShareServerReachable $scriptsDir) {
        $present = @((Invoke-PgSql -Conn $apc -Sql "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public';").Output -split "`n" | ForEach-Object { $_.Trim() })
        foreach ($name in @($Manifest.SchemaScripts)) {
            $src = Join-Path $scriptsDir $name
            if (-not (Test-Path -LiteralPath $src)) { continue }
            $want    = @(Get-SqlCreatedObjects -Path $src)
            $missing = @($want | Where-Object { $_ -notin $present })
            if ($missing) {
                $failed = $true
                Add-Result -Phase TSDB -Check "Schema objects of $name" -Status FAIL -Detail "$($missing.Count) of $($want.Count) missing in $dbName.public: $($missing -join ', ')"
            } else {
                Add-Result -Phase TSDB -Check "Schema objects of $name" -Status PASS -Detail "All $($want.Count) tables/views it creates are in $dbName.public"
            }
        }
    } else {
        Add-Result -Phase TSDB -Check "Schema objects" -Status WARN -Detail "Not compared with the scripts: $scriptsDir not reachable"
    }

    #endregion

    #region -- ODBC driver and DSN (32-bit) -----------------------------------

    try {
        $driver = Get-PgOdbcDriver -Preferred $pg.OdbcDriver
        if (-not $driver) {
            $setup = Get-RepoPath -Manifest $Manifest -SubPath $pg.OdbcInstallerRepoSubPath
            if (-not (Test-ShareServerReachable $setup) -or -not (Test-Path -LiteralPath $setup)) {
                throw "No 32-bit PostgreSQL ANSI ODBC driver installed and the installer is not reachable: $setup"
            }
            $logDir = Get-RunDir -State $State -Name Logs -Manifest $Manifest
            $ilog   = Join-Path $logDir "psqlodbc-setup_$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
            # Run a local copy: started from the share (a dotted name, so the Internet zone) Windows shows
            # "Open File - Security Warning" and waits for a click (VM run 2026-10-14)
            $localDir = Join-Path $env:TEMP "apc-psqlodbc-$([guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $localDir -Force | Out-Null
            $local = Join-Path $localDir (Split-Path $setup -Leaf)
            Write-Log INFO "Installing the PostgreSQL ODBC driver: $setup (local copy)"
            try {
                Copy-Item -LiteralPath $setup -Destination $local -Force -ErrorAction Stop
                Unblock-File -LiteralPath $local -ErrorAction SilentlyContinue
                $p = Start-Process -FilePath $local -ArgumentList '/install', '/quiet', '/norestart', '/log', "`"$ilog`"" -Wait -PassThru
            } finally { Remove-Item -LiteralPath $localDir -Recurse -Force -ErrorAction SilentlyContinue }
            if ($p.ExitCode -notin 0, 3010) { throw "psqlodbc-setup.exe exit code $($p.ExitCode) (log: $ilog)" }
            $driver = Get-PgOdbcDriver -Preferred $pg.OdbcDriver
            if (-not $driver) { throw "psqlodbc-setup.exe finished but no 32-bit PostgreSQL ANSI driver is registered (log: $ilog)" }
            Add-Result -Phase TSDB -Check "PostgreSQL ODBC driver" -Status $(if ($p.ExitCode -eq 3010) { 'WARN' } else { 'PASS' }) `
                -Detail "Installed: $($driver.Name)$(if ($p.ExitCode -eq 3010) { ' - Windows asks for a restart' })"
        } else {
            Add-Result -Phase TSDB -Check "PostgreSQL ODBC driver" -Status PASS -Detail "Already installed: $($driver.Name)"
        }

        # SOP: System DSN with "PostgreSQL ANSI (x86)" -> the 32-bit registry view
        $dsn    = $pg.OdbcDsn
        $dsnKey = "HKLM:\SOFTWARE\WOW6432Node\ODBC\ODBC.INI\$dsn"
        $srcKey = 'HKLM:\SOFTWARE\WOW6432Node\ODBC\ODBC.INI\ODBC Data Sources'
        $values = [ordered]@{
            Driver = $driver.Path; Database = $dbName; Servername = 'localhost'; Port = "$($pg.DefaultPort)"
            Username = $dbUser; Password = $apcPwd; SSLmode = 'disable'
        }
        $existing = if (Test-Path $dsnKey) { Get-ItemProperty $dsnKey } else { $null }
        $changed  = @($values.Keys | Where-Object { -not $existing -or [string]$existing.$_ -ne [string]$values[$_] })
        if ($changed) {
            if (-not (Test-Path $dsnKey)) { New-Item -Path $dsnKey -Force | Out-Null }
            foreach ($k in $values.Keys) { Set-ItemProperty -Path $dsnKey -Name $k -Value $values[$k] }
            if (-not (Test-Path $srcKey)) { New-Item -Path $srcKey -Force | Out-Null }
            Set-ItemProperty -Path $srcKey -Name $dsn -Value $driver.Name
        }
        $test = Test-OdbcDsn32 -Dsn $dsn -Password $apcPwd
        if ($test -eq 'OK') {
            Add-Result -Phase TSDB -Check "ODBC DSN $dsn (32-bit)" -Status PASS `
                -Detail "$(if (-not $existing) { 'Created' } elseif ($changed) { "Updated ($(($changed | Where-Object { $_ -ne 'Password' }) -join ', '))" } else { 'Already configured' }): $($driver.Name), localhost:$($pg.DefaultPort)/$dbName as $dbUser, SSL disable; connection test OK"
        } else {
            $failed = $true
            Add-Result -Phase TSDB -Check "ODBC DSN $dsn (32-bit)" -Status FAIL -Detail "Written, but the connection test failed: $test"
        }
    } catch {
        $failed = $true
        Add-Result -Phase TSDB -Check "ODBC DSN $($pg.OdbcDsn)" -Status FAIL -Detail "$_"
    }

    #endregion

    #region -- pgAdmin server registration ------------------------------------

    # SOP: Name and Host = VM name, port, maintenance DB TimescaleDB, apcuser, "Save password". The password
    # goes in the user's pgpass.conf (user decision 2026-10-14; the SOP's ODBC DSN keeps it in the registry
    # the same way) and the server's PassFile points at it, so pgAdmin connects without asking.
    $vm  = $env:COMPUTERNAME
    $who = "$env:USERDOMAIN\$env:USERNAME"
    $passFile = Get-PgPassFilePath
    try {
        $pp = Set-PgPassEntry -Path $passFile -Hosts @($vm, 'localhost') -Port $pg.DefaultPort -User $dbUser -Password $apcPwd
        Add-Result -Phase TSDB -Check "pgpass.conf ($who)" -Status PASS -Detail "$pp`: $passFile ($dbUser on $vm and localhost, port $($pg.DefaultPort))"
    } catch {
        $failed = $true
        Add-Result -Phase TSDB -Check "pgpass.conf ($who)" -Status FAIL -Detail "$_"
    }

    $reg = Register-PgAdminServer -PgAdminDir $pg.PgAdminDir -Name $vm -HostName $vm -Port $pg.DefaultPort -Database $dbName -User $dbUser -PassFile $passFile
    switch ($reg.Status) {
        'Present'    { Add-Result -Phase TSDB -Check "pgAdmin server $vm" -Status PASS -Detail "Already registered for $who, password from pgpass.conf" }
        'Registered' { Add-Result -Phase TSDB -Check "pgAdmin server $vm" -Status PASS -Detail "Registered for $who`: host $vm, port $($pg.DefaultPort), maintenance DB $dbName, user $dbUser, password from pgpass.conf" }
        'Updated'    { Add-Result -Phase TSDB -Check "pgAdmin server $vm" -Status PASS -Detail "Was registered for $who; now takes the password from pgpass.conf" }
        default {
            $failed = $true
            Add-Result -Phase TSDB -Check "pgAdmin server $vm" -Status FAIL -Detail $reg.Detail
        }
    }

    # What pgAdmin does: connect by VM name (through the pg_hba entry) with the password from pgpass.conf only
    $viaPassFile = @{ Exe = $psqlExe; Port = $pg.DefaultPort; User = $dbUser; Database = $dbName; Host = $vm; PassFile = $passFile }
    $r = Invoke-PgSql -Conn $viaPassFile -Sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';"
    if ($r.Ok) {
        Add-Result -Phase TSDB -Check "pgAdmin connection to $dbName" -Status PASS -Detail "$dbUser@$vm`:$($pg.DefaultPort) with the password from pgpass.conf: $($r.Output) table(s)/view(s) in public"
    } else {
        $failed = $true
        Add-Result -Phase TSDB -Check "pgAdmin connection to $dbName" -Status FAIL -Detail (Get-PgError $r.Output)
    }

    #endregion

    $apcPwd = ''; $suPwd = ''; $su.Password = ''; $apc.Password = ''
    if ($failed) { throw "TimescaleDB setup finished with failures - see the TSDB results." }
    Write-Log PASS "TimescaleDB VM setup complete."
}

#region -- Helpers -------------------------------------------------------------

function ConvertTo-PlainPassword {
    param($Secure)
    if ($Secure -isnot [Security.SecureString] -or $Secure.Length -eq 0) { return '' }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-RepoPath {
    # A manifest path that is absolute is used as is; otherwise it is under APC.RepositoryRoot
    param([Parameter(Mandatory)] [object]$Manifest, [Parameter(Mandatory)] [string]$SubPath)
    if ([IO.Path]::IsPathRooted($SubPath)) { return $SubPath }
    return Join-Path $Manifest.APC.RepositoryRoot $SubPath
}

function Invoke-PgSql {
    <#
        Runs SQL (-Sql, sent on stdin so passwords never show on a command line) or a file (-File) with psql.
        Conn: Exe, Port, User, Password or PassFile, optional Database (postgres) and Host (localhost).
        -w: never prompt; ON_ERROR_STOP: a failing statement fails the run (and with -SingleTransaction
        rolls everything back). Returns @{ Ok; Output } - Output trimmed, tuples only, unaligned.
    #>
    param([Parameter(Mandatory)] [hashtable]$Conn, [string]$Sql, [string]$File, [switch]$SingleTransaction)
    $db   = if ($Conn.Database) { $Conn.Database } else { 'postgres' }
    $hst  = if ($Conn.Host) { $Conn.Host } else { 'localhost' }
    $pgArgs = @('-h', $hst, '-p', "$($Conn.Port)", '-U', $Conn.User, '-d', $db, '-w', '-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1')
    if ($SingleTransaction) { $pgArgs += '-1' }
    $ErrorActionPreference = 'Continue'
    $OutputEncoding = New-Object Text.UTF8Encoding $false
    # With PassFile (and no Password) the password comes only from that pgpass file, as for pgAdmin
    $env:PGPASSWORD = $Conn.Password
    if ($Conn.PassFile) { $env:PGPASSFILE = $Conn.PassFile }
    try {
        if ($File) { $out = & $Conn.Exe @pgArgs -f $File 2>&1 }
        else       { $out = $Sql | & $Conn.Exe @pgArgs -f - 2>&1 }
        $code = $LASTEXITCODE
    } finally { $env:PGPASSWORD = ''; Remove-Item Env:\PGPASSFILE -ErrorAction SilentlyContinue }
    return @{ Ok = ($code -eq 0); Output = ((@($out) | ForEach-Object { "$_" }) -join "`n").Trim() }
}

function Wait-PgReady {
    # True once a login works (the server may still be starting after a service start/restart)
    param([hashtable]$Conn, [int]$TimeoutSec = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $r = Invoke-PgSql -Conn $Conn -Sql 'SELECT 1;'
        if ($r.Ok) { return $true }
        if ($r.Output -match 'password authentication failed|no password supplied|does not exist') { return $false }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Get-PgError {
    param([string]$Output)
    $lines = @($Output -split "`n" | Where-Object { $_ -match 'ERROR|FATAL|psql:' })
    if ($lines) { return ($lines -join '; ') }
    return $Output
}

function Get-PgLoginError {
    param([string]$Output, [string]$User)
    if ($Output -match 'password authentication failed') { return "the $User password was rejected - check it on the Sign in page" }
    if ($Output -match 'no password supplied')           { return "no $User password in this run" }
    return (Get-PgError $Output)
}

function Set-PgHbaEntry {
    <#
        Adds $Entry (whitespace-insensitive match) under "# IPv4 local connections:", after that block's
        host lines, keeping the file's line endings and writing UTF-8 without a BOM (PostgreSQL rejects
        a BOM). Returns 'Present', or the path of the .bak written before the change.
    #>
    param([Parameter(Mandatory)] [string]$Path, [Parameter(Mandatory)] [string]$Entry, [hashtable]$State)
    if (-not (Test-Path -LiteralPath $Path)) { throw "pg_hba.conf not found at $Path" }
    $text  = [IO.File]::ReadAllText($Path)
    $eol   = if ($text -match "`r`n") { "`r`n" } else { "`n" }
    $lines = [Collections.Generic.List[string]]($text -split '\r?\n')
    $want  = ($Entry.Trim() -split '\s+') -join ' '
    if ($lines | Where-Object { (($_.Trim() -split '\s+') -join ' ') -eq $want }) { return 'Present' }

    # Same column layout as the installer's lines: TYPE DATABASE USER ADDRESS METHOD
    $f = $want -split ' '
    $line = if ($f.Count -eq 5) { '{0,-7} {1,-15} {2,-15} {3,-23} {4}' -f $f } else { $want }

    $hdr = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*#\s*IPv4 local connections') { $hdr = $i; break } }
    if ($hdr -ge 0) {
        $at = $hdr + 1
        while ($at -lt $lines.Count -and $lines[$at] -match '^\s*host') { $at++ }
        $lines.Insert($at, $line)
    } else {
        if ($lines.Count -and $lines[$lines.Count - 1] -eq '') { $lines.Insert($lines.Count - 1, $line) } else { $lines.Add($line) }
    }

    $bak = Save-FileBackup -Path $Path -Stamp (Get-Date -Format 'yyyyMMdd-HHmmss') -State $State
    [IO.File]::WriteAllText($Path, ($lines -join $eol), (New-Object Text.UTF8Encoding $false))
    return $bak
}

function Get-PgOdbcDriver {
    # The 32-bit PostgreSQL ANSI driver: @{ Name; Path } or $null. The SOP calls it "PostgreSQL ANSI (x86)";
    # psqlODBC registers the 32-bit one as "PostgreSQL ANSI", so the manifest name is tried first, then any ANSI one.
    param([string]$Preferred)
    $root = 'HKLM:\SOFTWARE\WOW6432Node\ODBC\ODBCINST.INI'
    if (-not (Test-Path $root)) { return $null }
    $names = @(Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName })
    $name  = if ($Preferred -and $Preferred -in $names) { $Preferred } else { $names | Where-Object { $_ -match '^PostgreSQL ANSI' } | Select-Object -First 1 }
    if (-not $name) { return $null }
    $path = (Get-ItemProperty -Path (Join-Path $root $name) -ErrorAction SilentlyContinue).Driver
    if (-not $path) { return $null }
    return @{ Name = $name; Path = $path }
}

function Test-OdbcDsn32 {
    # The SOP's "Test" button: opens the DSN from a 32-bit PowerShell (the DSN and driver are 32-bit).
    # The password goes in an environment variable of that process, not on its command line. Returns 'OK' or the error.
    param([string]$Dsn, [string]$Password)
    $ps32 = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $ps32)) { return "32-bit PowerShell not found: $ps32" }
    $cmd = @"
`$c = New-Object System.Data.Odbc.OdbcConnection ('DSN=$Dsn;Pwd={' + `$env:APC_DSN_PWD.Replace('}', '}}') + '}')
try { `$c.Open(); `$x = `$c.CreateCommand(); `$x.CommandText = 'SELECT 1'; [void]`$x.ExecuteScalar(); 'OK' } catch { `$_.Exception.Message } finally { `$c.Dispose() }
"@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $env:APC_DSN_PWD = $Password
    try { $out = & $ps32 -NoProfile -NonInteractive -EncodedCommand $enc 2>&1 } finally { $env:APC_DSN_PWD = '' }
    return ((@($out) | ForEach-Object { "$_" }) -join ' ').Trim()
}

function Register-PgAdminServer {
    <#
        Registers the server in pgAdmin 4 (desktop mode) for the Windows user running the wizard, with
        pgAdmin's own setup.py: dump-servers to see whether a server of that name is there, load-servers to add it.
        The server gets PassFile (pgAdmin connects with the password from that pgpass file, no prompt). A server
        already there without it is updated in pgAdmin's database (load-servers cannot change a server).
        Returns @{ Status = Present | Registered | Updated | Failed; Detail }.
    #>
    param([string]$PgAdminDir, [string]$Name, [string]$HostName, [int]$Port, [string]$Database, [string]$User, [string]$PassFile)
    $py    = Join-Path $PgAdminDir 'python\python.exe'
    $setup = Join-Path $PgAdminDir 'web\setup.py'
    if (-not (Test-Path $py) -or -not (Test-Path $setup)) { return @{ Status = 'Failed'; Detail = "pgAdmin not found under $PgAdminDir" } }

    $tmp = Join-Path $env:TEMP "apc-pgadmin-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $existing = Get-PgAdminServer -PgAdminDir $PgAdminDir -Name $Name
        if ($existing) {
            if ($existing.PassFile -eq $PassFile) { return @{ Status = 'Present'; Detail = '' } }
            $u = Set-PgAdminServerPassFile -PgAdminDir $PgAdminDir -Name $Name -PassFile $PassFile
            if ($u -ne 'OK') { return @{ Status = 'Failed'; Detail = "Registered, but PassFile could not be set: $u" } }
            $check = Get-PgAdminServer -PgAdminDir $PgAdminDir -Name $Name
            if ($check.PassFile -ne $PassFile) { return @{ Status = 'Failed'; Detail = "PassFile written, but pgAdmin reports '$($check.PassFile)'" } }
            return @{ Status = 'Updated'; Detail = '' }
        }

        # PassFile/SSLMode: pgAdmin before 7; ConnectionParameters: pgAdmin 7+
        $json = @{ Servers = @{ '1' = [ordered]@{
            Name = $Name; Group = 'Servers'; Host = $HostName; Port = $Port
            MaintenanceDB = $Database; Username = $User; SSLMode = 'prefer'; PassFile = $PassFile
            ConnectionParameters = [ordered]@{ sslmode = 'prefer'; connect_timeout = 10; passfile = $PassFile }
        } } } | ConvertTo-Json -Depth 5
        $file = Join-Path $tmp 'servers.json'
        [IO.File]::WriteAllText($file, $json, (New-Object Text.UTF8Encoding $false))
        $l = Invoke-PgAdminSetup -PgAdminDir $PgAdminDir -Command 'load-servers' -File $file
        if (-not $l.Ok) {
            $hint = if (Get-Process -Name 'pgAdmin4' -ErrorAction SilentlyContinue) { ' - pgAdmin is open; close it and re-run' } else { '' }
            return @{ Status = 'Failed'; Detail = "setup.py load-servers: $($l.Output)$hint" }
        }
        $check = Get-PgAdminServer -PgAdminDir $PgAdminDir -Name $Name
        if (-not $check) { return @{ Status = 'Failed'; Detail = "setup.py load-servers ran, but the server is not listed: $($l.Output)" } }
        if ($check.PassFile -ne $PassFile) {
            $u = Set-PgAdminServerPassFile -PgAdminDir $PgAdminDir -Name $Name -PassFile $PassFile
            if ($u -ne 'OK') { return @{ Status = 'Failed'; Detail = "Registered, but PassFile could not be set: $u" } }
        }
        return @{ Status = 'Registered'; Detail = '' }
    } catch {
        return @{ Status = 'Failed'; Detail = "$_" }
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-PgAdminSetup {
    # pgAdmin's setup.py: sub-command form (pgAdmin 8+) first, then the option form (older versions)
    param([string]$PgAdminDir, [string]$Command, [string]$File)
    $ErrorActionPreference = 'Continue'
    $py    = Join-Path $PgAdminDir 'python\python.exe'
    $setup = Join-Path $PgAdminDir 'web\setup.py'
    $out = & $py $setup $Command $File 2>&1
    if ($LASTEXITCODE -ne 0) { $out = & $py $setup "--$Command" $File 2>&1 }
    return @{ Ok = ($LASTEXITCODE -eq 0); Output = ((@($out) | ForEach-Object { "$_" }) -join ' ').Trim() }
}

function Get-PgAdminServer {
    # The server of that name from pgAdmin's dump-servers: @{ Name; Host; Port; MaintenanceDB; Username; PassFile } or $null
    param([string]$PgAdminDir, [string]$Name)
    $dump = Join-Path $env:TEMP "apc-pgadmin-dump-$([guid]::NewGuid().ToString('N')).json"
    try {
        $d = Invoke-PgAdminSetup -PgAdminDir $PgAdminDir -Command 'dump-servers' -File $dump
        if (-not $d.Ok -or -not (Test-Path $dump)) { return $null }
        $cur = Get-Content $dump -Raw | ConvertFrom-Json
        if (-not $cur.Servers) { return $null }
        foreach ($p in $cur.Servers.PSObject.Properties) {
            $v = $p.Value
            if ($v.Name -ne $Name) { continue }
            $pf = if ($v.PSObject.Properties['ConnectionParameters'] -and $v.ConnectionParameters.PSObject.Properties['passfile']) { $v.ConnectionParameters.passfile }
                  elseif ($v.PSObject.Properties['PassFile']) { $v.PassFile } else { '' }
            return @{ Name = $v.Name; Host = $v.Host; Port = $v.Port; MaintenanceDB = $v.MaintenanceDB; Username = $v.Username; PassFile = [string]$pf }
        }
        return $null
    } finally { Remove-Item $dump -Force -ErrorAction SilentlyContinue }
}

function Set-PgAdminServerPassFile {
    # Sets the passfile of an existing pgAdmin server in the user's pgAdmin database (desktop mode:
    # %APPDATA%\pgAdmin\pgadmin4.db) with pgAdmin's own Python: connection_params JSON (pgAdmin 7+) or the
    # passfile column (older). Returns 'OK' or the error.
    param([string]$PgAdminDir, [string]$Name, [string]$PassFile)
    $db = Join-Path $env:APPDATA 'pgAdmin\pgadmin4.db'
    if (-not (Test-Path $db)) { return "pgAdmin database not found: $db" }
    $py = Join-Path $PgAdminDir 'python\python.exe'
    $script = @'
import json, sqlite3, sys
db, name, pf = sys.argv[1:4]
c = sqlite3.connect(db, timeout=10)
cols = [r[1] for r in c.execute("PRAGMA table_info(server)")]
rows = c.execute("SELECT id FROM server WHERE name = ?", (name,)).fetchall()
if not rows:
    print("server not found"); sys.exit(2)
for (sid,) in rows:
    if "connection_params" in cols:
        cp = c.execute("SELECT connection_params FROM server WHERE id = ?", (sid,)).fetchone()[0]
        d = json.loads(cp) if cp else {}
        d["passfile"] = pf
        c.execute("UPDATE server SET connection_params = ? WHERE id = ?", (json.dumps(d), sid))
    elif "passfile" in cols:
        c.execute("UPDATE server SET passfile = ? WHERE id = ?", (pf, sid))
    else:
        print("no passfile column in this pgAdmin version"); sys.exit(3)
c.commit()
print("OK")
'@
    $f = Join-Path $env:TEMP "apc-pgadmin-$([guid]::NewGuid().ToString('N')).py"
    [IO.File]::WriteAllText($f, $script, (New-Object Text.UTF8Encoding $false))
    $ErrorActionPreference = 'Continue'
    try { $out = & $py $f $db $Name $PassFile 2>&1 } finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    return ((@($out) | ForEach-Object { "$_" }) -join ' ').Trim()
}

function Get-PgPassFilePath {
    # libpq's default password file for the current Windows user
    return (Join-Path $env:APPDATA 'postgresql\pgpass.conf')
}

function Set-PgPassEntry {
    <#
        Puts host:port:*:user:password lines for each host in a pgpass file (libpq format; ':' and '\' escaped),
        replacing older lines for the same host/port/user and keeping all others. The file is in the user's
        profile, so only that user (and administrators) can read it. Returns 'Already present', 'Added' or 'Updated'.
    #>
    param([string]$Path, [string[]]$Hosts, [int]$Port, [string]$User, [string]$Password)
    $esc   = { param($v) $v.Replace('\', '\\').Replace(':', '\:') }
    $want  = @($Hosts | ForEach-Object { '{0}:{1}:*:{2}:{3}' -f (& $esc $_), $Port, (& $esc $User), (& $esc $Password) })
    $lines = @(if (Test-Path -LiteralPath $Path) { [IO.File]::ReadAllLines($Path) })
    if (@($want | Where-Object { $_ -cnotin $lines }).Count -eq 0) { return 'Already present' }
    $mine  = @($Hosts | ForEach-Object { '{0}:{1}:*:{2}:' -f (& $esc $_), $Port, (& $esc $User) })
    $keep  = @($lines | Where-Object { $l = $_; -not ($mine | Where-Object { $l.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }) })
    $state = if ($keep.Count -lt $lines.Count) { 'Updated' } else { 'Added' }
    New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, ((@($keep) + $want) -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding $false))
    return $state
}

function Get-SqlCreatedObjects {
    # Names of the tables and views a SQL script creates (comment lines ignored, 'public.' and quotes removed)
    param([string]$Path)
    $text = ([IO.File]::ReadAllLines($Path) | Where-Object { $_ -notmatch '^\s*--' }) -join "`n"
    $rx = '(?i)\bCREATE\s+(?:OR\s+REPLACE\s+)?(?:UNLOGGED\s+)?(?:TABLE|VIEW|MATERIALIZED\s+VIEW)\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:"?public"?\.)?"?([A-Za-z0-9_]+)"?'
    return @([regex]::Matches($text, $rx) | ForEach-Object { $_.Groups[1].Value.ToLower() } | Select-Object -Unique)
}

#endregion
