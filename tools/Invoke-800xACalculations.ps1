#Requires -Version 5.1
<#
.SYNOPSIS
    The Calculation Status Viewer check of D01558132 section 1.4: every 800xA calculation enabled and without error;
    with -Confirmed, a disabled or errored calculation is enabled again (the viewer's right-click > Enable).
.DESCRIPTION
    Inform IT Calculations (C:\Program Files (x86)\ABB Industrial IT\Inform IT\Calculations\bin) publishes the
    calculation aspect's object as ICalculationASO (Calculation.dll type library, IDispatch): Enabled, Status
    (0 = OK), StatusMessage, DisableOnError, Online. Through the 800xA .NET API (32-bit; restarts itself in 32-bit
    PowerShell if needed):
      1. the interface id of ICalculationASO, read from Calculation.dll's type library (not hard-coded)
      2. every aspect that offers it (CreateAspectEnumerator with an AspectQuery on that operation id)
      3. per calculation, over OPC DA (OPC.Automation -> ABB.AfwOpcDaSurrogate.1): "{object}{aspect}:Enabled",
         ":Status", ":StatusMessage" - the aspect properties are RW (the .NET API does not hand out ICalculationASO)
      4. -Confirmed: Enabled false, or Status not 0 -> Enabled = false then true over OPC (re-enable), wait, read again
    Exit codes: 0 all enabled and Status 0 (or no calculations), 1 problems found (report only), 5 problems left
    after re-enabling, 7 no running calculation could be read (aspects with no running calculation behind them are
    object type definitions: counted, not checked), 2 cannot connect to 800xA, 6 Inform IT
    Calculations not found. Only problems are listed (SJUM7AAPPS0048 has 602 calculation aspects).
    Output: C:\APC_Config\Logs\chmi-calcs_<ts>.txt
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Invoke-800xACalculations.ps1              # check only
    powershell -ExecutionPolicy Bypass -File .\tools\Invoke-800xACalculations.ps1 -Confirmed   # check + re-enable
#>
param(
    [switch]$Confirmed,
    [string]$BinDir     = 'C:\Program Files (x86)\ABB 800xA\Base\bin',
    [string]$CalcBinDir = 'C:\Program Files (x86)\ABB Industrial IT\Inform IT\Calculations\bin',
    [int]$WaitSeconds   = 15,
    [string]$OutDir     = 'C:\APC_Config\Logs'
)

if ([Environment]::Is64BitProcess -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $ps32 = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    $argz = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-BinDir', $BinDir,
              '-CalcBinDir', $CalcBinDir, '-WaitSeconds', $WaitSeconds, '-OutDir', $OutDir)
    if ($Confirmed) { $argz += '-Confirmed' }
    & $ps32 @argz
    exit $LASTEXITCODE
}

$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$outFile = Join-Path $OutDir "chmi-calcs_$ts.txt"
$report  = New-Object System.Collections.Generic.List[string]
function Say([string]$Text) { $report.Add($Text); Write-Host $Text }
function Fail([string]$What, $Err) {
    $e = if ($Err -is [System.Management.Automation.ErrorRecord]) { $Err.Exception } else { $Err }
    Say "  ERROR in ${What}: $($e.GetType().FullName): $($e.Message)"
    while ($e.InnerException) { $e = $e.InnerException; Say "    inner: $($e.GetType().FullName): $($e.Message)" }
}
function Finish([int]$Code) { $report | Out-File -FilePath $outFile -Width 300 -Encoding UTF8; "Written: $outFile"; exit $Code }

Say "800xA calculations - $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - user $env:USERDOMAIN\$env:USERNAME"
Say "Mode: $(if ($Confirmed) { 'CHECK + RE-ENABLE (confirmed)' } else { 'check only (no -Confirmed)' })"
Say ''

