BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $ModulesDir '09-DOCConfig.ps1')

    function New-DocManifest {
        param([string]$Root)
        $m = Get-TestManifest
        $m.DOC.BasePath       = Join-Path $Root 'DOC-{N}/DOC_II'
        $m.DOC.PluginsIQSPath = Join-Path $Root 'DOC-{N}/DOC_II/Plugins/IQS'
        $m
    }

    # Leaf elements of an XML file as path -> values, to compare what changed against the fixture
    function Get-XmlLeaves {
        param([string]$Path)
        $out = @{}
        $walk = {
            param($e, $p)
            $kids = @($e.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })
            if (-not $kids) { if (-not $out.ContainsKey($p)) { $out[$p] = @() }; $out[$p] += $e.InnerText.Trim() }
            foreach ($k in $kids) { & $walk $k "$p/$($k.LocalName)" }
        }
        $x = New-Object System.Xml.XmlDocument; $x.Load($Path)
        & $walk $x.DocumentElement ''
        $out
    }
    function Get-ChangedLeaves {
        param([string]$Original, [string]$Modified)
        $a = Get-XmlLeaves $Original; $b = Get-XmlLeaves $Modified
        @(@($a.Keys) + @($b.Keys) | Select-Object -Unique | Where-Object { ($a[$_] -join '|') -ne ($b[$_] -join '|') } | Sort-Object)
    }
}

Describe 'Step 9 - DOC XML configuration' {
    BeforeAll {
        Reset-StepResults
        $root  = Join-Path $TestDrive 'Medtronic'
        New-DocInstall -Root $root
        $state = New-HumState
        $state.DataAppsInstruments = @(
            @{ Type = 'CMM'; Count = 1; CNCs = @(1) }, @{ Type = 'CTSCAN'; Count = 1; CNCs = @(2) },
            @{ Type = 'BENCH'; Count = 1; CNCs = @(1, 2) }, @{ Type = 'CONTRACER'; Count = 3; CNCs = @(2) })
        Invoke-DOCConfig -Manifest (New-DocManifest $root) -State $state
        $doc2 = Join-Path $root 'DOC-2/DOC_II'
    }

    It 'reports no failures' {
        Get-StepResults -Status FAIL | Should -BeNullOrEmpty
    }

    It 'changes only the intended fields in <File>' -ForEach @(
        @{ File = 'DocDb.xml';                  Sub = '';             Changed = @('/Name') }
        @{ File = 'DOC_II.xml';                 Sub = '';             Changed = @('/CSVFileOutputPath', '/Name') }
        @{ File = 'PartLookup.xml';             Sub = '';             Changed = @('/Name') }
        @{ File = 'SpcDb.xml';                  Sub = 'Plugins/IQS/'; Changed = @('/Name') }
        @{ File = 'IqsDocSpcDataCollector.xml'; Sub = 'Plugins/IQS/'
           Changed = @('/Assets/AssetConfiguration/DBId', '/Assets/AssetConfiguration/Name', '/Name', '/SourceDataInclusionList/string') }
    ) {
        Get-ChangedLeaves (Get-Fixture "DOC/$File") (Join-Path $doc2 "$Sub$File") | Should -Be $Changed
    }

    It 'names each instance DOC-{n}' {
        ([xml](Get-Content (Join-Path $doc2 'DocDb.xml') -Raw)).Configuration.Name | Should -Be 'DOC-2 DocDb'
    }

    It 'points CSVFileOutputPath at SINC\CNC2 with the SOP pattern' {
        ([xml](Get-Content (Join-Path $doc2 'DOC_II.xml') -Raw)).Configuration.CSVFileOutputPath |
            Should -Be 'C:\Program Files\deviceWISE\Gateway\staging\SINC\CNC2\{AF}-{AN}-{BN}-{PF}-{PN}-{PSN} {DS} {TS}.csv'
    }

    It 'maps the Iqs asset to the DOC-assigned machine' {
        $a = ([xml](Get-Content (Join-Path $doc2 'Plugins/IQS/IqsDocSpcDataCollector.xml') -Raw)).Configuration.Assets.AssetConfiguration
        $a.DBId   | Should -Be 'Humacao_L20X_3'
        $a.Name   | Should -Be 'Primary [Humacao_L20X_3]'
        $a.Family | Should -Be 'CITIZEN_L20X_IV'
    }

    It 'builds the inclusion list from the instruments ticked for each CNC' {
        $x1 = [xml](Get-Content (Join-Path $root 'DOC-1/DOC_II/Plugins/IQS/IqsDocSpcDataCollector.xml') -Raw)
        $x2 = [xml](Get-Content (Join-Path $doc2 'Plugins/IQS/IqsDocSpcDataCollector.xml') -Raw)
        @($x1.Configuration.SourceDataInclusionList.string).Count | Should -Be 6    # CMM1, BENCH
        @($x2.Configuration.SourceDataInclusionList.string).Count | Should -Be 15   # CTSCAN1, BENCH, CONTRACER1-3
        $x2.Configuration.SourceDataInclusionList.string | Should -Contain '1ST_CTSCAN1_MPR : CTSCAN1'
        $x2.Configuration.SourceDataInclusionList.string | Should -Not -Contain '1ST_CMM1_MPR : CMM1'
    }

    It 'keeps the UTF-8 BOM and writes timestamped backups' {
        [System.IO.File]::ReadAllBytes((Join-Path $doc2 'DocDb.xml'))[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        (Get-ChildItem $doc2 -Recurse -Filter '*.bak').Count | Should -Be 5
    }
}

Describe 'Step 9 - missing and misplaced files' {
    BeforeEach { Reset-StepResults }

    It 'finds SpcDb.xml in DOC_II when it is not in Plugins\IQS' {
        $root = Join-Path $TestDrive 'Misplaced'
        New-DocInstall -Root $root -Count 1
        Move-Item (Join-Path $root 'DOC-1/DOC_II/Plugins/IQS/SpcDb.xml') (Join-Path $root 'DOC-1/DOC_II/')
        Invoke-DOCConfig -Manifest (New-DocManifest $root) -State (New-HumState -DocCount 1)
        Get-StepResults -Status FAIL | Should -BeNullOrEmpty
    }

    It 'reports FAIL when a DOC instance folder is missing' {
        $root = Join-Path $TestDrive 'OnlyTwo'
        New-DocInstall -Root $root -Count 2
        Invoke-DOCConfig -Manifest (New-DocManifest $root) -State (New-HumState)
        (Get-StepResults -Status FAIL).Check | Should -Contain 'DOC 3 install folder'
    }
}
