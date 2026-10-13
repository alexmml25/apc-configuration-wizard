#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    TEST VM ONLY. Installs deviceWISE packages (.pkg) through the gateway's import folder.
.DESCRIPTION
    Telit's import.readme.txt (Gateway 23.04.08): "Place a valid deviceWISE package or SUP file
    in this directory and it will be processed and installed on deviceWISE restart. The filename
    must be: package.sup". The outcome goes to package.results (the import side writes
    import.result, so both spellings are checked) and package.sup is deleted afterwards.
    This replaces the SOP step (D01555607 2.1.1, Administration > Packages > add).

    One package per dwcore restart, in the SOP order. dwts keeps running.
    Packages come from the APC repository share by default:
      <RepositoryRoot>\APC VM Software Components\deviceWise\3-Packages
    Already installed packages (Gateway\dwcore\packages\<name>.xml) are skipped.
    This CHANGES the gateway.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Test-DwPackage.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Test-DwPackage.ps1 -PackageDir D:\APC_Config\packages
#>
param(
    [string]$PackageDir  = '\\MSPM7AAPPS0342.cfrf.medtronic.com\Shared\APC\Deployment Resources\APC VM Software Components\deviceWise\3-Packages',
    # SOP order: OPC UA Server, OPC UA Client Driver, FileWatcher, CNCnetPDM
    [string[]]$Order     = @('dwopcua_server_v3', 'dwopcua', 'dwfilewatcher', 'dwcncnetpdm'),
    [string]$GatewayRoot = 'C:\Program Files\deviceWISE\Gateway',
    [int]$TimeoutSec     = 600
)

$ErrorActionPreference = 'Stop'
$importDir = Join-Path $GatewayRoot 'staging\system\import'
$pkgDir    = Join-Path $GatewayRoot 'dwcore\packages'
$target    = Join-Path $importDir 'package.sup'
$results   = @((Join-Path $importDir 'package.results'), (Join-Path $importDir 'package.result'))
if (-not (Test-Path $importDir)) { throw "Import folder not found: $importDir" }
if (-not (Test-Path $PackageDir)) { throw "Package folder not found: $PackageDir" }
if (Test-Path $target) { throw "A package.sup is already waiting in $importDir; remove it first." }

# File names look like dw.<name>.Windows-x64.<version>.pkg
$files = Get-ChildItem $PackageDir -Filter '*.pkg' -File
$plan = foreach ($name in $Order) {
    $f = $files | Where-Object { $_.Name -like "dw.$name.Windows-x64.*" } | Sort-Object Name | Select-Object -Last 1
    if (-not $f) { throw "No package dw.$name.Windows-x64.*.pkg in $PackageDir" }
    $installed = Test-Path (Join-Path $pkgDir "$name.xml")
    [pscustomobject]@{ Name = $name; File = $f; Installed = $installed }
}

Write-Host "Gateway:  $GatewayRoot`nPackages: $PackageDir" -ForegroundColor Cyan
$plan | ForEach-Object { Write-Host ("  {0,-18} {1,-55} {2}" -f $_.Name, $_.File.Name, $(if ($_.Installed) { 'already installed - skip' } else { 'install' })) }
$todo = @($plan | Where-Object { -not $_.Installed })
if (-not $todo) { Write-Host 'Nothing to install.'; return }
Write-Host 'This restarts deviceWISE Core once per package. TEST VM ONLY.' -ForegroundColor Yellow
if ((Read-Host 'Type INSTALL to continue') -ne 'INSTALL') { Write-Host 'Cancelled.'; return }

if ((Get-Service 'dwts').Status -ne 'Running') { Write-Host 'Starting dwts ...'; Start-Service 'dwts' }

foreach ($p in $todo) {
    Write-Host "`r`n===== $($p.Name): $($p.File.Name) =====" -ForegroundColor Cyan
    foreach ($r in $results) { if (Test-Path $r) { Remove-Item $r } }

    Write-Host 'Stopping dwcore ...'
    Stop-Service 'dwcore' -Force -WarningAction SilentlyContinue
    (Get-Service 'dwcore').WaitForStatus('Stopped', [TimeSpan]::FromSeconds(120))
    try {
        Copy-Item $p.File.FullName $target
    } finally {
        Write-Host 'Starting dwcore (installs the package during startup) ...'
        Start-Service 'dwcore' -WarningAction SilentlyContinue
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $done = $null
    while ((Get-Date) -lt $deadline -and -not $done) {
        Start-Sleep -Seconds 3
        if (-not (Test-Path $target)) { $done = $results | Where-Object { Test-Path $_ } | Select-Object -First 1 }
    }
    if ($done) {
        Get-Content $done | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Host "  No package result after $TimeoutSec s (package.sup still present: $(Test-Path $target))." -ForegroundColor Red
        break
    }
    Write-Host ("  {0}.xml now in dwcore\packages: {1}" -f $p.Name, (Test-Path (Join-Path $pkgDir "$($p.Name).xml")))
}

Write-Host "`r`nInstalled packages:"
Get-ChildItem $pkgDir -Filter '*.xml' | ForEach-Object { Write-Host "  $($_.BaseName)" }
