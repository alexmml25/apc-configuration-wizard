#Requires -Version 5.1
<#
.SYNOPSIS
    Test: can the wizard make Data Analyzer's OPC UA certificate without opening Data Analyzer (no login)?
.DESCRIPTION
    Data Analyzer makes its certificate on its first OPC connect, and it only connects after a login + Start
    Monitoring. Its OPC code is small (OPCUtil): Traeger Opc.UaFx.Client with the licence from License.txt,
    new OpcClient(url), MedtronicSU, SignAndEncrypt / Basic256, Connect(). The library names the certificate
    after the entry assembly ("APC Data Analyzer") and keeps it in <app folder>\CertificateStores.

    This tool does the same first connect from PowerShell, with the same library, licence and name, but against
    a COPY of the store folders (C:\APC_Config\Logs\da-cert-test_<ts>), so Data Analyzer's real certificate is
    not touched. By default it connects to a port nothing listens on: the certificate is made before the
    connect, and deviceWise never sees (or rejects) the test certificate. Then it compares the new certificate
    with Data Analyzer's own one: subject, application URI, host names, key size, validity, signature.
    Matching = Data Analyzer will accept a certificate the wizard makes, so Step 10 can make and trust it.
    32-bit (Data Analyzer is 32-bit only); the script restarts itself in 32-bit PowerShell if needed.
    Changes nothing outside the test folder. Output: C:\APC_Config\Logs\da-cert-test_<ts>.txt
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Test-DataAnalyzerCert.ps1
#>
param(
    [string]$DaDir  = 'C:\Medtronic\Data Analyzer',
    [string]$Url    = 'opc.tcp://127.0.0.1:1',          # nothing listens: no deviceWise side effect
    [string]$OutDir = 'C:\APC_Config\Logs'
)

if ([Environment]::Is64BitProcess) {
    $ps32 = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    & $ps32 -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -DaDir $DaDir -Url $Url -OutDir $OutDir
    exit $LASTEXITCODE
}

$ts      = Get-Date -Format 'yyyyMMdd_HHmmss'
$work    = Join-Path $OutDir "da-cert-test_$ts"
$outFile = "$work.txt"
$report  = New-Object System.Collections.Generic.List[string]
function Say([string]$Text) { $report.Add($Text); Write-Host $Text }
function Finish([int]$Code) { $report | Out-File -FilePath $outFile -Width 300 -Encoding UTF8; "Written: $outFile"; exit $Code }
function Describe($C) {
    if (-not $C) { return @('  (none)') }
    $uri = ''; $dns = @()
    foreach ($e in $C.Extensions) {
        if ($e.Oid.Value -eq '2.5.29.17') {
            foreach ($part in ($e.Format($false) -split ',\s*')) {
                if ($part -match '^URL=(.+)$') { $uri = $Matches[1] } elseif ($part -match '^DNS Name=(.+)$') { $dns += $Matches[1] } elseif ($part -match '^IP Address=(.+)$') { $dns += $Matches[1] }
            }
        }
    }
    @("  Subject   : $($C.Subject)"
      "  Issuer    : $($C.Issuer)"
      "  App URI   : $uri"
      "  Hosts     : $($dns -join ', ')"
      "  Key       : $($C.PublicKey.Key.KeySize) bit, $($C.SignatureAlgorithm.FriendlyName)"
      "  Valid     : $($C.NotBefore.ToString('yyyy-MM-dd')) -> $($C.NotAfter.ToString('yyyy-MM-dd')) ($([math]::Round(($C.NotAfter - $C.NotBefore).TotalDays / 365.25, 1)) years)"
      "  Thumbprint: $($C.Thumbprint)")
}
function Get-Info($C) {
    $uri = ''; foreach ($e in $C.Extensions) { if ($e.Oid.Value -eq '2.5.29.17' -and $e.Format($false) -match 'URL=([^,]+)') { $uri = $Matches[1] } }
    @{ Subject = $C.Subject; Uri = $uri; Key = $C.PublicKey.Key.KeySize; Sig = $C.SignatureAlgorithm.Value; Years = [math]::Round(($C.NotAfter - $C.NotBefore).TotalDays / 365.25) }
}

New-Item -ItemType Directory -Path $work -Force | Out-Null
Say "Data Analyzer certificate test - $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - user $env:USERDOMAIN\$env:USERNAME"
Say "Data Analyzer: $DaDir   test stores: $work\CertificateStores   connect to: $Url"
Say ''

# -- Data Analyzer's own certificate (reference) ----------------------------------------
Say '== 1. Data Analyzer''s own certificate =='
$orig = Get-ChildItem -LiteralPath (Join-Path $DaDir 'CertificateStores\App\certs') -Filter '*.der' -File -ErrorAction SilentlyContinue | Select-Object -First 1
$origCert = if ($orig) { New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $orig.FullName } else { $null }
Describe $origCert | ForEach-Object { Say $_ }
Say ''

