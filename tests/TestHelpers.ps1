<#
    Shared helpers for the Pester tests. Dot-source from BeforeAll:
        BeforeAll { . (Join-Path $PSScriptRoot 'TestHelpers.ps1') }

    Tests never touch real install paths: every manifest path is redirected into $TestDrive,
    services are stubbed, and State.SandboxRoot keeps Step 10 from creating folders elsewhere.
#>

$Script:RepoRoot   = Split-Path $PSScriptRoot -Parent
$Script:ModulesDir = Join-Path $Script:RepoRoot 'modules'
$Script:Fixtures   = Join-Path $PSScriptRoot 'fixtures'

# Runner-provided functions that step modules call, plus service stubs (functions win over cmdlets)
$global:StepResults    = [System.Collections.Generic.List[object]]::new()
$global:ServiceActions = [System.Collections.Generic.List[string]]::new()
function global:Write-Log  { param([string]$Level, [string]$Message) }
function global:Add-Result {
    param([string]$Phase, [string]$Check, [string]$Status, [string]$Detail = '')
    $global:StepResults.Add([pscustomobject]@{ Phase = $Phase; Check = $Check; Status = $Status; Detail = $Detail })
}
$global:OnServiceRestart = $null
function global:Restart-Service {
    param($Name, [switch]$Force, $ErrorAction)
    $global:ServiceActions.Add("restart $Name")
    if ($global:OnServiceRestart) { & $global:OnServiceRestart }
}
function global:Start-Sleep { param($Seconds, $Milliseconds) }   # no waiting in tests

# Make the service stub behave like CNCnetPDM: on start it creates <dll>_<DeviceNr>.dll for each <dll>_<DeviceNr>.ini
# and, unless -Connect None, writes a connection result to each device log (<Dir>\log\log_<DeviceNr>_<yyMMdd>.txt)
function Set-ServiceCreatesDriverDlls {
    param([string]$Dir, [ValidateSet('Success', 'NotConnected', 'CommandIncorrect', 'None')] [string]$Connect = 'Success')
    $global:OnServiceRestart = {
        $logDir = Join-Path $Dir 'log'
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        Get-ChildItem $Dir -Filter '*_*.ini' | Where-Object { $_.BaseName -match '_(\d{4})$' } | ForEach-Object {
            $nr = $Matches[1]
            Set-Content (Join-Path $Dir "$($_.BaseName).dll") 'created by service'
            $line = switch ($Connect) {
                'Success'      { "2026-09-30 12:24:33.509 Success writing command: <169|2|0|598> to controller" }
                'NotConnected' { "2026-09-30 12:24:33.509 Error(s) reported by device ${nr}: INIT Not connected(-2113798134)" }
                'CommandIncorrect' { "2026-09-30 15:27:43.451 Error(s) reported by device ${nr}: Parts_Machined Command incorrect, deactivated Part_Required Command incorrect, deactivated" }
                default        { $null }
            }
            if ($line) { Add-Content (Join-Path $logDir "log_${nr}_$(Get-Date -Format 'yyMMdd').txt") $line }
        }
    }.GetNewClosure()
}

# Point a CNCnetPDM.ini copy's log folder ([Protokoll] PFAD) at <folder>\log so tests never read real CNCnetPDM logs
function Set-TestLogDir {
    param([string]$IniPath)
    $logDir = Join-Path (Split-Path $IniPath -Parent) 'log'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $text = [System.IO.File]::ReadAllText($IniPath) -replace '(?m)^PFAD\s*=.*$', "PFAD = $logDir"
    [System.IO.File]::WriteAllText($IniPath, $text)
}
function global:Get-Service     { param($Name, $ErrorAction) [pscustomobject]@{ Name = $Name; Status = 'Running' } }

function Reset-StepResults { $global:StepResults.Clear(); $global:ServiceActions.Clear(); $global:OnServiceRestart = $null }
function Get-StepResults   { param([string]$Status) @($global:StepResults | Where-Object { -not $Status -or $_.Status -eq $Status }) }

function Get-TestManifest {
    Get-Content (Join-Path $Script:RepoRoot 'APC_ConfigManifest.json') -Raw | ConvertFrom-Json
}

function Get-Fixture { param([string]$RelativePath) Join-Path $Script:Fixtures $RelativePath }

