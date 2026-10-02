#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only discovery for Step 2 (TimescaleDB). Changes nothing.
.DESCRIPTION
    Writes a report to C:\APC_Config\Logs\tsdb-discovery_<ts>.txt with:
      - PostgreSQL service, version, data folder, pg_hba.conf entries (and whether the file has a BOM)
      - as postgres: apcuser role attributes, databases and owners, extensions, public tables
      - whether apcuser can log in to TimescaleDB with the password entered
      - PostgreSQL ODBC drivers and the PostgreSQL30 DSN in the 64-bit and 32-bit registry
      - the schema script folder on the APC share: files, sizes, and DROP / TRUNCATE / DELETE counts
    Passwords are asked for at the prompt, used only for psql (PGPASSWORD) and never written to the report.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Discover-TimescaleDB.ps1
#>
param(
    [string]$ManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'APC_ConfigManifest.json'),
    [string]$OutDir = 'C:\APC_Config\Logs'
)

$ErrorActionPreference = 'Continue'
$m  = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$pg = $m.PostgreSQL
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$out = Join-Path $OutDir ("tsdb-discovery_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$lines = [System.Collections.Generic.List[string]]::new()
function W([string]$Text = '') { $lines.Add($Text); Write-Host $Text }
function Plain([System.Security.SecureString]$S) {
    if (-not $S -or $S.Length -eq 0) { return '' }
    $b = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($S)
    try { [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($b) } finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

$pgPwd  = Plain (Read-Host 'postgres (superuser) password - Enter to skip the database queries' -AsSecureString)
$apcPwd = Plain (Read-Host 'apcuser password - Enter to skip the apcuser login test' -AsSecureString)

W "TimescaleDB discovery  $(Get-Date -Format s)  on $env:COMPUTERNAME as $env:USERDOMAIN\$env:USERNAME"
W "Manifest: Service=$($pg.Service)  BinDir=$($pg.BinDir)  PgHbaFile=$($pg.PgHbaFile)  Port=$($pg.DefaultPort)  DB=$($pg.LocalDB)  User=$($pg.LocalUser)"
W

# ---- Service and version --------------------------------------------------------
W '== PostgreSQL service =='
Get-Service -Name 'postgresql*' -ErrorAction SilentlyContinue | ForEach-Object { W ("  {0}  {1}  ({2})" -f $_.Name, $_.Status, $_.DisplayName) }
Get-CimInstance Win32_Service -Filter "Name LIKE 'postgresql%'" -ErrorAction SilentlyContinue | ForEach-Object { W "  PathName: $($_.PathName)"; W "  StartName: $($_.StartName)" }
$psql = Join-Path $pg.BinDir 'psql.exe'
W "  psql.exe: $psql  exists=$(Test-Path $psql)"
if (Test-Path $psql) { W "  $(& $psql --version 2>&1)" }
W

# ---- pg_hba.conf ----------------------------------------------------------------
W '== pg_hba.conf =='
if (Test-Path $pg.PgHbaFile) {
    $bytes = [System.IO.File]::ReadAllBytes($pg.PgHbaFile)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    W "  $($pg.PgHbaFile)  size=$($bytes.Length)  BOM=$bom  modified=$((Get-Item $pg.PgHbaFile).LastWriteTime)"
    $i = 0
    foreach ($l in [System.IO.File]::ReadAllLines($pg.PgHbaFile)) {
        $i++
        if ($l -match '^\s*#\s*(IPv4|IPv6|TYPE|"local"|Allow replication)' -or ($l.Trim() -and $l -notmatch '^\s*#')) { W ("  {0,4}: {1}" -f $i, $l) }
    }
    W "  Wanted entry '$($pg.HbaEntry)' present: $([bool]([System.IO.File]::ReadAllLines($pg.PgHbaFile) | Where-Object { ($_ -replace '\s+', ' ').Trim() -eq $pg.HbaEntry }))"
} else { W "  NOT FOUND: $($pg.PgHbaFile)" }
W

# ---- Database queries as postgres -------------------------------------------------
function Q([string]$Sql, [string]$Db = 'postgres', [string]$User = 'postgres', [string]$Pwd = $pgPwd) {
    $env:PGPASSWORD = $Pwd
    try { $r = & $psql -h localhost -p $pg.DefaultPort -U $User -d $Db -w -t -A -F ' | ' -c $Sql 2>&1 } finally { $env:PGPASSWORD = '' }
    return @($r | ForEach-Object { "$_" })
}
if ($pgPwd -and (Test-Path $psql)) {
    W '== As postgres =='
    W '  Server version:'; Q 'SHOW server_version;' | ForEach-Object { W "    $_" }
    W '  Roles (name | login | super | createrole | createdb | inherit | replication | bypassrls):'
    Q "SELECT rolname, rolcanlogin, rolsuper, rolcreaterole, rolcreatedb, rolinherit, rolreplication, rolbypassrls FROM pg_roles WHERE rolname NOT LIKE 'pg\_%' ORDER BY 1;" | ForEach-Object { W "    $_" }
    W '  Databases (name | owner | encoding):'
    Q "SELECT datname, pg_get_userbyid(datdba), pg_encoding_to_char(encoding) FROM pg_database WHERE NOT datistemplate ORDER BY 1;" | ForEach-Object { W "    $_" }
    W '  Available timescaledb versions:'
    Q "SELECT name, default_version, installed_version FROM pg_available_extensions WHERE name='timescaledb';" | ForEach-Object { W "    $_" }
    W "  Extensions in $($pg.LocalDB):"
    Q 'SELECT extname, extversion FROM pg_extension ORDER BY 1;' $pg.LocalDB | ForEach-Object { W "    $_" }
    W "  Public tables in $($pg.LocalDB) (name | rows estimate):"
    Q "SELECT c.relname, c.reltuples::bigint FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p') ORDER BY 1;" $pg.LocalDB | ForEach-Object { W "    $_" }
    W "  Hypertables:"
    Q 'SELECT hypertable_name FROM timescaledb_information.hypertables ORDER BY 1;' $pg.LocalDB | ForEach-Object { W "    $_" }
} else { W '== Database queries skipped (no postgres password or no psql.exe) ==' }
W

if ($apcPwd -and (Test-Path $psql)) {
    W "== apcuser login to $($pg.LocalDB) =="
    Q 'SELECT current_user, current_database();' $pg.LocalDB $pg.LocalUser $apcPwd | ForEach-Object { W "  $_" }
    W
}

# ---- ODBC -----------------------------------------------------------------------
W '== ODBC drivers (PostgreSQL) =='
foreach ($hive in 'HKLM:\SOFTWARE\ODBC\ODBCINST.INI', 'HKLM:\SOFTWARE\WOW6432Node\ODBC\ODBCINST.INI') {
    $bits = if ($hive -match 'WOW6432Node') { '32-bit' } else { '64-bit' }
    $drv = Get-ItemProperty "$hive\ODBC Drivers" -ErrorAction SilentlyContinue
    if ($drv) { $drv.PSObject.Properties | Where-Object { $_.Name -match 'PostgreSQL' } | ForEach-Object { W "  [$bits] $($_.Name) = $($_.Value)  driver=$((Get-ItemProperty "$hive\$($_.Name)" -ErrorAction SilentlyContinue).Driver)" } }
    else { W "  [$bits] no ODBC Drivers key" }
}
W "== DSN $($pg.OdbcDsn) =="
foreach ($hive in 'HKLM:\SOFTWARE\ODBC\ODBC.INI', 'HKLM:\SOFTWARE\WOW6432Node\ODBC\ODBC.INI') {
    $bits = if ($hive -match 'WOW6432Node') { '32-bit' } else { '64-bit' }
    $k = Get-ItemProperty "$hive\$($pg.OdbcDsn)" -ErrorAction SilentlyContinue
    if ($k) {
        $vals = $k.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object { if ($_.Name -match 'Password') { "$($_.Name)=<set:$([bool]$_.Value)>" } else { "$($_.Name)=$($_.Value)" } }
        W "  [$bits] $($vals -join '; ')"
    } else { W "  [$bits] not present" }
}
W

# ---- Schema scripts on the share ------------------------------------------------------
W '== Schema scripts =='
$dir = ([string]$m.APC.RepositoryRoot).TrimEnd('\') + '\' + [string]$m.SchemaScriptsRepoSubPath
W "  Folder: $dir  reachable=$(Test-Path $dir)"
if (Test-Path $dir) {
    Get-ChildItem $dir -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
        $t = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
        $c = { param($p) ([regex]::Matches($t, $p, 'IgnoreCase')).Count }
        W ("  {0,-30} {1,8} bytes  CREATE TABLE={2} IF NOT EXISTS={3} DROP={4} TRUNCATE={5} DELETE={6} INSERT={7}" -f $_.Name, $_.Length,
            (& $c 'CREATE\s+TABLE'), (& $c 'IF\s+NOT\s+EXISTS'), (& $c '\bDROP\s'), (& $c '\bTRUNCATE\b'), (& $c '\bDELETE\s+FROM\b'), (& $c '\bINSERT\s+INTO\b'))
    }
    W "  Manifest order: $($m.SchemaScripts -join ', ')"
}
W

# ---- pgAdmin ------------------------------------------------------------------------
W '== pgAdmin =='
foreach ($pat in 'C:\Program Files\pgAdmin*', 'C:\Program Files\PostgreSQL\*\pgAdmin*') {
    Get-Item $pat -ErrorAction SilentlyContinue | Where-Object PSIsContainer | ForEach-Object { W "  $($_.FullName)" }
}

$pgPwd = ''; $apcPwd = ''
[System.IO.File]::WriteAllLines($out, $lines)
Write-Host ''
Write-Host "Report: $out" -ForegroundColor Green
