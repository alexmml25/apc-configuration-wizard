#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only discovery for the Step 13 items that are still manual: DOC launch and indicators, Data Analyzer
    TimescaleDB connection, CNCnetPDM read/write through deviceWise, and the File Manager -> Data Collector file
    flow. Changes nothing.
.DESCRIPTION
    Zips into C:\APC_Config\Logs\manual-checks_<ts>.zip:
      - report.txt: Medtronic processes (path, command line, start time) and their TCP connections (netstat),
        PostgreSQL sessions (pg_stat_activity, as apcuser with the pgpass file Step 2 wrote), deviceWise OPC UA
        server certificate stores, and the folder tree of every Medtronic app (newest files first)
      - logs\: the last 400 lines of the newest log files of each Medtronic app (DOC-n, Data Analyzer,
        Data Collector, File Manager), so the DB / OPC connection messages can be found
      - devicewise\: the device definitions (XML) of CNC1-3 and CNC1-3_PATH from DWCORE.db
      - cncnetpdm\: the driver .ini files (parameter numbers, read/write), CNCnetPDM.ini without the license key
    Run in 64-bit PowerShell (the gateway sqlite3.dll is 64-bit), as the service account, elevated.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Discover-ManualChecks.ps1
#>
param(
    [string]$ManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'APC_ConfigManifest.json'),
    [string]$MedtronicDir = 'C:\Medtronic',
    [string]$OutDir = 'C:\APC_Config\Logs'
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$m    = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$ts    = Get-Date -Format 'yyyyMMdd_HHmmss'
$stage = Join-Path $env:TEMP "manual-checks_$ts"
$zip   = Join-Path $OutDir "manual-checks_$ts.zip"
New-Item -ItemType Directory -Path $stage, (Join-Path $stage 'logs'), (Join-Path $stage 'devicewise'), (Join-Path $stage 'cncnetpdm'), $OutDir -Force | Out-Null
$lines = [System.Collections.Generic.List[string]]::new()
function W([string]$Text = '') { $lines.Add($Text); Write-Host $Text }
function Section([string]$Title) { W ''; W "== $Title ==" }

W "Manual checks discovery  $(Get-Date -Format s)  on $env:COMPUTERNAME as $env:USERDOMAIN\$env:USERNAME"

# -- 1. processes and their TCP connections ------------------------------------------------------------
Section 'Medtronic / APC processes'
$procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ExecutablePath -like "$MedtronicDir\*" -or $_.Name -match 'DOC|DataAnalyzer|DataCollector|FileManager|CNCnetPDM'
})
foreach ($p in $procs) {
    W ("  PID {0,-6} {1}  started {2}" -f $p.ProcessId, $p.Name, $p.CreationDate)
    W "      path: $($p.ExecutablePath)"
    W "      cmd:  $($p.CommandLine)"
    W "      session: $($p.SessionId)  owner: $(try { $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner; "$($o.Domain)\$($o.User)" } catch { '?' })"
}
if (-not $procs) { W '  none found' }

Section 'TCP connections of those processes (netstat -ano)'
$pids = @($procs | ForEach-Object { [string]$_.ProcessId })
$net  = @(netstat -ano 2>$null)
foreach ($l in $net) {
    $f = ($l.Trim() -split '\s+')
    if ($f.Count -ge 5 -and $pids -contains $f[-1]) {
        $name = ($procs | Where-Object { [string]$_.ProcessId -eq $f[-1] } | Select-Object -First 1).Name
        W ("  {0,-22} {1}" -f $name, $l.Trim())
    }
}

# -- 2. PostgreSQL sessions -----------------------------------------------------------------------------
Section 'PostgreSQL sessions (pg_stat_activity)'
$pg   = $m.PostgreSQL
$psql = Join-Path $pg.BinDir 'psql.exe'
$pass = Join-Path $env:APPDATA 'postgresql\pgpass.conf'
if ((Test-Path $psql) -and (Test-Path $pass)) {
    $env:PGPASSFILE = $pass
    $sql = "SELECT pid, usename, datname, application_name, client_addr, client_port, backend_start, state, left(regexp_replace(query, '\s+', ' ', 'g'), 100) FROM pg_stat_activity WHERE backend_type = 'client backend' ORDER BY backend_start;"
    $out = $sql | & $psql -h localhost -p $pg.DefaultPort -U $pg.LocalUser -d $pg.LocalDB -w -X -A -F ' | ' -f - 2>&1
    $out | ForEach-Object { W "  $_" }
    Remove-Item Env:\PGPASSFILE -ErrorAction SilentlyContinue
} else { W "  skipped: psql ($psql) or pgpass ($pass) not found" }

