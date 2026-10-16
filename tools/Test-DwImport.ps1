#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    TEST VM ONLY. Imports a deviceWISE backup/export file through the gateway's import folder.
.DESCRIPTION
    Proves the route for the wizard: the gateway imports any "valid deviceWISE export or back-up
    file" placed at  Gateway\staging\system\import\import.dwx  when it restarts, writes the
    outcome to import.result (the readme says import.results) in the same folder and deletes import.dwx
    (Telit's import.readme.txt, installed with Gateway 23.04.08).
    This matches the SOP restore (D01555607 section 4.2, Workbench > Project > Restore), without Workbench.

    Steps:
      1. stops dwcore only (dwts has no dependency on it and must be running, or every
         transport and transaction fails with -4999 - first test, 2026-10-08),
      2. copies the gateway config DBs (DWCORE, DWAPP, DWUSER, DWTS) to a safety backup folder,
      3. copies the given file to import\import.dwx (with -Only: just those item types),
      4. starts dwcore and waits for import.result,
      5. prints import.result.
    Status 0 = imported. -1 on Certificates / Connections Log / Sessions is expected (runtime lists).
    This CHANGES the gateway configuration. To undo, stop dwcore and dwts, copy the DBs from the
    safety backup back into Gateway\db and start the services again.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Test-DwImport.ps1 -File 'C:\Temp\CHMI_backup.dbk'
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Test-DwImport.ps1 -File 'C:\Temp\CHMI_backup.dbk' -Only transport,transaction
.EXAMPLE
    # fresh gateway: keep the licence server setting (license.pool, voucher removed automatically),
    # leave out the licence status items (source VM's hardware id) and the runtime lists
    powershell -ExecutionPolicy Bypass -File .\tools\Test-DwImport.ps1 -File 'C:\Temp\CHMI_backup.dbk' -Exclude 'license,License Server,License Client,Certificates,Connections Log,Sessions'
#>
param(
    [Parameter(Mandatory)][string]$File,
    [string[]]$Only,                     # import just these <exportcontent type="..."> items
    [string[]]$Exclude,                  # import everything except these types
    [string]$GatewayRoot = 'C:\Program Files\deviceWISE\Gateway',
    [string]$BackupRoot  = "$(if (@([IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -eq 'D:\' -and $_.DriveType -eq 'Fixed' -and $_.IsReady }).Count) { 'D:' } else { 'C:' })\APC_Config\Backups",
    [int]$TimeoutSec     = 300
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $File)) { throw "File not found: $File" }
$importDir = Join-Path $GatewayRoot 'staging\system\import'
$dbDir     = Join-Path $GatewayRoot 'db'
$results   = Join-Path $importDir 'import.result'    # the readme says import.results; 23.04.08 writes import.result
$target    = Join-Path $importDir 'import.dwx'
if (-not (Test-Path $importDir)) { throw "Import folder not found: $importDir" }
if (Test-Path $target) { throw "An import.dwx is already waiting in $importDir; remove it first." }

# With -Only / -Exclude, build a smaller export with just those item types (file order kept)
$source = $File
# powershell -File passes "transport,transaction" as one string, so split it here
$Only    = @($Only    | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Exclude = @($Exclude | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
# The licence voucher is the lease the licence server gave the source VM (with a secret);
# a new gateway must get its own, so it is always removed. The server address/port stay.
$xml = New-Object Xml.XmlDocument
$xml.PreserveWhitespace = $true
$xml.Load($File)
$vouchers = @($xml.SelectNodes("//exportcontent[@type='license.pool']//PersistenceEntry[@name='voucher']"))
foreach ($v in $vouchers) { [void]$v.ParentNode.RemoveChild($v) }
if ($vouchers.Count) { Write-Host "Removed the source VM's licence voucher." }
if ($Only -or $Exclude -or $vouchers.Count) {
    $kept = 0
    foreach ($ec in @($xml.DocumentElement.SelectNodes('exportcontent'))) {
        $type = $ec.GetAttribute('type')
        $keep = (-not $Only -or $Only -contains $type) -and ($Exclude -notcontains $type)
        if ($keep) { $kept++ } else { [void]$xml.DocumentElement.RemoveChild($ec) }
    }
    if (-not $kept) { throw "No items left in $File (only: $($Only -join ', '); exclude: $($Exclude -join ', '))" }
    $source = Join-Path $env:TEMP ("dw-import-subset-{0}.dwx" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $w = New-Object IO.StreamWriter($source, $false, (New-Object Text.UTF8Encoding($false)))
    try { $xml.Save($w) } finally { $w.Close() }
    Write-Host ("Subset: $kept item(s)" + $(if ($Only) { "; only: $($Only -join ', ')" }) + $(if ($Exclude) { "; excluded: $($Exclude -join ', ')" }))
}

Write-Host "Gateway: $GatewayRoot`nImport:  $File ($((Get-Item $File).Length) bytes)" -ForegroundColor Cyan
Write-Host 'This stops deviceWISE and imports the file into the gateway. TEST VM ONLY.' -ForegroundColor Yellow
if ((Read-Host 'Type IMPORT to continue') -ne 'IMPORT') { Write-Host 'Cancelled.'; return }

$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$safety = Join-Path $BackupRoot "$ts\deviceWise-before-import"
New-Item -ItemType Directory -Path $safety -Force | Out-Null

# 1. Stop dwcore only; dwts keeps running so transports and transactions can be imported
if ((Get-Service 'dwts').Status -ne 'Running') { Write-Host 'Starting dwts ...'; Start-Service 'dwts' }
Write-Host 'Stopping dwcore ...'
Stop-Service 'dwcore' -Force
(Get-Service 'dwcore').WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))

try {
    # 2. Safety copy of the configuration databases (logs/reports skipped)
    foreach ($db in 'DWCORE.db', 'DWAPP.db', 'DWUSER.db', 'DWTS.db') {
        $src = Join-Path $dbDir $db
        if (Test-Path $src) { Copy-Item $src $safety; Write-Host "  saved $db" }
    }
    Write-Host "Safety backup: $safety"

    # 3. Queue the import
    foreach ($old in $results, "${results}s") { if (Test-Path $old) { Move-Item $old (Join-Path $safety ((Split-Path $old -Leaf) + '.previous')) } }
    Copy-Item $source $target
    Write-Host "Queued: $target"
} finally {
    # 4. Start again whatever happened above
    Write-Host 'Starting dwcore (the import runs during startup and can take minutes) ...'
    Start-Service 'dwcore' -WarningAction SilentlyContinue
}

$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline -and -not ((Test-Path $results) -and -not (Test-Path $target))) { Start-Sleep -Seconds 3 }

# 5. Outcome
if (Test-Path $results) {
    Write-Host "`r`n===== import.result =====" -ForegroundColor Cyan
    Get-Content $results | ForEach-Object { Write-Host $_ }
    Copy-Item $results $safety
} else {
    Write-Host "No import.result after $TimeoutSec s." -ForegroundColor Red
}
Write-Host ("import.dwx still present: {0}" -f (Test-Path $target))
Write-Host "Safety backup and results: $safety"
