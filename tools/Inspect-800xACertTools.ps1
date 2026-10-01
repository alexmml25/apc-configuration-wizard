#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only look inside the 800xA certificate tools, to see whether root creation and
    "Update Application Certificates" can be scripted (Step 11, SOP sub-steps 2 and 4).
.DESCRIPTION
    Nothing is run and nothing is changed. The assemblies are loaded reflection-only (metadata only,
    no code executes). The report lists:
      1. ABB.xA.Base.CertificateUtil.exe: its text strings (usage/help text, argument names)
      2. CertificateUtil.exe and ABB.xA.Base.Ua.ManagementPortal.exe: the ABB assemblies they reference
      3. In those assemblies: types and public methods whose names mention certificates, roots, signing,
         trust or stores
      4. The OPC UA config files next to them (ABB.Opc.Ua.*.Config.xml, ManagementPortal .exe.config)
    Output: C:\APC_Config\Logs\chmi-certtools.txt
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Inspect-800xACertTools.ps1
#>
param(
    [string]$BinDir = 'C:\Program Files (x86)\ABB 800xA\Base\bin',
    [string]$OutDir = 'C:\APC_Config\Logs'
)

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$outFile = Join-Path $OutDir 'chmi-certtools.txt'
$report  = New-Object System.Collections.Generic.List[string]
$report.Add("800xA certificate tools - $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$report.Add('')

$keyword = 'Cert|Root|Sign|Trust|Store|Pki|Issuer|Private|Key|Application'

# Resolve references from the 800xA bin folder (and the GAC) during reflection-only loads
$onResolve = [System.ResolveEventHandler] {
    param($sender, $e)
    $name = (New-Object System.Reflection.AssemblyName $e.Name).Name
    foreach ($ext in '.dll', '.exe') {
        $p = Join-Path $BinDir ($name + $ext)
        if (Test-Path -LiteralPath $p) { return [System.Reflection.Assembly]::ReflectionOnlyLoadFrom($p) }
    }
    try { return [System.Reflection.Assembly]::ReflectionOnlyLoad($e.Name) } catch { return $null }
}
[System.AppDomain]::CurrentDomain.add_ReflectionOnlyAssemblyResolve($onResolve)

function Get-Types([System.Reflection.Assembly]$Asm) {
    try { $Asm.GetTypes() } catch [System.Reflection.ReflectionTypeLoadException] { $_.Exception.Types | Where-Object { $_ } }
}

# -- 1. strings in CertificateUtil.exe ---------------------------------------
$util = Join-Path $BinDir 'ABB.xA.Base.CertificateUtil.exe'
$report.Add("== 1. Text strings in $util ==")
if (Test-Path -LiteralPath $util) {
    $bytes = [System.IO.File]::ReadAllBytes($util)
    # .NET user strings are UTF-16; plain ASCII strings cover native code and resources
    $u16 = [regex]::Matches([System.Text.Encoding]::Unicode.GetString($bytes), '[\x20-\x7E]{4,}') | ForEach-Object Value
    $asc = [regex]::Matches([System.Text.Encoding]::ASCII.GetString($bytes), '[\x20-\x7E]{6,}') | ForEach-Object Value
    $report.Add('-- UTF-16 strings --')
    $u16 | Select-Object -Unique | ForEach-Object { $report.Add("  $_") }
    $report.Add('-- ASCII strings with a keyword --')
    $asc | Where-Object { $_ -match $keyword -or $_ -match '^[-/]\w' } | Select-Object -Unique | ForEach-Object { $report.Add("  $_") }
} else { $report.Add('  (not found)') }
$report.Add('')

# -- 2 + 3. referenced ABB assemblies and certificate-related members ----------
$entry = @($util, (Join-Path $BinDir 'ABB.xA.Base.Ua.ManagementPortal.exe')) | Where-Object { Test-Path -LiteralPath $_ }
$seen  = @{}
$queue = New-Object System.Collections.Generic.Queue[string]
foreach ($e in $entry) { $queue.Enqueue($e) }

$report.Add('== 2. ABB assemblies referenced by CertificateUtil and the Management Portal ==')
$asms = New-Object System.Collections.Generic.List[object]
while ($queue.Count) {
    $path = $queue.Dequeue()
    if ($seen.ContainsKey($path)) { continue }
    $seen[$path] = $true
    try { $asm = [System.Reflection.Assembly]::ReflectionOnlyLoadFrom($path) }
    catch { $report.Add("  $([System.IO.Path]::GetFileName($path)): could not load ($($_.Exception.Message))"); continue }
    $asms.Add($asm)
    $refs = @($asm.GetReferencedAssemblies() | Where-Object { $_.Name -match '^(ABB|Afw|Opc)' })
    $report.Add("  $([System.IO.Path]::GetFileName($path)) -> $(($refs | ForEach-Object Name) -join ', ')")
    foreach ($r in $refs) {
        foreach ($ext in '.dll', '.exe') {
            $p = Join-Path $BinDir ($r.Name + $ext)
            # follow only the OPC UA / certificate / base assemblies, not the whole 800xA tree
            if ((Test-Path -LiteralPath $p) -and $r.Name -match 'Ua|Cert|Opc|Security|Base') { $queue.Enqueue($p) }
        }
    }
}
$report.Add('')

$report.Add('== 3. Types and public methods about certificates ==')
$flags = [System.Reflection.BindingFlags]'Public, Instance, Static, DeclaredOnly'
foreach ($asm in $asms) {
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($t in Get-Types $asm) {
        $methods = @()
        try { $methods = @($t.GetMethods($flags) | Where-Object { -not $_.IsSpecialName -and $_.Name -match $keyword }) } catch { }
        if ($t.FullName -notmatch $keyword -and -not $methods) { continue }
        $hits.Add("  [$($t.FullName)]")
        foreach ($m in $methods) {
            $sig = try { ($m.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ', ' } catch { '?' }
            $ret = try { $m.ReturnType.Name } catch { '?' }
            $hits.Add("      $(if ($m.IsStatic) { 'static ' })$ret $($m.Name)($sig)")
        }
    }
    if ($hits.Count) {
        $report.Add("-- $([System.IO.Path]::GetFileName($asm.Location)) --")
        $report.AddRange($hits)
    }
}
$report.Add('')

# -- 4. config files --------------------------------------------------------------
$report.Add('== 4. OPC UA config files ==')
$configs = @(Get-ChildItem -LiteralPath $BinDir -Filter 'ABB.Opc.Ua.*.Config.xml' -File -ErrorAction SilentlyContinue) +
           @(Get-Item -LiteralPath (Join-Path $BinDir 'ABB.xA.Base.Ua.ManagementPortal.exe.config') -ErrorAction SilentlyContinue)
foreach ($c in $configs | Where-Object { $_ }) {
    $report.Add("-- $($c.FullName) --")
    $report.Add([System.IO.File]::ReadAllText($c.FullName))
    $report.Add('')
}

[System.AppDomain]::CurrentDomain.remove_ReflectionOnlyAssemblyResolve($onResolve)
$report | Out-File -FilePath $outFile -Width 400 -Encoding UTF8
"Written: $outFile"
