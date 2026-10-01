#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only discovery of the deviceWISE Gateway API on this VM.
.DESCRIPTION
    Collects what is needed to rewrite the wizard's deviceWISE steps (04-07, 12):
      - deviceWISE services, their executables and the TCP ports they listen on
      - HTTP/HTTPS responses from those ports on common API / docs paths
      - API docs, help files and config files under the deviceWISE install folders
    Nothing is changed. The only requests sent are GETs and one POST of an empty
    JSON object to /api, which the gateway rejects without acting on it.
    Output: C:\APC_Config\Logs\dw-discovery-<timestamp>.txt
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Discover-DeviceWiseApi.ps1
#>

$ErrorActionPreference = 'Continue'
$ts      = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir  = 'C:\APC_Config\Logs'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$outFile = Join-Path $outDir "dw-discovery-$ts.txt"

function Out-Section([string]$Title) { "`r`n===== $Title =====" | Tee-Object -FilePath $outFile -Append }
function Out-Line([string]$Text)     { $Text | Tee-Object -FilePath $outFile -Append }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }   # self-signed gateway certs, this process only

Out-Line "deviceWISE API discovery - $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

#region -- Services and listening ports ----------------------------------------

Out-Section 'deviceWISE services'
$services = Get-CimInstance Win32_Service | Where-Object { $_.Name -like 'dw*' -or $_.DisplayName -like '*deviceWISE*' }
$pids = @()
foreach ($s in $services) {
    Out-Line ("{0,-12} {1,-8} PID {2,-6} {3}" -f $s.Name, $s.State, $s.ProcessId, $s.PathName)
    if ($s.ProcessId) { $pids += $s.ProcessId }
}
foreach ($p in Get-Process | Where-Object { $_.Path -like '*deviceWISE*' }) {
    if ($pids -notcontains $p.Id) { $pids += $p.Id; Out-Line "process    PID $($p.Id)  $($p.Path)" }
}

Out-Section 'Listening TCP ports (deviceWISE processes)'
$ports = @()
foreach ($c in Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $pids -contains $_.OwningProcess }) {
    $proc = (Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue).ProcessName
    Out-Line ("{0,-15} {1,-6} {2}" -f $c.LocalAddress, $c.LocalPort, $proc)
    if ($ports -notcontains $c.LocalPort) { $ports += $c.LocalPort }
}
foreach ($p in 8080, 8090, 8100, 8001, 443, 4012) { if ($ports -notcontains $p) { $ports += $p } }

#endregion

#region -- HTTP probes ----------------------------------------------------------

Out-Section 'HTTP probes'
$paths = '/', '/api', '/api/v2/version', '/api/version', '/swagger', '/swagger/index.html',
         '/api-docs', '/openapi.json', '/swagger.json', '/help', '/rest', '/workbench'

function Invoke-Probe([string]$Uri, [string]$Method = 'GET', [string]$Body = $null) {
    try {
        $req = [Net.HttpWebRequest]::Create($Uri)
        $req.Method = $Method; $req.Timeout = 4000; $req.ReadWriteTimeout = 4000
        if ($Body) {
            $req.ContentType = 'application/json'
            $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
            $req.ContentLength = $bytes.Length
            $s = $req.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
        }
        $resp = $req.GetResponse()
    } catch [Net.WebException] {
        $resp = $_.Exception.Response
        if (-not $resp) { return $null }   # connection refused / timeout
    } catch { return $null }
    $reader = New-Object IO.StreamReader($resp.GetResponseStream())
    $text   = $reader.ReadToEnd(); $reader.Close()
    $server = $resp.Headers['Server']
    $result = [pscustomobject]@{
        Status      = [int]$resp.StatusCode
        ContentType = $resp.ContentType
        Server      = $server
        Body        = ($text -replace '\s+', ' ')
    }
    $resp.Close()
    return $result
}

foreach ($port in $ports) {
    foreach ($scheme in 'http', 'https') {
        $root = Invoke-Probe "${scheme}://localhost:$port/"
        if (-not $root) { continue }
        Out-Line "--- ${scheme}://localhost:$port  (Server: $($root.Server))"
        foreach ($path in $paths) {
            $r = if ($path -eq '/') { $root } else { Invoke-Probe "${scheme}://localhost:$port$path" }
            if ($r) {
                $snippet = $r.Body.Substring(0, [Math]::Min(300, $r.Body.Length))
                Out-Line ("  GET  {0,-22} {1}  {2}  {3}" -f $path, $r.Status, $r.ContentType, $snippet)
            }
        }
        $r = Invoke-Probe "${scheme}://localhost:$port/api" 'POST' '{}'
        if ($r) {
            $snippet = $r.Body.Substring(0, [Math]::Min(500, $r.Body.Length))
            Out-Line ("  POST {0,-22} {1}  {2}  {3}" -f '/api {}', $r.Status, $r.ContentType, $snippet)
        }
    }
}

#endregion

#region -- Install folders: docs, help and config -----------------------------

$roots = @(
    'C:\Program Files\deviceWISE', 'C:\Program Files (x86)\deviceWISE',
    'C:\ProgramData\deviceWISE', "$env:APPDATA\deviceWISE", "$env:LOCALAPPDATA\deviceWISE"
) | Where-Object { Test-Path $_ }

Out-Section 'Install folders'
$roots | ForEach-Object { Out-Line $_ }

Out-Section 'API docs / help files'
foreach ($root in $roots) {
    Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'api|swagger|openapi|rest|json-?rpc|sdk|command' -or $_.Extension -in '.chm', '.pdf' } |
        Where-Object { $_.FullName -notmatch '\\staging\\' } |
        Select-Object -First 200 |
        ForEach-Object { Out-Line ("{0,10:N0}  {1}" -f $_.Length, $_.FullName) }
}

Out-Section 'Config lines mentioning ports / HTTP / API'
foreach ($root in $roots) {
    Get-ChildItem $root -Recurse -File -Include *.cfg, *.conf, *.ini, *.xml, *.properties, *.json -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -lt 1MB -and $_.FullName -notmatch '\\staging\\' } |
        Select-String -Pattern 'port|http|api|rest|webserver|web_server|listen' -ErrorAction SilentlyContinue |
        Select-Object -First 300 |
        ForEach-Object { Out-Line ("{0}:{1}: {2}" -f $_.Path, $_.LineNumber, $_.Line.Trim()) }
}

#endregion

Out-Section 'Done'
Out-Line "Saved to $outFile"
