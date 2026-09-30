#Requires -Version 5.1
<#
.SYNOPSIS
    800xA helpers dot-sourced by Step 11 (General Properties) and Step 12 (800xA Full backup).
.DESCRIPTION
    Wraps the proven 800xA kit in kits\800xA (see kits\800xA\HANDOFF.md) without changing it:
      Backup-800xA.ps1    Full backup through the Backup Definition aspect (32-bit PowerShell)
      Invoke-800xAGP.ps1  read / write one property via GPWrite3.vbs (32-bit cscript)
    Everything touching 800xA runs 32-bit. The wizard may run 64-bit, so the kit is called as child
    processes through the SysWOW64 paths, and each call is gated on its exit code.
    The kit files are checked against kits\800xA\SHA256SUMS.txt before use.
#>

. (Join-Path $PSScriptRoot 'Common.ps1')

$Script:ABB800xAWizardRoot = Split-Path -Parent $PSScriptRoot

$Script:ABB800xABackupExitText = @{
    0 = 'OK'
    1 = 'could not start the backup'
    2 = 'not confirmed'
    4 = 'no backup entry/log within the timeout'
    5 = 'backup completed with errors'
    6 = 'not enough free disk space on the backup drive'
}

function Get-800xAKit {
    <#
        Resolves the kit folder and the 32-bit executables from Manifest.ABB800xA and checks the kit
        against SHA256SUMS.txt. Returns @{ Dir; Ps32; Cscript32; Problems = [string[]] }.
    #>
    param([Parameter(Mandatory)] [object]$Manifest)
    $cfg = $Manifest.ABB800xA
    $dir = [Environment]::ExpandEnvironmentVariables([string]$cfg.KitDir)
    if (-not [System.IO.Path]::IsPathRooted($dir)) { $dir = Join-Path $Script:ABB800xAWizardRoot $dir }
    $kit = @{
        Dir       = $dir
        Ps32      = [Environment]::ExpandEnvironmentVariables([string]$cfg.PowerShell32)
        Cscript32 = [Environment]::ExpandEnvironmentVariables([string]$cfg.Cscript32)
        Problems  = [System.Collections.Generic.List[string]]::new()
    }
    foreach ($exe in 'Ps32', 'Cscript32') {
        if (-not (Test-Path -LiteralPath $kit[$exe])) { $kit.Problems.Add("32-bit executable not found: $($kit[$exe])") }
    }
    $sums = Join-Path $dir 'SHA256SUMS.txt'
    if (-not (Test-Path -LiteralPath $sums)) {
        $kit.Problems.Add("Kit checksum file not found: $sums")
        return $kit
    }
    foreach ($line in [System.IO.File]::ReadAllLines($sums)) {
        if ($line -notmatch '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') { continue }
        $file = Join-Path $dir $Matches[2]
        if (-not (Test-Path -LiteralPath $file)) { $kit.Problems.Add("Kit file missing: $($Matches[2])"); continue }
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        if ($hash -ne $Matches[1].ToUpper()) { $kit.Problems.Add("Kit file changed (SHA256 mismatch): $($Matches[2])") }
    }
    return $kit
}

function Invoke-800xABackup {
    <#
        Runs kits\800xA\Backup-800xA.ps1 -Start -Confirmed in 32-bit PowerShell and returns
        @{ Ok; ExitCode; Message; Name; Folder; Files; SizeMB; Errors; Warnings; LogFile }.
        The kit's own output is streamed to Write-Log as it runs (a backup takes about 1.5 minutes).
    #>
    param([Parameter(Mandatory)] [object]$Manifest, [Parameter(Mandatory)] [hashtable]$Kit, [string]$LogDir = 'C:\APC_Config\Logs')
    $b = $Manifest.ABB800xA.Backup
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    $log = Join-Path $LogDir ("Backup800xA_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $argz = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Kit.Dir 'Backup-800xA.ps1'),
              '-Start', '-Confirmed',
              '-MinFreeMB', [int]$b.MinFreeMB, '-TimeoutMin', [int]$b.TimeoutMin, '-PollSec', [int]$b.PollSec,
              '-DefPath', [string]$b.DefPath, '-LogFile', $log)

    & $Kit.Ps32 @argz 2>&1 | ForEach-Object { Write-Log INFO "  [800xA backup] $_" }
    $rc = $LASTEXITCODE

    $r = @{ Ok = ($rc -eq 0); ExitCode = $rc; LogFile = $log; Name = ''; Folder = ''; Files = ''; SizeMB = ''; Errors = ''; Warnings = ''
            Message = $(if ($Script:ABB800xABackupExitText.ContainsKey($rc)) { $Script:ABB800xABackupExitText[$rc] } else { "unexpected exit code $rc" }) }
    if (Test-Path -LiteralPath $log) {
        foreach ($line in [System.IO.File]::ReadAllLines($log)) {
            if ($line -match '\bBackup:\s+(.+?)\s*$') { $r.Name = $Matches[1] }
            if ($line -match '\bFolder:\s+(.+?)\s+files=(\d+)\s+size=([\d.]+) MB\s+errors=(\d+)\s+warnings=(\d+)') {
                $r.Folder = $Matches[1]; $r.Files = $Matches[2]; $r.SizeMB = $Matches[3]; $r.Errors = $Matches[4]; $r.Warnings = $Matches[5]
            }
        }
    }
    return $r
}

