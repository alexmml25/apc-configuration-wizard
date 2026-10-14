#Requires -Version 5.1
<#
.SYNOPSIS
    Writes CNCn.CNCAsset / CNCType through the gateway's OPC UA server and reads them back -
    the same code Step 4 runs (modules\DeviceWise.ps1), without the rest of Step 4.
.DESCRIPTION
    Anonymous, security None, OPC Foundation stack from 800xA (copied to C:\APC_Config\OpcUaStack).
    -ReadOnly only reads. The values are lost at the next dwcore restart (known limitation).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Test-DwCncAsset.ps1 -Cnc "Citizen 01|CITIZEN_L20X_IV,Citizen 03|CITIZEN_L20X_IV,Citizen 08|CITIZEN_L20X_IV"
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Test-DwCncAsset.ps1 -ReadOnly
#>
param(
    # 'Machine name|CNC type' per CNC, in CNC1..CNC3 order
    [string[]]$Cnc,
    [switch]$ReadOnly
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function Write-Log { param($Level, $Message) Write-Host "[$Level] $Message" }
. (Join-Path $root 'modules\DeviceWise.ps1')
$manifest = Get-Content (Join-Path $root 'APC_ConfigManifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$ns = $manifest.DeviceWise.OpcUaClient.Namespace

$Cnc = @($Cnc | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $ReadOnly -and -not $Cnc) { throw "Give -Cnc 'name|type',... or -ReadOnly" }
$wanted = [ordered]@{}
for ($i = 0; $i -lt $Cnc.Count; $i++) {
    $p = $Cnc[$i] -split '\|'
    $wanted["CNC$($i + 1).CNCAsset"] = $p[0].Trim()
    $wanted["CNC$($i + 1).CNCType"]  = $p[1].Trim()
}

$session = Open-DwUaSession -Manifest $manifest
try {
    Write-Host "Connected to $($manifest.DeviceWise.OpcUaClient.Endpoint) (stack copy: C:\APC_Config\OpcUaStack)"
    if (-not $ReadOnly) {
        $res = Set-DwUaValues -Session $session -Namespace $ns -Values $wanted
        foreach ($k in $res.Keys) { Write-Host ("write {0,-16} = {1,-20} -> {2}" -f $k, $wanted[$k], $res[$k]) }
    }
    $paths = if ($wanted.Count) { @($wanted.Keys) } else { 1..3 | ForEach-Object { "CNC$_.CNCAsset", "CNC$_.CNCType" } }
    foreach ($k in $paths) {
        $v = Get-DwUaValue -Session $session -Namespace $ns -Path $k
        Write-Host ("read  {0,-16} = '{1}' ({2})" -f $k, $v.Value, $v.StatusCode)
    }
} finally { [void]$session.Close() }
