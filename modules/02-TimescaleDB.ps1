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
    - pgAdmin: the VM's server registered for the signed-in Windows user (pgAdmin setup.py load-servers);
      saving the password in pgAdmin stays a manual step
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

    $vm = $env:COMPUTERNAME
    $reg = Register-PgAdminServer -PgAdminDir $pg.PgAdminDir -Name $vm -HostName $vm -Port $pg.DefaultPort -Database $dbName -User $dbUser
    $who = "$env:USERDOMAIN\$env:USERNAME"
    switch ($reg.Status) {
        'Present'    { Add-Result -Phase TSDB -Check "pgAdmin server $vm" -Status PASS -Detail "Already registered for $who" }
        'Registered' { Add-Result -Phase TSDB -Check "pgAdmin server $vm" -Status PASS -Detail "Registered for $who`: host $vm, port $($pg.DefaultPort), maintenance DB $dbName, user $dbUser" }
        default {
            Add-Result -Phase TSDB -Check "pgAdmin server $vm" -Status WARN `
                -Detail "Not registered automatically ($($reg.Detail)). In pgAdmin: Servers > Register > Server; Name and Host $vm, port $($pg.DefaultPort), maintenance DB $dbName, user $dbUser"
        }
    }
    Add-Result -Phase TSDB -Check "pgAdmin: save the $dbUser password" -Status MANUAL `
        -Detail "Open pgAdmin 4, connect to server $vm, enter the $dbUser password and tick 'Save password'; confirm the APC tables show under $dbName > Schemas > public > Tables"

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
        -w: never prompt; ON_ERROR_STOP: a failing statement fails the run (and with -SingleTransaction
        rolls everything back). Returns @{ Ok; Output } - Output trimmed, tuples only, unaligned.
    #>
    param([Parameter(Mandatory)] [hashtable]$Conn, [string]$Sql, [string]$File, [switch]$SingleTransaction)
    $db   = if ($Conn.Database) { $Conn.Database } else { 'postgres' }
    $pgArgs = @('-h', 'localhost', '-p', "$($Conn.Port)", '-U', $Conn.User, '-d', $db, '-w', '-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1')
    if ($SingleTransaction) { $pgArgs += '-1' }
    $ErrorActionPreference = 'Continue'
    $OutputEncoding = New-Object Text.UTF8Encoding $false
    $env:PGPASSWORD = $Conn.Password
    try {
        if ($File) { $out = & $Conn.Exe @pgArgs -f $File 2>&1 }
        else       { $out = $Sql | & $Conn.Exe @pgArgs -f - 2>&1 }
        $code = $LASTEXITCODE
    } finally { $env:PGPASSWORD = '' }
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

    $bak = "$Path.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
    Copy-Item -LiteralPath $Path -Destination $bak -Force
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
        pgAdmin 8+ uses sub-commands (load-servers), older versions options (--load-servers); both are tried.
        No password is stored (pgAdmin saves it when the user ticks 'Save password').
        Returns @{ Status = Present | Registered | Failed; Detail }.
    #>
    param([string]$PgAdminDir, [string]$Name, [string]$HostName, [int]$Port, [string]$Database, [string]$User)
    $py    = Join-Path $PgAdminDir 'python\python.exe'
    $setup = Join-Path $PgAdminDir 'web\setup.py'
    if (-not (Test-Path $py) -or -not (Test-Path $setup)) { return @{ Status = 'Failed'; Detail = "pgAdmin not found under $PgAdminDir" } }

    $ErrorActionPreference = 'Continue'
    $tmp = Join-Path $env:TEMP "apc-pgadmin-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $run = {
            param([string]$Cmd, [string]$File)
            $out = & $py $setup $Cmd $File 2>&1
            if ($LASTEXITCODE -ne 0) { $out = & $py $setup "--$Cmd" $File 2>&1 }
            return @{ Ok = ($LASTEXITCODE -eq 0); Output = ((@($out) | ForEach-Object { "$_" }) -join ' ').Trim() }
        }

        $dump = Join-Path $tmp 'current.json'
        $d = & $run 'dump-servers' $dump
        if ($d.Ok -and (Test-Path $dump)) {
            $cur = Get-Content $dump -Raw | ConvertFrom-Json
            if ($cur.Servers) {
                foreach ($p in $cur.Servers.PSObject.Properties) {
                    if ($p.Value.Name -eq $Name) { return @{ Status = 'Present'; Detail = '' } }
                }
            }
        }

        $json = @{ Servers = @{ '1' = [ordered]@{
            Name = $Name; Group = 'Servers'; Host = $HostName; Port = $Port
            MaintenanceDB = $Database; Username = $User; SSLMode = 'prefer'
        } } } | ConvertTo-Json -Depth 4
        $file = Join-Path $tmp 'servers.json'
        [IO.File]::WriteAllText($file, $json, (New-Object Text.UTF8Encoding $false))
        $l = & $run 'load-servers' $file
        if ($l.Ok) { return @{ Status = 'Registered'; Detail = '' } }
        $hint = if (Get-Process -Name 'pgAdmin4' -ErrorAction SilentlyContinue) { ' - pgAdmin is open; close it and re-run' } else { '' }
        return @{ Status = 'Failed'; Detail = "setup.py load-servers: $($l.Output)$hint" }
    } catch {
        return @{ Status = 'Failed'; Detail = "$_" }
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

#endregion
