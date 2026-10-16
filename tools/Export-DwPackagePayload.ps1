#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only: collects the files of installed deviceWISE packages into a folder for the wizard.
.DESCRIPTION
    The approved .pkg files are encrypted; the gateway rejects them from the import folder
    ("Failed to decrypt file", -7018 - fresh VM test 2026-10-13). Each installed package leaves its
    own install instructions in Gateway\dwcore\packages\<key>.xml, e.g. OPC UA Server V3:
        <Install><StopRuntime/>
          <AddFile from="dwopcua_server_v3.dll" to="plugins/dwopcua_server_v3.dll"/>
          <AddFile from="uastack.dll" to="uastack.dll"/><StartRuntime/></Install>
    This copies, for each package, that XML and every installed file (the AddFile 'to' path,
    relative to dwcore; AddStagingFile relative to staging) into <OutDir>\<key>\ under its
    'from' name, and writes SHA256SUMS.txt. Step 4 installs from that folder by following
    the same instructions. Run it on a gateway where the packages were installed through Workbench.
    Nothing on the gateway is changed.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Export-DwPackagePayload.ps1 -OutDir D:\APC_Config\Packages
#>
param(
    [string]$OutDir      = "$(if (@([IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -eq 'D:\' -and $_.DriveType -eq 'Fixed' -and $_.IsReady }).Count) { 'D:' } else { 'C:' })\APC_Config\Packages",
    [string[]]$Keys      = @('dwopcua_server_v3', 'dwopcua', 'dwfilewatcher', 'dwcncnetpdm'),
    [string]$GatewayRoot = 'C:\Program Files\deviceWISE\Gateway'
)

$ErrorActionPreference = 'Stop'
$Keys    = @($Keys | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$dwcore  = Join-Path $GatewayRoot 'dwcore'
$staging = Join-Path $GatewayRoot 'staging'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$sums = New-Object System.Collections.Generic.List[string]
$problems = 0

foreach ($key in $Keys) {
    $xmlPath = Join-Path $dwcore "packages\$key.xml"
    if (-not (Test-Path $xmlPath)) { Write-Host "[$key] not installed on this gateway" -ForegroundColor Red; $problems++; continue }
    [xml]$pkg = Get-Content $xmlPath -Raw
    $p = $pkg.DWPackage
    Write-Host ("[{0}] {1} {2} (dW {3}, build {4})" -f $key, $p.GetAttribute('name'), $p.GetAttribute('version'), $p.GetAttribute('dwversion'), $p.GetAttribute('build')) -ForegroundColor Cyan
    $dest = Join-Path $OutDir $key
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item $xmlPath (Join-Path $dest "$key.xml") -Force
    $sums.Add(("{0}  {1}" -f (Get-FileHash (Join-Path $dest "$key.xml") -Algorithm SHA256).Hash, "$key/$key.xml"))

    foreach ($a in @($p.SelectNodes('Install/*'))) {
        switch ($a.LocalName) {
            { $_ -in 'StopRuntime', 'StartRuntime' } { Write-Host "  $_"; continue }
            { $_ -in 'AddFile', 'AddStagingFile' } {
                $base = if ($a.LocalName -eq 'AddFile') { $dwcore } else { $staging }
                $src  = Join-Path $base ($a.GetAttribute('to') -replace '/', '\')
                if (-not (Test-Path $src)) { Write-Host "  $($a.LocalName) $($a.GetAttribute('to')): MISSING on this gateway" -ForegroundColor Red; $problems++; continue }
                $out = Join-Path $dest ($a.GetAttribute('from') -replace '/', '\')
                New-Item -ItemType Directory -Path (Split-Path $out) -Force | Out-Null
                Copy-Item $src $out -Force
                $sums.Add(("{0}  {1}" -f (Get-FileHash $out -Algorithm SHA256).Hash, "$key/$($a.GetAttribute('from'))"))
                Write-Host ("  {0} {1} -> {2} ({3:N0} bytes)" -f $a.LocalName, $a.GetAttribute('from'), $a.GetAttribute('to'), (Get-Item $out).Length)
            }
            default { Write-Host "  UNSUPPORTED action <$($a.LocalName)> - tell the wizard developer" -ForegroundColor Red; $problems++ }
        }
    }
}

$sums | Set-Content (Join-Path $OutDir 'SHA256SUMS.txt') -Encoding ASCII
Write-Host "`r`nSaved to $OutDir (SHA256SUMS.txt included). Problems: $problems" -ForegroundColor $(if ($problems) { 'Red' } else { 'Green' })
Write-Host 'Copy the whole folder to <RepositoryRoot>\APC VM Software Components\deviceWise\5-Automation\Packages'
