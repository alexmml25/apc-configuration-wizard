#Requires -Version 5.1
<#
.SYNOPSIS
    Updates the 800xA OPC UA application certificates the way the UA Management Portal's "Update Application
    Certificates" does (Step 11, SOP sub-step 4). TEST TOOL - run after Invoke-800xACreateRoot.ps1.
.DESCRIPTION
    Uses the portal's own ABB functions (32-bit; the script restarts itself in 32-bit STA PowerShell if needed):
      1. reads the root and revocation list from 800xA; the root must be in LocalMachine\Root with its key
      2. the portal's OPC UA client: ABB's client configuration, root + CRL in its trusted folder, and its own
         application certificate (800xAOpcUaManagementPortal) signed by the root when missing or signed by another root
      3. for each 800xA OPC UA application (UA Connect, UA Server; not external servers such as deviceWise):
         a. connect (OPC UA session, security on) and log in with the given Windows account
         b. push root + CRL into the application's trust list and take the root out of its issuer list
         c. ask it for a signing request, sign it with the root's key, push the certificate, ApplyChanges
         d. reconnect until the application presents the new certificate
         e. save the certificate in the application's 800xA certificate aspect
    Applications already on a certificate signed by the current root are left alone (use -Force to redo them).
    Before any change it saves the 800xA certificates of LocalMachine\My (public parts) and the pki folders into
    C:\APC_Config\Backups\<ts>_800xA-appcerts. Without -Confirmed it only makes the backup and reports.
    Exit codes: 0 updated (or nothing to do), 10 report only (no -Confirmed), 1 ABB assemblies not loaded,
    2 cannot connect to 800xA, 3 not administrator / bad parameters, 4 update failed, 5 updated but a check failed,
    6 root not usable on this node (run Invoke-800xACreateRoot.ps1 first).
    Output: C:\APC_Config\Logs\chmi-updatecerts_<ts>.txt
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Invoke-800xAUpdateAppCerts.ps1              # backup + report only
    powershell -ExecutionPolicy Bypass -File .\tools\Invoke-800xAUpdateAppCerts.ps1 -Confirmed   # update (password in a Windows credential dialog)
#>
param(
    [switch]$Confirmed,
    [switch]$Force,
    [string]$UserName = "$env:USERDOMAIN\$env:USERNAME",   # the account the operator logs in with in the portal
    [string]$BinDir  = 'C:\Program Files (x86)\ABB 800xA\Base\bin',
    [string]$PkiRoot = 'C:\ProgramData\ABB\Process Portal A',
    [string]$OutDir  = 'C:\APC_Config\Logs',
    [string]$BackupRoot = 'C:\APC_Config\Backups'
)

# ABB's certificate assemblies are 32-bit only; the portal's helpers expect an STA (WPF) thread
if ([Environment]::Is64BitProcess -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $ps32 = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    $argz = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-UserName', $UserName,
              '-BinDir', $BinDir, '-PkiRoot', $PkiRoot, '-OutDir', $OutDir, '-BackupRoot', $BackupRoot)
    if ($Confirmed) { $argz += '-Confirmed' }
    if ($Force)     { $argz += '-Force' }
    & $ps32 @argz
    exit $LASTEXITCODE
}

$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$outFile = Join-Path $OutDir "chmi-updatecerts_$ts.txt"
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
function Test-SignedBy($Cert, $Root) {
    # true when $Cert's chain ends at $Root (signature check, not the issuer name)
    if (-not $Cert -or -not $Root) { return $false }
    $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    $chain.ChainPolicy.RevocationMode = 'NoCheck'
    $chain.ChainPolicy.VerificationFlags = 'AllowUnknownCertificateAuthority'
    [void]$chain.ChainPolicy.ExtraStore.Add($Root)
    [void]$chain.Build($Cert)
    $last = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
    return ($chain.ChainElements.Count -gt 1 -and $last.Thumbprint -eq $Root.Thumbprint)
}
function Describe($Cert) {
    if (-not $Cert) { return '(no certificate)' }
    "$($Cert.Thumbprint)  issuer $($Cert.Issuer.Split(',')[0])  $($Cert.NotBefore.ToString('yyyy-MM-dd')) -> $($Cert.NotAfter.ToString('yyyy-MM-dd'))"
}

