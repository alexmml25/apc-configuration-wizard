#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only: turns the COM type libraries of 800xA's service administration DLLs into .NET interop assemblies
    (Microsoft's TypeLibConverter), so their interfaces (IAfwAdminServiceProviderEdit: Enabled, ...) can be read.
    Changes nothing; nothing is registered.
.DESCRIPTION
    For each DLL: LoadTypeLibEx (REGKIND_NONE) -> TypeLibConverter.ConvertTypeLibToAssembly -> Interop.<name>.dll,
    then a plain-text list of every interface and its members. All into one zip:
    C:\APC_Config\Logs\800xA-typelibs_<ts>.zip. 32-bit (restarts itself in 32-bit PowerShell if needed).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Export-800xATypeLibs.ps1
#>
param(
    [string]$BinDir = 'C:\Program Files (x86)\ABB 800xA\Base\bin',
    [string[]]$Dlls = @('AfwAbsInterfaces.dll', 'AfwServiceAspects.dll', 'AfwServiceViews.dll'),
    [string]$OutDir = 'C:\APC_Config\Logs'
)

if ([Environment]::Is64BitProcess) {
    $ps32 = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    & $ps32 -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -BinDir $BinDir -Dlls ($Dlls -join ',') -OutDir $OutDir
    exit $LASTEXITCODE
}
if ($Dlls.Count -eq 1 -and $Dlls[0] -match ',') { $Dlls = $Dlls[0] -split ',' }

Add-Type -TypeDefinition @'
using System;
using System.Reflection;
using System.Runtime.InteropServices;
public class ApcTlbSink : ITypeLibImporterNotifySink {
    // a type library that references another one (AfwServiceAspects -> AfwAbsInterfaces) needs that one converted too
    public static System.Collections.Generic.Dictionary<string, Assembly> Done = new System.Collections.Generic.Dictionary<string, Assembly>();
    public void ReportEvent(ImporterEventKind eventKind, int eventCode, string eventMsg) { }
    public Assembly ResolveRef(object typeLib) {
        string name = "Interop." + Marshal.GetTypeLibName((System.Runtime.InteropServices.ComTypes.ITypeLib)typeLib);
        Assembly a;
        if (Done.TryGetValue(name, out a)) return a;
        a = new TypeLibConverter().ConvertTypeLibToAssembly(typeLib, name + ".dll", TypeLibImporterFlags.None, this, null, null, name, null);
        Done[name] = a;
        return a;
    }
}
public static class ApcTlb {
    [DllImport("oleaut32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    public static extern void LoadTypeLibEx(string file, int regKind, [MarshalAs(UnmanagedType.Interface)] out object typeLib);
}
'@

$ts    = Get-Date -Format 'yyyyMMdd_HHmmss'
$stage = Join-Path $env:TEMP "800xA-typelibs_$ts"
$zip   = Join-Path $OutDir "800xA-typelibs_$ts.zip"
New-Item -ItemType Directory -Path $stage, $OutDir -Force | Out-Null
$summary = New-Object System.Collections.Generic.List[string]

foreach ($dll in $Dlls) {
    $path = Join-Path $BinDir $dll
    $name = "Interop.$([IO.Path]::GetFileNameWithoutExtension($dll))"
    try {
        $tlb = $null
        [ApcTlb]::LoadTypeLibEx($path, 2, [ref]$tlb)          # 2 = REGKIND_NONE: load only, never register
        $conv = New-Object System.Runtime.InteropServices.TypeLibConverter
        $libName = 'Interop.' + [System.Runtime.InteropServices.Marshal]::GetTypeLibName([System.Runtime.InteropServices.ComTypes.ITypeLib]$tlb)
        if ([ApcTlbSink]::Done.ContainsKey($libName)) { $asm = [ApcTlbSink]::Done[$libName] } else {
        $asm  = $conv.ConvertTypeLibToAssembly($tlb, "$name.dll", [System.Runtime.InteropServices.TypeLibImporterFlags]::None,
                                               (New-Object ApcTlbSink), $null, $null, $name, $null) }
        [ApcTlbSink]::Done[$name] = $asm
        [ApcTlbSink]::Done[$libName] = $asm      # the name a referencing library asks for
        $cwd = [Environment]::CurrentDirectory
        [Environment]::CurrentDirectory = $stage           # AssemblyBuilder.Save writes to the process directory
        try { $asm.Save("$name.dll") } catch { } finally { [Environment]::CurrentDirectory = $cwd }
        $summary.Add("== $dll -> $name.dll")
        foreach ($t in ($asm.GetTypes() | Sort-Object FullName)) {
            $kind = if ($t.IsInterface) { 'interface' } elseif ($t.IsEnum) { 'enum' } elseif ($t.IsValueType) { 'struct' } else { 'class' }
            $guid = ($t.GetCustomAttributes([System.Runtime.InteropServices.GuidAttribute], $false) | Select-Object -First 1).Value
            $summary.Add("  $kind $($t.FullName)  {$guid}")
            if ($t.IsInterface -or $t.IsValueType -or $t.IsEnum) {
                foreach ($m in $t.GetMembers([Reflection.BindingFlags]'Public,Instance,Static,DeclaredOnly')) {
                    $summary.Add("      $($m.MemberType)  $m")
                }
            }
        }
    } catch {
        $e = $_.Exception; $msg = $e.Message; while ($e.InnerException) { $e = $e.InnerException; $msg += " / $($e.Message)" }
        $summary.Add("== $dll : ERROR $msg")
    }
}

$summary | Set-Content -Path (Join-Path $stage 'typelibs.txt')
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
Remove-Item -LiteralPath $stage -Recurse -Force
$summary | Where-Object { $_ -match '^==|IAfwAdminServiceProvider|Enabl' } | ForEach-Object { $_ }
"Written: $zip"
