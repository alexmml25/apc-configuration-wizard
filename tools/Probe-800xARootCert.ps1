#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only check of the 800xA OPC UA root certificate state, using the UA Management Portal's own
    ABB functions (Step 11, SOP sub-steps 2-4).
.DESCRIPTION
    Loads ABB's portal assemblies from the 800xA bin folder (32-bit; the script restarts itself in 32-bit
    PowerShell if needed), connects to the running 800xA system the way the portal does
    (BackEnd800xA.Init) and reports:
      1. the root certificate 800xA uses (OPC UA Certificate aspect): thumbprint, subject, validity,
         the node that created it, and whether its revocation list exists
      2. the portal's own "root installed on this node?" check: the root's thumbprint in
         LocalMachine\Root, and whether it has its private key -> Installed / MissingPrivateKey /
         MissingFromWindowsStore / NotInstalledInThisNode
      3. every 800xA root certificate in LocalMachine\Root and LocalMachine\My, with private key yes/no
      4. the OPC UA applications the portal would update (UA Connect, UA Server, external servers)
    Nothing is written on a configured system: BackEnd800xA.Init only creates the certificate aspect
    when it does not exist yet (a system where Create Root Certificate was never done).
    Output: D:\APC_Config\Logs\chmi-rootprobe.txt
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Probe-800xARootCert.ps1
#>
param(
    [string]$BinDir = 'C:\Program Files (x86)\ABB 800xA\Base\bin',
    [string]$OutDir = "$(if (@([IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -eq 'D:\' -and $_.DriveType -eq 'Fixed' -and $_.IsReady }).Count) { 'D:' } else { 'C:' })\APC_Config\Logs"
)

# ABB's certificate assemblies are 32-bit only
if ([Environment]::Is64BitProcess) {
    $ps32 = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    & $ps32 -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -BinDir $BinDir -OutDir $OutDir
    exit $LASTEXITCODE
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$outFile = Join-Path $OutDir 'chmi-rootprobe.txt'
$report  = New-Object System.Collections.Generic.List[string]
function Say([string]$Text) { $report.Add($Text); Write-Host $Text }
function Fail([string]$What, $Err) {
    $e = if ($Err -is [System.Management.Automation.ErrorRecord]) { $Err.Exception } else { $Err }
    Say "  ERROR in ${What}: $($e.GetType().FullName): $($e.Message)"
    while ($e.InnerException) { $e = $e.InnerException; Say "    inner: $($e.GetType().FullName): $($e.Message)" }
}
function Save { $report | Out-File -FilePath $outFile -Width 300 -Encoding UTF8; "Written: $outFile" }

Say "800xA root certificate probe - $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - user $env:USERDOMAIN\$env:USERNAME - 64-bit process: $([Environment]::Is64BitProcess)"
Say ''

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
    foreach ($f in 'ABB.xA.Base.Ua.Common.dll', 'ABB.xA.Base.Ua.ManagementPortal.exe') {
        [void][System.Reflection.Assembly]::LoadFrom((Join-Path $BinDir $f))
    }
} catch { Fail 'loading the ABB assemblies' $_; Save; exit 1 }

# -- 1. connect and read the root from the 800xA aspect --------------------------
Say '== 1. Root certificate in 800xA (OPC UA Certificate aspect) =='
$backEnd = $null
$rootRaw = $null
try {
    $backEnd = New-Object ABB.xA.Base.Ua.ManagementPortal.Backend.BackEnd800xA
    $backEnd.Init()
    Say '  Connected to the 800xA system.'
} catch { Fail 'BackEnd800xA.Init (connect to 800xA)' $_; Save; exit 2 }