# The three Humacao machines from the HUM examples, plus one Site DB machine not assigned to DOC
function New-HumState {
    param([int]$DocCount = 3, [string[]]$Assign = @('Humacao_L20X_1', 'Humacao_L20X_3', 'Humacao_L20X_8'))
    $machines = @(
        @{ MachineName = 'Humacao_L20X_1'; IPAddress = '10.101.99.47'; Port = '683'; AssetFamily = 'CITIZEN_L20X_IV'; CNCType = 'CITIZEN_L20X_IV'; DLLName = 'citizenm.dll' },
        @{ MachineName = 'Humacao_L20X_2'; IPAddress = '10.101.99.50'; Port = '683'; AssetFamily = 'CITIZEN_L20X_IV'; CNCType = 'CITIZEN_L20X_IV'; DLLName = 'citizenm.dll' },
        @{ MachineName = 'Humacao_L20X_3'; IPAddress = '10.101.99.48'; Port = '683'; AssetFamily = 'CITIZEN_L20X_IV'; CNCType = 'CITIZEN_L20X_IV'; DLLName = 'citizenm.dll' },
        @{ MachineName = 'Humacao_L20X_8'; IPAddress = '10.101.99.63'; Port = '683'; AssetFamily = 'CITIZEN_L20X_IV'; CNCType = 'CITIZEN_L20X_IV'; DLLName = 'citizenm.dll' }
    )
    @{ SiteCode = 'MPR'; CNCMachines = $machines; DOCCount = $DocCount; DOCMachineAssignments = @($Assign | Select-Object -First $DocCount) }
}

# Text of an ini file without blank lines, with "; x" / ";x" comments normalised, and without the
# log folder line (tests point PFAD at their own folder)
function Get-NormalizedIni {
    param([string]$Path)
    @([System.IO.File]::ReadAllLines($Path) | Where-Object { $_.Trim() -and $_ -notmatch '^PFAD\s*=' } | ForEach-Object { $_.TrimEnd() -replace '^;\s*', ';' })
}

# Fake installed layout as on the APC VM: DOC-{n}\DOC_II, \Plugins (PartLookup), \Plugins\IQS (SpcDb, Iqs)
function New-DocInstall {
    param([string]$Root, [int]$Count = 3)
    for ($n = 1; $n -le $Count; $n++) {
        $base = Join-Path $Root "DOC-$n/DOC_II"
        $iqs  = Join-Path $base 'Plugins/IQS'
        New-Item -ItemType Directory -Path $iqs -Force | Out-Null
        'DocDb.xml', 'DOC_II.xml' | ForEach-Object { Copy-Item (Get-Fixture "DOC/$_") $base }
        Copy-Item (Get-Fixture 'DOC/PartLookup.xml') (Join-Path $base 'Plugins')
        'SpcDb.xml', 'IqsDocSpcDataCollector.xml'   | ForEach-Object { Copy-Item (Get-Fixture "DOC/$_") $iqs }
    }
}

<#
    Runs one #region of Step 13 (e.g. 'T5 - DOC' up to 'T6 - CNCnetPDM') with its inner helper functions
    and the given variables, and returns the $checks list it produced. Invoke-Verification as a whole needs
    a live VM (deviceWise, PostgreSQL, services), so the file-based sections are tested individually.
#>
function Invoke-VerificationRegion {
    param([Parameter(Mandatory)] [string]$From, [Parameter(Mandatory)] [string]$To, [hashtable]$Variables = @{})
    $src   = Get-Content (Join-Path $Script:ModulesDir '13-Verification.ps1') -Raw
    $start = $src.IndexOf("#region $From")
    $end   = $src.IndexOf("#region $To")
    if ($start -lt 0 -or $end -lt 0) { throw "Region '$From'..'$To' not found in 13-Verification.ps1" }
    $helpers = foreach ($name in 'Check', 'Blank', 'NA', 'Warn', 'DWGet', 'ReadIni', 'XmlAttr', 'LoadXml') {
        $m = [regex]::Match($src, "(?ms)^    function $name \{.*?^    \}\r?$")
        if (-not $m.Success) { throw "Helper $name not found in 13-Verification.ps1" }
        $m.Value
    }
    $body = @(
        'param($__vars)'
        'foreach ($__k in $__vars.Keys) { Set-Variable -Name $__k -Value $__vars[$__k] }'
        '$checks = [System.Collections.Generic.List[hashtable]]::new()'
        $helpers
        $src.Substring($start, $end - $start)
        ',$checks'
    ) -join "`n"
    . (Join-Path $Script:ModulesDir 'Common.ps1')
    & ([scriptblock]::Create($body)) $Variables
}

function Get-Check {
    param($Checks, [string]$NameLike)
    @($Checks | Where-Object { $_.Name -like $NameLike }) | Select-Object -First 1
}

# ---- Fake 800xA kit (same file names and output format as kits\800xA) ----
$Script:PwshPath = (Get-Process -Id $PID).Path

