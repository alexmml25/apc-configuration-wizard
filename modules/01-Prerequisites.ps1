#Requires -Version 5.1
<#
.SYNOPSIS
    Step 1 - Prerequisites: checks that this VM is ready before anything is changed.
.DESCRIPTION
    As in the APC Installation Manager, a failed check stops the run before Step 2.
      Windows account   the session is the site's service account (Manifest.AppAccount, e.g. ENT\SVC-APC-MPR)
      Install drive     the Medtronic apps are on one drive (Find-MedtronicInstall); each app found
      Services          PostgreSQL, deviceWise (dwcore), CNCnetPDM installed
      Machines          the machines loaded from the Site DB at sign-in (no second query); each DOC-assigned machine
                        has a Device Nr, an IP address and a DLL name
      800xA kit         present and unchanged (only when Step 11 is in the run)
      Run folder        writable
    APC_Config.ps1 (command line) has no sign-in: without State.CNCMachines the Site DB is queried here
    (01-SiteDBFetch.ps1).
#>

. (Join-Path $PSScriptRoot 'Common.ps1')

function Invoke-Prerequisites {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [switch]$NonInteractive
    )

    Write-Log STEP "Prerequisites"
    $sandbox = [bool]$State['SandboxRoot']

    # -- Windows account ------------------------------------------------------------------------------
    $svc = Get-AppAccount -Manifest $Manifest -State $State
    $me  = "$env:USERDOMAIN\$env:USERNAME"
    if (-not $svc) {
        Add-Result -Phase Prerequisites -Check 'Windows account' -Status WARN -Detail "No AppAccount / site in the manifest - signed in as $me"
    } elseif ($me -ieq $svc) {
        Add-Result -Phase Prerequisites -Check 'Windows account' -Status PASS -Detail $me
    } else {
        Add-Result -Phase Prerequisites -Check 'Windows account' -Status FAIL -Detail "Signed in to Windows as $me - sign in as $svc (the APC apps run as this account)"
    }

    # -- install drive and apps -----------------------------------------------------------------------
    if ($sandbox) {
        Write-Log INFO 'Test mode: install drive not checked'
    } else {
        $inst = Find-MedtronicInstall -Manifest $Manifest
        if ($inst.Error) {
            Add-Result -Phase Prerequisites -Check 'Medtronic install drive' -Status FAIL -Detail $inst.Error
        } else {
            Add-Result -Phase Prerequisites -Check 'Medtronic install drive' -Status PASS -Detail "$($inst.Drive) ($(@($inst.Apps).Count) app(s))"
            foreach ($a in @($inst.Apps)) { Add-Result -Phase Prerequisites -Check "$($a.Name) installed" -Status PASS -Detail $a.Folder }
            foreach ($x in @($inst.Missing)) { Add-Result -Phase Prerequisites -Check "$x installed" -Status WARN -Detail 'Not found - the steps that use it will fail' }
        }
    }

    # -- services -------------------------------------------------------------------------------------
    if (-not $sandbox) {
        foreach ($p in $Manifest.Services.PSObject.Properties) {
            $s = Get-Service -Name ([string]$p.Value) -ErrorAction SilentlyContinue
            if ($s) { Add-Result -Phase Prerequisites -Check "Service $($p.Value)" -Status PASS -Detail "$($p.Name), $($s.Status)" }
            else    { Add-Result -Phase Prerequisites -Check "Service $($p.Value)" -Status FAIL -Detail "$($p.Name) service not installed - install it with the APC Installation Manager" }
        }
    }

    # -- machines (from sign-in; the command line queries the Site DB here) -----------------------------
    if (-not @($State['CNCMachines']).Where({ $_ }).Count) {
        Write-Log INFO 'No machines from sign-in: querying the Site DB'
        . (Join-Path $PSScriptRoot '01-SiteDBFetch.ps1')
        Invoke-SiteDBFetch -Manifest $Manifest -State $State
    } else {
        Add-Result -Phase Prerequisites -Check 'Site DB machines' -Status PASS -Detail "$(@($State['CNCMachines']).Count) machine(s) loaded at sign-in"
    }
    $assigned = Get-AssignedCNCs -State $State -Manifest $Manifest   # (no @(): it returns the list as one object)
    foreach ($m in $assigned) {
        $n = $m.CNCIndex; $name = $m.MachineName
        $problems = @()
        if ($m.DeviceNrError) { $problems += $m.DeviceNrError }
        if (-not $m.IPAddress -or $m.IPAddress -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { $problems += "IP address '$($m.IPAddress)' is not valid" }
        if (-not $m.DLLName) { $problems += 'no DLL name (f_dllname) in the Site DB' }
        if ($problems) { Add-Result -Phase Prerequisites -Check "CNC$n $name" -Status FAIL -Detail (($problems -join '; ') + ' - correct the Site DB, then re-run') }
        else { Add-Result -Phase Prerequisites -Check "CNC$n $name" -Status PASS -Detail "Device $($m.DeviceNr), $($m.IPAddress):$($m.Port), $($m.DriverDll)" }
    }

    # -- 800xA kit (Step 11) ------------------------------------------------------------------------------
    if (11 -in @($State['RunSteps'])) {
        . (Join-Path $PSScriptRoot 'ABB800xA.ps1')
        $kit = Get-800xAKit -Manifest $Manifest
        if ($kit.Problems.Count) { Add-Result -Phase Prerequisites -Check '800xA kit' -Status FAIL -Detail ($kit.Problems -join '; ') }
        else { Add-Result -Phase Prerequisites -Check '800xA kit' -Status PASS -Detail $kit.Dir }
    }

    # -- run folder -----------------------------------------------------------------------------------------
    $logs = ''
    try {
        $logs  = Get-RunDir -State $State -Name Logs -Manifest $Manifest
        $probe = Join-Path $logs ".write_test_$PID"
        [System.IO.File]::WriteAllText($probe, 'ok'); Remove-Item -LiteralPath $probe -Force
        Add-Result -Phase Prerequisites -Check 'Run folder writable' -Status PASS -Detail (Split-Path $logs -Parent)
    } catch {
        Add-Result -Phase Prerequisites -Check 'Run folder writable' -Status FAIL -Detail "$logs : $($_.Exception.Message)"
    }

    Write-Log PASS 'Prerequisites checked.'
}
