<#
    800xA wrappers (modules\ABB800xA.ps1). The real kit needs 800xA, so these tests run a fake kit with the
    same file names and output format: a Backup-800xA.ps1 that writes a log like the real one and exits
    with a chosen code, and an Invoke-800xAGP.ps1 backed by a JSON "property store".
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $ModulesDir 'ABB800xA.ps1')

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
    Out "Backup: Full backup; 2026-09-30; 16-05"
    Out "Folder: C:\BACKUP\Full backup; 2026-09-30; 16-05   files=45  size=110.2 MB   errors=0  warnings=0"
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
}

Describe '800xA kit' {
    It 'the shipped kit in kits\800xA matches its SHA256SUMS.txt' {
        $m = Get-TestManifest
        $m.ABB800xA.PowerShell32 = $Script:PwshPath; $m.ABB800xA.Cscript32 = $Script:PwshPath
        (Get-800xAKit -Manifest $m).Problems | Should -BeNullOrEmpty
    }

    It 'reports a kit file that was changed' {
        $kit = New-Fake800xAKit
        Add-Content (Join-Path $kit 'GPWrite3.vbs') "' edited"
        (Get-800xAKit -Manifest (New-800xAManifest $kit)).Problems | Should -Contain 'Kit file changed (SHA256 mismatch): GPWrite3.vbs'
    }

    It 'reports a missing 32-bit executable' {
        $m = New-800xAManifest (New-Fake800xAKit)
        $m.ABB800xA.PowerShell32 = Join-Path $TestDrive 'no\powershell.exe'
        (Get-800xAKit -Manifest $m).Problems | Should -Contain "32-bit executable not found: $(Join-Path $TestDrive 'no\powershell.exe')"
    }
}

Describe 'Invoke-800xABackup (Step 12)' {
    It 'passes the kit the start/confirm switches and reads the backup name from its log' {
        $m = New-800xAManifest (New-Fake800xAKit)
        $r = Invoke-800xABackup -Manifest $m -Kit (Get-800xAKit -Manifest $m) -LogDir (Join-Path $TestDrive 'logs')
        $r.Ok       | Should -BeTrue
        $r.ExitCode | Should -Be 0
        $r.Name     | Should -Be 'Full backup; 2026-09-30; 16-05'
        $r.Files    | Should -Be '45'
        $r.Errors   | Should -Be '0'
        Get-Content $r.LogFile -Raw | Should -Match 'Start=True Confirmed=True MinFreeMB=2048'
    }

    It 'fails on exit code <Code> with "<Text>"' -ForEach @(
        @{ Code = 1; Text = 'could not start' }, @{ Code = 5; Text = 'completed with errors' }, @{ Code = 6; Text = 'not enough free disk' }
    ) {
        $m = New-800xAManifest (New-Fake800xAKit -BackupExit $Code)
        $r = Invoke-800xABackup -Manifest $m -Kit (Get-800xAKit -Manifest $m) -LogDir (Join-Path $TestDrive 'logs')
        $r.Ok       | Should -BeFalse
        $r.ExitCode | Should -Be $Code
        $r.Message  | Should -Match $Text
    }
}

