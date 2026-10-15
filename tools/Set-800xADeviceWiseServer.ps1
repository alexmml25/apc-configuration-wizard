#Requires -Version 5.1
<#
.SYNOPSIS
    Points 800xA's external OPC UA server "DEVICEWISE OPC UA" at this VM's deviceWise gateway (Step 11, SOP
    "OPC UA Server Info" aspect: General > Server URL), and sets up the OPC UA trust between them.
.DESCRIPTION
    VMs copied from another machine keep that machine's URL (SJUM7AAPPS0048 had opc.tcp://SJUM7AAPPS0065:48020,
    2026-10-15), so 800xA read the other machine's gateway. With the UA Management Portal's own functions
    (32-bit; the script restarts itself in 32-bit PowerShell if needed):
      1. the server's OPC UA Server Info aspect: ServerURL -> -ServerUrl (default opc.tcp://<this VM>:48020,
         the endpoint Step 4 sets) - IUAServerInfoAspectOperation.GetData / SetData
      2. the server certificate 800xA trusts for it -> this gateway's certificate (staging\uaserver\pkiserver\own)
         - BackEnd800xA.UpdateApplicationCertificateAspect, as the portal does
      3. file trust both ways: the gateway certificate into OPC UA Connect's pki\trusted, and OPC UA Connect's
         certificate (LocalMachine\My) into the gateway's pkiserver\trusted (out of rejected)
    Backup first (old URL and certificate, C:\APC_Config\Backups\<ts>_800xA-dwserver). Without -Confirmed it only
    backs up and reports. OPC UA Connect reads the new URL when it restarts (Step 11's service reset).
    Exit codes: 0 done (or already right), 10 report only, 1 ABB assemblies not loaded, 2 cannot connect to 800xA,
    3 not administrator, 4 failed, 6 server or gateway certificate not found.
    Output: C:\APC_Config\Logs\chmi-dwserver_<ts>.txt
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Set-800xADeviceWiseServer.ps1              # report only
    powershell -ExecutionPolicy Bypass -File .\tools\Set-800xADeviceWiseServer.ps1 -Confirmed
#>
param(
    [switch]$Confirmed,
    [switch]$CheckOnly,              # Step 13: report URL, certificate and upload placements; no backup, exit 0 when all right
    [string]$ServerName = 'DEVICEWISE OPC UA',
    [string]$ServerUrl  = '',
    [string]$GatewayDir = 'C:\Program Files\deviceWISE\Gateway',
    [string]$BinDir  = 'C:\Program Files (x86)\ABB 800xA\Base\bin',
    [string]$PkiRoot = 'C:\ProgramData\ABB\Process Portal A',
    [string]$OutDir  = 'C:\APC_Config\Logs',
    [string]$BackupRoot = 'C:\APC_Config\Backups'
)
if (-not $ServerUrl) { $ServerUrl = "opc.tcp://$($env:COMPUTERNAME):48020" }

if ([Environment]::Is64BitProcess -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $ps32 = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    $argz = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-ServerName', $ServerName,
              '-ServerUrl', $ServerUrl, '-GatewayDir', $GatewayDir, '-BinDir', $BinDir, '-PkiRoot', $PkiRoot,
              '-OutDir', $OutDir, '-BackupRoot', $BackupRoot)
    if ($Confirmed) { $argz += '-Confirmed' }
    if ($CheckOnly) { $argz += '-CheckOnly' }
    & $ps32 @argz
    exit $LASTEXITCODE
}

$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$outFile = Join-Path $OutDir "chmi-dwserver_$ts.txt"
$report  = New-Object System.Collections.Generic.List[string]
function Say([string]$Text) { $report.Add($Text); Write-Host $Text }
function Fail([string]$What, $Err) {
    $e = if ($Err -is [System.Management.Automation.ErrorRecord]) { $Err.Exception } else { $Err }
    Say "  ERROR in ${What}: $($e.GetType().FullName): $($e.Message)"
    while ($e.InnerException) { $e = $e.InnerException; Say "    inner: $($e.GetType().FullName): $($e.Message)" }
}
function Finish([int]$Code) { $report | Out-File -FilePath $outFile -Width 300 -Encoding UTF8; "Written: $outFile"; exit $Code }
$X509 = 'System.Security.Cryptography.X509Certificates.X509Certificate2'
function Load-Cert([string]$Path) { try { New-Object $X509 $Path } catch { $null } }

