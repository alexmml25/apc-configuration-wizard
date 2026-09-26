BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $ModulesDir '10-DataApps.ps1')

    # Installed configs copied from the default fixtures into a fresh folder
    function New-DataAppsInstall {
        param([string]$Variant = '')
        $dir = Join-Path $TestDrive "DataApps-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory -Path $dir | Out-Null
        Copy-Item (Get-Fixture "DataApps/DataCollector_FileManager$Variant.exe.config") (Join-Path $dir 'fm.config')
        Copy-Item (Get-Fixture "DataApps/DataCollector$Variant.exe.config")             (Join-Path $dir 'dc.config')
        Copy-Item (Get-Fixture "DataApps/DataAnalyzer$Variant.exe.config")              (Join-Path $dir 'da.config')
        $m = Get-TestManifest
        $m.DataApps.FileManagerConfig   = Join-Path $dir 'fm.config'
        $m.DataApps.DataCollectorConfig = Join-Path $dir 'dc.config'
        $m.DataApps.DataAnalyzerConfig  = Join-Path $dir 'da.config'
        @{ Dir = $dir; Manifest = $m }
    }
    function New-DataAppsState {
        param([string]$Dir, [string]$Site = 'MPR', [int]$DocCount = 3)
        $s = New-HumState -DocCount $DocCount
        $s.SiteCode          = $Site
        $s.DataAppsLocalRoot = Join-Path $Dir 'data'
        $s.SandboxRoot       = $TestDrive      # never create folders outside the test drive (e.g. D:\ shares)
        $s
    }
    # DataTypeSettings blocks as comparable rows; local root normalised to the HUM value
    function Get-DcRows {
        param([string]$Path, [string]$LocalRoot)
        $x = [xml](Get-Content $Path -Raw)
        foreach ($b in $x.configuration.DataTypeSettings.ChildNodes) {
            if ($b.NodeType -ne 'Element') { continue }
            $norm = { param($v) if ($LocalRoot) { $v = $v.Replace($LocalRoot, 'C:\Medtronic\DataCollector_Data') }; $v -replace '/', '\' }
            '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}' -f $b.LocalName, $b.Name, $b.Asset, (& $norm $b.CheckPath), (& $norm $b.ArchivePath),
                (& $norm $b.BroadcastFilePaths.Path1), $b.EndFileString, $b.OPCTags.TagPath
        }
    }
}

Describe 'Step 10 - Humacao site defaults rebuilt from the default configs' {
    BeforeAll {
        Reset-StepResults
        $inst  = New-DataAppsInstall
        $state = New-DataAppsState $inst.Dir
        Invoke-DataApps -Manifest $inst.Manifest -State $state
        $dc = [xml](Get-Content (Join-Path $inst.Dir 'dc.config') -Raw)
        $fm = [xml](Get-Content (Join-Path $inst.Dir 'fm.config') -Raw)
    }

    It 'reports no failures' {
        Get-StepResults -Status FAIL | Should -BeNullOrEmpty
    }

    It 'produces the same Data Collector blocks as the HUM example' {
        $ours = Get-DcRows (Join-Path $inst.Dir 'dc.config') $state.DataAppsLocalRoot | Sort-Object
        $hum  = Get-DcRows (Get-Fixture 'DataApps/DataCollectorHUM.exe.config') '' | Sort-Object
        $ours | Should -Be $hum
    }

    It 'produces the same CNCSettings as the HUM example in both configs' {
        $humDc = [xml](Get-Content (Get-Fixture 'DataApps/DataCollectorHUM.exe.config') -Raw)
        $humFm = [xml](Get-Content (Get-Fixture 'DataApps/DataCollector_FileManagerHUM.exe.config') -Raw)
        $dc.configuration.CNCSettings.OuterXml | Should -Be $humDc.configuration.CNCSettings.OuterXml
        ($fm.configuration.CNCSettings.ChildNodes | ForEach-Object { "$($_.LocalName)=$($_.CheckMismatchData)" }) |
            Should -Be ($humFm.configuration.CNCSettings.ChildNodes | ForEach-Object { "$($_.LocalName)=$($_.CheckMismatchData)" })
    }

    It 'writes the HUM File Manager source and error paths' {
        $rows = $fm.configuration.Paths.ChildNodes | ForEach-Object { "$($_.Name)|$($_.Path)|$($_.ErrorPath -replace '/', '\')" }
        $rows | Should -Contain 'CMM1|D:\CMM_Measurement_Reports\CSVCLC|D:\CMM_Measurement_Reports\CSVCLCError'
        $rows | Should -Contain 'CTSCAN1|Z:\CTScan_Inspection\CSVCLC|Z:\CTScan_Inspection\CSVCLCError'
        ($rows | Where-Object { $_ -like 'CONTRACER*' }).Count | Should -Be 3
    }

    It 'feeds every Data Collector CheckPath from a File Manager NewPath' {
        $newPaths = @($fm.configuration.Paths.ChildNodes | ForEach-Object { $_.NewPath })
        foreach ($b in $dc.configuration.DataTypeSettings.ChildNodes) { $newPaths | Should -Contain $b.CheckPath }
    }

    It 'sets BroadcastFile true only where a broadcast path is given' {
        foreach ($b in $dc.configuration.DataTypeSettings.ChildNodes) {
            $expected = if ($b.BroadcastFilePaths.Path1 -ne 'NA') { 'true' } else { 'false' }
            $b.BroadcastFile | Should -Be $expected -Because $b.LocalName
        }
    }

    It 'creates local data folders but nothing outside the sandbox' {
        Join-Path $state.DataAppsLocalRoot 'CMM/Backup' | Should -Exist
        @(Get-StepResults -Status WARN | Where-Object { $_.Check -like 'Directory*' }) | Should -BeNullOrEmpty
        Test-Path 'D:\CMM_Measurement_Reports\CSVCLCError' | Should -BeFalse
    }

    It 'changes nothing when run again' {
        $before = Get-Content (Join-Path $inst.Dir 'dc.config') -Raw
        Invoke-DataApps -Manifest $inst.Manifest -State $state
        Get-Content (Join-Path $inst.Dir 'dc.config') -Raw | Should -Be $before
    }
}