Say "800xA Update Application Certificates - $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - user $env:USERDOMAIN\$env:USERNAME"
Say "Mode: $(if ($Confirmed) { 'UPDATE (confirmed)' } else { 'backup + report only (no -Confirmed)' })$(if ($Force) { '  -Force' })   OPC UA login: $UserName"
Say ''

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Say 'ERROR: run as administrator (the root key and the portal certificate are in LocalMachine stores).'; Finish 3 }

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
    # the OPC Foundation stack ships in the same folder; load it first so its type names resolve in this script
    foreach ($f in 'Opc.Ua.Core.dll', 'Opc.Ua.Client.dll', 'Opc.Ua.Configuration.dll', 'Opc.Ua.Gds.Client.Common.dll', 'ABB.xA.Base.Ua.Common.dll') {
        $p = Join-Path $BinDir $f
        if (Test-Path -LiteralPath $p) { [void][System.Reflection.Assembly]::LoadFrom($p) }
    }
    $portalAsm = [System.Reflection.Assembly]::LoadFrom((Join-Path $BinDir 'ABB.xA.Base.Ua.ManagementPortal.exe'))
    # internal portal classes, called through reflection
    $gdsType = $portalAsm.GetType('ABB.xA.Base.Ua.ManagementPortal.GDS.GdsPushClient', $true)
    $cmType  = $portalAsm.GetType('ABB.xA.Base.Ua.ManagementPortal.GDS.CertificateManager', $true)
} catch { Fail 'loading the ABB assemblies' $_; Finish 1 }

$static = [System.Reflection.BindingFlags]'Public,NonPublic,Static'
function Get-GdsMethod([string]$Name, [int]$ParamCount) {
    $m = $gdsType.GetMethods($static) | Where-Object { $_.Name -eq $Name -and $_.GetParameters().Count -eq $ParamCount } | Select-Object -First 1
    if (-not $m) { throw "GdsPushClient.$Name($ParamCount parameters) not found in this 800xA version" }
    return $m
}
function Invoke-Gds([string]$Name, [object[]]$Arguments) {
    # MethodInfo.Invoke needs the plain .NET objects: PowerShell hands over objects made with New-Object
    # wrapped in a PSObject ("cannot be converted to type 'Opc.Ua.IUserIdentity'", VM run 2026-10-15)
    $plain = New-Object object[] $Arguments.Count
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $a = $Arguments[$i]
        if ($null -ne $a) { $plain[$i] = $a.PSObject.BaseObject }   # direct assignment: an if-expression would unroll byte[]
    }
    $r = (Get-GdsMethod $Name $Arguments.Count).Invoke($null, $plain)
    if ($r -is [System.Threading.Tasks.Task]) { return $r.GetAwaiter().GetResult() }
    return $r
}
function Close-Session($Session) { if ($Session) { try { $Session.Close() } catch { } ; try { $Session.Dispose() } catch { } } }

# -- 1. root -------------------------------------------------------------------------
Say '== 1. Root in 800xA =='
try {
    if (-not [System.Windows.Application]::Current) { $wpfApp = New-Object System.Windows.Application }
    $backEnd = New-Object ABB.xA.Base.Ua.ManagementPortal.Backend.BackEnd800xA
    $backEnd.Init()
    [ABB.xA.Base.Ua.ManagementPortal.BackEndProvider]::BackEnd = $backEnd
} catch { Fail 'BackEnd800xA.Init (connect to 800xA)' $_; Finish 2 }
$rootRaw = $backEnd.GetRootCertificate()
$crlRaw  = $backEnd.GetRevocationList()
if (-not ($rootRaw -and $rootRaw.Length)) { Say '  No root certificate in 800xA. Run Invoke-800xACreateRoot.ps1 first.'; Finish 6 }
$root = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (, [byte[]]$rootRaw)
$rootInStore = Get-StoreCert 'Root' $root.Thumbprint
Say "  $($root.Thumbprint)  $($root.Subject)  created on '$($backEnd.GetRootCertificateNodeName())'  CRL $(if ($crlRaw) { "$($crlRaw.Length) bytes" } else { 'MISSING' })"
Say "  LocalMachine\Root: $(if ($rootInStore) { "present, private key=$($rootInStore.HasPrivateKey)" } else { 'MISSING' })"
if (-not ($rootInStore -and $rootInStore.HasPrivateKey)) { Say '  This node cannot sign with the root. Run Invoke-800xACreateRoot.ps1 -Confirmed first.'; Finish 6 }
Say ''