Say "800xA deviceWise OPC UA server - $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - user $env:USERDOMAIN\$env:USERNAME"
Say "Mode: $(if ($Confirmed) { 'CHANGE (confirmed)' } else { 'backup + report only (no -Confirmed)' })   server '$ServerName' -> $ServerUrl"
Say ''
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Say 'ERROR: run as administrator.'; Finish 3 }

$onResolve = [System.ResolveEventHandler] {
    param($sender, $e)
    $name = (New-Object System.Reflection.AssemblyName $e.Name).Name
    foreach ($ext in '.dll', '.exe') {
        $p = Join-Path $BinDir ($name + $ext)
        if (Test-Path -LiteralPath $p) { return [System.Reflection.Assembly]::LoadFrom($p) }
    }
    return $null
}
[System.AppDomain]::CurrentDomain.add_AssemblyResolve($onResolve)
try {
    Add-Type -AssemblyName PresentationFramework
    foreach ($f in 'Opc.Ua.Core.dll', 'ABB.xA.Base.dll', 'ABB.xA.Base.Ua.Common.dll', 'ABB.xA.Base.Ua.AspectSystem.Configuration.dll', 'ABB.xA.Base.Ua.ManagementPortal.exe') {
        $p = Join-Path $BinDir $f
        if (Test-Path -LiteralPath $p) { [void][System.Reflection.Assembly]::LoadFrom($p) }
    }
} catch { Fail 'loading the ABB assemblies' $_; Finish 1 }

# -- 1. current state -----------------------------------------------------------------------
Say '== 1. Current =='
try {
    if (-not [System.Windows.Application]::Current) { $wpfApp = New-Object System.Windows.Application }
    $backEnd = New-Object ABB.xA.Base.Ua.ManagementPortal.Backend.BackEnd800xA
    $backEnd.Init()
    [ABB.xA.Base.Ua.ManagementPortal.BackEndProvider]::BackEnd = $backEnd
} catch { Fail 'BackEnd800xA.Init (connect to 800xA)' $_; Finish 2 }
$node = @($backEnd.GetApplicationNodeList()) | Where-Object { "$($_.Type)" -eq 'ExternalUaServer' -and $_.Name -eq $ServerName } | Select-Object -First 1
if (-not $node) { Say "  External OPC UA server '$ServerName' not found in 800xA (Node Administration Structure)."; Finish 6 }

$pki    = Join-Path $GatewayDir 'staging\uaserver\pkiserver'
$gwFile = Get-ChildItem -LiteralPath (Join-Path $pki 'own\certs') -Filter '*.der' -File -ErrorAction SilentlyContinue | Select-Object -First 1
$gwCert = if ($gwFile) { Load-Cert $gwFile.FullName } else { $null }
if (-not $gwCert) { Say "  Gateway certificate not found in $pki\own\certs."; Finish 6 }

