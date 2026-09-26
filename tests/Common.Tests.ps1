BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $ModulesDir 'Common.ps1')
    $manifest = Get-TestManifest
}

Describe 'Get-CNCDeviceInfo (CNCnetPDM DeviceNr rules)' {
    It '<Name> / <Family> -> DeviceNr <DeviceNr>, <Dll>' -ForEach @(
        @{ Name = 'Humacao_L20X_1'; Family = 'CITIZEN_L20X_IV'; DeviceNr = '1001'; Dll = 'citizenm.dll' }
        @{ Name = 'Humacao_L20X_8'; Family = 'CITIZEN_L20X_IV'; DeviceNr = '1008'; Dll = 'citizenm.dll' }
        @{ Name = 'MCR-CNC-0004';   Family = 'CITIZEN_L20E_V';  DeviceNr = '1104'; Dll = 'mitsubishim.dll' }
        @{ Name = 'Citizen 70';     Family = 'CITIZEN L20E_IV'; DeviceNr = '1070'; Dll = 'citizenm.dll' }
        @{ Name = 'Line_12';        Family = 'CITIZEN_M32_V';   DeviceNr = '1112'; Dll = 'mitsubishim.dll' }
    ) {
        $info = Get-CNCDeviceInfo -Machine @{ MachineName = $Name; AssetFamily = $Family } -Manifest $manifest
        $info.Error     | Should -BeNullOrEmpty
        $info.DeviceNr  | Should -Be $DeviceNr
        $info.DriverDll | Should -Be $Dll
    }

    It 'reports an error for <Case>' -ForEach @(
        @{ Case = 'no trailing number';   Name = 'Lathe-A';   Family = 'CITIZEN_L20X_IV' }
        @{ Case = 'number above 99';      Name = 'CNC_100';   Family = 'CITIZEN_L20X_IV' }
        @{ Case = 'family without IV/V';  Name = 'CNC_1';     Family = 'CITIZEN M32' }
    ) {
        $info = Get-CNCDeviceInfo -Machine @{ MachineName = $Name; AssetFamily = $Family } -Manifest $manifest
        $info.Error    | Should -Not -BeNullOrEmpty
        $info.DeviceNr | Should -BeNullOrEmpty
    }

    It 'falls back to CNCType when AssetFamily is empty' {
        (Get-CNCDeviceInfo -Machine @{ MachineName = 'X_2'; CNCType = 'CITIZEN_L20X_IV' } -Manifest $manifest).DeviceNr | Should -Be '1002'
    }
}

Describe 'Get-AssignedCNCs (CNC n = DOC instance n)' {
    It 'returns only DOC-assigned machines in DOC order' {
        $cncs = Get-AssignedCNCs -State (New-HumState) -Manifest $manifest
        $cncs.Count | Should -Be 3
        $cncs.MachineName | Should -Be @('Humacao_L20X_1', 'Humacao_L20X_3', 'Humacao_L20X_8')
        $cncs.CNCIndex    | Should -Be @(1, 2, 3)
        $cncs.DeviceNr    | Should -Be @('1001', '1003', '1008')
    }

    It 'honours DOCCount' {
        $cncs = Get-AssignedCNCs -State (New-HumState -DocCount 2) -Manifest $manifest
        $cncs.MachineName | Should -Be @('Humacao_L20X_1', 'Humacao_L20X_3')
    }

    It 'accepts PSCustomObject machines (wizard fetch) as well as hashtables (Step 1)' {
        $state = New-HumState
        $state.CNCMachines = @($state.CNCMachines | ForEach-Object { [pscustomobject]$_ })
        (Get-AssignedCNCs -State $state -Manifest $manifest).DeviceNr | Should -Be @('1001', '1003', '1008')
    }

    It 'keeps CNC numbering when an assigned machine is missing from Site DB data' {
        $state = New-HumState -Assign @('Humacao_L20X_1', 'Gone_9', 'Humacao_L20X_8')
        $cncs = Get-AssignedCNCs -State $state -Manifest $manifest
        $cncs.CNCIndex | Should -Be @(1, 3)
    }
}

Describe 'DOC helpers' {
    It 'builds the SINC CSV output path with the SOP pattern' {
        Get-DOCCsvOutputPath -Manifest $manifest -N 2 |
            Should -Be 'C:\Program Files\deviceWISE\Gateway\staging\SINC\CNC2\{AF}-{AN}-{BN}-{PF}-{PN}-{PSN} {DS} {TS}.csv'
    }

    It 'builds the inclusion list from the instruments ticked for the CNC (user example)' {
        $state = New-HumState
        $state.DataAppsInstruments = @(
            @{ Type = 'CTSCAN'; Count = 1; CNCs = @(1) }, @{ Type = 'CMM'; Count = 1; CNCs = @(1) }, @{ Type = 'BENCH'; Count = 1; CNCs = @(1) }
        )
        $list = Get-DOCInclusionList -Manifest $manifest -State $state -Cnc 1
        $expected = 'CTSCAN1', 'CMM1', 'BENCH' | ForEach-Object { $n = $_; '1ST', 'SPC', 'VER' | ForEach-Object { "${_}_${n}_MPR : $n" } }
        $list | Should -Be $expected
    }

    It 'numbers CONTRACER 1..3 and leaves out instruments not ticked for the CNC' {
        $state = New-HumState
        $state.SiteCode = 'MCR'
        $state.DataAppsInstruments = @(@{ Type = 'CONTRACER'; Count = 3; CNCs = @(2) }, @{ Type = 'CMM'; Count = 1; CNCs = @(1) })
        $list = Get-DOCInclusionList -Manifest $manifest -State $state -Cnc 2
        $list.Count | Should -Be 9
        $list       | Should -Contain 'VER_CONTRACER3_MCR : CONTRACER3'
        $list       | Should -Not -Contain '1ST_CMM1_MCR : CMM1'
    }

    It 'uses the site defaults when the wizard made no selection' {
        $list = Get-DOCInclusionList -Manifest $manifest -State (New-HumState) -Cnc 3
        ($list | ForEach-Object { ($_ -split ' : ')[1] } | Select-Object -Unique) |
            Should -Be @('CMM1', 'CTSCAN1', 'BENCH', 'CONTRACER1', 'CONTRACER2', 'CONTRACER3')
    }
}