function Get-800xAPropertyPlan {
    <#
        Turns Manifest.ABB800xA.Properties into a checked write list. Each entry:
          ItemId, Value (tokens expanded), Type, Description, Problem ('' when the entry is valid)
        Tokens in Value/ItemId: {COMPUTERNAME}, {SITE}, {CNC1}..{CNC3} (DOC-assigned machine names),
        {DEVICENR1}..{DEVICENR3}.
        Refused (HANDOFF): values containing ", and SourceCode / TriggerText / ActionTrig_* properties.
    #>
    param([Parameter(Mandatory)] [object]$Manifest, [Parameter(Mandatory)] [hashtable]$State)
    $tokens = @{ COMPUTERNAME = $env:COMPUTERNAME; SITE = [string]$State['SiteCode'] }
    foreach ($m in (Get-AssignedCNCs -State $State -Manifest $Manifest)) {
        $tokens["CNC$($m.CNCIndex)"]      = $m.MachineName
        $tokens["DEVICENR$($m.CNCIndex)"] = $m.DeviceNr
    }
    $expand = {
        param([string]$Text)
        [regex]::Replace($Text, '\{([A-Z0-9]+)\}', { param($x) if ($tokens.ContainsKey($x.Groups[1].Value)) { [string]$tokens[$x.Groups[1].Value] } else { $x.Value } })
    }
    $numeric = @{ Int8 = [sbyte]; Byte = [byte]; Int16 = [int16]; UInt16 = [uint16]; Int32 = [int32]; UInt32 = [uint32]
                  Int64 = [int64]; UInt64 = [uint64]; Float = [single]; Double = [double] }

    foreach ($p in @($Manifest.ABB800xA.Properties)) {
        if (-not $p) { continue }
        $item  = & $expand ([string]$p.ItemId)
        $value = & $expand ([string]$p.Value)
        $type  = if ($p.Type) { [string]$p.Type } else { 'String' }
        $problem = ''
        if (-not $item) { $problem = 'ItemId is empty' }
        elseif ($item -match ':(SourceCode|TriggerText|ActionTrig_)') { $problem = 'This property must never be written (calculation code / triggers / order flags)' }
        elseif ("$item $value" -match '\{[A-Z0-9]+\}') { $problem = "Unknown token in '$item' / '$value'" }
        elseif ($value -match '"') { $problem = 'Values containing double quotes are not supported' }
        elseif ($type -eq 'Bool' -and $value -notin 'True', 'False') { $problem = "Bool value must be True or False, not '$value'" }
        elseif ($numeric.ContainsKey($type)) {
            $parsed = $null
            try { $parsed = [System.Convert]::ChangeType($value, $numeric[$type], [System.Globalization.CultureInfo]::InvariantCulture) } catch { }
            if ($null -eq $parsed) { $problem = "'$value' is not a valid $type" }
        }
        elseif ($type -ne 'String' -and $type -ne 'Bool') { $problem = "Unknown Type '$type' (String, Bool, Int16/32/64, UInt16/32/64, Int8, Byte, Float, Double)" }
        [pscustomobject]@{ ItemId = $item; Value = $value; Type = $type; Description = [string]$p.Description; Problem = $problem }
    }
}

function Invoke-800xAGPCall {
    <#
        Reads ($Value omitted) or writes + reads back one property through the kit's Invoke-800xAGP
        (GPWrite3.vbs under 32-bit cscript). Returns the kit's result object:
        ItemId, Before, After, Success, ExitCode, Error, Output.
    #>
    param([Parameter(Mandatory)] [hashtable]$Kit, [Parameter(Mandatory)] [string]$ItemId, [string]$Value, [string]$Server)
    . (Join-Path $Kit.Dir 'Invoke-800xAGP.ps1')
    $call = @{ ItemId = $ItemId; Server = $Server; ScriptPath = (Join-Path $Kit.Dir 'GPWrite3.vbs') }
    if ($PSBoundParameters.ContainsKey('Value')) { $call.Value = $Value }
    return Invoke-800xAGP @call
}

