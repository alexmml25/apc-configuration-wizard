#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a new 800xA OPC UA root certificate the way the UA Management Portal's "Create Root
    Certificate" does (Step 11, SOP sub-step 2). Called by Step 11 with -IfNeeded -Confirmed.
.DESCRIPTION
    Calls the portal's own ABB function CertificateHandler.RunGenerateAndInstallRootCertificateAndRevocationList
    (32-bit, the script restarts itself in 32-bit PowerShell if needed), which:
      1. creates the root "800xAOpcUaRoot" (O / OU / C, valid N years) as a PFX
      2. imports it with its private key into LocalMachine\Root (machine key)
      3. creates its revocation list
      4. writes root + revocation list + this node's name to the 800xA OPC UA Certificate aspect
    Before that it saves everything needed to undo it into <run>\Backups\ <ts>_800xA-root:
      - the current root and revocation list from 800xA (old-root.der, old-crl.crl, old-nodename.txt)
      - the 800xA certificates in LocalMachine\Root and LocalMachine\My (public parts, .cer)
      - the OPC UA Connect / Management Portal pki folders
    Without -Confirmed it only makes the backup and reports what it would do.
    It does NOT update the application certificates (sub-step 4); after a new root, the existing
    application certificates are signed by the old root until they are updated.
    -IfNeeded: create only when this node cannot sign with the current root - no root, the root without its key
    here (e.g. left from the machine the VM was copied from), or a root made on a node that is not part of this
    800xA system. A root that is Installed here is kept (exit 11); a root that belongs to another node of this
    system is never replaced (exit 12: create/sign there).
    Exit codes: 0 created and verified, 10 backup only (no -Confirmed), 11 kept (-IfNeeded, root usable here),
    12 not replaced (root of another node of this system), 1 ABB assemblies not loaded, 2 cannot connect to
    800xA, 3 not administrator / bad parameters, 4 create failed, 5 created but a check failed.
    Output: <run>\Logs\ (standalone: <work folder>\Logs\) chmi-createroot_<ts>.txt
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\modules\Invoke-800xACreateRoot.ps1              # backup + report only
    powershell -ExecutionPolicy Bypass -File .\modules\Invoke-800xACreateRoot.ps1 -Confirmed   # create the root
