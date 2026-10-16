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
      3. per calculation, over OPC DA (a VBScript with OPC.Automation -> ABB.AfwOpcDaSurrogate.1, 32-bit cscript,
         one batch): "{object}{aspect}:Enabled",
         ":Status", ":StatusMessage" - the aspect properties are RW (the .NET API does not hand out ICalculationASO)
      4. -Confirmed: Enabled false, or Status not 0 -> Enabled = false then true over OPC (re-enable), wait, read again
    Exit codes: 0 all enabled and Status 0 (or no calculations), 1 problems found (report only), 5 problems left
    after re-enabling, 8 not enabled for safety (Object Type Structure check not working, or more than 25),
    7 no running calculation could be read (aspects with no running calculation behind them are
    object type definitions: counted, not checked), 2 cannot connect to 800xA, 6 Inform IT
    Calculations not found. Only problems are listed (SJUM7AAPPS0048 has 602 calculation aspects).
    Output: <run>\Logs\ (standalone: <work folder>\Logs\) chmi-calcs_<ts>.txt
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\modules\Invoke-800xACalculations.ps1              # check only
    powershell -ExecutionPolicy Bypass -File .\modules\Invoke-800xACalculations.ps1 -Confirmed   # check + re-enable
#>
param(
    [switch]$Confirmed,
    [string]$BinDir     = 'C:\Program Files (x86)\ABB 800xA\Base\bin',
    [string]$CalcBinDir = 'C:\Program Files (x86)\ABB Industrial IT\Inform IT\Calculations\bin',
    [int]$WaitSeconds   = 15,
    [string]$OutDir     = $(if (@([IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -eq 'D:\' -and $_.DriveType -eq 'Fixed' -and $_.IsReady }).Count) { 'D:\APC_Config\Logs' } else { 'C:\APC_Config\Logs' })
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

# OPC DA through a small VBScript in 32-bit cscript, as the 800xA kit does: from PowerShell the OPCItem COM object
# cannot be called ("no method named Read" / NullReference with late binding, VM 2026-10-15). One cscript run reads
# a list of items, another writes. Lines: read "R|<item>", write "W|<item>|<True/False>"; output "<item>|OK|<value>|<quality>"
# or "<item>|ERR|<message>".
$vbs = @'
Option Explicit
Dim fso, inF, outF, opc, g, line, parts, it, h, v
Set fso = CreateObject("Scripting.FileSystemObject")
Set inF = fso.OpenTextFile(WScript.Arguments(0), 1)
Set outF = fso.CreateTextFile(WScript.Arguments(1), True)
On Error Resume Next
Set opc = CreateObject("OPC.Automation")
opc.Connect WScript.Arguments(2)
If Err.Number <> 0 Then outF.WriteLine "*|ERR|connect: " & Err.Description : WScript.Quit 2
Set g = opc.OPCGroups.Add("ApcCalcs")
h = 0
Do While Not inF.AtEndOfStream
    line = inF.ReadLine
    If Len(line) > 2 Then
        parts = Split(line, "|")
        h = h + 1 : Err.Clear
        Set it = g.OPCItems.AddItem(parts(1), h)
        If Err.Number <> 0 Then
            outF.WriteLine parts(1) & "|ERR|AddItem: " & Err.Description
        Else
            If parts(0) = "W" Then it.Write CBool(parts(2))
            If Err.Number <> 0 Then
                outF.WriteLine parts(1) & "|ERR|Write: " & Err.Description
            Else
                it.Read 2
                If Err.Number <> 0 Then
                    outF.WriteLine parts(1) & "|ERR|Read: " & Err.Description
                Else
                    v = Replace(Replace(Replace(CStr(it.Value), vbCr, " "), vbLf, " "), "|", "/")
                    outF.WriteLine parts(1) & "|OK|" & v & "|" & it.Quality
                End If
            End If
        End If
    End If
Loop
opc.OPCGroups.RemoveAll
opc.Disconnect
outF.Close
'@
$vbsFile = Join-Path $env:TEMP "apc-calcs-$([guid]::NewGuid().ToString('N')).vbs"
[IO.File]::WriteAllText($vbsFile, $vbs, [Text.Encoding]::ASCII)
$cscript = Join-Path $env:WINDIR 'SysWOW64\cscript.exe'

function Invoke-OpcBatch([string[]]$Lines) {
    # returns a hashtable item -> @{ Ok; Value; Quality; Good; Error }
    $in  = Join-Path $env:TEMP "apc-calcs-$([guid]::NewGuid().ToString('N')).in"
    $out = "$in.out"
    [IO.File]::WriteAllLines($in, $Lines, [Text.Encoding]::ASCII)
    $null = & $cscript //nologo $vbsFile $in $out 'ABB.AfwOpcDaSurrogate.1' 2>&1
    $res = @{}
    if (Test-Path -LiteralPath $out) {
        foreach ($l in [IO.File]::ReadAllLines($out)) {
            $p = $l -split '\|', 4
            if ($p[1] -eq 'OK') {
                $q = [int]$p[3]
                $res[$p[0]] = @{ Ok = $true; Value = $p[2]; Quality = $q; Good = (($q -band 0xC0) -eq 0xC0); Error = '' }
            } else { $res[$p[0]] = @{ Ok = $false; Value = $null; Quality = 0; Good = $false; Error = $p[2] } }
        }
    }
    Remove-Item -LiteralPath $in, $out -Force -ErrorAction SilentlyContinue
    return $res
}

# -- diagnostics: a known item (from a GPExplore of Cell_1) and how the first aspect maps to an OPC item -------
Say '== Diagnostics =='
$known = '{4B9023E4-39F5-46BD-9018-A4387D1E1890}{147B1B12-9885-4662-9A7F-7B5BC55234C5}:Enabled'   # Cell_1 Cancelled Calculation
$first = $calcs | Select-Object -First 1
$fb = Item-Base $first
$d = Invoke-OpcBatch @("R|$known", "R|$fb`:Enabled")
foreach ($id in $known, "$fb`:Enabled") {
    $r = $d[$id]
    Say "  $id -> $(if ($r -and $r.Ok) { "value '$($r.Value)' quality $($r.Quality)" } elseif ($r) { "FAILED: $($r.Error)" } else { 'no answer from the OPC script' })"
}
Say ''

# -- 3. read every calculation in one batch -------------------------------------------------------------
$bases = @{}
foreach ($c in $calcs) { $b = Item-Base $c; if ($b) { $bases[$c.Id.ToString()] = $b } }
$lines = foreach ($b in $bases.Values) { "R|$b`:Enabled"; "R|$b`:Status"; "R|$b`:StatusMessage" }
Say "Reading $($lines.Count) OPC values ..."
$vals = Invoke-OpcBatch $lines
function Read-Calc($Info, $Values) {
    $b = $bases[$Info.Id.ToString()]
    if (-not $b) { return $null }
    $en = $Values["$b`:Enabled"]
    if (-not $en -or -not $en.Ok -or -not $en.Good) { return $null }    # not in OPC: no running calculation behind it
    $st = $Values["$b`:Status"]; $ms = $Values["$b`:StatusMessage"]
    [pscustomobject]@{ Base = $b; Enabled = ("$($en.Value)" -eq 'True'); Status = $(if ($st) { $st.Value }); Message = [string]$(if ($ms) { $ms.Value }) }
}

# Calculations defined in the Object Type Structure (on type objects: Cell, Corrections, Transition, ...) are
# templates: disabled by design, not in the Calculation Status Viewer, and must never be enabled ("Calculations in the
# object type structure may not be enabled"). SJUM7AAPPS0048: 602 aspects = 361 running + 241 type definitions.
$mByName = $aosType.GetMethods() | Where-Object { $_.Name -eq 'GetAspects' -and $_.GetParameters().Count -eq 2 -and $_.GetParameters()[1].ParameterType -eq [string] } | Select-Object -First 1
$typeObj = @{}
function Test-TypeDefinition($Info) {
    $oid = $Info.Id.ObjectId
    $key = "$oid"
    if (-not $typeObj.ContainsKey($key)) {
        $isType = $false
        try { foreach ($a in (Invoke-M $mByName $aos @($oid, 'Object Type Structure'))) { $isType = $true; break } } catch { }
        $typeObj[$key] = $isType
    }
    return $typeObj[$key]
}

Say '== Calculations (Calculation Status Viewer): only problems are listed =='
$problems = @(); $okCount = 0; $unread = @(); $typeDefs = 0; $byLookup = 0; $byMessage = 0
foreach ($c in $calcs) {
    $s = Read-Calc $c $vals
    if ($null -eq $s) { $unread += $c; continue }
    $ok = $s.Enabled -and "$($s.Status)" -eq '0'
    if ($ok) { $okCount++; continue }
    $isTypeDef = Test-TypeDefinition $c
    if ("$($s.Message)" -match 'object type structure') { $byMessage++ }
    if ($isTypeDef) { $byLookup++ }
    if ($isTypeDef -or "$($s.Message)" -match 'object type structure') { $typeDefs++; continue }   # never checked or enabled
    $name = Name-Of $c
    Say ("  FAIL  {0}  enabled={1} status={2}{3}" -f $name, $s.Enabled, $s.Status, $(if ($s.Message.Trim()) { " - $($s.Message)" }))
    $problems += [pscustomobject]@{ Name = $name; Info = $c; Calc = $s }
}
$running = $okCount + $problems.Count
Say "  $running running calculation(s) (the Calculation Status Viewer's list): $okCount OK, $($problems.Count) disabled or in error"
if ($typeDefs) { Say "  $typeDefs calculation(s) in the Object Type Structure (templates, disabled by design) - not checked, never enabled" }
if ($unread.Count) {
    $why = @($unread | ForEach-Object { $vals["$($bases[$_.Id.ToString()])`:Enabled"] } | Where-Object { $_ -and -not $_.Ok } | Select-Object -First 1)
    Say "  $($unread.Count) calculation aspect(s) not in OPC (no running calculation, e.g. object type definitions) - not checked$(if ($why) { "; e.g. $($why[0].Error)" }); by object:"
    $unread | Group-Object { ((Name-Of $_) -split ' : ')[0] } | Sort-Object Count -Descending | Select-Object -First 10 |
        ForEach-Object { Say ("    {0,4} x {1}" -f $_.Count, $_.Name) }
}
Say ''
function Close-Opc { Remove-Item -LiteralPath $vbsFile -Force -ErrorAction SilentlyContinue }
if (-not $running) { Say 'Could not read any running calculation.'; Close-Opc; Finish 7 }
if (-not $problems) { Say "All $running running calculation(s) enabled with status 0."; Close-Opc; Finish 0 }
if (-not $Confirmed) { Say "$($problems.Count) calculation(s) disabled or in error. With -Confirmed they are enabled again."; Close-Opc; Finish 1 }
# safety: a template enabled by mistake would run on the type object - stop when the type check looks broken or the list is long
if ($byMessage -and -not $byLookup) { Say 'NOT enabling: the Object Type Structure lookup found nothing although ABB reports type calculations - check the list by hand.'; Close-Opc; Finish 8 }
if ($problems.Count -gt 25) { Say "NOT enabling: $($problems.Count) calculations is more than expected (limit 25) - check them in the Calculation Status Viewer."; Close-Opc; Finish 8 }

Say "== Re-enable $($problems.Count) calculation(s) (Enabled over OPC, as the viewer's Enable) =="
$off = @($problems | Where-Object { $_.Calc.Enabled } | ForEach-Object { "W|$($_.Calc.Base):Enabled|False" })
if ($off) { $null = Invoke-OpcBatch $off; Start-Sleep -Seconds 2 }      # errored but enabled: off, then on
$on = Invoke-OpcBatch @($problems | ForEach-Object { "W|$($_.Calc.Base):Enabled|True" })
foreach ($p in $problems) {
    $r = $on["$($p.Calc.Base):Enabled"]
    Say "  $(if ($r -and $r.Ok) { 'enabled' } else { "FAILED to enable ($($r.Error))" }): $($p.Name)"
}
Say "  waiting $WaitSeconds s for the calculations to run..."
Start-Sleep -Seconds $WaitSeconds
$again = Invoke-OpcBatch @(foreach ($p in $problems) { "R|$($p.Calc.Base):Enabled"; "R|$($p.Calc.Base):Status"; "R|$($p.Calc.Base):StatusMessage" })
$left = 0
foreach ($p in $problems) {
    $s = Read-Calc $p.Info $again
    $ok = $s -and $s.Enabled -and "$($s.Status)" -eq '0'
    Say ("  {0}  {1}  enabled={2} status={3}{4}" -f $(if ($ok) { 'OK  ' } else { 'FAIL' }), $p.Name, $s.Enabled, $s.Status, $(if ($s -and $s.Message.Trim()) { " - $($s.Message)" }))
    if (-not $ok) { $left++ }
}
Close-Opc
[System.AppDomain]::CurrentDomain.remove_AssemblyResolve($onResolve)
Finish $(if ($left) { 5 } else { 0 })
