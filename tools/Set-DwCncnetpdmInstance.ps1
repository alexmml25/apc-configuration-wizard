#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Registers the CNCnetPDM instance on the deviceWISE gateway (SOP D01555607 2.1.1,
    CNCnetPDM Instance Management > Add), without Workbench.
.DESCRIPTION
    The registration is not part of a Workbench backup/export, so the template import cannot
    bring it. The gateway keeps it in Gateway\db\DWUSER.db, table persistence:
        grp = 'cncnetpdm.instances', name = <instance name>, value = <CNCnetPDM folder>
    (seen on SJUM1CAPPD0017: CNCNetPDM = C:\Medtronic\CNCNetPDM).
    The table has a unique index on (grp, name), so the row is written with INSERT OR REPLACE.

    -Show only reads (no service stop). Otherwise: stops dwcore (dwts keeps running), copies
    DWUSER.db to a safety folder, writes the row, reads it back and starts dwcore again.
    The database is opened through the gateway's own sqlite3.dll (public SQLite library),
    so no other tools are needed. Must run in 64-bit PowerShell (the DLL is x64).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Set-DwCncnetpdmInstance.ps1 -Show
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Set-DwCncnetpdmInstance.ps1
#>
param(
    [string]$InstanceName = 'CNCNetPDM',
    [string]$InstancePath = 'C:\Medtronic\CNCNetPDM',
    [switch]$Show,
    [string]$GatewayRoot  = 'C:\Program Files\deviceWISE\Gateway',
    [string]$BackupRoot   = 'C:\APC_Config\Backups'
)

$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess) { throw 'Run this in 64-bit PowerShell (the gateway sqlite3.dll is x64).' }
$dll = Join-Path $GatewayRoot 'dwcore\sqlite3.dll'
$db  = Join-Path $GatewayRoot 'db\DWUSER.db'
foreach ($p in $dll, $db) { if (-not (Test-Path $p)) { throw "Not found: $p" } }

if (-not ('DwSqlite' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class DwSqlite {
    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr LoadLibrary(string path);

    const string L = "sqlite3.dll";
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_open_v2(byte[] file, out IntPtr db, int flags, IntPtr vfs);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_close_v2(IntPtr db);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_busy_timeout(IntPtr db, int ms);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int n, out IntPtr stmt, IntPtr tail);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_bind_text(IntPtr stmt, int i, byte[] v, int n, IntPtr destructor);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_step(IntPtr stmt);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_column_count(IntPtr stmt);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr sqlite3_column_text(IntPtr stmt, int i);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_finalize(IntPtr stmt);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr sqlite3_errmsg(IntPtr db);

    const int ROW = 100, DONE = 101;
    static readonly IntPtr TRANSIENT = new IntPtr(-1);

    static byte[] Z(string s) { return Encoding.UTF8.GetBytes(s + "\0"); }
    static string S(IntPtr p) {
        if (p == IntPtr.Zero) return null;
        int n = 0; while (Marshal.ReadByte(p, n) != 0) n++;
        byte[] b = new byte[n]; Marshal.Copy(p, b, 0, n); return Encoding.UTF8.GetString(b);
    }
    static string Err(IntPtr db) { return S(sqlite3_errmsg(db)); }

    // flags: 1 = read only, 2 = read/write (never create)
    public static IntPtr Open(string path, bool write) {
        IntPtr db;
        int rc = sqlite3_open_v2(Z(path), out db, write ? 2 : 1, IntPtr.Zero);
        if (rc != 0) { string e = Err(db); sqlite3_close_v2(db); throw new Exception("sqlite open " + rc + ": " + e); }
        sqlite3_busy_timeout(db, 10000);
        return db;
    }
    public static void Close(IntPtr db) { sqlite3_close_v2(db); }

    public static List<string[]> Query(IntPtr db, string sql, params string[] args) {
        IntPtr st;
        if (sqlite3_prepare_v2(db, Z(sql), -1, out st, IntPtr.Zero) != 0) throw new Exception("sqlite prepare: " + Err(db));
        var rows = new List<string[]>();
        try {
            for (int i = 0; i < args.Length; i++) sqlite3_bind_text(st, i + 1, Z(args[i]), -1, TRANSIENT);
            int rc;
            while ((rc = sqlite3_step(st)) == ROW) {
                int n = sqlite3_column_count(st); var r = new string[n];
                for (int c = 0; c < n; c++) r[c] = S(sqlite3_column_text(st, c));
                rows.Add(r);
            }
            if (rc != DONE) throw new Exception("sqlite step " + rc + ": " + Err(db));
        } finally { sqlite3_finalize(st); }
        return rows;
    }
}
'@
}
if ([DwSqlite]::LoadLibrary($dll) -eq [IntPtr]::Zero) { throw "Cannot load $dll" }

$select = "SELECT name, value FROM persistence WHERE grp = 'cncnetpdm.instances' ORDER BY name"
function Show-Instances($h) {
    $rows = [DwSqlite]::Query($h, $select)
    if (-not $rows.Count) { Write-Host '  (no CNCnetPDM instance registered)' }
    foreach ($r in $rows) { Write-Host ("  {0} = {1}" -f $r[0], $r[1]) }
}

Write-Host "Gateway DB: $db" -ForegroundColor Cyan
if ($Show) {
    $h = [DwSqlite]::Open($db, $false)
    try { Write-Host 'Registered CNCnetPDM instances:'; Show-Instances $h } finally { [DwSqlite]::Close($h) }
    return
}

if (-not (Test-Path $InstancePath)) { throw "CNCnetPDM folder not found: $InstancePath" }
Write-Host "Register: $InstanceName = $InstancePath"

$safety = Join-Path $BackupRoot ("{0}\deviceWise-before-cncnetpdm-instance" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $safety -Force | Out-Null

Write-Host 'Stopping dwcore ...'
Stop-Service 'dwcore' -Force -WarningAction SilentlyContinue
(Get-Service 'dwcore').WaitForStatus('Stopped', [TimeSpan]::FromSeconds(120))
try {
    Copy-Item $db $safety
    Write-Host "Safety copy: $safety\DWUSER.db"
    $h = [DwSqlite]::Open($db, $true)
    try {
        Write-Host 'Before:'; Show-Instances $h
        [void][DwSqlite]::Query($h, "INSERT OR REPLACE INTO persistence (name, grp, value) VALUES (?, 'cncnetpdm.instances', ?)", $InstanceName, $InstancePath)
        Write-Host 'After:';  Show-Instances $h
    } finally { [DwSqlite]::Close($h) }
} finally {
    Write-Host 'Starting dwcore ...'
    Start-Service 'dwcore' -WarningAction SilentlyContinue
}
Write-Host 'Done. Check Workbench > Administration > CNCnetPDM Instance Management: the instance should show Connected.'
