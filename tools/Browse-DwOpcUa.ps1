#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only: browses the deviceWISE gateway's OPC UA server and prints the CNC devices' variables.
.DESCRIPTION
    Uses the OPC Foundation .NET stack (Opc.Ua.Core / Opc.Ua.Client) that 800xA installs in
    C:\Program Files (x86)\ABB 800xA\Base\bin, copied to C:\APC_Config\OpcUaStack first (800xA's
    files are only read). Connects anonymously with security
    mode None (the gateway allows both), browses Objects for the devices matching -Device and prints
    their child nodes down to -Depth levels with NodeIds; CNCAsset / CNCType are also read.
    The client certificate store is C:\APC_Config\pki (created if needed). Nothing on the gateway
    is changed. Output also saved to C:\APC_Config\Logs\dw-opcua-browse-<timestamp>.txt
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Browse-DwOpcUa.ps1
#>
param(
    [string]$Endpoint = 'opc.tcp://localhost:48020',
    [string]$StackDir = 'C:\Program Files (x86)\ABB 800xA\Base\bin',
    [string]$Device   = '^CNC\d$',
    [int]$Depth       = 2
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path 'C:\APC_Config\Logs' -Force | Out-Null
$out = 'C:\APC_Config\Logs\dw-opcua-browse-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
function Out-Line([string]$t) { Write-Host $t; Add-Content -Path $out -Value $t }

Out-Line "OPC UA browse - $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Endpoint - PowerShell $($PSVersionTable.PSVersion) $(if ([Environment]::Is64BitProcess) { '64-bit' } else { '32-bit' })"

# Same loading as Step 4: the stack is copied to C:\APC_Config\OpcUaStack and loaded from there
function Write-Log { param($Level, $Message) }
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\DeviceWise.ps1')
$Global:DwUaStackSource = $StackDir
$Global:DwUaStackCopy   = 'C:\APC_Config\OpcUaStack'
if (Test-Path $Global:DwUaStackCopy) { Remove-Item (Join-Path $Global:DwUaStackCopy '*') -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $Global:DwUaStackCopy -Force | Out-Null
[AppDomain]::CurrentDomain.add_AssemblyResolve([ResolveEventHandler]{
    param($sender, $e)
    $name = (New-Object Reflection.AssemblyName($e.Name)).Name
    $src  = Join-Path $Global:DwUaStackSource "$name.dll"
    if (-not (Test-Path $src)) { return $null }
    $dst = Join-Path $Global:DwUaStackCopy "$name.dll"
    if (-not (Test-Path $dst)) { Copy-Item $src $dst -Force }
    return [Reflection.Assembly]::LoadFrom($dst)
})
foreach ($dll in 'Opc.Ua.Core.dll', 'Opc.Ua.Client.dll') {
    $f = Join-Path $StackDir $dll
    if (-not (Test-Path $f)) { throw "Not found: $f" }
    $dst = Join-Path $Global:DwUaStackCopy $dll
    Copy-Item $f $dst -Force
    $a = [Reflection.Assembly]::LoadFrom($dst)
    Out-Line ("Loaded {0} {1} (file {2}, copy in {3})" -f $a.GetName().Name, $a.GetName().Version, (Get-Item $f).VersionInfo.FileVersion, $Global:DwUaStackCopy)
}
Get-ChildItem $StackDir -Filter 'Opc.Ua*.dll' | ForEach-Object { Out-Line ("  available: {0}" -f $_.Name) }

function Wait-Task($r) { if ($r -is [Threading.Tasks.Task]) { $r.GetAwaiter().GetResult() } else { $r } }

#region -- Client configuration (anonymous, security None) ---------------------

$pki = 'C:\APC_Config\pki'
$cfg = New-Object Opc.Ua.ApplicationConfiguration
$cfg.ApplicationName = 'APC Config Wizard'
$cfg.ApplicationUri  = "urn:$($env:COMPUTERNAME):APCConfigWizard"
$cfg.ApplicationType = [Opc.Ua.ApplicationType]::Client
$sec = New-Object Opc.Ua.SecurityConfiguration
$sec.ApplicationCertificate = New-Object Opc.Ua.CertificateIdentifier
$sec.ApplicationCertificate.StoreType   = 'Directory'
$sec.ApplicationCertificate.StorePath   = "$pki\own"
$sec.ApplicationCertificate.SubjectName = 'CN=APC Config Wizard'
$sec.TrustedPeerCertificates   = New-Object Opc.Ua.CertificateTrustList
$sec.TrustedPeerCertificates.StoreType = 'Directory'; $sec.TrustedPeerCertificates.StorePath = "$pki\trusted"
$sec.TrustedIssuerCertificates = New-Object Opc.Ua.CertificateTrustList
$sec.TrustedIssuerCertificates.StoreType = 'Directory'; $sec.TrustedIssuerCertificates.StorePath = "$pki\issuer"
$sec.RejectedCertificateStore  = New-Object Opc.Ua.CertificateTrustList
$sec.RejectedCertificateStore.StoreType = 'Directory'; $sec.RejectedCertificateStore.StorePath = "$pki\rejected"
$sec.AutoAcceptUntrustedCertificates = $true
$cfg.SecurityConfiguration = $sec
$cfg.TransportQuotas = New-Object Opc.Ua.TransportQuotas
$cfg.TransportQuotas.OperationTimeout = 15000
$cfg.ClientConfiguration = New-Object Opc.Ua.ClientConfiguration
$cfg.ClientConfiguration.DefaultSessionTimeout = 60000
[void](Wait-Task ($cfg.Validate([Opc.Ua.ApplicationType]::Client)))
$cfg.CertificateValidator.add_CertificateValidation([Opc.Ua.CertificateValidationEventHandler]{ param($s, $e) $e.Accept = $true })
Out-Line 'Client configuration validated.'

#endregion

#region -- Connect -------------------------------------------------------------

$epDesc = [Opc.Ua.Client.CoreClientUtils]::SelectEndpoint($Endpoint, $false, 15000)
Out-Line ("Endpoint: {0}  mode {1}  policy {2}" -f $epDesc.EndpointUrl, $epDesc.SecurityMode, $epDesc.SecurityPolicyUri)
$epCfg = [Opc.Ua.EndpointConfiguration]::Create($cfg)
$cep   = New-Object Opc.Ua.ConfiguredEndpoint($null, $epDesc, $epCfg)
$session = Wait-Task ([Opc.Ua.Client.Session]::Create($cfg, $cep, $false, 'APC wizard browse', 60000, (New-Object Opc.Ua.UserIdentity), $null))
Out-Line "Session open. Namespaces:"
for ($i = 0; $i -lt $session.NamespaceUris.Count; $i++) { Out-Line ("  ns={0} {1}" -f $i, $session.NamespaceUris.GetString($i)) }

#endregion

#region -- Browse ----------------------------------------------------------------

function Get-Children($nodeId) {
    $b = New-Object Opc.Ua.Client.Browser($session)
    $b.BrowseDirection = [Opc.Ua.BrowseDirection]::Forward
    $b.ReferenceTypeId = [Opc.Ua.ReferenceTypeIds]::HierarchicalReferences
    $b.IncludeSubtypes = $true
    $b.NodeClassMask   = 0
    return @($b.Browse($nodeId))
}
function Show-Tree($nodeId, [int]$level, [string]$indent) {
    foreach ($r in Get-Children $nodeId) {
        $id = [Opc.Ua.ExpandedNodeId]::ToNodeId($r.NodeId, $session.NamespaceUris)
        $line = "{0}{1}  [{2}]  {3}" -f $indent, $r.DisplayName.Text, $r.NodeClass, $id
        if ($r.NodeClass -eq [Opc.Ua.NodeClass]::Variable -and $r.DisplayName.Text -match '^(CNCAsset|CNCType)$') {
            try { $v = $session.ReadValue($id); $line += "  = '$($v.Value)' ($($v.StatusCode))" } catch { $line += "  (read failed: $($_.Exception.Message))" }
        }
        Out-Line $line
        if ($level -lt $Depth) { Show-Tree $id ($level + 1) ($indent + '    ') }
    }
}

try {
    Out-Line "`r`nObjects:"
    foreach ($r in Get-Children ([Opc.Ua.ObjectIds]::ObjectsFolder)) {
        $id = [Opc.Ua.ExpandedNodeId]::ToNodeId($r.NodeId, $session.NamespaceUris)
        Out-Line ("  {0}  [{1}]  {2}" -f $r.DisplayName.Text, $r.NodeClass, $id)
        if ($r.DisplayName.Text -match $Device) { Show-Tree $id 1 '      ' }
    }
} finally {
    [void]$session.Close()
}

#endregion

Out-Line "`r`nSaved to $out"
