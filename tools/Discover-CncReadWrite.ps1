#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only discovery for the Step 13 CNCnetPDM read / write checks: where the CNC variable 2_597
    (#597, CNCToSegregateParts) can be reached through deviceWise. Changes nothing.
.DESCRIPTION
    Writes C:\APC_Config\Logs\cnc-readwrite_<ts>.txt with:
      - the deviceWise triggers (DWCORE.db) whose definition mentions 597 / CNCToSegregateParts, and how they
        move the value between CNCn and CNCn_PATH
      - the top of the deviceWise OPC UA address space (Objects folder, 2 levels): which devices are exposed
      - a read of candidate nodes: CNC1_PATH.2_597, CNC1.Control.CNCToSegregateParts, CNC1.CNCAsset
    Run in 64-bit PowerShell, as the service account, after Step 7 has given the devices the configured driver ini.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Discover-CncReadWrite.ps1
#>
param(
    [string]$ManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'APC_ConfigManifest.json'),
    [string]$OutDir = 'C:\APC_Config\Logs',
    [int]$Cnc = 1
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$m    = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$out   = Join-Path $OutDir ("cnc-readwrite_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$lines = [System.Collections.Generic.List[string]]::new()
function W([string]$Text = '') { $lines.Add($Text); Write-Host $Text }
function Write-Log { param($Level, $Message) }       # DeviceWise.ps1 helpers log through the wizard
. (Join-Path $root 'modules\DeviceWise.ps1')

W "CNC read/write discovery  $(Get-Date -Format s)  on $env:COMPUTERNAME as $env:USERDOMAIN\$env:USERNAME"
$paths = Get-DwPaths -Manifest $m
$ns    = $m.DeviceWise.OpcUaClient.Namespace

# -- 1. triggers that move #597 --------------------------------------------------------------------------
W ''; W '== Triggers mentioning 597 / CNCToSegregateParts (DWCORE.db) =='
try {
    $rows = Invoke-DwDbQuery -Paths $paths -Database 'DWCORE.db' -Sql "SELECT project, name, state, xml FROM triggers WHERE xml LIKE '%597%' OR xml LIKE '%CNCToSegregateParts%' ORDER BY project, name"
    W "  $($rows.Count) trigger(s)"
    foreach ($r in $rows) {
        W "  -- [$($r[0])] $($r[1])  state $($r[2])"
        $x = [string]$r[3]
        # the lines that name the variable, with some context
        foreach ($hit in [regex]::Matches($x, '.{0,300}(597|CNCToSegregateParts).{0,300}')) { W ("     " + ($hit.Value -replace '\s+', ' ')) }
    }
} catch { W "  failed: $($_.Exception.Message)" }

# -- 2. OPC UA address space ------------------------------------------------------------------------------
W ''; W '== deviceWise OPC UA address space (Objects, 2 levels) =='
$session = $null
try {
    $session = Open-DwUaSession -Manifest $m
    $browser = New-Object Opc.Ua.Client.Browser($session)
    $browser.BrowseDirection = [Opc.Ua.BrowseDirection]::Forward
    $browser.ReferenceTypeId = [Opc.Ua.ReferenceTypeIds]::HierarchicalReferences
    $browser.IncludeSubtypes = $true
    foreach ($ref in $browser.Browse([Opc.Ua.ObjectIds]::ObjectsFolder)) {
        W "  $($ref.DisplayName)   [$($ref.NodeId)]  $($ref.NodeClass)"
        if ("$($ref.DisplayName)" -match '^CNC\d|Device|Gateway') {
            $id = [Opc.Ua.ExpandedNodeId]::ToNodeId($ref.NodeId, $session.NamespaceUris)
            $kids = @($browser.Browse($id))
            foreach ($k in ($kids | Select-Object -First 40)) { W "      $($k.DisplayName)   [$($k.NodeId)]  $($k.NodeClass)" }
            if ($kids.Count -gt 40) { W "      ... $($kids.Count) in all" }
        }
    }
} catch { W "  failed: $($_.Exception.Message)" }

# -- 2b. the server's methods (m:Methods) and their arguments ---------------------------------------------
W ''; W '== deviceWise OPC UA methods (m:Methods) =='
if ($session) {
    try {
        $mb = New-Object Opc.Ua.Client.Browser($session)
        $mb.BrowseDirection = [Opc.Ua.BrowseDirection]::Forward
        $mb.ReferenceTypeId = [Opc.Ua.ReferenceTypeIds]::HierarchicalReferences
        $mb.IncludeSubtypes = $true
        $methodsId = Get-DwUaNodeId -Session $session -Namespace $ns -Path 'm:Methods'
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue(@($methodsId, 0))
        while ($queue.Count) {
            $item = $queue.Dequeue(); $id = $item[0]; $depth = $item[1]
            foreach ($r in $mb.Browse($id)) {
                $rid = [Opc.Ua.ExpandedNodeId]::ToNodeId($r.NodeId, $session.NamespaceUris)
                W ("  {0}{1}   [{2}]  {3}" -f ('  ' * $depth), $r.DisplayName, $r.NodeId, $r.NodeClass)
                if ("$($r.NodeClass)" -eq 'Method') {
                    # InputArguments / OutputArguments are properties of the method node
                    $pb = New-Object Opc.Ua.Client.Browser($session)
                    $pb.ReferenceTypeId = [Opc.Ua.ReferenceTypeIds]::HasProperty
                    foreach ($pr in $pb.Browse($rid)) {
                        $pid2 = [Opc.Ua.ExpandedNodeId]::ToNodeId($pr.NodeId, $session.NamespaceUris)
                        $val = $session.ReadValue($pid2).Value
                        $args2 = @(foreach ($a in @($val)) {
                            $ext = if ($a -is [Opc.Ua.ExtensionObject]) { $a.Body } else { $a }
                            if ($ext -is [Opc.Ua.Argument]) {
                                $t = try { [Opc.Ua.TypeInfo]::GetBuiltInType($ext.DataType) } catch { $ext.DataType }
                                "$($ext.Name):$t$(if ($ext.ValueRank -ge 0) { '[]' })$(if ($ext.Description.Text) { " ($($ext.Description.Text))" })"
                            } else { "$ext" }
                        })
                        W ("  {0}    {1}: {2}" -f ('  ' * $depth), $pr.DisplayName, ($args2 -join ', '))
                    }
                } elseif ($depth -lt 3) { $queue.Enqueue(@($rid, $depth + 1)) }
            }
        }
    } catch { W "  failed: $($_.Exception.Message)" }
}

# -- 3. candidate nodes -----------------------------------------------------------------------------------
W ''; W "== Reads (CNC$Cnc) =="
if ($session) {
    foreach ($p in "CNC${Cnc}_PATH.2_597", "CNC${Cnc}_PATH.1_597", "CNC${Cnc}_PATH.2_599", "CNC$Cnc.Control.CNCToSegregateParts", "CNC$Cnc.CNCAsset") {
        try {
            $v = Get-DwUaValue -Session $session -Namespace $ns -Path $p
            W ("  {0,-40} value '{1}'  status {2}  source time {3}" -f $p, $v.Value, $v.StatusCode, $v.SourceTimestamp)
        } catch { W ("  {0,-40} FAILED: {1}" -f $p, $_.Exception.Message) }
    }
    try { [void]$session.Close() } catch { }
}

# -- 4. deviceWise listening ports (is there a local gateway API besides OPC UA?) -----------------------
W ''; W '== deviceWise processes and their listening ports =='
$dwProcs = @(Get-Process -Name 'dwcore', 'dwts', 'dwhttp*', 'dw*' -ErrorAction SilentlyContinue | Sort-Object Id -Unique)
foreach ($p in $dwProcs) {
    $ports = @(netstat -ano -p TCP | Where-Object { $_ -match 'LISTENING' -and ($_.Trim() -split '\s+')[-1] -eq "$($p.Id)" } | ForEach-Object { ($_.Trim() -split '\s+')[1] })
    W ("  {0,-12} PID {1,-6} listening: {2}" -f $p.ProcessName, $p.Id, ($ports -join ', '))
}
$props = Get-ChildItem ([string]$m.DeviceWise.GatewayInstallDir) -Filter '*.properties' -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 10
foreach ($f in $props) {
    W "  -- $($f.FullName)"
    Get-Content $f.FullName -ErrorAction SilentlyContinue | Where-Object { $_ -match 'port|http|api|rest' -and $_ -notmatch 'password' } | Select-Object -First 15 | ForEach-Object { W "     $_" }
}

$lines | Set-Content -Path $out
W ''; W "Written: $out"