# -- 1. interface id of ICalculationASO from the type library ------------------------------------
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class ApcCalcTlb {
    [DllImport("oleaut32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void LoadTypeLibEx(string file, int regKind, [MarshalAs(UnmanagedType.Interface)] out object typeLib);
    // the GUID of the interface with that name, from a type library (REGKIND_NONE: load only, never register)
    public static string InterfaceId(string file, string name) {
        object o; LoadTypeLibEx(file, 2, out o);
        ITypeLib tlb = (ITypeLib)o;
        int n = tlb.GetTypeInfoCount();
        for (int i = 0; i < n; i++) {
            string tname, doc, help; int ctx;
            tlb.GetDocumentation(i, out tname, out doc, out ctx, out help);
            if (!string.Equals(tname, name, StringComparison.OrdinalIgnoreCase)) continue;
            ITypeInfo ti; tlb.GetTypeInfo(i, out ti);
            IntPtr p; ti.GetTypeAttr(out p);
            try { return ((System.Runtime.InteropServices.ComTypes.TYPEATTR)Marshal.PtrToStructure(p, typeof(System.Runtime.InteropServices.ComTypes.TYPEATTR))).guid.ToString("B").ToUpperInvariant(); }
            finally { ti.ReleaseTypeAttr(p); }
        }
        return null;
    }
}
'@
$calcDll = Join-Path $CalcBinDir 'Calculation.dll'
if (-not (Test-Path -LiteralPath $calcDll)) { Say "Inform IT Calculations not found: $calcDll"; Finish 6 }
try { $iid = [ApcCalcTlb]::InterfaceId($calcDll, 'ICalculationASO') } catch { Fail 'reading the Calculation.dll type library' $_; Finish 6 }
if (-not $iid) { Say "ICalculationASO not in the Calculation.dll type library"; Finish 6 }
Say "ICalculationASO: $iid"

# -- 2. every calculation aspect ------------------------------------------------------------------
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
    [void][System.Reflection.Assembly]::LoadFrom((Join-Path $BinDir 'ABB.xA.Base.dll'))
    $aos = [ABB.xA.Base.System800xAExtensions]::GetBaseServices([ABB.xA.Base.System800xA]::GetCurrent()).AspectObjectsServices
} catch { Fail 'connecting to 800xA' $_; Finish 2 }

function Invoke-M($Method, $Target, [object[]]$Arguments) {
    # MethodInfo.Invoke needs plain .NET objects; the comma keeps a returned enumerator from being unrolled
    $plain = New-Object object[] $Arguments.Count
    for ($i = 0; $i -lt $Arguments.Count; $i++) { if ($null -ne $Arguments[$i]) { $plain[$i] = $Arguments[$i].PSObject.BaseObject } }
    $r = $Method.Invoke($Target.PSObject.BaseObject, $plain)
    for ($i = 0; $i -lt $Arguments.Count; $i++) { $Arguments[$i] = $plain[$i] }   # out parameters
    return ,$r
}
$aosType = [ABB.xA.Base.IAspectObjectsServices]
$mEnum   = $aosType.GetMethod('CreateAspectEnumerator')
$mOp     = $aosType.GetMethod('TryGetAspectOperation')
$pars    = $mEnum.GetParameters()

$calcs = @()
foreach ($opId in @($iid, $iid.Trim('{}'), $iid.ToLowerInvariant(), $iid.Trim('{}').ToLowerInvariant())) {
    try {
        $q  = New-Object ABB.xA.Base.AspectQuery (, [string[]]@($opId))
        $en = Invoke-M $mEnum $aos @($q, [Enum]::ToObject($pars[1].ParameterType, 0), [Enum]::ToObject($pars[2].ParameterType, 0), [Enum]::Parse($pars[3].ParameterType, 'All'))
        try { $calcs = @($en | Where-Object { -not $_.IsDeleted } | ForEach-Object { $_ }) } finally { $en.Dispose() }
        if ($calcs.Count) { $script:opIdUsed = $opId; break }
    } catch { Fail "aspect query ($opId)" $_ }
}
Say "Calculation aspects: $($calcs.Count)"
Say ''
if (-not $calcs.Count) { Say 'No calculations configured - nothing to check.'; Finish 0 }

function Name-Of($Info) {
    $obj = try { $Info.Id.ObjectId } catch { $null }
    $on  = ''
    if ($obj) {
        try {
            $mInfo = $aosType.GetMethod('GetObjectInfo')
            $list = [Activator]::CreateInstance([System.Collections.Generic.List``1].MakeGenericType($obj.GetType()))
            $list.Add($obj)
            foreach ($oi in (Invoke-M $mInfo $aos @($list, [Enum]::Parse($mInfo.GetParameters()[1].ParameterType, 'Name')))) { $on = $oi.Name }
        } catch { }
    }
    if ($on) { "$on : $($Info.Name)" } else { $Info.Name }
}

# The calculation aspects publish their settings as OPC properties (GPExplore of Cell_1 / Corrections, 2026-10-15):
# ItemID "{object GUID}{aspect GUID}:Enabled | Status | StatusMessage", all RW. The 800xA .NET API lists the aspects
# (above) but does not hand out ICalculationASO (TryGetAspectOperation = False although HasAspectOperation = True), so
# they are read and enabled over OPC DA (OPC.Automation, the component the 800xA kit uses) in one session.
function Get-Guid($Value) { if ("$Value" -match '([0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})') { '{' + $Matches[1].ToUpperInvariant() + '}' } }
function Item-Base($Info) {
    $ref = $Info.Id
    $obj = Get-Guid $ref.ObjectId
    $asp = $null
    foreach ($pn in 'AspectId', 'Id', 'LocalId', 'AspectGuid') {
        $pi = $ref.GetType().GetProperty($pn)
        if ($pi) { $asp = Get-Guid ($pi.GetValue($ref, $null)); if ($asp -and $asp -ne $obj) { break } else { $asp = $null } }
    }
    if (-not $asp) {   # any other GUID-valued property of the AspectRef
        foreach ($pi in $ref.GetType().GetProperties()) {
            $g = try { Get-Guid ($pi.GetValue($ref, $null)) } catch { $null }
            if ($g -and $g -ne $obj) { $asp = $g; break }
        }
    }
    if ($obj -and $asp) { "$obj$asp" }
}

try {
    $opc = New-Object -ComObject OPC.Automation
    $opc.Connect('ABB.AfwOpcDaSurrogate.1')
    $grp = $opc.OPCGroups.Add('ApcCalcs')
} catch { Fail 'connecting to the 800xA OPC DA server (OPC.Automation, ABB.AfwOpcDaSurrogate.1)' $_; Finish 2 }
$script:handle = 0
function Read-Item([string]$ItemId) {
    $step = 'AddItem'
    try {
        $script:handle++
        $it = $grp.OPCItems.AddItem($ItemId, $script:handle)
        $step = 'Read'
        $it.Read(2)                                   # 2 = from the device, not the cache
        [pscustomobject]@{ Item = $it; Value = $it.Value; Good = (($it.Quality -band 0xC0) -eq 0xC0); Quality = $it.Quality }
    } catch { $script:lastItemError = "$step $ItemId : $($_.Exception.GetBaseException().Message)"; $null }
}
function Read-Calc($Info) {
    $base = Item-Base $Info
    if (-not $base) { return $null }
    $en = Read-Item "$base`:Enabled"
    if ($null -eq $en -or -not $en.Good) { return $null }    # not in OPC: no running calculation behind this aspect
    $st = Read-Item "$base`:Status"
    $ms = Read-Item "$base`:StatusMessage"
    [pscustomobject]@{ Base = $base; EnabledItem = $en.Item; Enabled = ("$($en.Value)" -eq 'True'); Status = $(if ($st) { $st.Value }); Message = [string]$(if ($ms) { $ms.Value }) }
}
function Close-Opc { try { $opc.OPCGroups.RemoveAll(); $opc.Disconnect() } catch { } }

# -- diagnostics: a known item (from a GPExplore of Cell_1) and how the first aspect maps to an OPC item -------
Say '== Diagnostics =='
$known = '{4B9023E4-39F5-46BD-9018-A4387D1E1890}{147B1B12-9885-4662-9A7F-7B5BC55234C5}:Enabled'   # Cell_1 Cancelled Calculation
$k = Read-Item $known
Say "  known item $known -> $(if ($k) { "value '$($k.Value)' quality $($k.Quality)" } else { "FAILED: $script:lastItemError" })"
$first = $calcs | Select-Object -First 1
$fb = Item-Base $first
Say "  first aspect $(Name-Of $first) -> $fb"
foreach ($pi in $first.Id.GetType().GetProperties()) {
    $v = try { $pi.GetValue($first.Id, $null) } catch { "<$($_.Exception.GetBaseException().Message)>" }
    Say "    AspectRef.$($pi.Name) = $v"
}
$f = Read-Item "$fb`:Enabled"
Say "  first aspect Enabled -> $(if ($f) { "value '$($f.Value)' quality $($f.Quality)" } else { "FAILED: $script:lastItemError" })"
$c1 = $calcs | Where-Object { (Name-Of $_) -like 'Cell_1 : Cancelled*' } | Select-Object -First 1
if ($c1) { Say "  Cell_1 Cancelled Calculation from the query -> $(Item-Base $c1)  (GPExplore: $($known -replace ':Enabled$', ''))" }
Say ''

# -- 3. check (and re-enable) ---------------------------------------------------------------------------
Say '== Calculations (Calculation Status Viewer): only problems are listed =='
$problems = @(); $okCount = 0; $unread = @()
foreach ($c in $calcs) {
    $s = Read-Calc $c
    if ($null -eq $s) { $unread += $c; continue }
    $ok = $s.Enabled -and "$($s.Status)" -eq '0'
    if ($ok) { $okCount++; continue }
    $name = Name-Of $c
    Say ("  FAIL  {0}  enabled={1} status={2}{3}" -f $name, $s.Enabled, $s.Status, $(if ($s.Message) { " - $($s.Message)" }))
    $problems += [pscustomobject]@{ Name = $name; Info = $c; Calc = $s }
}
$running = $okCount + $problems.Count
Say "  $running running calculation(s) (the Calculation Status Viewer's list): $okCount OK, $($problems.Count) disabled or in error"
if ($unread.Count) {
    Say "  $($unread.Count) calculation aspect(s) not in OPC (no running calculation, e.g. object type definitions) - not checked; by object:"
    $unread | Group-Object { ((Name-Of $_) -split ' : ')[0] } | Sort-Object Count -Descending | Select-Object -First 10 |
        ForEach-Object { Say ("    {0,4} x {1}" -f $_.Count, $_.Name) }
}
Say ''
if (-not $running) { Say 'Could not read any running calculation.'; Close-Opc; Finish 7 }
if (-not $problems) { Say "All $running running calculation(s) enabled with status 0."; Close-Opc; Finish 0 }
if (-not $Confirmed) { Say "$($problems.Count) calculation(s) disabled or in error. With -Confirmed they are enabled again."; Close-Opc; Finish 1 }

Say "== Re-enable $($problems.Count) calculation(s) (Enabled over OPC, as the viewer's Enable) =="
foreach ($p in $problems) {
    try {
        if ($p.Calc.Enabled) { $p.Calc.EnabledItem.Write($false); Start-Sleep -Seconds 2 }   # errored but enabled: off, then on
        $p.Calc.EnabledItem.Write($true)
        Say "  enabled: $($p.Name)"
    } catch { Fail "enabling $($p.Name)" $_ }
}
Say "  waiting $WaitSeconds s for the calculations to run..."
Start-Sleep -Seconds $WaitSeconds
$left = 0
foreach ($p in $problems) {
    $s = Read-Calc $p.Info
    $ok = $s -and $s.Enabled -and "$($s.Status)" -eq '0'
    Say ("  {0}  {1}  enabled={2} status={3}{4}" -f $(if ($ok) { 'OK  ' } else { 'FAIL' }), $p.Name, $s.Enabled, $s.Status, $(if ($s.Message) { " - $($s.Message)" }))
    if (-not $ok) { $left++ }
}
Close-Opc
[System.AppDomain]::CurrentDomain.remove_AssemblyResolve($onResolve)
Finish $(if ($left) { 5 } else { 0 })
