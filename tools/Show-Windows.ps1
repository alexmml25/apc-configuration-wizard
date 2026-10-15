#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only: lists the visible top-level windows (title, window class, owning process and its path), to see what
    a pop-up really is - e.g. DOC's "PartLookup_DB" message - so the wizard can close the right thing.
    Run while the pop-up is showing, in the same session. Touches nothing.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Show-Windows.ps1
#>
param([string]$Filter = '')

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class ApcWinList {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    static string Cls(IntPtr h) { var s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }
    static string Txt(IntPtr h) { var s = new StringBuilder(1024); GetWindowText(h, s, 1024); return s.ToString(); }
    public static List<string[]> List() {
        var rows = new List<string[]>();
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            uint pid; GetWindowThreadProcessId(h, out pid);
            var kids = new List<string>();
            EnumChildWindows(h, (c, l2) => { var t = Txt(c).Trim(); kids.Add(Cls(c) + (t.Length > 0 ? "='" + t + "'" : "")); return kids.Count < 15; }, IntPtr.Zero);
            IntPtr owner = GetWindow(h, 4);
            rows.Add(new string[] { pid.ToString(), h.ToString("X"), Cls(h), Txt(h), owner.ToString("X"), string.Join(" | ", kids) });
            return true; }, IntPtr.Zero);
        return rows;
    }
}
'@

foreach ($r in [ApcWinList]::List()) {
    $p = Get-Process -Id ([int]$r[0]) -ErrorAction SilentlyContinue
    $line = "PID {0,-6} {1,-28} hwnd {2,-8} owner {3,-8} class '{4}'  title '{5}'" -f $r[0], $(if ($p) { $p.ProcessName } else { '?' }), $r[1], $r[4], $r[2], $r[3]
    if ($Filter -and "$line $($r[5])" -notlike "*$Filter*") { continue }
    if (-not $r[3] -and -not $Filter -and $r[2] -notmatch '32770|WindowsForms') { continue }   # skip untitled plumbing windows
    $line
    if ($p -and $p.Path) { "        path: $($p.Path)" }
    if ($r[5]) { "        children: $($r[5])" }
}
