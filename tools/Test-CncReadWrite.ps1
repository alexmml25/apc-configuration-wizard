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
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Test-CncReadWrite.ps1 -Write -TagId 2_597 -TagName 2_597
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
function Read-Tag([string]$Id, [string]$Nm) {
    $r = Invoke-Method '6_CNC_DemandReadTagInteger' @([string]$device, [string]$Id, [string]$Nm)
    if (-not $r.Ok) { return "call failed: $($r.Error)" }
    "ERROR_CODE=$($r.Out[0]) ERROR_MESSAGE='$($r.Out[1])' TagValue=$($r.Out[2])"
}

W ''; W "== Read $device $Tag (6_CNC_DemandReadTagInteger) =="
$combos = New-Object System.Collections.Generic.List[object]    # (an if-expression would unroll the pairs)
if ($TagId -or $TagName) { $combos.Add(@($TagId, $TagName)) } else { $combos.Add(@($Tag, $Tag)); $combos.Add(@($Tag, '')); $combos.Add(@('', $Tag)) }
foreach ($c in $combos) { W ("  TagID='{0}' TagName='{1}'  -> {2}" -f $c[0], $c[1], (Read-Tag $c[0] $c[1])) }

if ($Write) {
    $id = if ($TagId) { $TagId } else { $Tag }; $nm = if ($PSBoundParameters.ContainsKey('TagName')) { $TagName } else { $Tag }
    W ''; W "== Write $device $Tag (7_CNC_DemandWriteTagInteger), TagID='$id' TagName='$nm' =="
    W "  before: $(Read-Tag $id $nm)"
    foreach ($v in 10, 0) {
        $r = Invoke-Method '7_CNC_DemandWriteTagInteger' @([string]$device, [string]$id, [string]$nm, [long]$v)
        W "  write $v -> $(if ($r.Ok) { "ERROR_CODE=$($r.Out[0]) ERROR_MESSAGE='$($r.Out[1])'" } else { "call failed: $($r.Error)" })"
        Start-Sleep -Seconds 2
        W "  read back: $(Read-Tag $id $nm)"
    }
}
try { [void]$session.Close() } catch { }

$lines | Set-Content -Path $out
W ''; W "Written: $out"