try {
    $aos  = [ABB.xA.Base.System800xAExtensions]::GetBaseServices([ABB.xA.Base.System800xA]::GetCurrent()).AspectObjectsServices   # extension method: called on its static class
    # ObjectId / AspectCategoryId live in another ABB assembly: take their types from GetAspects(ObjectId, AspectCategoryId)
    $ga = [ABB.xA.Base.IAspectObjectsServices].GetMethods() | Where-Object {
        $_.Name -eq 'GetAspects' -and $_.GetParameters().Count -eq 2 -and $_.GetParameters()[1].ParameterType.Name -eq 'AspectCategoryId' } | Select-Object -First 1
    $oid  = [Activator]::CreateInstance($ga.GetParameters()[0].ParameterType, [object[]]@([string]$node.BackEndSpecificString))
    $cat  = [Activator]::CreateInstance($ga.GetParameters()[1].ParameterType, [object[]]@('{1C564034-1F2E-4708-9951-429549EB7F7C}'))   # OPC UA Server Info
    $aref = $null
    foreach ($a in $ga.Invoke($aos, [object[]]@($oid, $cat))) { $aref = $a; break }
    if ($null -eq $aref) { throw "no OPC UA Server Info aspect on '$ServerName'" }
    $opType = [ABB.xA.Base.Ua.AspectSystem.Configuration.IUAServerInfoAspectOperation]
    $getOp  = [ABB.xA.Base.IAspectObjectsServicesExtensions].GetMethod('GetAspectOperation').MakeGenericMethod($opType)
    $op     = $getOp.Invoke($null, [object[]]@($aos, $aref))
    $data   = $op.GetData()
} catch { Fail 'reading the OPC UA Server Info aspect' $_; Finish 4 }
$oldUrl = [string]$data.ServerURL
Say "  '$ServerName': Server URL $oldUrl   use security: $($data.UseSecurity)"
Say "  certificate 800xA trusts for it: $(if ($node.Certificate) { "$($node.Certificate.Thumbprint) $($node.Certificate.Subject) (to $($node.Certificate.NotAfter.ToString('yyyy-MM-dd')))" } else { '(none)' })"
Say "  this gateway's certificate:      $($gwCert.Thumbprint) $($gwCert.Subject) (to $($gwCert.NotAfter.ToString('yyyy-MM-dd')))"
$uaConnect = $null
$my = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', 'LocalMachine'); $my.Open('ReadOnly')
$uaConnect = @($my.Certificates | Where-Object { $_.Subject -match '^CN=800xAOpcUaConnect(,|$)' } | Sort-Object NotBefore -Descending) | Select-Object -First 1
$my.Close()
Say "  OPC UA Connect certificate:      $(if ($uaConnect) { "$($uaConnect.Thumbprint) (to $($uaConnect.NotAfter.ToString('yyyy-MM-dd')))" } else { 'NOT FOUND in LocalMachine\My' })"
$urlOk  = [string]::Equals($oldUrl, $ServerUrl, [StringComparison]::OrdinalIgnoreCase)
$certOk = $node.Certificate -and $node.Certificate.Thumbprint -eq $gwCert.Thumbprint
# SOP OPC UA Server Info > Placements / Upload: every placement Uploaded (Node Status = Uploaded)
$placements = @($data.UploadPlacements)
foreach ($pl in $placements) { Say "  placement '$($pl.NodeName)'  status $($pl.Status)" }
$notUp = @($placements | Where-Object { "$($_.Status)" -ne 'Uploaded' })
$plOk  = $placements.Count -gt 0 -and -not $notUp
Say ("Upload placements: {0}, {1}" -f $placements.Count, $(if (-not $placements.Count) { 'none - add a placement and Upload to 800xA' } elseif ($notUp) { "not uploaded: $(($notUp | ForEach-Object { "$($_.NodeName) ($($_.Status))" }) -join ', ')" } else { 'all Uploaded' }))
Say ''
if ($CheckOnly) {
    Say "Check: URL $(if ($urlOk) { 'OK' } else { "is $oldUrl, expected $ServerUrl" }); certificate $(if ($certOk) { 'OK' } else { 'not this gateway''s' }); placements $(if ($plOk) { 'OK' } else { 'NOT OK' })"
    Finish $(if ($urlOk -and $certOk -and $plOk) { 0 } else { 1 })
}

# -- backup -----------------------------------------------------------------------------------
$backupDir = Join-Path $BackupRoot "${ts}_800xA-dwserver"
Say "== 2. Backup -> $backupDir =="
try {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    Set-Content -Path (Join-Path $backupDir 'old-serverurl.txt') -Value $oldUrl
    if ($node.Certificate) { [IO.File]::WriteAllBytes((Join-Path $backupDir "old-server-cert-$($node.Certificate.Thumbprint).der"), $node.Certificate.RawData) }
    Set-Content -Path (Join-Path $backupDir 'RESTORE.txt') -Value @(
        "Old Server URL of '$ServerName': $oldUrl (Engineering Workplace > Node Administration Structure > $ServerName > OPC UA Server Info > General)."
        'Old trusted server certificate: old-server-cert-*.der (UA Management Portal: connect to the server and trust it).')
    Say "  saved the old URL and certificate"
} catch { Fail 'backup' $_; Finish 4 }
Say ''

if (-not $Confirmed) {
    Say "No -Confirmed: stopping here. Would $(if ($urlOk) { 'keep the URL' } else { "set the URL to $ServerUrl" }), $(if ($certOk) { 'keep' } else { 'set' }) the trusted server certificate, and set up file trust both ways."
    Finish 10
}

