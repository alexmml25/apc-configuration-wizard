<#
    Step 13 as a whole needs a live VM, so these tests run its file-based sections (T5 DOC, T6 CNCnetPDM,
    T7-T9 data applications) against output produced by Steps 8-10, and against untouched default files.
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $ModulesDir '08-CNCnetPDM.ps1')
    . (Join-Path $ModulesDir '09-DOCConfig.ps1')
    . (Join-Path $ModulesDir '10-DataApps.ps1')
}

Describe 'Step 13 T5 - DOC checks' {
    BeforeAll {
        $state = New-HumState
        function Invoke-T5 {
            param([string]$Root)
            $m = Get-TestManifest
            $m.DOC.BasePath = Join-Path $Root 'DOC-{N}/DOC_II'; $m.DOC.PluginsIQSPath = Join-Path $Root 'DOC-{N}/DOC_II/Plugins/IQS'
            Invoke-VerificationRegion -From 'T5 - DOC' -To 'T6 - CNCnetPDM' -Variables @{
                Manifest = $m; State = $state; docCfg = $m.DOC; docCount = 3
                machines = (Get-AssignedCNCs -State $state -Manifest $m)
            }
        }
        $configured = Join-Path $TestDrive 'Configured'; New-DocInstall -Root $configured
        $m = Get-TestManifest
        $m.DOC.BasePath = Join-Path $configured 'DOC-{N}/DOC_II'; $m.DOC.PluginsIQSPath = Join-Path $configured 'DOC-{N}/DOC_II/Plugins/IQS'
        Invoke-DOCConfig -Manifest $m -State $state
        $after = Invoke-T5 $configured

        $untouched = Join-Path $TestDrive 'Untouched'; New-DocInstall -Root $untouched
        $before = Invoke-T5 $untouched
    }

    It 'passes every automated DOC check after Step 9' {
        @($after | Where-Object { $_.Status -notin 'PASS', 'BLANK' } | ForEach-Object { "$($_.Name): $($_.Detail)" }) | Should -BeNullOrEmpty
    }

    It 'fails <Check> on untouched default files' -ForEach @(
        @{ Check = 'DOC_II.xml CSVFileOutputPath' }
        @{ Check = 'IqsDocSpcDataCollector.xml asset mapping' }
        @{ Check = 'DOC configuration completeness' }
    ) {
        (Get-Check $before $Check).Status | Should -Be 'FAIL'
    }

    It 'still passes connection checks on untouched files (they are verified, not changed)' {
        (Get-Check $before 'DocDB.xml connection config').Status | Should -Be 'PASS'
    }
}

Describe 'Step 13 T6 - CNCnetPDM checks' {
    BeforeAll {
        $dir = Join-Path $TestDrive 'CNCnetPDM'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Copy-Item (Get-Fixture 'CNCnetPDM/CNCnetPDM.ini'), (Get-Fixture 'CNCnetPDM/melcfg.ini') $dir
        'citizenm.dll', 'citizenm_CNC1.dll', 'citizenm_CNC2.dll', 'citizenm_CNC3.dll' | ForEach-Object { Set-Content (Join-Path $dir $_) 'x' }
        $m = Get-TestManifest
        $m.CNCnetPDM.InstallDir = $dir; $m.CNCnetPDM.FallbackDir = $dir
        $state = New-HumState
        Invoke-CNCnetPDM -Manifest $m -State $state
        function Invoke-T6 {
            param([hashtable]$State)
            Invoke-VerificationRegion -From 'T6 - CNCnetPDM' -To 'T7 - File Manager' -Variables @{
                Manifest = $m; State = $State; cncPdm = $m.CNCnetPDM; baseUrl = ''
                machines = (Get-AssignedCNCs -State $State -Manifest $m)
            }
        }
    }

    It 'passes items 2-8 after Step 8' {
        $checks = Invoke-T6 $state
        @($checks | Where-Object { $_.T -eq 6 -and $_.I -ge 2 -and $_.I -le 8 -and $_.Status -ne 'PASS' } | ForEach-Object { "$($_.Name): $($_.Detail)" }) |
            Should -BeNullOrEmpty
    }

    It 'fails the ini entries when DOC assignments change after Step 8' {
        $swapped = New-HumState -Assign @('Humacao_L20X_3', 'Humacao_L20X_1', 'Humacao_L20X_8')
        $checks = Invoke-T6 $swapped
        (Get-Check $checks 'CNCnetPDM.ini entry for CNC1*').Status | Should -Be 'FAIL'
        (Get-Check $checks 'CNCnetPDM.ini entry for CNC3*').Status | Should -Be 'PASS'
    }
}

Describe 'Step 13 T7-T9 - data application checks' {
    BeforeAll {
        $dir = Join-Path $TestDrive 'DataApps'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Copy-Item (Get-Fixture 'DataApps/DataCollector_FileManager.exe.config') (Join-Path $dir 'fm.config')
        Copy-Item (Get-Fixture 'DataApps/DataCollector.exe.config')             (Join-Path $dir 'dc.config')
        Copy-Item (Get-Fixture 'DataApps/DataAnalyzer.exe.config')              (Join-Path $dir 'da.config')
        $m = Get-TestManifest
        $m.DataApps.FileManagerConfig = Join-Path $dir 'fm.config'; $m.DataApps.DataCollectorConfig = Join-Path $dir 'dc.config'
        $m.DataApps.DataAnalyzerConfig = Join-Path $dir 'da.config'
        $state = New-HumState
        $state.SiteCode = 'MCR'
        $state.DataAppsLocalRoot = Join-Path $dir 'data'
        $state.SandboxRoot = $TestDrive
        # local share folders so the "source reachable" check can pass
        $state.DataAppsInstruments = @('CMM', 'CTSCAN', 'BENCH', 'CONTRACER') | ForEach-Object {
            $src = Join-Path $dir "share/$_"; New-Item -ItemType Directory -Path $src -Force | Out-Null
            @{ Type = $_; Count = 1; CNCs = @(1, 2, 3); SourcePath = $src; ErrorPath = ''; BroadcastPath = '' }
        }
        $vars = @{ Manifest = $m; State = $state; da = $m.DataApps; siteCode = 'MCR' }
        $before = Invoke-VerificationRegion -From 'T7 - File Manager' -To 'T10 - CHMI' -Variables $vars
        Invoke-DataApps -Manifest $m -State $state
        $after  = Invoke-VerificationRegion -From 'T7 - File Manager' -To 'T10 - CHMI' -Variables $vars
        $processChecks = '*process running*'
    }

    It 'passes every file-based data app check after Step 10' {
        @($after | Where-Object { $_.Status -eq 'FAIL' -and $_.Name -notlike $processChecks } | ForEach-Object { "$($_.Name): $($_.Detail)" }) |
            Should -BeNullOrEmpty
    }

    It 'fails the site code check on the untouched Data Analyzer config (MPR -> MCR)' {
        (Get-Check $before 'Site identifier configured*').Status | Should -Be 'FAIL'
    }
}
