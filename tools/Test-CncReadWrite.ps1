#Requires -Version 5.1
<#
.SYNOPSIS
    CNCnetPDM read / write through deviceWise, the CHMI route: the OPC UA methods the CHMI project publishes,
    6_CNC_DemandReadTagInteger (DeviceName, TagID, TagName -> TagValue) and 7_CNC_DemandWriteTagInteger
    (DeviceName, TagID, TagName, TagValue). They reach the CNCn_PATH devices, which are not exposed over OPC UA.
.DESCRIPTION
    Default (read-only):
      - prints how both triggers use their inputs (DWCORE.db trigger XML; full XML saved next to the report)
      - reads CNC<n>_PATH 2_597 with a few TagID / TagName combinations
    -Write: on CNC<n>_PATH 2_597 (#597 CNCToSegregateParts) writes 10, reads it back, writes 0, reads it back.
      10 means nothing to the CNC logic (user, 2026-10-15); 0 is the idle value.
    Report: C:\APC_Config\Logs\cnc-readwrite-test_<ts>.txt. 64-bit PowerShell, service account.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Test-CncReadWrite.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Test-CncReadWrite.ps1 -Write
#>
param(
    [string]$ManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'APC_ConfigManifest.json'),
    [string]$OutDir = 'C:\APC_Config\Logs',
    [int]$Cnc = 1,
    [string]$Tag = '2_597',
    [string]$TagId,
    [string]$TagName,
    [switch]$Write
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$m    = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$ts    = Get-Date -Format 'yyyyMMdd_HHmmss'
$out   = Join-Path $OutDir "cnc-readwrite-test_$ts.txt"
$lines = [System.Collections.Generic.List[string]]::new()
function W([string]$Text = '') { $lines.Add($Text); Write-Host $Text }
function Write-Log { param($Level, $Message) }       # DeviceWise.ps1 helpers log through the wizard
. (Join-Path $root 'modules\DeviceWise.ps1')

$device = "CNC${Cnc}_PATH"
W "CNC read/write test  $(Get-Date -Format s)  on $env:COMPUTERNAME as $env:USERDOMAIN\$env:USERNAME   $device $Tag   mode: $(if ($Write) { 'WRITE 10 then 0' } else { 'read-only' })"
$paths = Get-DwPaths -Manifest $m
$ns    = $m.DeviceWise.OpcUaClient.Namespace

# -- 1. how the triggers use their inputs ----------------------------------------------------------------
W ''; W '== CHMI triggers behind the methods =='
foreach ($t in '6_CNC_DemandReadTagInteger', '7_CNC_DemandWriteTagInteger') {
    try {
        $x = Get-DwXml -Paths $paths -Table triggers -Name $t -Project 'CHMI'
        if (-not $x) { W "  $t : not found"; continue }
        $file = Join-Path $OutDir "trigger_${t}_$ts.xml"; $x.Save($file)
        W "  -- $t  (full XML: $file)"
        $txt = $x.OuterXml
        foreach ($hit in [regex]::Matches($txt, '<(VariableInfo|LocalVariable|StaticVariable|Property|Node)\b[^>]*>')) {
            $v = $hit.Value
            if ($v -match 'TagID|TagName|DeviceName|TagValue|device|variable|expression|text=') { W "     $v" }
        }
    } catch { W "  $t : failed: $($_.Exception.Message)" }
}

# -- 2. method calls ------------------------------------------------------------------------------------
$session = Open-DwUaSession -Manifest $m
$obj = Get-DwUaNodeId -Session $session -Namespace $ns -Path 'p:CHMI'
function Invoke-Method([string]$Name, [object[]]$InArgs) {
    $mid = Get-DwUaNodeId -Session $session -Namespace $ns -Path "t:CHMI.$Name"
    try {
        $res = @($session.Call($obj, $mid, $InArgs))
        return @{ Ok = $true; Out = $res }
    } catch { return @{ Ok = $false; Error = $_.Exception.InnerException.Message + $_.Exception.Message } }
}
function Read-Tag([string]$Id, [string]$Nm, [string]$Method = '6_CNC_DemandReadTagValue') {
    # 6_CNC_DemandReadTagValue returns a Double (the CNC offsets are FLOAT8), 6_CNC_DemandReadTagInteger an Int64
    $r = Invoke-Method $Method @([string]$device, [string]$Id, [string]$Nm)
    if (-not $r.Ok) { return "call failed: $($r.Error)" }
    "ERROR_CODE=$($r.Out[0]) ERROR_MESSAGE='$($r.Out[1])' TagValue=$($r.Out[2])"
}

W ''; W "== Reads on $device (TagID = TagName = tag) =="
foreach ($t in @('STATN', '1_597', $Tag) | Select-Object -Unique) {
    foreach ($meth in '6_CNC_DemandReadTagValue', '6_CNC_DemandReadTagInteger') {
        W ("  {0,-8} {1,-28} -> {2}" -f $t, $meth, (Read-Tag $t $t $meth))
    }
}
W ''; W "== Read $device $Tag, TagID / TagName combinations (6_CNC_DemandReadTagValue) =="
$combos = New-Object System.Collections.Generic.List[object]    # (an if-expression would unroll the pairs)
if ($TagId -or $TagName) { $combos.Add(@($TagId, $TagName)) } else { $combos.Add(@($Tag, $Tag)); $combos.Add(@($Tag, '')); $combos.Add(@('', $Tag)) }
foreach ($c in $combos) { W ("  TagID='{0}' TagName='{1}'  -> {2}" -f $c[0], $c[1], (Read-Tag $c[0] $c[1])) }

if ($Write) {
    # 7_CNC_DemandWriteTagValue / 6_CNC_DemandReadTagValue (Invoke-DwCncTag): the offsets are FLOAT8
    W ''; W "== Write $device ${Tag}: 10, then 0 (7_CNC_DemandWriteTagValue, read back with 6_CNC_DemandReadTagValue) =="
    $r = Invoke-DwCncTag -Session $session -Namespace $ns -Device $device -Tag $Tag
    W "  before: $(if ($r.Ok) { $r.Value } else { $r.Error })"
    foreach ($v in 10, 0) {
        $w = Invoke-DwCncTag -Session $session -Namespace $ns -Device $device -Tag $Tag -WriteValue "$v"
        W "  write $v -> $(if ($w.Ok) { 'OK' } else { $w.Error })"
        Start-Sleep -Seconds 2
        $r = Invoke-DwCncTag -Session $session -Namespace $ns -Device $device -Tag $Tag
        W "  read back: $(if ($r.Ok) { $r.Value } else { $r.Error })$(if ($r.Ok -and [double]$r.Value -eq $v) { '  (matches)' } elseif ($r.Ok) { '  (DIFFERENT)' })"
    }
}
try { [void]$session.Close() } catch { }

$lines | Set-Content -Path $out
W ''; W "Written: $out"