# -- 3. deviceWise OPC UA server certificates and device definitions -----------------------------------
Section 'deviceWise OPC UA server certificate stores'
$dwRoot = [string]$m.DeviceWise.GatewayInstallDir
foreach ($s in 'trusted\certs', 'rejected\certs', 'rejected') {
    $d = Join-Path $dwRoot "staging\uaserver\pkiserver\$s"
    if (-not (Test-Path $d)) { continue }
    foreach ($f in Get-ChildItem $d -File -ErrorAction SilentlyContinue) {
        $sub = try { (New-Object Security.Cryptography.X509Certificates.X509Certificate2($f.FullName)).Subject } catch { '?' }
        W ("  {0,-16} {1}  {2:s}  {3}" -f $s, $f.Name, $f.LastWriteTime, $sub)
    }
}

Section 'deviceWise device definitions (DWCORE.db)'
try {
    function Write-Log { param($Level, $Message) }      # DeviceWise.ps1 helpers log through the wizard
    . (Join-Path $root 'modules\DeviceWise.ps1')
    $paths = Get-DwPaths -Manifest $m
    $rows = Invoke-DwDbQuery -Paths $paths -Database 'DWCORE.db' -Sql 'SELECT name, state FROM devices ORDER BY name'
    foreach ($r in $rows) { W "  device $($r[0])  state $($r[1])" }
    foreach ($n in 'CNC1', 'CNC2', 'CNC3', 'CNC1_PATH', 'CNC2_PATH', 'CNC3_PATH') {
        $x = Get-DwXml -Paths $paths -Table devices -Name $n
        if ($x) { $x.Save((Join-Path $stage "devicewise\$n.xml")); W "  saved devicewise\$n.xml" }
    }
} catch { W "  failed: $($_.Exception.Message)" }

# -- 4. CNCnetPDM driver files --------------------------------------------------------------------------
Section 'CNCnetPDM'
$pdm = [string]$m.CNCnetPDM.InstallDir
if (Test-Path $pdm) {
    Get-ChildItem $pdm -File -Filter '*.ini' -ErrorAction SilentlyContinue | ForEach-Object {
        $dest = Join-Path $stage "cncnetpdm\$($_.Name)"
        if ($_.Name -eq 'CNCnetPDM.ini') {
            (Get-Content $_.FullName) -replace '^(\s*License\s*=).*$', '$1 <removed>' | Set-Content $dest
        } else { Copy-Item $_.FullName $dest }
        W "  saved cncnetpdm\$($_.Name)  ($($_.Length) bytes)"
    }
} else { W "  $pdm not found" }

# -- 5. Medtronic app folders and newest logs -----------------------------------------------------------
Section "Folders under $MedtronicDir (depth 3, newest first, max 40 per app)"
foreach ($app in Get-ChildItem $MedtronicDir -Directory -ErrorAction SilentlyContinue) {
    if ($app.Name -eq 'CNCNetPDM') { continue }          # its log folder is large; the driver files are above
    W "  [$($app.Name)]"
    $files = @(Get-ChildItem $app.FullName -File -Recurse -Depth 3 -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    $files | Select-Object -First 40 | ForEach-Object { W ("    {0:s}  {1,10}  {2}" -f $_.LastWriteTime, $_.Length, $_.FullName.Substring($app.FullName.Length + 1)) }
    $logs = @($files | Where-Object { $_.Extension -in '.log', '.txt' -and $_.FullName -match 'log' } | Select-Object -First 3)
    foreach ($l in $logs) {
        $dest = Join-Path $stage ("logs\{0}__{1}" -f $app.Name, ($l.FullName.Substring($app.FullName.Length + 1) -replace '[\\/:]', '_'))
        Get-Content $l.FullName -Tail 400 -ErrorAction SilentlyContinue | Set-Content $dest
        W "    -> saved the last 400 lines of $($l.Name)"
    }
}

$lines | Set-Content -Path (Join-Path $stage 'report.txt')
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
Remove-Item -LiteralPath $stage -Recurse -Force
W ''
W "Written: $zip"
