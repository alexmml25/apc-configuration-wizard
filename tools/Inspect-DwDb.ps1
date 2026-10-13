#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only look into the deviceWISE gateway databases (Gateway\db\*.db) through the gateway's sqlite3.dll.
.DESCRIPTION
    -Group <name>  lists DWUSER.db persistence rows of that group (e.g. opcua_server_v3, system,
                   cncnetpdm.instances); without -Group and -Find, lists all groups with their row counts.
    -Find <text>   searches every text column of every table in DWCORE, DWAPP, DWUSER and DWTS
                   for the text (e.g. 'Citizen 01'), and prints table, column and a short excerpt.
    Values of columns or names that look like passwords/secrets/keys/vouchers are masked.
    Opens the databases read-only; dwcore can keep running. Nothing is changed.
    Output also saved to C:\APC_Config\Logs\dw-db-<timestamp>.txt
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Inspect-DwDb.ps1 -Group opcua_server_v3
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Inspect-DwDb.ps1 -Find "Citizen 01"
#>
param(
    [string]$Group,
    [string]$Find,
    [string]$GatewayRoot = 'C:\Program Files\deviceWISE\Gateway'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function Write-Log { param($Level, $Message) }
. (Join-Path $root 'modules\DeviceWise.ps1')
$paths = @{ Root = $GatewayRoot; Db = Join-Path $GatewayRoot 'db'; Sqlite = Join-Path $GatewayRoot 'dwcore\sqlite3.dll' }
Initialize-DwSqlite -Paths $paths

New-Item -ItemType Directory -Path 'C:\APC_Config\Logs' -Force | Out-Null
$out = "C:\APC_Config\Logs\dw-db-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss')
function Out-Line([string]$t) { Write-Host $t; Add-Content -Path $out -Value $t }
$secret = '(?i)pass|secret|key|voucher|hash|token'
function Mask([string]$name, [string]$value) { if ($name -match $secret) { '<masked>' } else { $value } }

Out-Line "deviceWISE DB inspection - $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

if ($Group -or -not $Find) {
    $h = [DwSqlite]::Open((Join-Path $paths.Db 'DWUSER.db'), $false)
    try {
        if ($Group) {
            Out-Line "`r`n== DWUSER.db persistence, group '$Group'"
            foreach ($r in [DwSqlite]::Query($h, 'SELECT name, value FROM persistence WHERE grp = ? ORDER BY name', $Group)) {
                $v = ([string](Mask $r[0] $r[1])) -replace '[\x00-\x1F]', '?'
                if ($v.Length -gt 300) { $v = $v.Substring(0, 300) + '...' }
                Out-Line ("  {0} = {1}" -f $r[0], $v)
            }
        } else {
            Out-Line "`r`n== DWUSER.db persistence groups"
            foreach ($r in [DwSqlite]::Query($h, 'SELECT grp, COUNT(*) FROM persistence GROUP BY grp ORDER BY grp')) { Out-Line ("  {0,-40} {1}" -f $r[0], $r[1]) }
        }
    } finally { [DwSqlite]::Close($h) }
}

if ($Find) {
    foreach ($dbName in 'DWCORE.db', 'DWAPP.db', 'DWUSER.db', 'DWTS.db') {
        $file = Join-Path $paths.Db $dbName
        if (-not (Test-Path $file)) { continue }
        Out-Line "`r`n== $dbName : '$Find'"
        $h = [DwSqlite]::Open($file, $false)
        try {
            $tables = [DwSqlite]::Query($h, "SELECT name FROM sqlite_master WHERE type = 'table'")
            foreach ($t in $tables) {
                $table = $t[0]
                $cols = [DwSqlite]::Query($h, "SELECT name FROM pragma_table_info(?)", $table)
                foreach ($c in $cols) {
                    $col = $c[0]
                    $sql = 'SELECT CAST("{1}" AS TEXT) FROM "{0}" WHERE instr(CAST("{1}" AS TEXT), ?) > 0 LIMIT 5' -f $table.Replace('"', '""'), $col.Replace('"', '""')
                    try { $hits = [DwSqlite]::Query($h, $sql, $Find) } catch { continue }
                    foreach ($hit in $hits) {
                        $v = [string]$hit[0]; $i = $v.IndexOf($Find)
                        $ex = $v.Substring([Math]::Max(0, $i - 80), [Math]::Min($v.Length - [Math]::Max(0, $i - 80), 200)) -replace '[\x00-\x1F]', ' '
                        Out-Line ("  {0}.{1}: ...{2}..." -f $table, $col, (Mask $col $ex))
                    }
                }
            }
        } finally { [DwSqlite]::Close($h) }
    }
}
Out-Line "`r`nSaved to $out"