# -- 2. applications -----------------------------------------------------------------------
Say '== 2. 800xA OPC UA applications =='
$nodes = @($backEnd.GetApplicationNodeList())
$todo = @()
foreach ($n in $nodes) {
    $type = "$($n.Type)"
    $signed = Test-SignedBy $n.Certificate $root
    Say "  $type  '$($n.Name)'  $($n.ServerUrl)"
    Say "      $(Describe $n.Certificate)  signed by current root: $signed"
    if ($type -in 'UaConnect', 'UaServer') {
        if (-not $signed -or $Force) { $todo += $n } else { Say '      -> already up to date' }
    } else { Say '      -> not updated (external server or the portal itself)' }
}
$connectSvc = Join-Path $PkiRoot 'OpcUaConnect\pki\trusted\certs'
$uaTrustsRoot = [bool](Get-ChildItem -LiteralPath $connectSvc -Filter '*.der' -ErrorAction SilentlyContinue | Where-Object {
    try { (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $_.FullName).Thumbprint -eq $root.Thumbprint } catch { $false } })
Say "  OPC UA Connect pki\trusted has the current root: $uaTrustsRoot$(if (-not $uaTrustsRoot) { '  (it must trust the portal certificate the update connects with; restart the OPC UA Connect service if the connect is rejected)' })"
Say ''

# -- backup -------------------------------------------------------------------------------
$backupDir = Join-Path $BackupRoot "${ts}_800xA-appcerts"
Say "== 3. Backup -> $backupDir =="
try {
    $certDir = Join-Path $backupDir 'store-certs'
    New-Item -ItemType Directory -Path $certDir -Force | Out-Null
    $s = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', 'LocalMachine')
    $s.Open('ReadOnly')
    foreach ($c in $s.Certificates | Where-Object { $_.Subject -match '800xA' }) {
        [IO.File]::WriteAllBytes((Join-Path $certDir "My-$($c.Subject.Split(',')[0].Substring(3))-$($c.Thumbprint).cer"), $c.Export('Cert'))
        Say "  saved [My] $($c.Subject.Split(',')[0])  $($c.Thumbprint)  key=$($c.HasPrivateKey)"
    }
    $s.Close()
    foreach ($n in $nodes | Where-Object { $_.Certificate }) {
        [IO.File]::WriteAllBytes((Join-Path $certDir "aspect-$($n.Name -replace '[^\w.-]', '_')-$($n.Certificate.Thumbprint).cer"), $n.Certificate.RawData)
    }
    foreach ($app in 'OpcUaConnect', 'OpcUaManagementPortal') {
        $src = Join-Path (Join-Path $PkiRoot $app) 'pki'
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $backupDir "$app-pki") -Recurse -Force; Say "  saved $src" }
    }
    Set-Content -Path (Join-Path $backupDir 'RESTORE.txt') -Value @(
        'The old application certificates (public parts) are in store-certs; their private keys stay in the applications.'
        'An application pushed a new certificate keeps the old one until it is replaced again: re-run Update Application'
        'Certificates in the UA Management Portal, or copy the *-pki folders back with the 800xA OPC UA services stopped.')
} catch { Fail 'backup' $_; Say 'Backup failed - nothing was changed.'; Finish 4 }
Say ''

