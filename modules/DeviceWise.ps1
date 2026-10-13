#Requires -Version 5.1
<#
.SYNOPSIS
    deviceWise helpers dot-sourced by the deviceWise steps (4, and later 5, 6, 8).
.DESCRIPTION
    The gateway (23.04.08) has no usable local API for configuration, so the steps use Telit's
    documented import folder, Gateway\staging\system\import (import.readme.txt in the install):
      import.dwx   a deviceWise export / Workbench backup, imported when dwcore starts;
                   outcome in import.result (the readme says import.results), file then deleted
      package.sup  a package; NOT usable with the approved .pkg files (encrypted: "Failed to
                   decrypt file", -7018). Packages are installed from an exported payload
                   by following their own install instructions (Get-DwPackagePlan).
    Rules found on the test VMs (2026-10-08 / 10-13):
      - dwts must be running during an import, or every transport / transaction fails (-4999);
        dwcore and dwts have no service dependency, so only dwcore is restarted.
      - Status 0 = imported. Certificates / Connections Log / Sessions are runtime lists (-1).
    The configuration comes from an approved baseline Workbench backup (.dbk, plain XML; baseline
    = SJUM7AAPPS0065, user decision 2026-10-13). This VM's values are patched in before the import.
    Values that are not part of an export (CNCnetPDM instance, gateway settings) live in
    Gateway\db\DWUSER.db, table persistence; they are read through the gateway's own sqlite3.dll.
#>

. (Join-Path $PSScriptRoot 'Common.ps1')

function Get-DwPaths {
    param([Parameter(Mandatory)] [object]$Manifest)
    $root = $Manifest.DeviceWise.GatewayInstallDir
    return @{
        Root      = $root
        ImportDir = Join-Path $root 'staging\system\import'
        Packages  = Join-Path $root 'dwcore\packages'
        Db        = Join-Path $root 'db'
        Sqlite    = Join-Path $root 'dwcore\sqlite3.dll'
    }
}

function Get-DwRepoPath {
    # A manifest path that is absolute is used as is; otherwise it is under APC.RepositoryRoot
    param([Parameter(Mandatory)] [object]$Manifest, [Parameter(Mandatory)] [string]$SubPath)
    if ([IO.Path]::IsPathRooted($SubPath)) { return $SubPath }
    return Join-Path $Manifest.APC.RepositoryRoot $SubPath
}

#region -- Baseline -> import file -------------------------------------------

function Set-DwSystemName {
    # The 'system' item is base64 of: <length byte><gateway name><rest>, e.g. \x0eSJUM7AAPPS0065\x01 0 \x00\x03 1.0
    param([Parameter(Mandatory)] [string]$Base64, [Parameter(Mandatory)] [string]$Name)
    $bytes = [Convert]::FromBase64String($Base64.Trim())
    $len   = [int]$bytes[0]
    if ($len -lt 1 -or $len + 1 -gt $bytes.Length) { throw "Unexpected gateway name format in the baseline 'system' item." }
    if ($Name.Length -gt 255) { throw "Gateway name '$Name' is too long." }
    $rest  = New-Object byte[] ($bytes.Length - 1 - $len)
    [Array]::Copy($bytes, 1 + $len, $rest, 0, $rest.Length)
    $new = @([byte]$Name.Length) + [Text.Encoding]::ASCII.GetBytes($Name) + $rest
    return [Convert]::ToBase64String([byte[]]$new)
}

function Set-DwVariableDefault {
    # Adds/replaces default="..." on a top-level <VariableInfo name="$Variable"> in a device's
    # Variables property. The CNC devices have persist_values=false, so a default is what the
    # gateway sets again on every start.
    param([Parameter(Mandatory)] [string]$VariablesXml, [Parameter(Mandatory)] [string]$Variable, [string]$Value)
    $esc = [Security.SecurityElement]::Escape($Value)
    $pattern = '<VariableInfo\b[^>]*\bname="' + [regex]::Escape($Variable) + '"[^>]*?/?>'
    $m = [regex]::Match($VariablesXml, $pattern)
    if (-not $m.Success) { throw "Variable $Variable not found in the device definition." }
    $tag = $m.Value -replace '\s+default="[^"]*"', ''
    $tag = $tag -replace '(\s*/?>)$', (' default="' + $esc.Replace('$', '$$') + '"$1')
    return $VariablesXml.Substring(0, $m.Index) + $tag + $VariablesXml.Substring($m.Index + $m.Length)
}

function New-DwBaseImport {
    <#
        Builds the Step 4 import from the baseline backup:
          keeps the item types in Manifest.DeviceWise.BaseImportTypes; of type 'device' only
          BaseDevices (CNC1-3), of type 'file' only the OPC UA device files of those devices;
          removes the licence voucher (lease issued to the source VM);
          sets the gateway name, the OPC UA endpoint host and CNCn CNCAsset / CNCType defaults.
        $Cncs: hashtables with CNCIndex, MachineName, CNCType (Get-AssignedCNCs).
        Returns @{ Xml = [xml]; Items = [string[]] 'type/name'; Changes = [string[]] }.
    #>
    param(
        [Parameter(Mandatory)] [string]$BaselinePath,
        [Parameter(Mandatory)] [object]$Manifest,
        [Parameter(Mandatory)] [object[]]$Cncs,
        [Parameter(Mandatory)] [string]$GatewayName
    )
    $dw      = $Manifest.DeviceWise
    $types   = @($dw.BaseImportTypes)
    $devices = @($dw.CNCNodes)
    $xml = New-Object Xml.XmlDocument
    $xml.PreserveWhitespace = $true
    $xml.Load($BaselinePath)
    if ($xml.DocumentElement.Name -ne 'export') { throw "$BaselinePath is not a deviceWise export/backup (root <$($xml.DocumentElement.Name)>)." }

    $changes = New-Object System.Collections.Generic.List[string]
    $items   = New-Object System.Collections.Generic.List[string]
    foreach ($ec in @($xml.DocumentElement.SelectNodes('exportcontent'))) {
        $type = $ec.GetAttribute('type'); $name = $ec.GetAttribute('name')
        $keep = $types -contains $type
        if ($keep -and $type -eq 'device') { $keep = $devices -contains $name }
        if ($keep -and $type -eq 'file')   { $keep = @($devices | Where-Object { $name -eq "/uaserver/devices/$_.json" }).Count -gt 0 }
        if ($keep) { $items.Add("$type/$name") } else { [void]$xml.DocumentElement.RemoveChild($ec) }
    }

    foreach ($v in @($xml.SelectNodes("//exportcontent[@type='license.pool']//PersistenceEntry[@name='voucher']"))) {
        [void]$v.ParentNode.RemoveChild($v); $changes.Add('licence voucher of the source VM removed')
    }

    $sys = $xml.SelectSingleNode("//exportcontent[@type='system']/exportitem")
    if ($sys) {
        $sys.InnerText = Set-DwSystemName -Base64 $sys.InnerText -Name $GatewayName
        $changes.Add("gateway name = $GatewayName")
    }

    $ep = $xml.SelectSingleNode("//exportcontent[@type='Endpoints']/exportitem")
    if ($ep) {
        $text = $ep.InnerText
        $new  = [regex]::Replace($text, '("endpoint_address"\s*:\s*"opc\.tcp://)[^:/"]+', { param($m) $m.Groups[1].Value + $GatewayName })
        if ($new -ne $text) { $changes.Add("OPC UA endpoint host = $GatewayName") }
        # SOP 2.1.1: all security policies except the last (Aes256Sha256RsaPss); the baseline differs
        if ($dw.PSObject.Properties['OpcUaSecurityPolicies']) {
            $pol  = @($dw.OpcUaSecurityPolicies) -join ','
            $new2 = [regex]::Replace($new, '("group_security_security_policies"\s*:\s*")[^"]*', { param($m) $m.Groups[1].Value + $pol })
            if ($new2 -ne $new) { $changes.Add("OPC UA security policies = $pol") }
            $new = $new2
        }
        $ep.InnerText = $new
    }

    foreach ($c in $Cncs) {
        $node = "CNC$($c.CNCIndex)"
        $prop = $xml.SelectSingleNode("//exportcontent[@type='device' and @name='$node']//DeviceDefinition/Properties/Property[@name='Variables']")
        if (-not $prop) { throw "Device $node is not in the baseline." }
        $vars = $prop.GetAttribute('value')
        $vars = Set-DwVariableDefault -VariablesXml $vars -Variable 'CNCAsset' -Value ([string]$c.MachineName)
        $vars = Set-DwVariableDefault -VariablesXml $vars -Variable 'CNCType'  -Value ([string]$c.CNCType)
        $prop.SetAttribute('value', $vars)
        $changes.Add("$node CNCAsset = $($c.MachineName), CNCType = $($c.CNCType)")
    }
    return @{ Xml = $xml; Items = [string[]]$items; Changes = [string[]]$changes }
}

function Save-DwXml {
    param([Parameter(Mandatory)] [xml]$Xml, [Parameter(Mandatory)] [string]$Path)
    $w = New-Object IO.StreamWriter($Path, $false, (New-Object Text.UTF8Encoding($false)))
    try { $Xml.Save($w) } finally { $w.Close() }
}

#endregion

#region -- Gateway: services, import folder ------------------------------------

function Restart-DwCore {
    # Stops dwcore, runs $WhileStopped, starts dwcore again whatever happened. dwts keeps running.
    param([Parameter(Mandatory)] [scriptblock]$WhileStopped, [int]$StopTimeoutSec = 180)
    if ((Get-Service 'dwts').Status -ne 'Running') { Write-Log INFO 'Starting dwts (needed during imports)'; Start-Service 'dwts' }
    Write-Log INFO 'Stopping dwcore'
    Stop-Service 'dwcore' -Force -WarningAction SilentlyContinue
    (Get-Service 'dwcore').WaitForStatus('Stopped', [TimeSpan]::FromSeconds($StopTimeoutSec))
    try { & $WhileStopped }
    finally {
        Write-Log INFO 'Starting dwcore (imports run during startup and can take minutes)'
        Start-Service 'dwcore' -WarningAction SilentlyContinue
    }
}

function Wait-DwImportFile {
    # Waits until the gateway has consumed $Queued and written one of $ResultFiles; returns its path or $null
    param([string]$Queued, [string[]]$ResultFiles, [int]$TimeoutSec = 900)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Path $Queued)) {
            $r = $ResultFiles | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($r) { return $r }
        }
        Start-Sleep -Seconds 3
    }
    return $null
}