function Invoke-800xAPropertyStep {
    <#
        Writes Manifest.ABB800xA.Properties (Step 11): for each entry read the current value, skip it when it
        already has the wanted value, otherwise write + read back through the kit. Before/after values go to
        C:\APC_Config\Logs\800xA_changes_<ts>.log and the step results. Stops (throws) at the first failed
        read/write; the remaining entries are reported as not attempted. Nothing is written when the list
        has an invalid entry or the kit fails its checksum check.
    #>
    param([Parameter(Mandatory)] [object]$Manifest, [Parameter(Mandatory)] [hashtable]$State,
          [string]$Phase = 'CHMI', [string]$LogDir = 'C:\APC_Config\Logs')

    $plan = @(Get-800xAPropertyPlan -Manifest $Manifest -State $State)
    if ($plan.Count -eq 0) {
        Write-Log INFO "No 800xA properties configured (manifest ABB800xA.Properties) - nothing to write."
    } else {
        $invalid = @($plan | Where-Object Problem)
        foreach ($p in $invalid) { Add-Result -Phase $Phase -Check "800xA property $($p.ItemId)" -Status FAIL -Detail $p.Problem }
        if ($invalid) { throw "800xA property list has errors - nothing was written. Fix Manifest.ABB800xA.Properties." }

        $kit = Get-800xAKit -Manifest $Manifest
        foreach ($problem in $kit.Problems) { Add-Result -Phase $Phase -Check "800xA kit" -Status FAIL -Detail $problem }
        if ($kit.Problems.Count) { throw "800xA kit not usable - nothing was written." }

        $server    = [string]$Manifest.ABB800xA.OpcServer
        $changeLog = Join-Path $LogDir ("800xA_changes_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        New-Item -ItemType Directory -Path (Split-Path $changeLog) -Force | Out-Null
        $changes = [System.Collections.Generic.List[object]]::new()
        Write-Log INFO "Writing $($plan.Count) 800xA propert$(if ($plan.Count -eq 1) {'y'} else {'ies'}) via $server (log: $changeLog)"

        for ($i = 0; $i -lt $plan.Count; $i++) {
            $p = $plan[$i]
            $label = "800xA property $($p.ItemId)"
            $read = Invoke-800xAGPCall -Kit $kit -ItemId $p.ItemId -Server $server
            if (-not $read.Success) {
                Add-Result -Phase $Phase -Check $label -Status FAIL -Detail "Read failed (exit $($read.ExitCode)): $($read.Error)"
            } else {
                $same = switch ($p.Type) {
                    'String' { $read.Before -ceq $p.Value }
                    'Bool'   { $read.Before -eq $p.Value }
                    default  { try { [double]::Parse($read.Before, [Globalization.CultureInfo]::InvariantCulture) -eq [double]::Parse($p.Value, [Globalization.CultureInfo]::InvariantCulture) } catch { $false } }
                }
                if ($same) {
                    Add-Result -Phase $Phase -Check $label -Status PASS -Detail "Already '$($read.Before)' - not written"
                    Add-Content -Path $changeLog -Value ("{0}  {1}: '{2}' unchanged" -f (Get-Date -Format 's'), $p.ItemId, $read.Before)
                    $changes.Add([pscustomobject]@{ ItemId = $p.ItemId; Before = $read.Before; After = $read.Before; Written = $false })
                    continue
                }
                $w = Invoke-800xAGPCall -Kit $kit -ItemId $p.ItemId -Value $p.Value -Server $server
                $line = "{0}: '{1}' -> '{2}'" -f $p.ItemId, $w.Before, $w.After
                Add-Content -Path $changeLog -Value ("{0}  {1}  exit={2}{3}" -f (Get-Date -Format 's'), $line, $w.ExitCode, $(if ($w.Error) { "  $($w.Error)" }))
                Write-Log INFO "  $line"
                if ($w.Success) {
                    Add-Result -Phase $Phase -Check $label -Status PASS -Detail "'$($w.Before)' -> '$($w.After)'"
                    $changes.Add([pscustomobject]@{ ItemId = $p.ItemId; Before = $w.Before; After = $w.After; Written = $true })
                    continue
                }
                $why = if ($w.ExitCode -eq 3) { "write accepted but read-back differs ('$($w.After)', expected '$($p.Value)')" } else { "write failed (exit $($w.ExitCode)): $($w.Error)" }
                Add-Result -Phase $Phase -Check $label -Status FAIL -Detail $why
            }
            # gate: stop at the first failure, leave the remaining properties untouched
            for ($j = $i + 1; $j -lt $plan.Count; $j++) {
                Add-Result -Phase $Phase -Check "800xA property $($plan[$j].ItemId)" -Status WARN -Detail 'Not attempted (an earlier property failed)'
            }
            $State['800xAPropertyChanges'] = $changes.ToArray()
            throw "800xA property write stopped at $($p.ItemId) - see $changeLog"
        }
        $State['800xAPropertyChanges'] = $changes.ToArray()
        $State['800xAChangeLog'] = $changeLog
    }
}
