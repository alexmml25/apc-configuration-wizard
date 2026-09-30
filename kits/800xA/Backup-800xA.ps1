<#
 Start an 800xA Full backup from a script, using the Backup Definition aspect's IBackupDefASO interface
 bound by its exact type description (IID 04ed4420-15e8-4722-834c-89c0f7e94c8f).

 Default = READ-ONLY report (getters only). -Start = PrepareStartBackup + StartBackup after typing YES.
 Completion is read from <provider path>\<backup name>\Backup.log ("Backup completed." + "Errors: n, Warnings: m").
 Exit codes: 0 OK (0 errors) | 1 start failed | 2 not confirmed | 4 no entry/log within timeout | 5 completed with errors | 6 not enough free disk
 Undocumented ABB interface: run -Start on a non-production system first.

 Run in 32-bit PowerShell (needs GPWrite3.vbs in the same folder for listing Backups):
   Report: C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "%USERPROFILE%\Downloads\800xA-TestKit\Backup-800xA.ps1"
   Start:  ... same ... -Start
#>
param(
    [string]$DefPath    = '[Maintenance Structure]Backup Definitions/Full backup',
    [switch]$Start,
    [switch]$Confirmed,                # skip the YES prompt (caller already confirmed)
    [int]$MinFreeMB     = 2048,        # refuse to start below this free space on the backup drive
    [string]$Version    = '',
    [int]$TimeoutMin    = 90,
    [int]$PollSec       = 15,
    [string]$LogFile    = (Join-Path $PSScriptRoot ("Backup800xA_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss')))
)
$ErrorActionPreference = 'Continue'
function Out([string]$t) { $l = "{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $t; Write-Host $l; Add-Content -Path $LogFile -Value $l }
if ([IntPtr]::Size -ne 4) { Write-Warning "Use 32-bit PowerShell (SysWOW64 path)."; exit 1 }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

[StructLayout(LayoutKind.Sequential)]
public struct AfwBlob { public uint size; public IntPtr data; }

// Method order = vtable order from the type description (slots 28..108)
[ComImport, Guid("04ed4420-15e8-4722-834c-89c0f7e94c8f"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
public interface IBackupDefASO {
    void SetADInfo(int mode);
    void GetADInfo(out int mode);
    void GetIncludedServices(out uint count, out IntPtr ids);
    void ClearServices();
    void IncludeServiceInBackup(ref Guid serviceId);
    void ExcludeServiceFromBackup(ref Guid serviceId);
    void SetServiceArguments(ref Guid serviceId, ref AfwBlob args);
    void GetServiceArguments(ref Guid serviceId, out AfwBlob args);
    void SetProviderId(ref Guid providerId);
    void GetProviderId(out Guid providerId);
    void GetProviders(out uint count, out IntPtr ids);
    void GetIsReadOnly(out int isReadOnly);
    void GetInfo(ref Guid providerId, [MarshalAs(UnmanagedType.BStr)] out string name, [MarshalAs(UnmanagedType.BStr)] out string path, [MarshalAs(UnmanagedType.BStr)] out string node, out uint freeDiskSpace);
    void PrepareStartBackup([MarshalAs(UnmanagedType.BStr)] string versionString, out Guid aspectId, out Guid objectId);
    void GetIsVersionPage(out int isVersionPage);
    void GetBackupableServices(out uint count, out IntPtr ids);
    void IsProviderRunning(ref Guid providerId, [MarshalAs(UnmanagedType.BStr)] out string value);
    void StartBackup(ref Guid objectId);
    void IsProviderEnabled(ref Guid providerId);
    int GetPurgeCount();
    void SetPurgeCount(int count);
}

public static class BackupApi {
    static IBackupDefASO B(object o) { return (IBackupDefASO)o; }
    static Guid[] ReadGuids(IntPtr p, uint n) {
        var r = new Guid[n];
        for (int i = 0; i < n; i++) r[i] = (Guid)Marshal.PtrToStructure(new IntPtr(p.ToInt64() + i * 16), typeof(Guid));
        return r;
    }
    static void Line(StringBuilder sb, string label, Func<string> f) {
        try { sb.AppendLine("  " + label + ": " + f()); }
        catch (Exception e) { var x = e; while (x.InnerException != null) x = x.InnerException; sb.AppendLine("  " + label + ": FAILED " + x.Message); }
    }
    public static string Report(object o) {
        var b = B(o); var sb = new StringBuilder();
        Line(sb, "PurgeCount", () => b.GetPurgeCount().ToString());
        Line(sb, "IsReadOnly", () => { int v; b.GetIsReadOnly(out v); return v.ToString(); });
        Line(sb, "AspectDir mode (0 nothing, 1 current, 2 all versions)", () => { int v; b.GetADInfo(out v); return v.ToString(); });
        Line(sb, "Selected provider", () => { Guid g; b.GetProviderId(out g); return g.ToString("B"); });
        Line(sb, "Providers", () => {
            uint n; IntPtr p; b.GetProviders(out n, out p);
            var s = new StringBuilder(n + " provider(s)");
            foreach (var g in ReadGuids(p, n)) {
                var gg = g; string name = "", path = "", node = "", run = ""; uint free = 0;
                try { b.GetInfo(ref gg, out name, out path, out node, out free); } catch (Exception e) { name = "GetInfo failed: " + e.Message; }
                try { b.IsProviderRunning(ref gg, out run); } catch (Exception e) { run = "failed: " + e.Message; }
                s.Append("\n     " + gg.ToString("B") + "  name=" + name + "  node=" + node + "  path=" + path + "  freeDisk=" + free + "  running=" + run);
            }
            return s.ToString();
        });
        Line(sb, "Included services", () => { uint n; IntPtr p; b.GetIncludedServices(out n, out p); return n + " : " + string.Join(", ", Array.ConvertAll(ReadGuids(p, n), g => g.ToString("B"))); });
        Line(sb, "Backupable services", () => { uint n; IntPtr p; b.GetBackupableServices(out n, out p); return n.ToString(); });
        return sb.ToString();
    }
    public static string ProviderPath(object o) { var b = B(o); Guid g; b.GetProviderId(out g); string n, path, node; uint f; b.GetInfo(ref g, out n, out path, out node, out f); return path; }
    public static string Running(object o) { var b = B(o); Guid g; b.GetProviderId(out g); string s; b.IsProviderRunning(ref g, out s); return s; }
    public static Guid[] Prepare(object o, string version) { Guid a, ob; B(o).PrepareStartBackup(version, out a, out ob); return new Guid[] { a, ob }; }
    public static void StartBackup(object o, Guid objectId) { B(o).StartBackup(ref objectId); }
}
'@

function Get-BackupList {
    $vbs = Join-Path $PSScriptRoot 'GPWrite3.vbs'
    $out = & "$env:WINDIR\SysWOW64\cscript.exe" //nologo $vbs /server:ABB.AfwOpcDaSurrogate.1 '/browse:[Maintenance Structure]|Backups' 2>&1
    @($out | Where-Object { $_ -match '^\s*\[B\]\s+(.+)$' } | ForEach-Object { ($_ -replace '^\s*\[B\]\s+', '').Trim() })
}

Out "Backup-800xA  Host=$env:COMPUTERNAME  User=$env:USERDOMAIN\$env:USERNAME  Mode=$(if ($Start) {'START'} else {'REPORT'})"
$sys = (New-Object -ComObject ABB.ABBSystems).DefaultSystem
$obj = $null
foreach ($t in @({ $sys.Object($DefPath) }, { @($sys.Objects($DefPath))[0] })) { if ($null -eq $obj) { try { $obj = & $t } catch {} } }
if ($null -eq $obj) { Out "Backup definition not found: $DefPath"; exit 1 }
$bd = $obj.Aspect('Backup Definition').InterfaceDisp('IBackupDefASO')
if ($null -eq $bd) { Out "IBackupDefASO not available."; exit 1 }

Out "Definition: $DefPath  ($($obj.id))"
foreach ($l in ([BackupApi]::Report($bd) -split "`r?`n")) { if ($l) { Out $l } }
$before = Get-BackupList
Out "Existing backups: $($before.Count)  (newest listed last)"
$before | Select-Object -Last 3 | ForEach-Object { Out "   $_" }

if (-not $Start) { Out "Report only. Re-run with -Start to run a backup."; Out "Log: $LogFile"; exit 0 }

$idle = try { [BackupApi]::Running($bd) } catch { "?" }
Out "Provider running state before start: '$idle'"
$root0 = try { [BackupApi]::ProviderPath($bd) } catch { 'C:\BACKUP' }
$drive = try { Get-PSDrive -Name ($root0.Substring(0,1)) -ErrorAction Stop } catch { $null }
if ($drive) {
    $freeMB = [math]::Round($drive.Free / 1MB)
    Out "Free space on $($drive.Name): $freeMB MB (minimum $MinFreeMB MB)"
    if ($freeMB -lt $MinFreeMB) { Out "Not enough free disk space. Nothing started."; exit 6 }
}
if (-not $Confirmed) {
    $answer = Read-Host "Type YES to start a Full backup now"
    if ($answer -cne 'YES') { Out "Not confirmed. Nothing started."; exit 2 }
} else { Out "Confirmed by caller (-Confirmed)." }

try {
    $ids = [BackupApi]::Prepare($bd, $Version)
    Out "PrepareStartBackup OK: aspectId=$($ids[0].ToString('B'))  objectId=$($ids[1].ToString('B'))"
    [BackupApi]::StartBackup($bd, $ids[1])
    Out "StartBackup called."
} catch {
    $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
    Out "START FAILED: [$($e.GetType().Name)] $($e.Message)"; exit 1
}

$root = try { [BackupApi]::ProviderPath($bd) } catch { 'C:\BACKUP' }
$t0 = Get-Date; $deadline = $t0.AddMinutes($TimeoutMin); $newName = $null; $folder = $null
do {
    Start-Sleep -Seconds $PollSec
    if (-not $newName) { $newName = (Get-BackupList | Where-Object { $before -notcontains $_ } | Select-Object -Last 1) }
    if ($newName) { $folder = Join-Path $root $newName }
    $log = if ($folder) { Join-Path $folder 'Backup.log' } else { $null }
    $text = if ($log -and (Test-Path -LiteralPath $log)) { Get-Content -LiteralPath $log -Raw } else { '' }
    $last = if ($text) { (($text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 1).Trim() } else { '(no log yet)' }
    Out ("  entry={0}  log: {1}" -f $(if ($newName) { $newName } else { '(not yet)' }), $last)
    if ($text -match 'Backup completed\.') { break }
    if ($text -match '(?i)backup (failed|aborted|cancel)') { break }
} while ((Get-Date) -lt $deadline)

if (-not $newName -or -not $text) { Out "RESULT: no backup entry/log seen within $TimeoutMin min - check in Workplace."; Out "Log: $LogFile"; exit 4 }
$files = @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue)
$mb = [math]::Round((($files | Measure-Object Length -Sum).Sum) / 1MB, 1)
$errs = 0; $warns = 0
if ($text -match 'Errors:\s*(\d+),\s*Warnings:\s*(\d+)') { $errs = [int]$Matches[1]; $warns = [int]$Matches[2] }
$dur = [math]::Round(((Get-Date) - $t0).TotalSeconds)
Out "Backup: $newName"
Out "Folder: $folder   files=$($files.Count)  size=$mb MB   errors=$errs  warnings=$warns"
if ($text -match 'Backup completed\.' -and $errs -eq 0) { Out "RESULT: BACKUP OK"; Out "Log: $LogFile"; exit 0 }
Out "RESULT: backup finished with problems - see $log"; Out "Log: $LogFile"; exit 5
