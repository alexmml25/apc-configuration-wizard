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
    param([string]$Dir, [ValidateSet('Success', 'NotConnected', 'None')] [string]$Connect = 'Success')
    $global:OnServiceRestart = {
        $logDir = Join-Path $Dir 'log'
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        Get-ChildItem $Dir -Filter '*_*.ini' | Where-Object { $_.BaseName -match '_(\d{4})$' } | ForEach-Object {
            $nr = $Matches[1]
            Set-Content (Join-Path $Dir "$($_.BaseName).dll") 'created by service'
            $line = switch ($Connect) {
                'Success'      { "2026-09-30 12:24:33.509 Success writing command: <169|2|0|598> to controller" }
                'NotConnected' { "2026-09-30 12:24:33.509 Error(s) reported by device ${nr}: INIT Not connected(-2113798134)" }
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
