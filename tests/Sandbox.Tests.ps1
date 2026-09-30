BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $ModulesDir '03-SINCFolders.ps1')
    . (Join-Path $ModulesDir '08-CNCnetPDM.ps1')
    . (Join-Path $ModulesDir '09-DOCConfig.ps1')
    . (Join-Path $ModulesDir '10-DataApps.ps1')
}

Describe 'Test mode (sandbox)' {
    BeforeAll {
        Reset-StepResults
        # A fake "installed" VM layout
        $installed = Join-Path $TestDrive 'installed'
        $daDir  = Join-Path $installed 'DataApps'; New-Item -ItemType Directory -Path $daDir | Out-Null
        Copy-Item (Get-Fixture 'DataApps/DataCollector_FileManager.exe.config'), (Get-Fixture 'DataApps/DataCollector.exe.config'),
                  (Get-Fixture 'DataApps/DataAnalyzer.exe.config') $daDir
        $pdmDir = Join-Path $installed 'CNCnetPDM'; New-Item -ItemType Directory -Path $pdmDir | Out-Null
        Copy-Item (Get-Fixture 'CNCnetPDM/CNCnetPDM.ini'), (Get-Fixture 'CNCnetPDM/melcfg.ini') $pdmDir
        'citizenm.dll', 'citizenm_CNC1.ini', 'citizenm_CNC2.ini', 'citizenm_CNC3.ini', 'unrelated.dll' | ForEach-Object { Set-Content (Join-Path $pdmDir $_) 'x' }
        New-DocInstall -Root $installed

        $m = Get-TestManifest
        $m.DataApps.FileManagerConfig   = Join-Path $daDir 'DataCollector_FileManager.exe.config'
        $m.DataApps.DataCollectorConfig = Join-Path $daDir 'DataCollector.exe.config'
        $m.DataApps.DataAnalyzerConfig  = Join-Path $daDir 'DataAnalyzer.exe.config'
        $m.CNCnetPDM.InstallDir = $pdmDir; $m.CNCnetPDM.FallbackDir = $pdmDir
        $m.DOC.BasePath       = Join-Path $installed 'DOC-{N}/DOC_II'
        $m.DOC.PluginsIQSPath = Join-Path $installed 'DOC-{N}/DOC_II/Plugins/IQS'
        $m.DeviceWise.SINCStaging = Join-Path $installed 'SINC'

        $originals = @{}
        Get-ChildItem $installed -Recurse -File | ForEach-Object { $originals[$_.FullName] = Get-FileHash $_.FullName }

        $sandboxRoot = Join-Path $TestDrive 'Sandbox/20260926-120000'
        $sb = New-SandboxManifest -Manifest $m -Root $sandboxRoot
        $state = New-HumState
        $state.SandboxRoot       = $sandboxRoot
        $state.DataAppsLocalRoot = $sb.Manifest.DataApps.LocalDataRoot

        # Run the file-editing steps against the sandbox manifest, as the wizard does in test mode
        Invoke-SINCFolders -Manifest $sb.Manifest -State $state
        Invoke-CNCnetPDM   -Manifest $sb.Manifest -State $state
        Invoke-DOCConfig   -Manifest $sb.Manifest -State $state
        Invoke-DataApps    -Manifest $sb.Manifest -State $state
    }

    It 'copies every installed file the wizard edits, and nothing it does not' {
        $sb.Missing | Should -BeNullOrEmpty
        $sb.Copied.Count | Should -Be (3 + 2 + 4 + 15)    # data apps + ini files + citizenm drivers + 3 x 5 DOC XMLs
        Join-Path $sandboxRoot 'CNCnetPDM/unrelated.dll' | Should -Not -Exist
    }

    It 'points every edited path into the sandbox' {
        $paths = @(
            $sb.Manifest.DataApps.FileManagerConfig, $sb.Manifest.DataApps.DataCollectorConfig, $sb.Manifest.DataApps.DataAnalyzerConfig,
            $sb.Manifest.DataApps.LocalDataRoot, $sb.Manifest.CNCnetPDM.InstallDir, $sb.Manifest.CNCnetPDM.FallbackDir,
            $sb.Manifest.DOC.BasePath, $sb.Manifest.DOC.PluginsIQSPath, $sb.Manifest.DeviceWise.SINCStaging)
        foreach ($p in $paths) { $p | Should -BeLike "$sandboxRoot*" }
    }

    It 'leaves the original manifest unchanged' {
        $m.CNCnetPDM.InstallDir | Should -Be $pdmDir
    }

    It 'runs Steps 3, 8, 9 and 10 without failures' {
        @(Get-StepResults -Status FAIL | ForEach-Object { "$($_.Check): $($_.Detail)" }) | Should -BeNullOrEmpty
    }

    It 'edits the sandbox copies' {
        Join-Path $sandboxRoot 'CNCnetPDM/citizenm_1008.ini' | Should -Exist
        Join-Path $sandboxRoot 'SINC/CNC3/DoneError'         | Should -Exist
        (Get-Content (Join-Path $sandboxRoot 'CNCnetPDM/CNCnetPDM.ini') -Raw) | Should -Match '3 = 1008;'
    }

    It 'does not modify, rename or add anything in the installed folders' {
        $now = @{}
        Get-ChildItem $installed -Recurse -File | ForEach-Object { $now[$_.FullName] = Get-FileHash $_.FullName }
        @($now.Keys) | Sort-Object | Should -Be (@($originals.Keys) | Sort-Object)
        foreach ($k in $originals.Keys) { $now[$k].Hash | Should -Be $originals[$k].Hash -Because $k }
        Join-Path $installed 'SINC' | Should -Not -Exist
    }

    It 'does not restart services' {
        $global:ServiceActions | Should -BeNullOrEmpty
    }

    It 'Test-SandboxPath allows only paths inside the sandbox' {
        Test-SandboxPath $state (Join-Path $sandboxRoot 'x/y') | Should -BeTrue
        Test-SandboxPath $state (Join-Path $TestDrive 'elsewhere') | Should -BeFalse
        Test-SandboxPath @{} (Join-Path $TestDrive 'elsewhere')    | Should -BeTrue
    }
}