#>
param(
    [switch]$Confirmed,
    [switch]$IfNeeded,
    [string]$Organization     = 'ABB',
    [string]$OrganizationUnit = 'Industrial Automation',
    [string]$Country          = 'CA',
    [ValidateRange(3, 10)] [int]$ValidYears = 10,     # the portal offers 3-10 years
    [string]$BinDir  = 'C:\Program Files (x86)\ABB 800xA\Base\bin',
    [string]$PkiRoot = 'C:\ProgramData\ABB\Process Portal A',
    [string]$OutDir  = $(if (@([IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -eq 'D:\' -and $_.DriveType -eq 'Fixed' -and $_.IsReady }).Count) { 'D:\APC_Config\Logs' } else { 'C:\APC_Config\Logs' }),
    [string]$BackupRoot = $(if (@([IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -eq 'D:\' -and $_.DriveType -eq 'Fixed' -and $_.IsReady }).Count) { 'D:\APC_Config\Backups' } else { 'C:\APC_Config\Backups' })
)

# ABB's certificate assemblies are 32-bit only; WPF needs an STA thread
if ([Environment]::Is64BitProcess -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $ps32 = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    $argz = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
              '-Organization', $Organization, '-OrganizationUnit', $OrganizationUnit, '-Country', $Country,
              '-ValidYears', $ValidYears, '-BinDir', $BinDir, '-PkiRoot', $PkiRoot, '-OutDir', $OutDir, '-BackupRoot', $BackupRoot)
    if ($Confirmed) { $argz += '-Confirmed' }
    if ($IfNeeded)  { $argz += '-IfNeeded' }
    & $ps32 @argz
    exit $LASTEXITCODE
}

$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$outFile = Join-Path $OutDir "chmi-createroot_$ts.txt"
$report  = New-Object System.Collections.Generic.List[string]
function Say([string]$Text) { $report.Add($Text); Write-Host $Text }
function Fail([string]$What, $Err) {
    $e = if ($Err -is [System.Management.Automation.ErrorRecord]) { $Err.Exception } else { $Err }
    Say "  ERROR in ${What}: $($e.GetType().FullName): $($e.Message)"
    while ($e.InnerException) { $e = $e.InnerException; Say "    inner: $($e.GetType().FullName): $($e.Message)" }
}
function Finish([int]$Code) { $report | Out-File -FilePath $outFile -Width 300 -Encoding UTF8; "Written: $outFile"; exit $Code }
function Get-StoreCert([string]$Store, [string]$Thumbprint) {
    $s = New-Object System.Security.Cryptography.X509Certificates.X509Store($Store, 'LocalMachine')
    $s.Open('ReadOnly')
    try { $f = $s.Certificates.Find('FindByThumbprint', $Thumbprint, $false); if ($f.Count) { $f[0] } } finally { $s.Close() }
}

Say "800xA Create Root Certificate - $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - user $env:USERDOMAIN\$env:USERNAME"
Say "Mode: $(if ($Confirmed) { 'CREATE (confirmed)' } else { 'backup + report only (no -Confirmed)' })   Subject: CN=800xAOpcUaRoot, O=$Organization, OU=$OrganizationUnit, C=$Country   Valid: $ValidYears years"
Say ''

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Say 'ERROR: run as administrator (the root is imported into LocalMachine\Root).'; Finish 3 }
if (-not ($Organization -and $OrganizationUnit -and $Country)) { Say 'ERROR: Organization, OrganizationUnit and Country must not be empty (the portal requires them).'; Finish 3 }

# Resolve ABB / OPC Foundation references from the 800xA bin folder
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
    foreach ($f in 'ABB.xA.Base.Ua.Common.dll', 'ABB.xA.Base.Ua.ManagementPortal.exe') {
        [void][System.Reflection.Assembly]::LoadFrom((Join-Path $BinDir $f))
    }
} catch { Fail 'loading the ABB assemblies' $_; Finish 1 }

# -- connect and read the current root ------------------------------------------
Say '== 1. Current root in 800xA =='
try {
    $backEnd = New-Object ABB.xA.Base.Ua.ManagementPortal.Backend.BackEnd800xA
    $backEnd.Init()
} catch { Fail 'BackEnd800xA.Init (connect to 800xA)' $_; Finish 2 }
$oldRaw = $backEnd.GetRootCertificate()
$oldCrl = $backEnd.GetRevocationList()
$oldNode = $backEnd.GetRootCertificateNodeName()
$oldThumb = ''
if ($oldRaw -and $oldRaw.Length) {
    $old = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (, [byte[]]$oldRaw)
    $oldThumb = $old.Thumbprint
    Say "  $($old.Thumbprint)  $($old.Subject)  $($old.NotBefore.ToString('yyyy-MM-dd')) -> $($old.NotAfter.ToString('yyyy-MM-dd'))  created on '$oldNode'"
} else { Say '  (none)' }
Say ''

if ($IfNeeded -and $oldThumb) {
    $here  = Get-StoreCert 'Root' $oldThumb
    $hosts = @(foreach ($n in @($backEnd.GetApplicationNodeList())) {
        if ("$($n.Type)" -in 'UaConnect', 'UaServer') {
            if ($n.ServerUrl -match '^opc\.tcp://([^:/]+)') { $Matches[1] }
            foreach ($a in @($n.Addresses)) { $a }
        }
    }) | ForEach-Object { ($_ -split '\.')[0].ToUpperInvariant() } | Select-Object -Unique
    $nodeShort = (([string]$oldNode) -split '\.')[0].ToUpperInvariant()
    $thisShort = ([Environment]::MachineName).ToUpperInvariant()
    if ($here -and $here.HasPrivateKey) {
        Say "Root is Installed on this node (in LocalMachine\Root with its key): kept, nothing created."
        Finish 11
    }
    if ($nodeShort -and $nodeShort -ne $thisShort -and $nodeShort -in $hosts) {
        Say "Root was created on $oldNode, which is a node of this 800xA system: not replaced. Sign there, or ask the APC Team."
        Finish 12
    }
    Say "Root not usable here ($(if ($here) { 'in LocalMachine\Root without its key' } else { 'not in LocalMachine\Root' }); created on '$oldNode', not a node of this system): a new root is needed."
    Say ''
}

# -- backup -----------------------------------------------------------------------
$backupDir = Join-Path $BackupRoot "${ts}_800xA-root"
Say "== 2. Backup -> $backupDir =="
try {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    if ($oldRaw -and $oldRaw.Length) { [IO.File]::WriteAllBytes((Join-Path $backupDir 'old-root.der'), $oldRaw) }
    if ($oldCrl -and $oldCrl.Length) { [IO.File]::WriteAllBytes((Join-Path $backupDir 'old-crl.crl'), $oldCrl) }
    Set-Content -Path (Join-Path $backupDir 'old-nodename.txt') -Value $oldNode
    $certDir = Join-Path $backupDir 'store-certs'
    New-Item -ItemType Directory -Path $certDir -Force | Out-Null
    foreach ($storeName in 'Root', 'My') {
        $s = New-Object System.Security.Cryptography.X509Certificates.X509Store($storeName, 'LocalMachine')
        $s.Open('ReadOnly')
        foreach ($c in $s.Certificates | Where-Object { $_.Subject -match '800xA' }) {
            [IO.File]::WriteAllBytes((Join-Path $certDir "$storeName-$($c.Subject.Split(',')[0].Substring(3))-$($c.Thumbprint).cer"), $c.Export('Cert'))
            Say "  saved [$storeName] $($c.Subject.Split(',')[0])  $($c.Thumbprint)  key=$($c.HasPrivateKey)"
        }
        $s.Close()
    }
    foreach ($app in 'OpcUaConnect', 'OpcUaManagementPortal') {
        $src = Join-Path (Join-Path $PkiRoot $app) 'pki'
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $backupDir "$app-pki") -Recurse -Force
            Say "  saved $src"
        }
    }
    Set-Content -Path (Join-Path $backupDir 'RESTORE.txt') -Value @(
        'To put the old root back in 800xA: BackEnd800xA.Init(), then SetRootCertificate(old-root.der bytes, old-crl.crl bytes).'
        "Note: SetRootCertificate records this node ('$([Environment]::MachineName)') as NodeName; the old value was '$oldNode'."
        'The new root stays in LocalMachine\Root until removed (certlm.msc > Trusted Root Certification Authorities).'
        'The pki folders can be copied back from *-pki (stop the 800xA OPC UA services first).')
} catch { Fail 'backup' $_; Say 'Backup failed - nothing was changed.'; Finish 4 }
Say ''

if (-not $Confirmed) {
    Say 'No -Confirmed: stopping here. Nothing in 800xA or the certificate stores was changed.'
    Say 'With -Confirmed the script would create a new root with the subject and validity above, import it into'
    Say 'LocalMachine\Root with its private key, and write it to the 800xA OPC UA Certificate aspect.'
    Finish 10
}

# -- create (the portal's own function) --------------------------------------------
Say '== 3. Create root (CertificateHandler.RunGenerateAndInstallRootCertificateAndRevocationList) =='
try {
    # the ABB function writes to 800xA through BackEndProvider.BackEnd on the WPF UI thread
    if (-not [System.Windows.Application]::Current) { $wpfApp = New-Object System.Windows.Application }
    [ABB.xA.Base.Ua.ManagementPortal.BackEndProvider]::BackEnd = $backEnd
    $err = ''
    # same password the portal uses; it only protects the PFX while it is imported
    $ok = [ABB.xA.Base.Ua.ManagementPortal.CertificateHandler]::RunGenerateAndInstallRootCertificateAndRevocationList(
            [ref]$err, 'dummyPassword', $ValidYears, '', '', $Organization, $OrganizationUnit, $Country)
    if (-not $ok) { Say "  FAILED: $err"; Finish 4 }
    Say '  Done.'
} catch { Fail 'create root' $_; Finish 4 }
Say ''

# -- verify ---------------------------------------------------------------------------
Say '== 4. Checks =='
$problems = 0
$newRaw = $backEnd.GetRootCertificate()
$new = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (, [byte[]]$newRaw)
Say "  800xA root now : $($new.Thumbprint)  $($new.Subject)  $($new.NotBefore.ToString('yyyy-MM-dd')) -> $($new.NotAfter.ToString('yyyy-MM-dd'))"
if ($new.Thumbprint -eq $oldThumb) { Say '  FAIL: the root in 800xA did not change'; $problems++ }
$node = $backEnd.GetRootCertificateNodeName()
Say "  created on     : '$node'"
if (-not [string]::Equals($node, [Environment]::MachineName, [StringComparison]::OrdinalIgnoreCase)) { Say "  FAIL: NodeName is not this machine"; $problems++ }
$crl = $backEnd.GetRevocationList()
Say "  revocation list: $(if ($crl -and $crl.Length) { "$($crl.Length) bytes" } else { 'MISSING' })"
if (-not ($crl -and $crl.Length)) { $problems++ }
$inStore = Get-StoreCert 'Root' $new.Thumbprint
Say "  LocalMachine\Root: $(if ($inStore) { "present, private key=$($inStore.HasPrivateKey)" } else { 'MISSING' })"
if (-not ($inStore -and $inStore.HasPrivateKey)) { $problems++ } else { Say '  Portal state   : Installed (Update Application Certificates can sign on this node)' }

# the 800xA OPC UA services copy the new root into their pki\issuer folders by themselves
$issuer = Join-Path $PkiRoot 'OpcUaConnect\pki\issuer\certs'
$seen = $false
for ($i = 0; $i -lt 12 -and -not $seen; $i++) {
    $seen = [bool](Get-ChildItem -LiteralPath $issuer -Filter '*.der' -ErrorAction SilentlyContinue | Where-Object {
        try { (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $_.FullName).Thumbprint -eq $new.Thumbprint } catch { $false } })
    if (-not $seen) { Start-Sleep -Seconds 5 }
}
Say "  OPC UA Connect pki\issuer has the new root: $seen$(if (-not $seen) { '  (info only: may need the OPC UA Connect service to pick it up)' })"
Say ''
Say 'Next: Update Application Certificates (sub-step 4). Until then the application certificates are still signed by the old root.'

try { $backEnd.Dispose() } catch { }
[System.AppDomain]::CurrentDomain.remove_AssemblyResolve($onResolve)
Finish $(if ($problems) { 5 } else { 0 })