# -- 3. change -----------------------------------------------------------------------------------
Say '== 3. Change =='
$problems = 0
try {
    if (-not $urlOk) {
        $data.ServerURL = $ServerUrl
        $op.SetData($data)
        Say "  Server URL: $oldUrl -> $ServerUrl"
    } else { Say "  Server URL already $ServerUrl" }
} catch { Fail 'setting the Server URL' $_; $problems++ }
try {
    if (-not $certOk) {
        $node.Certificate = $gwCert
        $backEnd.UpdateApplicationCertificateAspect($node)
        Say "  trusted server certificate -> $($gwCert.Thumbprint)"
    } else { Say '  trusted server certificate already this gateway''s' }
} catch { Fail 'setting the trusted server certificate' $_; $problems++ }
try {
    # OPC UA Connect (client) trusts the gateway
    $uaTrusted = Join-Path $PkiRoot 'OpcUaConnect\pki\trusted\certs'
    New-Item -ItemType Directory -Path $uaTrusted -Force | Out-Null
    $have = @(Get-ChildItem -LiteralPath $uaTrusted -File -ErrorAction SilentlyContinue | ForEach-Object { (Load-Cert $_.FullName).Thumbprint })
    if ($gwCert.Thumbprint -notin $have) {
        [IO.File]::WriteAllBytes((Join-Path $uaTrusted "$($gwCert.GetNameInfo('SimpleName', $false)) [$($gwCert.Thumbprint)].der"), $gwCert.RawData)
        Say '  OPC UA Connect trusts the gateway certificate (pki\trusted)'
    } else { Say '  OPC UA Connect already trusts the gateway certificate' }
    # the gateway (server) trusts OPC UA Connect
    if ($uaConnect) {
        $gwTrusted = Join-Path $pki 'trusted\certs'
        New-Item -ItemType Directory -Path $gwTrusted -Force | Out-Null
        $have = @(Get-ChildItem -LiteralPath $gwTrusted -File -ErrorAction SilentlyContinue | ForEach-Object { (Load-Cert $_.FullName).Thumbprint })
        if ($uaConnect.Thumbprint -notin $have) {
            [IO.File]::WriteAllBytes((Join-Path $gwTrusted "800xAOpcUaConnect [$($uaConnect.Thumbprint)].der"), $uaConnect.RawData)
            Say '  the gateway trusts the OPC UA Connect certificate (pkiserver\trusted)'
        } else { Say '  the gateway already trusts the OPC UA Connect certificate' }
        Get-ChildItem -LiteralPath (Join-Path $pki 'rejected') -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { (Load-Cert $_.FullName).Thumbprint -eq $uaConnect.Thumbprint } | Remove-Item -Force -ErrorAction SilentlyContinue
    } else { Say '  OPC UA Connect certificate not found - run the certificate update first'; $problems++ }
} catch { Fail 'file trust' $_; $problems++ }
Say ''

# -- 4. check ---------------------------------------------------------------------------------------
Say '== 4. Check =='
try {
    $now  = $op.GetData()
    $n2   = @($backEnd.GetApplicationNodeList()) | Where-Object { "$($_.Type)" -eq 'ExternalUaServer' -and $_.Name -eq $ServerName } | Select-Object -First 1
    Say "  Server URL now: $($now.ServerURL)"
    Say "  trusted server certificate now: $(if ($n2.Certificate) { $n2.Certificate.Thumbprint } else { '(none)' })"
    if (-not [string]::Equals([string]$now.ServerURL, $ServerUrl, [StringComparison]::OrdinalIgnoreCase)) { $problems++ }
    if (-not ($n2.Certificate -and $n2.Certificate.Thumbprint -eq $gwCert.Thumbprint)) { $problems++ }
    if (-not $plOk) { Say '  upload placements not all Uploaded (see above)' }   # reported by Step 11 on its own line
} catch { Fail 'check' $_; $problems++ }
Say ''
Say 'OPC UA Connect picks up the new URL when it restarts (Step 11 service reset, OPC UA Connect first).'

try { $backEnd.Dispose() } catch { }
[System.AppDomain]::CurrentDomain.remove_AssemblyResolve($onResolve)
Finish $(if ($problems) { 4 } else { 0 })
