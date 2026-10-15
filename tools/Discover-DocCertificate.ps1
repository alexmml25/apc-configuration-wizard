#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only: where DOC's OPC UA client certificate ("OPC-UA-API", per user) and its trust list live, so Step 9 can
    trust DOC in deviceWise and deviceWise in DOC. Changes nothing.
.DESCRIPTION
    Writes C:\APC_Config\Logs\doc-cert_<ts>.txt (and copies DocOpcUa.xml of DOC-1 next to it):
      - the deviceWise OPC UA server stores (trusted / rejected) with subject, thumbprint and date
      - Windows certificate stores of this user and of the machine: any certificate whose subject contains
        OPC-UA-API / DOC, or whose thumbprint is in deviceWise's rejected store
      - profile and ProgramData folders that look like OPC UA certificate stores (pki, CertificateStores,
        'OPC Foundation', *.der / *.pfx named OPC-UA-API)
      - DocOpcUa.xml (DOC-1): every line about endpoint, security, certificate, store, trust
    Run as the account DOC runs as (the service account), the same session the wizard uses.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Discover-DocCertificate.ps1
#>
param(
    [string]$ManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'APC_ConfigManifest.json'),
    [string]$OutDir = 'C:\APC_Config\Logs',
    [string]$Name = 'OPC-UA-API'
)

$ErrorActionPreference = 'Continue'
$m  = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$out   = Join-Path $OutDir "doc-cert_$ts.txt"
$lines = [System.Collections.Generic.List[string]]::new()
function W([string]$Text = '') { $lines.Add($Text); Write-Host $Text }
$X509 = 'System.Security.Cryptography.X509Certificates.X509Certificate2'
function Load($Path) { try { New-Object $X509 $Path } catch { $null } }

W "DOC certificate discovery  $(Get-Date -Format s)  on $env:COMPUTERNAME as $env:USERDOMAIN\$env:USERNAME  (profile $env:USERPROFILE)"

# -- 1. deviceWise server stores ---------------------------------------------------------------------------
W ''; W '== deviceWise OPC UA server stores =='
$pki = ([string]$m.DeviceWise.GatewayInstallDir).TrimEnd('\') + '\staging\uaserver\pkiserver'
$rejectedThumbs = @()
foreach ($sub in 'trusted', 'rejected', 'issuers', 'own') {
    foreach ($f in Get-ChildItem (Join-Path $pki $sub) -Recurse -File -ErrorAction SilentlyContinue) {
        $c = Load $f.FullName
        W ("  {0,-9} {1:s}  {2}  {3}  {4}" -f $sub, $f.LastWriteTime, $(if ($c) { $c.Thumbprint } else { '?' }), $(if ($c) { $c.Subject } else { '' }), $f.FullName.Substring($pki.Length + 1))
        if ($c -and $sub -eq 'rejected') { $rejectedThumbs += $c.Thumbprint }
    }
}

# -- 2. Windows certificate stores ------------------------------------------------------------------------
W ''; W "== Windows certificate stores (subject like *$Name* / *DOC*, or thumbprint in deviceWise rejected) =="
foreach ($loc in 'CurrentUser', 'LocalMachine') {
    foreach ($store in Get-ChildItem "Cert:\$loc" -ErrorAction SilentlyContinue) {
        foreach ($c in Get-ChildItem $store.PSPath -ErrorAction SilentlyContinue) {
            if ($c.Subject -like "*$Name*" -or $c.Subject -match '\bDOC\b' -or $rejectedThumbs -contains $c.Thumbprint) {
                W ("  Cert:\{0}\{1}  {2}  {3}  key={4}  {5:d} -> {6:d}" -f $loc, $store.Name, $c.Thumbprint, $c.Subject, $c.HasPrivateKey, $c.NotBefore, $c.NotAfter)
                foreach ($ext in $c.Extensions | Where-Object { $_.Oid.FriendlyName -eq 'Subject Alternative Name' }) { W "      SAN: $($ext.Format($false))" }
            }
        }
    }
}

# -- 3. folders that look like OPC UA stores ---------------------------------------------------------------
W ''; W '== OPC UA store folders in the profile / ProgramData (newest 60) =='
$roots = @($env:APPDATA, $env:LOCALAPPDATA, $env:USERPROFILE, $env:ProgramData, (Join-Path $env:ProgramData 'OPC Foundation')) | Where-Object { $_ } | Select-Object -Unique
$hits = foreach ($r in $roots) {
    Get-ChildItem $r -Recurse -File -Depth 6 -ErrorAction SilentlyContinue |
        Where-Object { ($_.Extension -in '.der', '.pfx', '.pem', '.crt') -and ($_.FullName -match 'pki|Certificate|OPC|UA' -or $_.Name -like "*$Name*") }
}
$hits | Sort-Object FullName -Unique | Sort-Object LastWriteTime -Descending | Select-Object -First 60 | ForEach-Object {
    $c = if ($_.Extension -ne '.pfx') { Load $_.FullName }
    W ("  {0:s}  {1}  {2}" -f $_.LastWriteTime, $_.FullName, $(if ($c) { "$($c.Thumbprint) $($c.Subject)" } else { '' }))
}

# -- 4. DocOpcUa.xml -------------------------------------------------------------------------------------
W ''; W '== DocOpcUa.xml (DOC-1): endpoint / security / certificate / store lines =='
$docXml = Join-Path (([string]$m.DOC.BasePath).Replace('{N}', '1')) 'Plugins\OPC UA\DocOpcUa.xml'
if (Test-Path $docXml) {
    Copy-Item $docXml (Join-Path $OutDir "DocOpcUa_DOC-1_$ts.xml") -Force
    W "  copied to $(Join-Path $OutDir "DocOpcUa_DOC-1_$ts.xml")"
    $n = 0
    foreach ($l in Get-Content $docXml) {
        $n++
        if ($l -match 'opc\.tcp|Endpoint|Security|Certificat|Store|Trust|Pki|Subject|Application|User|Password|Url') {
            W ("  {0,5}: {1}" -f $n, ($l.Trim() -replace '(?i)(password[^>]*>)[^<]*', '$1***'))
        }
    }
} else { W "  not found: $docXml" }

$lines | Set-Content -Path $out
W ''; W "Written: $out"