if (-not $todo) { Say 'Nothing to update: every 800xA OPC UA application already has a certificate signed by the current root.'; Finish 0 }
if (-not $Confirmed) {
    Say "No -Confirmed: stopping here. Would update: $(($todo | ForEach-Object { $_.Name }) -join ', ')."
    Say 'With -Confirmed the script asks for the password of the OPC UA login above, makes the portal certificate if needed,'
    Say 'and for each application pushes root + CRL, signs a new certificate with the root and saves it in 800xA.'
    Finish 10
}

# Windows credential dialog (paste works there, unlike a hidden console prompt); user name filled in
$cred = Get-Credential -UserName $UserName -Message 'OPC UA login to the 800xA applications (same account as the UA Management Portal Connect)'
if (-not $cred) { Say 'No credentials entered - nothing was updated.'; Finish 4 }
$UserName = $cred.UserName
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password)
try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
$identity = New-Object Opc.Ua.UserIdentity($UserName, $plain)
$plain = $null

# -- 4. the portal's OPC UA client ----------------------------------------------------------------
Say '== 4. Portal OPC UA client (800xAOpcUaManagementPortal) =='
try {
    $inst = [ABB.xA.Base.Ua.Common.OpcUaConfig]::CreateApplicationInstance([Opc.Ua.ApplicationType]::Client, $null, $null)
    $sigma = [ABB.xA.Base.Ua.Common.EnvironmentVariable]::ExpandSigmaRootDir()
    if (-not $sigma) { $sigma = Split-Path $BinDir -Parent }
    $cfg = New-Object 'ABB.xA.Base.Ua.Common.OpcUaConfig+ConfigData'
    $cfg.ConfigFileName  = Join-Path (Join-Path $sigma 'bin') 'ABB.Opc.Ua.ManagementPortal.Config.xml'
    $cfg.ApplicationName = ''
    $cfg.ProductUri      = ''
    [void][ABB.xA.Base.Ua.Common.OpcUaConfig]::LoadApplicationConfiguration($inst, $cfg, [byte[]]$rootRaw)
    $secCfg = $inst.ApplicationConfiguration.SecurityConfiguration
    $trustedPath = [Opc.Ua.Utils]::ReplaceSpecialFolderNames($secCfg.TrustedPeerCertificates.StorePath)
    if ("$($secCfg.TrustedPeerCertificates.StoreType)" -eq 'Directory') {
        New-Item -ItemType Directory -Path $trustedPath -Force | Out-Null
        $msg = ''
        [void][ABB.xA.Base.Ua.ManagementPortal.CertificateHandler]::CopyRootCertAndRevocationListFromBackEndToPkiStructure($trustedPath, [ref]$msg)
        if ($msg) { Say "  root/CRL to $trustedPath`: $msg" }
    }
    $portalCert = $null
    try { $portalCert = $secCfg.ApplicationCertificate.Find($true).GetAwaiter().GetResult() } catch { }
    if (-not (Test-SignedBy $portalCert $root)) {
        Say "  current: $(Describe $portalCert) -> making a new one signed by the root"
        $portalCert = [ABB.xA.Base.Ua.ManagementPortal.CertificateHandler]::CreateApplicationCertificateForPortal($secCfg, '')
        if ($portalCert) {
            # audit event as the portal raises it; AspectRef.Empty is looked up from the method (its assembly varies)
            try {
                $audit = $backEnd.GetType().GetMethod('GenerateCertificateAuditEvent')
                $arType = $audit.GetParameters()[2].ParameterType
                $empty = $arType.GetField('Empty', [System.Reflection.BindingFlags]'Public,Static')
                $emptyVal = if ($empty) { $empty.GetValue($null) } else { $arType.GetProperty('Empty').GetValue($null) }
                [void]$audit.Invoke($backEnd, @($portalCert, $null, $emptyVal))
            } catch { Say "  (audit event not raised: $($_.Exception.Message))" }
        }
    }
    $inst.CheckApplicationInstanceCertificate($false, [uint16]0).GetAwaiter().GetResult() | Out-Null
    Say "  portal certificate: $(Describe $secCfg.ApplicationCertificate.Certificate)"
} catch { Fail 'portal OPC UA client' $_; Finish 4 }
Say ''

