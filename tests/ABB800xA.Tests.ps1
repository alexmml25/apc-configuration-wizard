<#
    800xA wrappers (modules\ABB800xA.ps1). The real kit needs 800xA, so these tests run a fake kit with the
    same file names and output format: a Backup-800xA.ps1 that writes a log like the real one and exits
    with a chosen code, and an Invoke-800xAGP.ps1 backed by a JSON "property store".
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $ModulesDir 'ABB800xA.ps1')

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

Describe 'Step 11 shipped property list (Inspections GP / Verification GP)' {
    BeforeAll { $Script:Shipped = Get-TestManifest }

    It 'writes the CSV paths per DOC-assigned cell and leaves the shift settings alone when not chosen' {
        $state = New-HumState -DocCount 2
        $state['DataAppsLocalRoot'] = 'C:\Medtronic\DataCollector_Data\'
        $p = @(Get-800xAPropertyPlan -Manifest $Script:Shipped -State $state)
        $p.Problem | Where-Object { $_ } | Should -BeNullOrEmpty
        $write = @($p | Where-Object { -not $_.Skip })
        $write.ItemId | Should -Be @(
            'Root/Medtronic/Cell_1/Measurements:SampleCSV_Filepath', 'Root/Medtronic/Cell_2/Measurements:SampleCSV_Filepath',
            'Root/Medtronic/Cell_1/Measurements:100pctCSV_Filepath', 'Root/Medtronic/Cell_2/Measurements:100pctCSV_Filepath')
        $write[0].Value | Should -Be 'C:\Medtronic\DataCollector_Data\BENCH'
        $write[2].Value | Should -Be 'C:\Medtronic\DataCollector_Data\100%'
        ($p | Where-Object ItemId -eq 'Cell_1:VerificationOnShift').Skip | Should -Match 'VERIFYONSHIFT not set'
        ($p | Where-Object ItemId -eq 'Cell_1:Shift1Hour').Skip          | Should -Match 'only written when VERIFYONSHIFT is True'
    }

    It 'uses per-cell choices, and the MPR first shift hour 5 before VerificationOnShift' {
        $state = New-HumState
        $state['800xASettings'] = @{ CELL1 = @{ VERIFYONSHIFT = $true }; CELL2 = @{ VERIFYONSHIFT = $false } }
        $p = @(Get-800xAPropertyPlan -Manifest $Script:Shipped -State $state | Where-Object { $_.ItemId -notmatch 'Measurements' -and -not $_.Skip })
        $p.ItemId | Should -Be @('Cell_1:Shift1Hour', 'Cell_1:VerificationOnShift', 'Cell_2:VerificationOnShift')
        $p.Value  | Should -Be @('5', 'True', 'False')
        $p.Problem | Where-Object { $_ } | Should -BeNullOrEmpty
    }

    It 'uses the default first shift hour 7 for other sites' {
        $state = New-HumState -DocCount 1
        $state['SiteCode'] = 'MCR'
        $state['800xASettings'] = @{ VERIFYONSHIFT = 'True' }
        (Get-800xAPropertyPlan -Manifest $Script:Shipped -State $state | Where-Object ItemId -eq 'Cell_1:Shift1Hour').Value | Should -Be '7'
    }

    It 'rejects a shift start hour outside 0-23' {
        $state = New-HumState -DocCount 1
        $state['800xASettings'] = @{ VERIFYONSHIFT = $true; SHIFT1HOUR = 24 }
        (Get-800xAPropertyPlan -Manifest $Script:Shipped -State $state | Where-Object ItemId -match 'Shift1Hour').Problem | Should -Match 'above the maximum 23'
    }

    It 'lets a site key override the defaults' {
        $m = Get-TestManifest
        $m.ABB800xA.Settings.MPR | Add-Member -NotePropertyName SAMPLECSVPATH -NotePropertyValue 'D:\Bench'
        $p = @(Get-800xAPropertyPlan -Manifest $m -State (New-HumState -DocCount 1) | Where-Object ItemId -match 'SampleCSV')
        $p.Value | Should -Be 'D:\Bench'
    }

    It 'flags a When that names an unknown setting' {
        $m = New-800xAManifest (New-Fake800xAKit) @(@{ ItemId = 'Cell_1:X'; Value = '1'; Type = 'Int32'; When = 'NOPE' })
        (Get-800xAPropertyPlan -Manifest $m -State (New-HumState)).Problem | Should -Match "unknown setting 'NOPE'"
    }

    It 'reports skipped entries as SKIP and does not touch them' {
        Reset-StepResults
        $kit = New-Fake800xAKit
        $m = New-800xAManifest $kit @(@{ ItemId = 'Cell_{CELL}:Flag'; Value = '{VERIFYONSHIFT}'; Type = 'Bool' })
        Invoke-800xAPropertyStep -Manifest $m -State (New-HumState -DocCount 1) -LogDir (Join-Path $TestDrive 'logs-skip')
        (Get-StepResults | Where-Object Check -eq '800xA property Cell_1:Flag').Status | Should -Be 'SKIP'
        (Get-Store $kit).'Cell_1:Flag' | Should -Not -Be 'False'
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
