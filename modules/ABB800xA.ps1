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

function Get-800xASettings {
    <#
        Values for the Step 11 setting tokens: Manifest.ABB800xA.Settings.Default, then Settings.<SiteCode>,
        then State['800xASettings'] (operator choices) on top. Keys are token names (upper case).
        Each layer may hold CELL1..CELL3 objects with per-cell values; with -Cell n, a layer's CELLn values
        apply on top of that layer's own values.
        {DATAROOT} inside a value is the DataApps local data root (State DataAppsLocalRoot or the manifest's).
        Returns a hashtable of strings; Bool values become 'True' / 'False', and an empty value means
        "not set - leave 800xA unchanged".
    #>
    param([Parameter(Mandatory)] [object]$Manifest, [Parameter(Mandatory)] [hashtable]$State, [int]$Cell)
    $pairsOf = {
        param($Layer)
        if ($Layer -is [System.Collections.IDictionary]) { foreach ($k in $Layer.Keys) { [pscustomobject]@{ Name = [string]$k; Value = $Layer[$k] } } }
        elseif ($Layer) { foreach ($f in $Layer.PSObject.Properties) { [pscustomobject]@{ Name = $f.Name; Value = $f.Value } } }
    }
    $layers = @()
    $cfg = $Manifest.ABB800xA.PSObject.Properties['Settings']
    if ($cfg -and $cfg.Value) {
        foreach ($key in 'Default', [string]$State['SiteCode']) {
            if ($key -and $cfg.Value.PSObject.Properties[$key]) { $layers += $cfg.Value.$key }
        }
    }
    $layers += $State['800xASettings']

    $values = @{}
    foreach ($layer in $layers) {
        if (-not $layer) { continue }
        $cellLayer = $null
        foreach ($kv in @(& $pairsOf $layer)) {
            $name = $kv.Name.ToUpper()
            if ($name -match '^CELL\d+$') { if ($Cell -and $name -eq "CELL$Cell") { $cellLayer = $kv.Value }; continue }
            $values[$name] = [string]$kv.Value
        }
        foreach ($kv in @(& $pairsOf $cellLayer)) { $values[$kv.Name.ToUpper()] = [string]$kv.Value }
    }
    $dataRoot = if ($State['DataAppsLocalRoot']) { [string]$State['DataAppsLocalRoot'] } else { [string]$Manifest.DataApps.LocalDataRoot }
    foreach ($k in @($values.Keys)) { $values[$k] = $values[$k].Replace('{DATAROOT}', $dataRoot.TrimEnd('\')) }
    return $values
}

function Get-800xAPropertyPlan {
    <#
        Turns Manifest.ABB800xA.Properties into a checked write list. Each entry:
          ItemId, Value (tokens expanded), Type, Description,
          Problem ('' when the entry is valid), Skip ('' or why the entry is left unchanged)
        Tokens in Value/ItemId: {COMPUTERNAME}, {SITE}, {CNC1}..{CNC3} (DOC-assigned machine names),
        {DEVICENR1}..{DEVICENR3}, and the setting tokens from Get-800xASettings (e.g. {VERIFYONSHIFT}).
        An entry whose ItemId contains {CELL} is repeated for each DOC-assigned CNC n (Cell_n); {CNC}/{DEVICENR}
        then mean that CNC's machine name / Device Nr, and setting tokens use that cell's values.
        Optional per entry: When = a setting token; the entry is only written when that setting is True.
                            Min / Max = allowed range for numeric types.
        Skipped: a setting used in Value is empty (not set), or the When setting is not True.
        Refused (HANDOFF): values containing ", and SourceCode / TriggerText / ActionTrig_* properties.
    #>
    param([Parameter(Mandatory)] [object]$Manifest, [Parameter(Mandatory)] [hashtable]$State)
    $base = @{ COMPUTERNAME = $env:COMPUTERNAME; SITE = [string]$State['SiteCode'] }
    $cncs = Get-AssignedCNCs -State $State -Manifest $Manifest   # already an array (return ,$result); @() would nest it
    foreach ($m in $cncs) {
        $base["CNC$($m.CNCIndex)"]      = $m.MachineName
        $base["DEVICENR$($m.CNCIndex)"] = $m.DeviceNr
    }
    $expand = {
        param([string]$Text, [hashtable]$Tokens)
        [regex]::Replace($Text, '\{([A-Z0-9]+)\}', { param($x) if ($Tokens.ContainsKey($x.Groups[1].Value)) { [string]$Tokens[$x.Groups[1].Value] } else { $x.Value } })
    }
    $numeric = @{ Int8 = [sbyte]; Byte = [byte]; Int16 = [int16]; UInt16 = [uint16]; Int32 = [int32]; UInt32 = [uint32]
                  Int64 = [int64]; UInt64 = [uint64]; Float = [single]; Double = [double] }

    $field = { param($Entry, [string]$Name) $f = $Entry.PSObject.Properties[$Name]; if ($f) { $f.Value } }

    foreach ($p in @($Manifest.ABB800xA.Properties)) {
        if (-not $p) { continue }
        $when = "$(& $field $p 'When')".ToUpper()   # an empty pipeline cast to [string] is $null, not ''
        $min  = & $field $p 'Min'
        $max  = & $field $p 'Max'
        $type = if (& $field $p 'Type') { [string]$p.Type } else { 'String' }

        # one pass per DOC-assigned CNC for {CELL} entries, otherwise a single pass
        $passes = if ([string]$p.ItemId -match '\{CELL\}') {
            @($cncs | ForEach-Object { @{ Cell = [int]$_.CNCIndex; Extra = @{ CELL = $_.CNCIndex; CNC = $_.MachineName; DEVICENR = $_.DeviceNr } } })
        } else { @(@{ Cell = 0; Extra = @{} }) }

        foreach ($pass in $passes) {
            $settings = Get-800xASettings -Manifest $Manifest -State $State -Cell $pass.Cell
            $tokens = $base.Clone()
            foreach ($k in $settings.Keys) { $tokens[$k] = $settings[$k] }
            foreach ($k in $pass.Extra.Keys) { $tokens[$k] = $pass.Extra[$k] }

            $item  = & $expand ([string]$p.ItemId) $tokens
            $value = & $expand ([string]$p.Value) $tokens
            $unset = @([regex]::Matches([string]$p.Value, '\{([A-Z0-9]+)\}') | ForEach-Object { $_.Groups[1].Value } |
                       Where-Object { $settings.ContainsKey($_) -and -not $settings[$_] })
            $skip = ''
            if ($when -and $settings.ContainsKey($when) -and $settings[$when] -ne 'True') { $skip = "only written when $when is True" }
            elseif ($unset) { $skip = "$($unset -join ', ') not set - left unchanged" }

            $problem = ''
            if (-not $item) { $problem = 'ItemId is empty' }
            elseif ($item -match ':(SourceCode|TriggerText|ActionTrig_)') { $problem = 'This property must never be written (calculation code / triggers / order flags)' }
            elseif ($when -and -not $settings.ContainsKey($when)) { $problem = "When refers to an unknown setting '$when'" }
            elseif ($skip) { }
            elseif ("$item $value" -match '\{[A-Z0-9]+\}') { $problem = "Unknown token in '$item' / '$value'" }
            elseif ($value -match '"') { $problem = 'Values containing double quotes are not supported' }
            elseif ($type -eq 'Bool' -and $value -notin 'True', 'False') { $problem = "Bool value must be True or False, not '$value'" }
            elseif ($numeric.ContainsKey($type)) {
                $parsed = $null
                try { $parsed = [System.Convert]::ChangeType($value, $numeric[$type], [System.Globalization.CultureInfo]::InvariantCulture) } catch { }
                if ($null -eq $parsed) { $problem = "'$value' is not a valid $type" }
                elseif ($null -ne $min -and [double]$parsed -lt [double]$min) { $problem = "$value is below the minimum $min" }
                elseif ($null -ne $max -and [double]$parsed -gt [double]$max) { $problem = "$value is above the maximum $max" }
            }
            elseif ($type -ne 'String' -and $type -ne 'Bool') { $problem = "Unknown Type '$type' (String, Bool, Int16/32/64, UInt16/32/64, Int8, Byte, Float, Double)" }
            [pscustomobject]@{ ItemId = $item; Value = $value; Type = $type; Description = [string](& $field $p 'Description'); Problem = $problem; Skip = $skip }
        }
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
        foreach ($p in @($plan | Where-Object Skip)) { Add-Result -Phase $Phase -Check "800xA property $($p.ItemId)" -Status SKIP -Detail $p.Skip }
        $plan = @($plan | Where-Object { -not $_.Skip })
    }
    if ($plan.Count) {
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

$Script:OpcUaServerStateText = @{
    0 = 'Running'; 1 = 'Failed'; 2 = 'NoConfiguration'; 3 = 'Suspended'
    4 = 'Shutdown'; 5 = 'Test'; 6 = 'CommunicationFault'; 7 = 'Unknown'
}

function Get-800xAOpcUaServerStatus {
    <#
        Reads (never writes) the status of the OPC UA server that 800xA OPC UA Connect is connected to
        (Node Administration -> DEVICEWISE OPC UA), through the kit's Invoke-800xAGP. The Server URL itself
        is aspect data and not visible over OPC; the server's own status and build info show whether the
        connection works and which product answers. Returns State, StateText, Product, Manufacturer,
        Version, StartTime, CurrentTime, Good (all reads quality Good), Error.
    #>
    param([Parameter(Mandatory)] [object]$Manifest, [hashtable]$Kit)
    $prefix = [string]$Manifest.CHMI.OpcUaStatusItemPrefix
    $status = [ordered]@{ State = $null; StateText = ''; Product = ''; Manufacturer = ''; Version = ''; StartTime = ''; CurrentTime = ''; Good = $true; Error = '' }
    if (-not $Kit) { $Kit = Get-800xAKit -Manifest $Manifest }
    if ($Kit.Problems.Count) { $status.Error = "800xA kit not usable: $($Kit.Problems -join '; ')"; return [pscustomobject]$status }

    $items = [ordered]@{
        State        = 'ServerStatus.State'
        Product      = 'ServerStatus.BuildInfo.ProductName'
        Manufacturer = 'ServerStatus.BuildInfo.ManufacturerName'
        Version      = 'ServerStatus.BuildInfo.SoftwareVersion'
        StartTime    = 'ServerStatus.StartTime'
        CurrentTime  = 'ServerStatus.CurrentTime'
    }
    foreach ($key in $items.Keys) {
        $r = Invoke-800xAGPCall -Kit $Kit -ItemId "$prefix$($items[$key])" -Server ([string]$Manifest.ABB800xA.OpcServer)
        if (-not $r.Success) { $status.Error = "Read of $prefix$($items[$key]) failed (exit $($r.ExitCode)): $($r.Error)"; break }
        # OPC DA quality: 192-219 = Good; anything else means the value is not live
        if ($r.Output -match 'quality=(\d+)' -and ([int]$Matches[1] -band 0xC0) -ne 0xC0) { $status.Good = $false }
        $status[$key] = $r.Before
    }
    if (-not $status.Error) {
        $code = 0
        if ([int]::TryParse([string]$status.State, [ref]$code)) {
            $status.State = $code
            $status.StateText = if ($Script:OpcUaServerStateText.ContainsKey($code)) { $Script:OpcUaServerStateText[$code] } else { "state $code" }
        } else { $status.StateText = "unreadable state '$($status.State)'" }
    }
    [pscustomobject]$status
}

function Test-800xAServerIsOtherGateway {
    # '' when the server start time 800xA reads matches this VM's dwcore process start (within 3 minutes, local or
    # UTC), else the reason. '' too when it cannot be compared (no dwcore process, unreadable time).
    param($StartTime)
    try {
        $q = @(& sc.exe queryex dwcore 2>$null) | Where-Object { $_ -match '^\s*PID\s*:\s*(\d+)' } | Select-Object -First 1
        if (-not $q -or [int]$Matches[1] -le 0) { return '' }
        $local = (Get-Process -Id ([int]$Matches[1]) -ErrorAction Stop).StartTime
        $read  = if ($StartTime -is [datetime]) { $StartTime } else { [datetime]::Parse([string]$StartTime, [Globalization.CultureInfo]::InvariantCulture) }
        $diffLocal = [math]::Abs(($read - $local).TotalMinutes)
        $diffUtc   = [math]::Abs(($read - $local.ToUniversalTime()).TotalMinutes)
        if ([math]::Min($diffLocal, $diffUtc) -le 3) { return '' }
        return "800xA reads a deviceWise server started $read, but this VM's dwcore started $local - the DEVICEWISE OPC UA Server URL points to another machine (Step 11 sets it)"
    } catch { return '' }
}

function Test-800xAOpcUaServer {
    <#
        Adds one result for the OPC UA server connection: PASS when it is Running with Good quality and the
        product matches CHMI.ExpectedServerProduct, WARN when another product answers, FAIL otherwise.
        Returns the detail text; throws on FAIL when -Throw is given (for Step 13's Check blocks).
    #>
    param([Parameter(Mandatory)] [object]$Manifest, [string]$Phase = 'CHMI', [string]$Check = 'OPC UA server connection', [switch]$Throw)
    $s = Get-800xAOpcUaServerStatus -Manifest $Manifest
    $expected = [string]$Manifest.CHMI.ExpectedServerProduct
    $who = "$($s.Product) $($s.Version) ($($s.Manufacturer))".Trim()
    if ($s.Error) {
        $status = 'FAIL'; $detail = $s.Error
    } elseif ($s.State -ne 0) {
        $status = 'FAIL'; $detail = "Server state $($s.StateText) - $who"
    } elseif (-not $s.Good) {
        $status = 'FAIL'; $detail = 'Values are not live (OPC quality not Good) - check the connection in Node Administration'
    } elseif ($expected -and $s.Product -notmatch [regex]::Escape($expected)) {
        $status = 'WARN'; $detail = "Running, but the server is '$who', expected $expected"
    } elseif (($other = Test-800xAServerIsOtherGateway -StartTime $s.StartTime)) {
        # 800xA can read another machine's gateway (a VM copied from SJUM7AAPPS0065 kept its Server URL, 2026-10-15)
        $status = 'FAIL'; $detail = $other
    } else {
        $status = 'PASS'; $detail = "Running - $who, server started $($s.StartTime)"
    }
    if ($Throw) {
        if ($status -eq 'FAIL') { throw $detail }
        return $(if ($status -eq 'WARN') { "WARN: $detail" } else { $detail })
    }
    Add-Result -Phase $Phase -Check $Check -Status $status -Detail $detail
    $detail
}

function Get-800xAOpcUaCertificates {
    <#
        Reads (never changes) the 800xA OPC UA certificates under CHMI.PkiRoot.
        - Root: the newest 800xAOpcUaRoot in OpcUaConnect\pki\issuer or pki\trusted. The portal's Update
          Application Certificates moves the root from the issuer list to the trusted list (VM 2026-10-15), and an
          older root with the same name can sit in either (seen on the MPR VM), so the newest one counts.
        - 800xAOpcUaConnect and 800xAOpcUaManagementPortal: the newest of their pki file and their LocalMachine\My
          certificate (where the applications keep the one they use): whether each one is signed by that root. This is checked on the signature (certificate chain), not on the
          issuer name, because every 800xA root has the same name.
        Returns one object per certificate: Name, Path, Found, Thumbprint, NotBefore, Issuer, IssuedByRoot.
    #>
    param([Parameter(Mandatory)] [object]$Manifest)
    $cfg  = $Manifest.CHMI
    $root = [string]$cfg.RootCertName
    $X509 = 'System.Security.Cryptography.X509Certificates'

    $newest = {
        param([string]$App, [string]$Store, [string]$Filter)
        $dir = [string]$cfg.PkiRoot
        foreach ($part in $App, 'pki', $Store, 'certs') { $dir = Join-Path $dir $part }
        $cert = @(Get-ChildItem -LiteralPath $dir -Filter $Filter -File -ErrorAction SilentlyContinue | ForEach-Object {
            try { New-Object "$X509.X509Certificate2" $_.FullName | Add-Member -NotePropertyName File -NotePropertyValue $_.FullName -PassThru } catch { }
        }) | Sort-Object NotBefore -Descending | Select-Object -First 1
        @{ Cert = $cert; Path = if ($cert) { $cert.File } else { Join-Path $dir $Filter } }
    }
    $signedBy = {
        param($Cert, $RootCert)
        if (-not $Cert -or -not $RootCert) { return $false }
        if ($Cert.Thumbprint -eq $RootCert.Thumbprint) { return $true }
        $chain = New-Object "$X509.X509Chain"
        $chain.ChainPolicy.RevocationMode    = 'NoCheck'
        $chain.ChainPolicy.VerificationFlags = 'AllowUnknownCertificateAuthority, IgnoreNotTimeValid'
        [void]$chain.ChainPolicy.ExtraStore.Add($RootCert)
        [void]$chain.Build($Cert)
        $top = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
        # the chain only reaches the root when the root's key verifies the signature
        $top.Thumbprint -eq $RootCert.Thumbprint -and -not @($chain.ChainStatus | Where-Object { $_.Status -match 'NotSignatureValid' })
    }

    $pick = {
        # newest of several candidates (each @{ Cert; Path })
        param([object[]]$Candidates)
        $best = @($Candidates | Where-Object { $_.Cert } | Sort-Object { $_.Cert.NotBefore } -Descending | Select-Object -First 1)
        if ($best) { $best[0] } else { $Candidates[0] }
    }
    $fromMy = {
        param([string]$Cn)
        $st = New-Object "$X509.X509Store" ('My', 'LocalMachine')
        try {
            $st.Open('ReadOnly')
            $cert = @($st.Certificates | Where-Object { $_.Subject -match "^CN=$([regex]::Escape($Cn))(,|$)" } | Sort-Object NotBefore -Descending | Select-Object -First 1)
            @{ Cert = if ($cert) { $cert[0] } else { $null }; Path = "Cert:\LocalMachine\My (CN=$Cn)" }
        } catch { @{ Cert = $null; Path = "Cert:\LocalMachine\My (CN=$Cn)" } } finally { $st.Close() }
    }

    $rootInfo = & $pick @((& $newest 'OpcUaConnect' 'issuer' "$root*.der"), (& $newest 'OpcUaConnect' 'trusted' "$root*.der"))
    $items = @(
        @{ Name = $root;                        Info = $rootInfo }
        @{ Name = '800xAOpcUaConnect';          Info = (& $pick @((& $newest 'OpcUaConnect' 'own' '800xAOpcUaConnect*.der'), (& $fromMy '800xAOpcUaConnect'))) }
        @{ Name = '800xAOpcUaManagementPortal'; Info = (& $pick @((& $newest 'OpcUaManagementPortal' 'trusted' '800xAOpcUaManagementPortal*.der'), (& $fromMy '800xAOpcUaManagementPortal'))) }
    )
    foreach ($i in $items) {
        $cert = $i.Info.Cert
        [pscustomobject]@{
            Name         = $i.Name
            Path         = $i.Info.Path
            Found        = [bool]$cert
            Thumbprint   = if ($cert) { $cert.Thumbprint } else { '' }
            NotBefore    = if ($cert) { $cert.NotBefore } else { $null }
            Issuer       = if ($cert) { $cert.Issuer } else { '' }
            IssuedByRoot = [bool](& $signedBy $cert $rootInfo.Cert)
        }
    }
}

function Get-800xAServiceStates {
    <#
        Reads (never writes) SERVICE_STATE / S_STATUS / S_DESCRIPTION of each service provider in
        Manifest.CHMI.ServiceChecks (D01558132 section 1.4 order) over OPC DA, through the kit.
        Normal = SERVICE_STATE 'Service', S_STATUS 0, quality Good (all providers on SJUM7AAPPS0048, 2026-10-15).
        A provider that cannot be read is 'Missing' (Optional entries: not on this node) or a problem.
        The 1.4 untick/tick of Enabled is not scripted: the interface behind it is internal to 800xA (user: check only).
        Returns one object per entry: Name, ItemPath, State, Status, Description, Good, Ok, Missing, Detail.
    #>
    param([Parameter(Mandatory)] [object]$Manifest, [hashtable]$Kit)
    if (-not $Kit) { $Kit = Get-800xAKit -Manifest $Manifest }
    $server = [string]$Manifest.ABB800xA.OpcServer
    foreach ($svc in @($Manifest.CHMI.ServiceChecks)) {
        $path = ([string]$svc.ItemPath) -replace '\{HOST\}', $env:COMPUTERNAME
        $o = [ordered]@{ Name = [string]$svc.Name; ItemPath = $path; State = ''; Status = $null; Description = ''; Good = $true; Ok = $false; Missing = $false; Detail = '' }
        if ($Kit.Problems.Count) { $o.Detail = "800xA kit not usable: $($Kit.Problems -join '; ')"; [pscustomobject]$o; continue }
        $read = $true
        foreach ($p in 'SERVICE_STATE', 'S_STATUS', 'S_DESCRIPTION') {
            $r = Invoke-800xAGPCall -Kit $Kit -ItemId "$path`:$p" -Server $server
            if (-not $r.Success) {
                if ($p -eq 'S_DESCRIPTION') { continue }
                $read = $false; $o.Detail = "read of $path`:$p failed (exit $($r.ExitCode)): $($r.Error)"; break
            }
            if ($r.Output -match 'quality=(\d+)' -and ([int]$Matches[1] -band 0xC0) -ne 0xC0) { $o.Good = $false }
            switch ($p) { 'SERVICE_STATE' { $o.State = [string]$r.Before } 'S_STATUS' { $o.Status = $r.Before } 'S_DESCRIPTION' { $o.Description = [string]$r.Before } }
        }
        if (-not $read) {
            if ($svc.PSObject.Properties['Optional'] -and $svc.Optional) { $o.Missing = $true; $o.Ok = $true; $o.Detail = 'no provider for this service on this node - skipped' }
            [pscustomobject]$o; continue
        }
        $o.Ok = ($o.State -eq 'Service' -and "$($o.Status)" -eq '0' -and $o.Good)
        $o.Detail = "SERVICE_STATE '$($o.State)', S_STATUS $($o.Status)$(if (-not $o.Good) { ', quality not Good' })$(if ($o.Description) { " - $($o.Description)" })"
        [pscustomobject]$o
    }
}

function Invoke-800xACalculationCheck {
    <#
        tools\Invoke-800xACalculations.ps1 (32-bit): every Inform IT calculation enabled with Status 0 - the
        Calculation Status Viewer check of D01558132 1.4. -Confirm re-enables a disabled or errored one (the
        viewer's right-click > Enable). Returns @{ Code; Report; Lines }: 0 all OK / none, 1 problems (check only),
        5 problems left after re-enabling, other = could not check.
    #>
    param([Parameter(Mandatory)] [object]$Manifest, [string]$LogDir = 'C:\APC_Config\Logs', [switch]$Confirm)
    $tool = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools\Invoke-800xACalculations.ps1'
    $ps32 = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    $toolArgs = @('-OutDir', $LogDir)
    if ($Manifest.CHMI.PSObject.Properties['CalculationsBinDir'] -and $Manifest.CHMI.CalculationsBinDir) { $toolArgs += @('-CalcBinDir', [string]$Manifest.CHMI.CalculationsBinDir) }
    if ($Confirm) { $toolArgs += '-Confirmed' }
    $out  = @(& $ps32 -NoProfile -STA -ExecutionPolicy Bypass -File $tool @toolArgs 2>&1 | ForEach-Object { "$_" })
    $rep  = @($out | Where-Object { $_ -match '^Written: ' } | Select-Object -Last 1) -replace '^Written: ', ''
    @{ Code = $LASTEXITCODE; Report = "$rep"; Lines = $out }
}

function Get-800xACellOpcStates {
    <#
        Reads (never writes) <Manifest.CHMI.CellOpcPath with {n}>:CNCAsset / :CNCType for each DOC-assigned CNC through
        the kit. The 'OPC' child of each Medtronic cell is the uploaded deviceWise CNC{n} node (SOP: each cell must have a
        child named OPC); matching values with Good quality prove it exists, is named right and is live.
        Returns per cell: Cell, Machine, Asset, Type, Good, Exists, Ok, Detail.
    #>
    param([Parameter(Mandatory)] [object]$Manifest, [Parameter(Mandatory)] [hashtable]$State, [hashtable]$Kit)
    if (-not $Kit) { $Kit = Get-800xAKit -Manifest $Manifest }
    $server = [string]$Manifest.ABB800xA.OpcServer
    $tmpl   = if ($Manifest.CHMI.PSObject.Properties['CellOpcPath'] -and $Manifest.CHMI.CellOpcPath) { [string]$Manifest.CHMI.CellOpcPath } else { 'Root/Medtronic/Cell_{n}/OPC' }
    $assigned = Get-AssignedCNCs -State $State -Manifest $Manifest   # assignment unrolls the ,$result it returns (@() would nest it)
    foreach ($m in $assigned) {
        $path = $tmpl -replace '\{n\}', $m.CNCIndex
        $o = [ordered]@{ Cell = "Cell_$($m.CNCIndex)"; Path = $path; Machine = [string]$m.MachineName; MachineType = [string]$m.CNCType
                         Asset = ''; Type = ''; Good = $true; Exists = $false; Ok = $false; Detail = '' }
        if ($Kit.Problems.Count) { $o.Detail = "800xA kit not usable: $($Kit.Problems -join '; ')"; [pscustomobject]$o; continue }
        foreach ($p in 'CNCAsset', 'CNCType') {
            $r = Invoke-800xAGPCall -Kit $Kit -ItemId "$path`:$p" -Server $server
            if (-not $r.Success) { $o.Detail = "no $path`:$p ($($r.Error)) - the cell has no 'OPC' child, or it is not uploaded/named OPC"; break }
            $o.Exists = $true
            if ($r.Output -match 'quality=(\d+)' -and ([int]$Matches[1] -band 0xC0) -ne 0xC0) { $o.Good = $false }
            if ($p -eq 'CNCAsset') { $o.Asset = [string]$r.Before } else { $o.Type = [string]$r.Before }
        }
        if ($o.Exists -and -not $o.Detail) {
            $o.Ok = $o.Good -and $o.Asset -eq $o.Machine -and (-not $o.MachineType -or $o.Type -eq $o.MachineType)
            $o.Detail = "$path`: CNCAsset '$($o.Asset)', CNCType '$($o.Type)'$(if (-not $o.Good) { ', quality not Good (not live)' })$(if ($o.Asset -ne $o.Machine) { " - expected '$($o.Machine)'" })"
        }
        [pscustomobject]$o
    }
}