Describe 'Get-800xAPropertyPlan' {
    It 'expands tokens' {
        $m = New-800xAManifest (New-Fake800xAKit) @(@{ ItemId = 'Cell_{SITE}:URL1'; Value = '\\{COMPUTERNAME}\{CNC2}-{DEVICENR2}.png'; Type = 'String' })
        $p = Get-800xAPropertyPlan -Manifest $m -State (New-HumState)
        $p.ItemId  | Should -Be 'Cell_MPR:URL1'
        $p.Value   | Should -Be "\\$env:COMPUTERNAME\Humacao_L20X_3-1003.png"
        $p.Problem | Should -BeNullOrEmpty
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'a forbidden property';   Item = 'Calc_1:SourceCode'; Value = 'x';      Type = 'String' }
        @{ Case = 'an order flag';          Item = 'Obj:ActionTrig_1';  Value = '1';      Type = 'Int32' }
        @{ Case = 'double quotes';          Item = 'Cell_1:URL1';       Value = 'a"b';    Type = 'String' }
        @{ Case = 'a bad Bool';             Item = 'Cell_1:Flag';       Value = 'yes';    Type = 'Bool' }
        @{ Case = 'a bad number';           Item = 'Cell_1:Count';      Value = '1.5';    Type = 'Int32' }
        @{ Case = 'an unknown token';       Item = 'Cell_1:URL1';       Value = '{NOPE}'; Type = 'String' }
        @{ Case = 'an unknown type';        Item = 'Cell_1:URL1';       Value = 'x';      Type = 'Text' }
    ) {
        $m = New-800xAManifest (New-Fake800xAKit) @(@{ ItemId = $Item; Value = $Value; Type = $Type })
        (Get-800xAPropertyPlan -Manifest $m -State (New-HumState)).Problem | Should -Not -BeNullOrEmpty
    }

    It 'keeps GUID-style ItemIDs untouched' {
        $id = '{3E2F1A00-1111-2222-3333-444455556666}{0A0B0C0D-1111-2222-3333-444455556666}:PartNumberTag'
        $m = New-800xAManifest (New-Fake800xAKit) @(@{ ItemId = $id; Value = 'P1'; Type = 'String' })
        $p = Get-800xAPropertyPlan -Manifest $m -State (New-HumState)
        $p.ItemId | Should -Be $id
        $p.Problem | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-800xAPropertyStep (Step 11)' {
    BeforeEach { Reset-StepResults }

    It 'writes changed values, skips unchanged ones and logs before/after' {
        $kit = New-Fake800xAKit
        $m = New-800xAManifest $kit @(
            @{ ItemId = 'Cell_1:URL1';  Value = 'C:\new.png'; Type = 'String' }
            @{ ItemId = 'Cell_1:Count'; Value = '5';          Type = 'Int32' }
            @{ ItemId = 'Cell_1:Flag';  Value = 'True';       Type = 'Bool' })
        $state = New-HumState
        $logDir = Join-Path $TestDrive 'logs-ok'
        Invoke-800xAPropertyStep -Manifest $m -State $state -LogDir $logDir

        (Get-Store $kit).'Cell_1:URL1' | Should -Be 'C:\new.png'
        (Get-StepResults | Where-Object Check -eq '800xA property Cell_1:URL1').Detail  | Should -Be "'C:\old.png' -> 'C:\new.png'"
        (Get-StepResults | Where-Object Check -eq '800xA property Cell_1:Count').Detail | Should -Be "Already '5' - not written"
        Get-StepResults -Status FAIL | Should -BeNullOrEmpty
        $log = Get-Content $state['800xAChangeLog'] -Raw
        $log | Should -Match "Cell_1:URL1: 'C:\\old.png' -> 'C:\\new.png'  exit=0"
        $log | Should -Match "Cell_1:Count: '5' unchanged"
        @($state['800xAPropertyChanges'] | Where-Object Written).ItemId | Should -Be @('Cell_1:URL1', 'Cell_1:Flag')
    }

    It 'stops at the first failure and does not attempt the rest' {
        $kit = New-Fake800xAKit
        $m = New-800xAManifest $kit @(
            @{ ItemId = 'Differ:X';    Value = 'v';          Type = 'String' }
            @{ ItemId = 'Cell_1:URL1'; Value = 'C:\new.png'; Type = 'String' })
        { Invoke-800xAPropertyStep -Manifest $m -State (New-HumState) -LogDir (Join-Path $TestDrive 'logs-stop') } | Should -Throw '*stopped at Differ:X*'
        (Get-StepResults | Where-Object Check -eq '800xA property Differ:X').Detail   | Should -Match 'read-back differs'
        (Get-StepResults | Where-Object Check -eq '800xA property Cell_1:URL1').Detail | Should -Be 'Not attempted (an earlier property failed)'
        (Get-Store $kit).'Cell_1:URL1' | Should -Be 'C:\old.png'
    }

    It 'fails when the current value cannot be read' {
        $m = New-800xAManifest (New-Fake800xAKit) @(@{ ItemId = 'Fail:Y'; Value = 'v'; Type = 'String' })
        { Invoke-800xAPropertyStep -Manifest $m -State (New-HumState) -LogDir (Join-Path $TestDrive 'logs-read') } | Should -Throw
        (Get-StepResults -Status FAIL).Detail | Should -Match 'Read failed \(exit 1\)'
    }

    It 'writes nothing when an entry is invalid' {
        $kit = New-Fake800xAKit
        $m = New-800xAManifest $kit @(
            @{ ItemId = 'Cell_1:URL1'; Value = 'C:\new.png'; Type = 'String' }
            @{ ItemId = 'Cell_1:Flag'; Value = 'maybe';      Type = 'Bool' })
        { Invoke-800xAPropertyStep -Manifest $m -State (New-HumState) -LogDir (Join-Path $TestDrive 'logs-invalid') } | Should -Throw '*nothing was written*'
        (Get-Store $kit).'Cell_1:URL1' | Should -Be 'C:\old.png'
    }

    It 'writes nothing when the kit fails its checksum check' {
        $kit = New-Fake800xAKit
        Add-Content (Join-Path $kit 'Invoke-800xAGP.ps1') '# edited'
        $m = New-800xAManifest $kit @(@{ ItemId = 'Cell_1:URL1'; Value = 'C:\new.png'; Type = 'String' })
        { Invoke-800xAPropertyStep -Manifest $m -State (New-HumState) -LogDir (Join-Path $TestDrive 'logs-kit') } | Should -Throw '*kit not usable*'
        (Get-Store $kit).'Cell_1:URL1' | Should -Be 'C:\old.png'
    }

    It 'does nothing when no properties are configured' {
        Invoke-800xAPropertyStep -Manifest (New-800xAManifest (New-Fake800xAKit)) -State (New-HumState) -LogDir (Join-Path $TestDrive 'logs-none')
        Get-StepResults | Should -BeNullOrEmpty
    }
}