Describe 'Step 10 - custom selection' {
    BeforeAll {
        Reset-StepResults
        $inst  = New-DataAppsInstall
        $state = New-DataAppsState $inst.Dir -Site 'MCR' -DocCount 2
        $state.DataAppsInstruments = @(
            @{ Type = 'CMM';       Count = 1; CNCs = @(1);    SourcePath = '\\share\cmm'; ErrorPath = ''; BroadcastPath = (Join-Path $inst.Dir 'bc') }
            @{ Type = 'CTSCAN';    Count = 1; CNCs = @(2, 3); SourcePath = '\\share\ct';  ErrorPath = ''; BroadcastPath = '' }
            @{ Type = 'BENCH';     Count = 1; CNCs = @();     SourcePath = '';            ErrorPath = ''; BroadcastPath = '' }
            @{ Type = 'CONTRACER'; Count = 2; CNCs = @(1, 2); SourcePath = '\\share\con'; ErrorPath = ''; BroadcastPath = '' })
        Invoke-DataApps -Manifest $inst.Manifest -State $state
        $dc = [xml](Get-Content (Join-Path $inst.Dir 'dc.config') -Raw)
        $da = [xml](Get-Content (Join-Path $inst.Dir 'da.config') -Raw)
    }

    It 'writes only ticked instruments for CNCs within the DOC count' {
        @($dc.configuration.DataTypeSettings.ChildNodes | ForEach-Object { $_.LocalName }) |
            Should -Be @('CNC1.CMM', 'CNC1.CONTRACER1', 'CNC1.CONTRACER2', 'CNC2.CTSCAN', 'CNC2.CONTRACER1', 'CNC2.CONTRACER2')
    }

    It 'names single instruments CMM1 / CTSCAN1 (not a single character)' {
        $names = @($dc.configuration.DataTypeSettings.ChildNodes | ForEach-Object { $_.Name })
        $names | Should -Contain 'CMM1'
        $names | Should -Contain 'CTSCAN1'
    }

    It 'sets the site code in the Data Analyzer OPC process names' {
        $v = @{}; $da.configuration.appSettings.add | ForEach-Object { $v[$_.key] = $_.value }
        $v['Opc_FirstRunProcess']     | Should -Be '^1ST_(.*)_MCR$'
        $v['Opc_VerificationProcess'] | Should -Be '^VER_(.*)_MCR$'
        $v['Opc_ProductionProcess']   | Should -Be '^SPC_(.*)_MCR$'
    }

    It 'sizes the per-CNC Data Analyzer lists to the DOC count' {
        $v = @{}; $da.configuration.appSettings.add | ForEach-Object { $v[$_.key] = $_.value }
        $v['Opc_CNCAssets']     | Should -Be 'CNC1|CNC2'
        $v['Opc_DOCCHMIs']      | Should -Be 'DOC-CHMI|DOC-CHMI'
        $v['Opc_DataAnalyzers'] | Should -Be 'DataAnalyzer.DA1|DataAnalyzer.DA1'
    }
}

Describe 'Step 10 - installed config missing an instrument block' {
    It 'reports FAIL for that instrument and still writes the others' {
        Reset-StepResults
        $inst = New-DataAppsInstall
        $dcPath = Join-Path $inst.Dir 'dc.config'
        $x = [xml](Get-Content $dcPath -Raw)
        @($x.SelectNodes("//DataTypeSettings/*[contains(local-name(),'CTSCAN')]")) | ForEach-Object { [void]$_.ParentNode.RemoveChild($_) }
        $x.Save($dcPath)
        Invoke-DataApps -Manifest $inst.Manifest -State (New-DataAppsState $inst.Dir)
        (Get-StepResults -Status FAIL).Check | Should -Be @('Data Collector: CTSCAN')
        @(([xml](Get-Content $dcPath -Raw)).configuration.DataTypeSettings.ChildNodes).Count | Should -Be 15
    }
}