# -- 5. update each application -------------------------------------------------------------
Say '== 5. Update =='
$problems = 0
$updated  = @()
foreach ($n in $todo) {
    Say "  -- $($n.Name)  $($n.ServerUrl)"
    $session = $null
    try {
        $session = Invoke-Gds 'Connect' @($inst, $n.ServerUrl, $identity)
        Say '     connected (security on)'
        $trust = Invoke-Gds 'GetTrustedCertificates' @($session, $true)
        [void](Invoke-Gds 'UpdateTrustList' @($session, $trust, [byte[]]$rootRaw, [byte[]]$crlRaw, $true))
        Say '     trust list: root + CRL trusted, root removed from the issuer list'
        $cm = [Activator]::CreateInstance($cmType, [System.Reflection.BindingFlags]'Public,NonPublic,Instance', $null, [object[]]@([string]$root.Thumbprint), $null)
        try { $newCert = Invoke-Gds 'UpdateCertificate' @($session, $cm, $n) } finally { $cm.Dispose() }
        if (-not $newCert) { throw 'the application returned no certificate' }
        Say "     pushed + ApplyChanges: $(Describe $newCert)"
    } catch {
        Fail "update of $($n.Name)" $_
        if ("$_" -match 'BadCertificateUntrusted|BadSecurityChecksFailed|BadIdentityTokenRejected|BadUserAccessDenied') {
            Say '     hint: certificate or login rejected - check the password, and that OPC UA Connect trusts the root (restart its service).'
        }
        Close-Session $session; $problems++; continue
    }
    Close-Session $session
    try { [ABB.xA.Base.Ua.ManagementPortal.CertificateHandler]::WriteCertificateToTrustedDirectory($trustedPath, $newCert) } catch { Fail 'copy to the portal trusted folder' $_ }

    # the application restarts its endpoint after ApplyChanges: reconnect until it shows the new certificate
    $ok = $false
    for ($i = 1; $i -le 30 -and -not $ok; $i++) {
        Start-Sleep -Seconds 2
        $s2 = $null
        try {
            $s2 = Invoke-Gds 'Connect' @($inst, $n.ServerUrl, $identity)
            $shown = Invoke-Gds 'GetCertificate' @($s2)
            $ok = ($shown -and $shown.Thumbprint -eq $newCert.Thumbprint)
        } catch { } finally { Close-Session $s2 }
    }
    if (-not $ok) { Say '     FAIL: the application does not present the new certificate after 60 s'; $problems++; continue }
    Say '     reconnect: the application presents the new certificate'
    try {
        $n.Certificate = $newCert
        $backEnd.UpdateApplicationCertificateAspect($n)
        Say '     saved in the 800xA application certificate aspect'
        $updated += $n.Name
    } catch { Fail 'UpdateApplicationCertificateAspect' $_; $problems++ }
}
Say ''

# -- 6. checks -------------------------------------------------------------------------------------
Say '== 6. Checks =='
foreach ($n in @($backEnd.GetApplicationNodeList()) | Where-Object { "$($_.Type)" -in 'UaConnect', 'UaServer' }) {
    $signed = Test-SignedBy $n.Certificate $root
    Say "  $($n.Name): $(Describe $n.Certificate)  signed by current root: $signed"
    if (-not $signed) { $problems++ }
}
$my = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', 'LocalMachine')
$my.Open('ReadOnly')
foreach ($c in $my.Certificates | Where-Object { $_.Subject -match 'CN=800xAOpcUa(Connect|ManagementPortal)\b' }) {
    Say "  [My] $($c.Subject.Split(',')[0])  $(Describe $c)  key=$($c.HasPrivateKey)  signed by current root: $(Test-SignedBy $c $root)"
}
$my.Close()
Say ''
Say "Updated: $(if ($updated) { $updated -join ', ' } else { 'none' })"

try { $backEnd.Dispose() } catch { }
[System.AppDomain]::CurrentDomain.remove_AssemblyResolve($onResolve)
Finish $(if ($problems) { if ($updated) { 5 } else { 4 } } else { 0 })