function New-Fake800xAKit {
    param([int]$BackupExit = 0)
    $dir = Join-Path $TestDrive "kit-$([guid]::NewGuid().ToString('N').Substring(0,6))"
    New-Item -ItemType Directory -Path $dir | Out-Null
    Set-Content (Join-Path $dir 'Backup-800xA.ps1') @"
param([string]`$DefPath, [switch]`$Start, [switch]`$Confirmed, [int]`$MinFreeMB, [int]`$TimeoutMin, [int]`$PollSec, [string]`$LogFile)
function Out([string]`$t) { `$l = "12:00:00  `$t"; Write-Host `$l; Add-Content -Path `$LogFile -Value `$l }
Out "Backup-800xA  Mode=START  Def=`$DefPath  Start=`$Start Confirmed=`$Confirmed MinFreeMB=`$MinFreeMB"
if ($BackupExit -eq 0) {
    `$root = if (`$env:FAKE_800XA_BACKUPDIR) { `$env:FAKE_800XA_BACKUPDIR } else { 'C:\BACKUP' }
    `$folder = Join-Path `$root 'Full backup; 2026-09-30; 16-05'
    if (`$env:FAKE_800XA_BACKUPDIR) { New-Item -ItemType Directory -Path `$folder -Force | Out-Null; Set-Content (Join-Path `$folder 'Backup.log') 'Backup completed.' }
    Out "Backup: Full backup; 2026-09-30; 16-05"
    Out "Folder: `$folder   files=45  size=110.2 MB   errors=0  warnings=0"
    Out "RESULT: BACKUP OK"
} else { Out "RESULT: failed" }
exit $BackupExit
"@
    Set-Content (Join-Path $dir 'Invoke-800xAGP.ps1') @'
function Invoke-800xAGP {
    param([Parameter(Mandatory)][string]$ItemId, [string]$Value, [string]$Server, [string]$ScriptPath)
    $storePath = Join-Path (Split-Path $ScriptPath) 'store.json'
    $store = @{}; (Get-Content $storePath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $store[$_.Name] = $_.Value }
    if ($ItemId -like 'Fail:*') { return [pscustomobject]@{ ItemId = $ItemId; Before = $null; After = $null; Success = $false; ExitCode = 1; Error = "ERROR at step 'AddItem $ItemId'"; Output = '' } }
    $before = [string]$store[$ItemId]
    if (-not $PSBoundParameters.ContainsKey('Value')) { return [pscustomobject]@{ ItemId = $ItemId; Before = $before; After = $null; Success = $true; ExitCode = 0; Error = $null; Output = '' } }
    $after = if ($ItemId -like 'Differ:*') { 'something else' } else { $Value }
    $store[$ItemId] = $after; $store | ConvertTo-Json | Set-Content $storePath
    $rc = if ($after -ceq $Value) { 0 } else { 3 }
    [pscustomobject]@{ ItemId = $ItemId; Before = $before; After = $after; Success = ($rc -eq 0); ExitCode = $rc; Error = $null; Output = '' }
}
'@
    Set-Content (Join-Path $dir 'GPWrite3.vbs') "' fake"
    Set-Content (Join-Path $dir 'GPExplore.vbs') "' fake"
    Set-Content (Join-Path $dir 'store.json') '{ "Cell_1:URL1": "C:\\old.png", "Cell_1:Count": "5", "Cell_1:Flag": "False" }'
    $sums = 'Backup-800xA.ps1', 'GPWrite3.vbs', 'Invoke-800xAGP.ps1', 'GPExplore.vbs' |
            ForEach-Object { "$((Get-FileHash (Join-Path $dir $_) -Algorithm SHA256).Hash.ToLower())  $_" }
    Set-Content (Join-Path $dir 'SHA256SUMS.txt') $sums
    $dir
}
function New-800xAManifest {
    param([string]$KitDir, [object[]]$Properties = @())
    $m = Get-TestManifest
    $m.ABB800xA.KitDir = $KitDir
    $m.ABB800xA.PowerShell32 = $Script:PwshPath
    $m.ABB800xA.Cscript32 = $Script:PwshPath
    $m.ABB800xA.Properties = @($Properties | ForEach-Object { [pscustomobject]$_ })
    $m
}
function Get-Store { param([string]$Kit) Get-Content (Join-Path $Kit 'store.json') -Raw | ConvertFrom-Json }

# robocopy stand-in for tests (copies with Copy-Item, honours /XD full paths, exit code 1 = files copied)
function global:robocopy.exe {
    $src = $args[0]; $dst = $args[1]
    $xd = @(); $inXd = $false
    foreach ($a in $args[2..($args.Count - 1)]) {
        if ($a -eq '/XD') { $inXd = $true; continue }
        if ($a -match '^/[A-Za-z]+(:|$)') { $inXd = $false; continue }   # a robocopy switch, not a path
        if ($inXd) { $xd += $a }
    }
    $global:RobocopyCalls.Add([pscustomobject]@{ Source = $src; Destination = $dst; Exclude = $xd })
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    Get-ChildItem -LiteralPath $src -Recurse -File | Where-Object { $f = $_.FullName; -not ($xd | Where-Object { $f.StartsWith($_ + [IO.Path]::DirectorySeparatorChar) }) } | ForEach-Object {
        $target = Join-Path $dst $_.FullName.Substring($src.Length).TrimStart([char]92, [char]47)
        New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $target
    }
    $global:LASTEXITCODE = 1
}
$global:RobocopyCalls = [System.Collections.Generic.List[object]]::new()
