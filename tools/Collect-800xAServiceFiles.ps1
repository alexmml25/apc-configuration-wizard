#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only: zips the 800xA service / calculation files needed to automate the D01558132 section 1.4 service
    reset and the Calculation Status Viewer check, plus the latest services discovery report. Changes nothing.
.DESCRIPTION
    Collects into C:\APC_Config\Logs\800xA-service-files_<ts>.zip:
      - from the 800xA bin folder: AfwServiceManager.exe (+ .config), AfwServiceAspects.dll,
        AfwServiceClientHelper.dll, AfwServiceViews.dll
      - the files behind the COM classes ABB.CalcServiceServer, ABB.AfwAdminServiceProvider, ABB.AfwAdminServiceGroup,
        ABB.AfwServiceProviderIdObj (InprocServer32 / LocalServer32), and the .NET assemblies next to the
        calculation server whose names contain "Calc"
      - the newest C:\APC_Config\Logs\chmi-services_*.txt
    Copy the zip to the project folder (the ABB files are git-ignored there).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Collect-800xAServiceFiles.ps1
#>
param(
    [string]$BinDir = 'C:\Program Files (x86)\ABB 800xA\Base\bin',
    [string]$OutDir = 'C:\APC_Config\Logs'
)

$ts    = Get-Date -Format 'yyyyMMdd_HHmmss'
$stage = Join-Path $env:TEMP "800xA-service-files_$ts"
$zip   = Join-Path $OutDir "800xA-service-files_$ts.zip"
New-Item -ItemType Directory -Path $stage, $OutDir -Force | Out-Null
$list = New-Object System.Collections.Generic.List[string]

function Add-File([string]$Path, [string]$Why) {
    $Path = [Environment]::ExpandEnvironmentVariables($Path.Trim('"'))
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { $list.Add("MISSING  $Path  ($Why)"); return }
    $dest = Join-Path $stage (Split-Path $Path -Leaf)
    if (-not (Test-Path -LiteralPath $dest)) { Copy-Item -LiteralPath $Path -Destination $dest -Force }
    $list.Add("added    $Path  ($Why)")
}

foreach ($f in 'AfwServiceManager.exe', 'AfwServiceManager.exe.config', 'AfwServiceAspects.dll', 'AfwServiceClientHelper.dll', 'AfwServiceViews.dll') {
    Add-File (Join-Path $BinDir $f) 'service manager / aspects'
}

# the files behind the COM classes (32-bit view: this runs in either PowerShell, so check both registry views)
foreach ($progId in 'ABB.CalcServiceServer', 'ABB.AfwAdminServiceProvider', 'ABB.AfwAdminServiceGroup', 'ABB.AfwServiceProviderIdObj') {
    $clsid = $null
    foreach ($root in 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes', 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Classes') {
        $c = (Get-ItemProperty -LiteralPath "$root\$progId\CLSID" -ErrorAction SilentlyContinue).'(default)'
        if ($c) { $clsid = $c; break }
    }
    if (-not $clsid) { $list.Add("MISSING  $progId (not registered)"); continue }
    foreach ($root in 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Classes\CLSID', 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\CLSID') {
        foreach ($k in 'InprocServer32', 'LocalServer32') {
            $v = (Get-ItemProperty -LiteralPath "$root\$clsid\$k" -ErrorAction SilentlyContinue).'(default)'
            if ($v) {
                $exe = ($v -replace '^"([^"]+)".*$', '$1') -replace '\s+[-/].*$', ''
                Add-File $exe "$progId $k"
                if ($progId -eq 'ABB.CalcServiceServer') {
                    Get-ChildItem -LiteralPath (Split-Path $exe -Parent) -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match 'Calc' -and $_.Extension -in '.dll', '.exe', '.config' } |
                        ForEach-Object { Add-File $_.FullName 'next to the calculation server' }
                }
            }
        }
    }
}

$disc = Get-ChildItem -LiteralPath $OutDir -Filter 'chmi-services_*.txt' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
if ($disc) { Add-File $disc.FullName 'latest services discovery report' }

$list | Set-Content -Path (Join-Path $stage 'CONTENTS.txt')
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
Remove-Item -LiteralPath $stage -Recurse -Force
$list | ForEach-Object { $_ }
"Written: $zip"