try {
    $rootRaw = $backEnd.GetRootCertificate()
    if (-not $rootRaw -or $rootRaw.Length -eq 0) {
        Say '  No root certificate in 800xA (aspect empty) - Create Root Certificate has never been done on this system.'
    } else {
        $root = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (, [byte[]]$rootRaw)
        Say "  Thumbprint : $($root.Thumbprint)"
        Say "  Subject    : $($root.Subject)"
        Say "  Valid      : $($root.NotBefore) -> $($root.NotAfter)"
    }
} catch { Fail 'GetRootCertificate' $_ }
try { Say "  Created on node (aspect NodeName): '$($backEnd.GetRootCertificateNodeName())'   this machine: '$([Environment]::MachineName)'" } catch { Fail 'GetRootCertificateNodeName' $_ }
try {
    $crl = $backEnd.GetRevocationList()
    Say "  Revocation list: $(if ($crl -and $crl.Length) { "$($crl.Length) bytes" } else { 'MISSING' })"
} catch { Fail 'GetRevocationList' $_ }
Say ''

# -- 2. the portal's own state check ------------------------------------------------
Say '== 2. Portal state check (root thumbprint in LocalMachine\Root) =='
if ($rootRaw -and $rootRaw.Length) {
    try {
        # same lookup as the portal (CertificateSupport.GetRootCertificateFromWindowsStore is internal to ABB)
        $rootStore = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'LocalMachine')
        $rootStore.Open('ReadOnly')
        $found = $rootStore.Certificates.Find('FindByThumbprint', $root.Thumbprint, $false)
        $inStore = if ($found.Count) { $found[0] } else { $null }
        $rootStore.Close()
        $nodeName = $backEnd.GetRootCertificateNodeName()
        $state = if (-not $inStore) {
            if ($nodeName -and -not [string]::Equals($nodeName, [Environment]::MachineName, [StringComparison]::OrdinalIgnoreCase)) { 'NotInstalledInThisNode' } else { 'MissingFromWindowsStore' }
        } elseif (-not $inStore.HasPrivateKey) { 'MissingPrivateKey' } else { 'Installed' }
        Say "  State: $state"
        Say $(switch ($state) {
            'Installed'               { '  -> This node holds the root and its key: Update Application Certificates can sign here.' }
            'MissingPrivateKey'       { '  -> The root is in the store but without its key: this node cannot sign.' }
            'MissingFromWindowsStore' { '  -> The root 800xA uses is not in this node''s store: the portal shows "No private key..." and cannot sign.' }
            'NotInstalledInThisNode'  { "  -> The root was created on node '$nodeName': only that node can sign, unless the root is imported here." }
        })
        if ($inStore) { $inStore.Dispose() }
    } catch { Fail 'state check' $_ }
} else { Say '  (no root in 800xA)' }
Say ''

# -- 3. all 800xA certificates in the LocalMachine stores ---------------------------
Say '== 3. 800xA certificates in LocalMachine\Root and LocalMachine\My =='
foreach ($storeName in 'Root', 'My') {
    try {
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($storeName, 'LocalMachine')
        $store.Open('ReadOnly')
        foreach ($c in $store.Certificates | Where-Object { $_.Subject -match '800xA' }) {
            $mark = if ($rootRaw -and $root -and $c.Thumbprint -eq $root.Thumbprint) { '  <- root 800xA uses' } else { '' }
            Say "  [$storeName] $($c.Subject.Split(',')[0])  $($c.Thumbprint)  key=$($c.HasPrivateKey)  $($c.NotBefore.ToString('yyyy-MM-dd')) -> $($c.NotAfter.ToString('yyyy-MM-dd'))$mark"
        }
        $store.Close()
    } catch { Fail "reading LocalMachine\$storeName" $_ }
}
Say ''

# -- 4. applications the portal would update --------------------------------------
Say '== 4. OPC UA applications (what Update Application Certificates would cover) =='
try {
    foreach ($n in $backEnd.GetApplicationNodeList()) {
        $cert = $n.Certificate
        Say "  $($n.Type)  '$($n.Name)'  $($n.ServerUrl)"
        if ($cert) { Say "      cert $($cert.Thumbprint)  valid to $($cert.NotAfter.ToString('yyyy-MM-dd'))  issuer $($cert.Issuer.Split(',')[0])" }
        else { Say '      no certificate' }
    }
} catch { Fail 'GetApplicationNodeList' $_ }

try { $backEnd.Dispose() } catch { }
[System.AppDomain]::CurrentDomain.remove_AssemblyResolve($onResolve)
Save