# -- same library, licence and name as Data Analyzer --------------------------------------
Say '== 2. First connect as Data Analyzer would (test stores) =='
$onResolve = [System.ResolveEventHandler] {
    param($sender, $e)
    $p = Join-Path $DaDir ((New-Object System.Reflection.AssemblyName $e.Name).Name + '.dll')
    if (Test-Path -LiteralPath $p) { return [System.Reflection.Assembly]::LoadFrom($p) }
    return $null
}
[System.AppDomain]::CurrentDomain.add_AssemblyResolve($onResolve)
try {
    [void][System.Reflection.Assembly]::LoadFrom((Join-Path $DaDir 'Opc.UaFx.Client.dll'))
    $lic = Join-Path $DaDir 'License.txt'
    if (Test-Path -LiteralPath $lic) {
        [Opc.UaFx.Client.Licenser]::LicenseKey = (Get-Content -LiteralPath $lic -TotalCount 1)
        Say "  licence: $lic"
    } else { Say "  licence: $lic not found (the library may run in its evaluation mode)" }

    [xml]$cfg = Get-Content -LiteralPath (Join-Path $DaDir 'DataAnalyzer.exe.config') -Raw
    $setting = { param($k) ($cfg.SelectNodes('//add') | Where-Object { $_.key -eq $k } | Select-Object -First 1).value }
    $user = & $setting 'Opc_User'
    $pwd  = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((& $setting 'Opc_EncryptedPassword')))   # Data Analyzer: Base64Decode

    $client = New-Object Opc.UaFx.Client.OpcClient $Url
    $client.Configuration.ApplicationName = 'APC Data Analyzer'          # what the library takes from DataAnalyzer.exe
    $stores = Join-Path $work 'CertificateStores'
    $client.CertificateStores.ApplicationStore.Path   = Join-Path $stores 'App'
    $client.CertificateStores.TrustedPeerStore.Path   = Join-Path $stores 'Trusted'
    $client.CertificateStores.TrustedIssuerStore.Path = Join-Path $stores 'TrustedIssuer'
    $client.CertificateStores.RejectedStore.Path      = Join-Path $stores 'Rejected'
    $client.Security.UserIdentity   = New-Object Opc.UaFx.Client.OpcClientIdentity $user, $pwd
    $client.Security.EndpointPolicy = New-Object Opc.UaFx.OpcSecurityPolicy ([Opc.UaFx.OpcSecurityMode]::SignAndEncrypt), ([Opc.UaFx.OpcSecurityAlgorithm]::Basic256)
    Say "  application name: $($client.Configuration.ApplicationName)   store: $($client.CertificateStores.ApplicationStore.Path)"
    try { $client.Connect(); Say "  connected (state $($client.State))" }
    catch { Say "  connect: $($_.Exception.GetBaseException().Message)  (expected with the default URL)" }
    finally { try { $client.Disconnect() } catch { } ; try { $client.Dispose() } catch { } }
} catch {
    $e = $_.Exception
    Say "  ERROR: $($e.GetType().FullName): $($e.Message)"
    while ($e.InnerException) { $e = $e.InnerException; Say "    inner: $($e.GetType().FullName): $($e.Message)" }
    Finish 2
}
Say ''

# -- compare -------------------------------------------------------------------------------
Say '== 3. Certificate made by the test =='
$made = Get-ChildItem -LiteralPath (Join-Path $stores 'App') -Recurse -Filter '*.der' -File -ErrorAction SilentlyContinue | Select-Object -First 1
$madeCert = if ($made) { New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $made.FullName } else { $null }
if ($made) { Say "  file: $($made.FullName.Substring($work.Length + 1))" }
Describe $madeCert | ForEach-Object { Say $_ }
Get-ChildItem -LiteralPath $stores -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { Say "  store file: $($_.FullName.Substring($work.Length + 1))" }
Say ''

Say '== 4. Same as Data Analyzer''s? =='
if (-not $madeCert) { Say '  NO certificate was made: the library did not create one before the connect. Re-run with -Url opc.tcp://localhost:48020'; Finish 3 }
if (-not $origCert) { Say '  Data Analyzer has no certificate to compare with (it never connected on this VM).'; Finish 4 }
$a = Get-Info $origCert; $b = Get-Info $madeCert
$diff = @(foreach ($k in 'Subject', 'Uri', 'Key', 'Sig', 'Years') { if ("$($a[$k])" -ne "$($b[$k])") { "  differs: $k  Data Analyzer '$($a[$k])'  test '$($b[$k])'" } })
if ($diff) { $diff | ForEach-Object { Say $_ }; Say '  RESULT: DIFFERENT - see above'; Finish 1 }
Say '  RESULT: SAME subject, application URI, key, signature and validity -> the wizard can make it for Data Analyzer'
[System.AppDomain]::CurrentDomain.remove_AssemblyResolve($onResolve)
Finish 0
