#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only search for the deviceWISE jar that talks to the gateway on ports 4011/4012.
.DESCRIPTION
    dwjavaapi.jar turned out to be the CloudLINK tunnel / M2M Portal client, not the
    gateway admin API. This lists every non-third-party jar under the deviceWISE folders
    with its packages, and the class names that look like gateway administration
    (sessions, variables, triggers, projects, local DB, packages, users, OPC UA ...).
    Only zip entry names are read, so it is quick. Nothing is changed.
    Output: C:\APC_Config\Logs\dw-jar-scan.txt
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Find-DwGatewayClient.ps1
#>
param(
    [string[]]$Roots = @('C:\Program Files\deviceWISE', 'C:\Program Files (x86)\deviceWISE'),
    [string]$OutDir  = 'C:\APC_Config\Logs'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$thirdParty = '^(commons-|httpclient|httpcore|httpmime|jackson|jdom|flatlaf|not-yet-commons|org\.eclipse|relaxng|syntaxpane|wsdl4j|xsom|jaxb|slf4j|log4j|activemq|derby|h2-|hsqldb|jna|bc(prov|pkix)|gson|guava|json-|javax\.|jms|mail|xml|xerces|junit)'
$keywords   = 'gateway|session|login|auth|connect|variable|trigger|project|localdb|database|table|package|licen|opcua|opc_ua|security|user|import|export|device|command|request|api'

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$outFile = Join-Path $OutDir 'dw-jar-scan.txt'
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("deviceWISE jar scan - $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")

$jars = foreach ($root in $Roots | Where-Object { Test-Path $_ }) {
    Get-ChildItem $root -Recurse -File -Include *.jar, *.war -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\jre\\' }
}

$lines.Add("`r`n===== All jars (outside jre) =====")
foreach ($j in $jars | Sort-Object FullName) { $lines.Add(("{0,12:N0}  {1}" -f $j.Length, $j.FullName)) }

foreach ($j in $jars | Where-Object { $_.Name -notmatch $thirdParty } | Sort-Object FullName) {
    try { $zip = [IO.Compression.ZipFile]::OpenRead($j.FullName) } catch { $lines.Add("`r`n## $($j.FullName): cannot open ($_)"); continue }
    try {
        $classes = @($zip.Entries | Where-Object { $_.FullName -like '*.class' } |
                     ForEach-Object { ($_.FullName -replace '\.class$', '') -replace '/', '.' })
        $mainClass = ''
        $mf = $zip.Entries | Where-Object { $_.FullName -eq 'META-INF/MANIFEST.MF' }
        if ($mf) {
            $r = New-Object IO.StreamReader($mf.Open()); $text = $r.ReadToEnd(); $r.Close()
            $mainClass = (($text -split "`r?`n") | Where-Object { $_ -match '^(Main-Class|Class-Path|Implementation-(Title|Version)):' }) -join ' ; '
        }
    } finally { $zip.Dispose() }

    $lines.Add("`r`n## $($j.FullName)  ($($classes.Count) classes)")
    if ($mainClass) { $lines.Add("   manifest: $mainClass") }

    $lines.Add('   packages:')
    $classes | ForEach-Object { $_ -replace '\.[^.]+$', '' } | Group-Object | Sort-Object Name |
        ForEach-Object { $lines.Add(("     {0,5}  {1}" -f $_.Count, $_.Name)) }

    $hits = $classes | Where-Object { $_ -notmatch '\$\d+$' -and (($_ -split '\.')[-1] -match $keywords) } | Sort-Object
    if ($hits) {
        $lines.Add("   matching classes ($(@($hits).Count), first 150):")
        $hits | Select-Object -First 150 | ForEach-Object { $lines.Add("     $_") }
    }
}

$lines | Set-Content -Path $outFile -Encoding UTF8
"Saved to $outFile ($($lines.Count) lines)"
