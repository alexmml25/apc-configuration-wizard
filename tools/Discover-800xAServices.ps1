#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only: how 800xA keeps service providers (Enabled) and calculations, for Step 11's service reset
    (D01558132 section 1.4) and the Calculation Status Viewer check. Changes nothing.
.DESCRIPTION
    Through the 800xA .NET API (32-bit; restarts itself in 32-bit PowerShell if needed):
      1. every Service Provider object (object type {3F053B31-CB33-11d2-8577-0060B0CEAB60}): name, and its aspects
         (name, aspect type, category) - to find the "Service Provider Definition" aspect that holds Enabled
      2. the aspects of the Calculation Server objects - to find the Calculation Status Viewer
      3. 800xA bin files and 32-bit COM ProgIDs about services / calculations (the API behind those aspects)
    Output: C:\APC_Config\Logs\chmi-services_<ts>.txt
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Discover-800xAServices.ps1
#>
param(
    [string]$BinDir = 'C:\Program Files (x86)\ABB 800xA\Base\bin',
    [string]$OutDir = 'C:\APC_Config\Logs'
)

if ([Environment]::Is64BitProcess -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $ps32 = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    & $ps32 -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath -BinDir $BinDir -OutDir $OutDir
    exit $LASTEXITCODE
}

$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$outFile = Join-Path $OutDir "chmi-services_$ts.txt"
$report  = New-Object System.Collections.Generic.List[string]
function Say([string]$Text) { $report.Add($Text); Write-Host $Text }
function Fail([string]$What, $Err) {
    $e = if ($Err -is [System.Management.Automation.ErrorRecord]) { $Err.Exception } else { $Err }
    Say "  ERROR in ${What}: $($e.GetType().FullName): $($e.Message)"
    while ($e.InnerException) { $e = $e.InnerException; Say "    inner: $($e.GetType().FullName): $($e.Message)" }
}
function Finish([int]$Code) { $report | Out-File -FilePath $outFile -Width 400 -Encoding UTF8; "Written: $outFile"; exit $Code }

Say "800xA services / calculations discovery - $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - user $env:USERDOMAIN\$env:USERNAME"
Say ''

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
try { [void][System.Reflection.Assembly]::LoadFrom((Join-Path $BinDir 'ABB.xA.Base.dll')) } catch { Fail 'loading ABB.xA.Base.dll' $_; Finish 1 }

try { $aos = [ABB.xA.Base.System800xA]::GetCurrent().GetBaseServices().AspectObjectsServices }
catch { Fail 'connecting to 800xA' $_; Finish 2 }

# id types live in another ABB assembly: take them from the method signatures
$aosType = [ABB.xA.Base.IAspectObjectsServices]
$mEnum   = $aosType.GetMethod('CreateObjectEnumerator')
$tTrack  = $mEnum.GetParameters()[1].ParameterType
$tObjDet = $mEnum.GetParameters()[2].ParameterType
$tTypeId = [ABB.xA.Base.ObjectQuery].GetProperty('ObjectTypeIds').PropertyType.GetElementType()
$mAll    = $aosType.GetMethods() | Where-Object { $_.Name -eq 'GetAspects' -and $_.GetParameters().Count -eq 1 } | Select-Object -First 1
$mInfo   = $aosType.GetMethod('GetAspectInfo')
$tAspDet = $mInfo.GetParameters()[1].ParameterType

function Get-Objects([string]$TypeGuid) {
    $tid = [Activator]::CreateInstance($tTypeId, [object[]]@($TypeGuid))
    $arr = [Array]::CreateInstance($tTypeId, 1); $arr.SetValue($tid, 0)
    $q   = New-Object ABB.xA.Base.ObjectQuery
    $q.ObjectTypeIds = $arr
    $en  = $mEnum.Invoke($aos, [object[]]@($q, [Enum]::ToObject($tTrack, 0), [Enum]::Parse($tObjDet, 'All')))
    try { @($en | ForEach-Object { $_ }) } finally { $en.Dispose() }
}
function Show-Aspects($ObjectId, [string]$Indent = '    ') {
    $refs  = @($mAll.Invoke($aos, [object[]]@($ObjectId)))
    $infos = @($mInfo.Invoke($aos, [object[]]@($refs, [Enum]::Parse($tAspDet, 'All'))))
    foreach ($i in $infos) {
        $cat = try { $i.AspectCategoryId } catch { '' }
        Say "$Indent- '$($i.Name)'  type $($i.AspectTypeId)  category $cat"
    }
}

# -- 1. service providers --------------------------------------------------------------------------
Say '== 1. Service Provider objects and their aspects =='
try {
    $providers = @(Get-Objects '{3F053B31-CB33-11d2-8577-0060B0CEAB60}' | Where-Object { -not $_.IsDeleted } | Sort-Object Name)
    Say "  $($providers.Count) service provider(s)"
    $want = 'OPC UA Connect|OPC UA Server|Property Expression|Property Transfer|Soft Alarm|Softpoint|SP_|Alarm Manager|Calculation'
    foreach ($p in $providers) {
        $mark = if ($p.Name -match $want) { '*' } else { ' ' }
        Say " $mark $($p.Name)   id $($p.Id)   type $($p.ObjectTypeId)"
        if ($mark -eq '*') { Show-Aspects $p.Id }
    }
} catch { Fail 'service providers' $_ }
Say ''

# -- 2. calculation server objects ------------------------------------------------------------------
Say '== 2. Objects named like Calculation (all types) and their aspects =='
try {
    $q = New-Object ABB.xA.Base.ObjectQuery
    $en = $mEnum.Invoke($aos, [object[]]@($q, [Enum]::ToObject($tTrack, 0), [Enum]::Parse($tObjDet, 'All')))
    try { $calc = @($en | Where-Object { -not $_.IsDeleted -and $_.Name -match 'Calculation' } | ForEach-Object { $_ }) } finally { $en.Dispose() }
    foreach ($o in $calc | Select-Object -First 20) {
        Say "  $($o.Name)   id $($o.Id)   type $($o.ObjectTypeId)"
        Show-Aspects $o.Id
    }
} catch { Fail 'calculation objects' $_ }
Say ''

# -- 3. files and COM ProgIDs ------------------------------------------------------------------------
Say '== 3. 800xA bin files and 32-bit COM ProgIDs (services / calculations) =='
Get-ChildItem -LiteralPath $BinDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Calc|SrvProv|ServiceProv|ServiceMgr|SvcMgr|Afw.*Serv' } |
    ForEach-Object { Say "  file $($_.Name)  $($_.VersionInfo.FileVersion)" }
Get-ChildItem 'Registry::HKEY_CLASSES_ROOT' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^(Afw|ABB).*(Serv|Calc|SrvProv)' } |
    Select-Object -First 80 | ForEach-Object { Say "  progid $($_.PSChildName)" }

[System.AppDomain]::CurrentDomain.remove_AssemblyResolve($onResolve)
Finish 0