function Read-DwImportResult {
    # Parses import.result: 'Type[t] Item[n] import status[s]' lines and 'Overall import status[s]'
    param([Parameter(Mandatory)] [string]$Path)
    $items = @(); $overall = $null
    foreach ($line in Get-Content $Path) {
        if ($line -match '^Type\[(.*)\] Item\[(.*)\] import status\[(-?\d+)\]') {
            $items += [pscustomobject]@{ Type = $Matches[1]; Item = $Matches[2]; Status = [int]$Matches[3] }
        } elseif ($line -match 'Overall import status\[(-?\d+)\]') { $overall = [int]$Matches[1] }
    }
    return [pscustomobject]@{ Items = $items; Overall = $overall; Lines = @(Get-Content $Path) }
}

function Save-DwDatabases {
    # Safety copy of the configuration databases (dwcore must be stopped). Logs/reports are skipped.
    param([Parameter(Mandatory)] [hashtable]$Paths, [Parameter(Mandatory)] [string]$Dest)
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    foreach ($db in 'DWCORE.db', 'DWAPP.db', 'DWUSER.db', 'DWTS.db') {
        $src = Join-Path $Paths.Db $db
        if (Test-Path $src) { Copy-Item $src $Dest -Force }
    }
}

function Get-DwPackagePlan {
    <#
        Reads the approved package payload (Manifest.DeviceWise.PackagesRepoSubPath, made by
        tools\Export-DwPackagePayload.ps1 from a gateway installed through Workbench):
          <dir>\<key>\<key>.xml   the package's own install instructions (DWPackage/Install)
          <dir>\<key>\<from>      each file the instructions add
          <dir>\SHA256SUMS.txt    checksums of all of them
        The .pkg files themselves are encrypted; the gateway rejects them as package.sup (-7018).
        Returns one entry per key: @{ Key; Name; Version; Xml; Copies = @(@{ Src; Dest }); Installed }.
        Throws on a missing file, a checksum mismatch or an install action the wizard does not know.
    #>
    param([Parameter(Mandatory)] [hashtable]$Paths, [Parameter(Mandatory)] [string]$PayloadDir, [Parameter(Mandatory)] [string[]]$Keys)
    $sumFile = Join-Path $PayloadDir 'SHA256SUMS.txt'
    if (-not (Test-Path $sumFile)) { throw "SHA256SUMS.txt not found in $PayloadDir" }
    $sums = @{}
    foreach ($line in Get-Content $sumFile) { if ($line -match '^([0-9A-Fa-f]{64})\s+(.+)$') { $sums[$Matches[2].Trim()] = $Matches[1].ToUpper() } }
    $check = {
        param([string]$rel)
        $file = Join-Path $PayloadDir ($rel -replace '/', '\')
        if (-not (Test-Path $file)) { throw "Package payload file missing: $file" }
        if (-not $sums.ContainsKey($rel)) { throw "No checksum for $rel in SHA256SUMS.txt" }
        if ((Get-FileHash $file -Algorithm SHA256).Hash -ne $sums[$rel]) { throw "Checksum mismatch: $file" }
        return $file
    }
    $plan = foreach ($key in $Keys) {
        $xmlFile = & $check "$key/$key.xml"
        [xml]$pkg = Get-Content $xmlFile -Raw
        $copies = @()
        foreach ($a in @($pkg.DocumentElement.SelectNodes('Install/*'))) {
            switch ($a.LocalName) {
                { $_ -in 'StopRuntime', 'StartRuntime' } { continue }   # dwcore is stopped/started around all packages
                'AddFile'        { $copies += @{ Src = (& $check "$key/$($a.GetAttribute('from'))"); Dest = Join-Path $Paths.Root ('dwcore\'  + ($a.GetAttribute('to') -replace '/', '\')) } }
                'AddStagingFile' { $copies += @{ Src = (& $check "$key/$($a.GetAttribute('from'))"); Dest = Join-Path $Paths.Root ('staging\' + ($a.GetAttribute('to') -replace '/', '\')) } }
                default          { throw "Package $key uses install action <$($a.LocalName)>, which the wizard does not support." }
            }
        }
        @{ Key = $key; Name = $pkg.DocumentElement.GetAttribute('name'); Version = $pkg.DocumentElement.GetAttribute('version'); Xml = $xmlFile; Copies = $copies
           Installed = Test-Path (Join-Path $Paths.Packages "$key.xml") }
    }
    return ,@($plan)
}

function Install-DwPackages {
    # Installs the plan's packages that are not installed yet, in one dwcore stop: the files from
    # their install instructions, then <key>.xml into dwcore\packages (how the gateway records an
    # installed package). $BeforeCopy runs first while dwcore is stopped. Returns the keys installed.
    param([Parameter(Mandatory)] [hashtable]$Paths, [Parameter(Mandatory)] [object[]]$Plan, [scriptblock]$BeforeCopy)
    $todo = @($Plan | Where-Object { -not $_.Installed })
    if (-not $todo.Count) { return @() }
    Restart-DwCore -WhileStopped {
        if ($BeforeCopy) { & $BeforeCopy }
        foreach ($p in $todo) {
            foreach ($c in $p.Copies) {
                New-Item -ItemType Directory -Path (Split-Path $c.Dest) -Force | Out-Null
                Copy-Item $c.Src $c.Dest -Force
                Write-Log INFO "  $($p.Key): $(Split-Path $c.Src -Leaf) -> $($c.Dest)"
            }
            Copy-Item $p.Xml (Join-Path $Paths.Packages "$($p.Key).xml") -Force
        }
    }
    return @($todo | ForEach-Object { $_.Key })
}

#endregion

#region -- DWUSER.db through the gateway's sqlite3.dll -------------------------

function Initialize-DwSqlite {
    param([Parameter(Mandatory)] [hashtable]$Paths)
    if (-not [Environment]::Is64BitProcess) { throw 'The gateway sqlite3.dll is 64-bit; run the wizard in 64-bit PowerShell.' }
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
    if ([DwSqlite]::LoadLibrary($Paths.Sqlite) -eq [IntPtr]::Zero) { throw "Cannot load $($Paths.Sqlite)" }
}

function Get-DwPersistence {
    # Reads DWUSER.db persistence rows of one group (read-only; dwcore may be running).
    param([Parameter(Mandatory)] [hashtable]$Paths, [Parameter(Mandatory)] [string]$Group)
    Initialize-DwSqlite -Paths $Paths
    $h = [DwSqlite]::Open((Join-Path $Paths.Db 'DWUSER.db'), $false)
    try {
        $out = @{}
        foreach ($r in [DwSqlite]::Query($h, 'SELECT name, value FROM persistence WHERE grp = ?', $Group)) { $out[$r[0]] = $r[1] }
        return $out
    } finally { [DwSqlite]::Close($h) }
}

#endregion
