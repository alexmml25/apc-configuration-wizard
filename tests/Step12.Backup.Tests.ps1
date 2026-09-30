BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $ModulesDir '12-Backup.ps1')

    # Fake VM: C:\Medtronic with DOC, data apps, CNCnetPDM (+ logs), measurement data and old backups
    function New-BackupFixture {
        param([switch]$CncPdmOutside)
        $root = Join-Path $TestDrive "vm-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        $med  = Join-Path $root 'Medtronic'
        foreach ($f in 'DOC-1/DOC_II/DOC_II.xml', 'File Manager/DataCollector_FileManager.exe.config', 'Data Collector/DataCollector.exe.config',
                       'CNCNetPDM/CNCnetPDM.ini', 'CNCNetPDM/log/log_master_260930.txt', 'DataCollector_Data/CMM/part.csv', 'Backup/DOC-1/old.xml') {
            $p = Join-Path $med $f
            New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null
            Set-Content $p 'x'
        }
        $pdm = Join-Path $med 'CNCNetPDM'
        if ($CncPdmOutside) {
            $pdm = Join-Path $root 'CNCnetPDM_8.0.0.0'
            New-Item -ItemType Directory -Path (Join-Path $pdm 'log') -Force | Out-Null
            Set-Content (Join-Path $pdm 'CNCnetPDM.ini') 'x'; Set-Content (Join-Path $pdm 'log/log_1001.txt') 'x'
        }
        $m = New-800xAManifest (New-Fake800xAKit)
        $m.Backup.Root = Join-Path $root 'APC_Config/Backups'
        $m.Backup.MedtronicDir = $med
        $m.CNCnetPDM.InstallDir = $pdm; $m.CNCnetPDM.FallbackDir = $pdm
        $env:FAKE_800XA_BACKUPDIR = Join-Path $root 'BACKUP'
        @{ Root = $root; Manifest = $m }
    }
    function Get-BackupDir { param([hashtable]$State) $State['BackupRoot'] }
}

AfterAll { Remove-Item Env:FAKE_800XA_BACKUPDIR -ErrorAction SilentlyContinue }

Describe 'Step 12 - backup into one timestamped folder' {
    BeforeAll {
        Reset-StepResults; $global:RobocopyCalls.Clear()
        $fx = New-BackupFixture
        $state = New-HumState
        Invoke-Backup -Manifest $fx.Manifest -State $state
        $dest = Get-BackupDir $state
    }

    It 'creates a date-time folder under Backup.Root' {
        $dest | Should -BeLike (Join-Path $fx.Root 'APC_Config/Backups/*')
        (Split-Path $dest -Leaf) | Should -Match '^\d{8}-\d{6}$'
    }

    It 'runs the 800xA backup and copies it into the backup folder' {
        $state['Backup800xA'].Ok   | Should -BeTrue
        $state['Backup800xA'].Name | Should -Be 'Full backup; 2026-09-30; 16-05'
        Join-Path $dest '800xA/Full backup; 2026-09-30; 16-05/Backup.log' | Should -Exist
        (Get-StepResults | Where-Object Check -eq '800xA Full backup').Status | Should -Be 'PASS'
    }

    It 'copies C:\Medtronic without logs, measurement data and old backups' {
        Join-Path $dest 'Medtronic/DOC-1/DOC_II/DOC_II.xml'                    | Should -Exist
        Join-Path $dest 'Medtronic/File Manager/DataCollector_FileManager.exe.config' | Should -Exist
        Join-Path $dest 'Medtronic/CNCNetPDM/CNCnetPDM.ini'                     | Should -Exist
        Join-Path $dest 'Medtronic/CNCNetPDM/log'                              | Should -Not -Exist
        Join-Path $dest 'Medtronic/DataCollector_Data'                         | Should -Not -Exist
        Join-Path $dest 'Medtronic/Backup'                                     | Should -Not -Exist
    }

    It 'does not copy CNCnetPDM a second time when it is inside C:\Medtronic' {
        @($global:RobocopyCalls | Where-Object Source -like '*CNCNetPDM*') | Should -BeNullOrEmpty
        Join-Path $dest 'CNCnetPDM' | Should -Not -Exist
    }

    It 'reminds that deviceWise must be backed up manually' {
        (Get-StepResults | Where-Object Check -eq 'deviceWise backup').Status | Should -Be 'WARN'
    }

    It 'reports no failures' {
        Get-StepResults -Status FAIL | Should -BeNullOrEmpty
    }
}

Describe 'Step 12 - other cases' {
    BeforeEach { Reset-StepResults; $global:RobocopyCalls.Clear() }

    It 'copies CNCnetPDM separately (without its logs) when installed outside C:\Medtronic' {
        $fx = New-BackupFixture -CncPdmOutside
        $state = New-HumState
        Invoke-Backup -Manifest $fx.Manifest -State $state
        Join-Path (Get-BackupDir $state) 'CNCnetPDM/CNCnetPDM.ini' | Should -Exist
        Join-Path (Get-BackupDir $state) 'CNCnetPDM/log'           | Should -Not -Exist
    }

    It 'reports FAIL when the 800xA backup fails, and still backs up the rest' {
        $fx = New-BackupFixture
        $fx.Manifest.ABB800xA.KitDir = New-Fake800xAKit -BackupExit 6
        $state = New-HumState
        Invoke-Backup -Manifest $fx.Manifest -State $state
        (Get-StepResults | Where-Object Check -eq '800xA Full backup').Detail | Should -Match 'Exit 6: not enough free disk'
        Join-Path (Get-BackupDir $state) 'Medtronic/DOC-1/DOC_II/DOC_II.xml' | Should -Exist
    }
}
