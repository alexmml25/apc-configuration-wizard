BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $ModulesDir 'Common.ps1')
    $manifest = Get-TestManifest
}

Describe 'Get-CNCDeviceInfo (CNCnetPDM DeviceNr rules)' {
    # DeviceNr = family digit + 3-digit machine number; DLL = Site DB f_dllname
    It '<Name> / <Family> -> DeviceNr <DeviceNr>' -ForEach @(
        @{ Name = 'Citizen 01';        Family = 'CITIZEN_L20X_IV'; DeviceNr = '1001' }
        @{ Name = 'Humacao_L20X_8';    Family = 'CITIZEN_L20X_IV'; DeviceNr = '1008' }
        @{ Name = 'Citizen 68';        Family = 'CITIZEN_L20E_IV'; DeviceNr = '2068' }
        @{ Name = 'MCR-CNC-0004';      Family = 'CITIZEN_L20E_IV'; DeviceNr = '2004' }
        @{ Name = 'Citizen 28';        Family = 'CITIZEN_M32_IV';  DeviceNr = '3028' }
        @{ Name = 'Citizen L320 1';    Family = 'CITIZEN_L20E_V';  DeviceNr = '4001' }
        @{ Name = 'Citizen 100';       Family = 'CITIZEN_L20E_V';  DeviceNr = '4100' }
        @{ Name = 'Citizen 300';       Family = 'CITIZEN_L20E_V';  DeviceNr = '4300' }
        @{ Name = 'Citizen M325 1';    Family = 'CITIZEN_M32_V';   DeviceNr = '5001' }
        @{ Name = 'Citizen 83';        Family = 'CITIZEN_M32_V';   DeviceNr = '5083' }
        @{ Name = 'L12 Line 5';        Family = 'CITIZEN_L12';     DeviceNr = '6005' }
        @{ Name = 'Citizen 70';        Family = 'CITIZEN L20E_IV'; DeviceNr = '2070' }
    ) {
        $info = Get-CNCDeviceInfo -Machine @{ MachineName = $Name; AssetFamily = $Family; DLLName = 'citizenm.dll' } -Manifest $manifest
        $info.Error    | Should -BeNullOrEmpty
        $info.DeviceNr | Should -Be $DeviceNr
    }

    It 'takes the DLL from the Site DB, whatever the family' {
        (Get-CNCDeviceInfo -Machine @{ MachineName = 'C_1'; AssetFamily = 'CITIZEN_L20X_IV'; DLLName = 'mitsubishim.dll' } -Manifest $manifest).DriverDll |
            Should -Be 'mitsubishim.dll'
    }

    It 'gives every machine in the Humacao test Site DB a different DeviceNr' {
        $rows = @(
            @('CITIZEN_L20X_IV', 1, 3, 4, 5, 6, 8, 16, 19), @('CITIZEN_L20E_IV', 68), @('CITIZEN_M32_IV', 28, 29, 31, 35, 36, 59, 67, 71),
            @('CITIZEN_L20E_V', 100, 101, 102, 103, 104, 105, 106, 300, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 21, 22, 23, 24, 26, 27),
            @('CITIZEN_M32_V', 83, 84, 85, 86, 87, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14))
        $nrs = foreach ($r in $rows) { foreach ($n in $r[1..($r.Count - 1)]) {
            (Get-CNCDeviceInfo -Machine @{ MachineName = "M $n"; AssetFamily = $r[0]; DLLName = 'x.dll' } -Manifest $manifest).DeviceNr } }
        @($nrs | Where-Object { -not $_ }).Count | Should -Be 0
        @($nrs | Group-Object | Where-Object Count -gt 1).Count | Should -Be 0
    }

    It 'accepts a name of exactly 15 characters (Humacao_L20X_13)' {
        (Get-CNCDeviceInfo -Machine @{ MachineName = 'Humacao_L20X_13'; AssetFamily = 'CITIZEN_L20X_IV'; DLLName = 'citizenm.dll' } -Manifest $manifest).DeviceNr | Should -Be '1013'
    }

    It 'reports an error for <Case>' -ForEach @(
        @{ Case = 'no trailing number';      Name = 'Lathe-A';     Family = 'CITIZEN_L20X_IV'; Dll = 'citizenm.dll' }
        @{ Case = 'number above 999';        Name = 'CNC 1000';    Family = 'CITIZEN_L20X_IV'; Dll = 'citizenm.dll' }
        @{ Case = 'unknown family';          Name = 'CNC_1';       Family = 'CITIZEN M32';     Dll = 'citizenm.dll' }
        @{ Case = 'no DLL in the Site DB';   Name = 'CNC_1';       Family = 'CITIZEN_L20X_IV'; Dll = '' }
        @{ Case = 'name longer than 15 characters (CNCnetPDM cuts it)'; Name = 'Citizen L320EA 10'; Family = 'CITIZEN_L20E_V'; Dll = 'mitsubishim.dll' }
    ) {
        $info = Get-CNCDeviceInfo -Machine @{ MachineName = $Name; AssetFamily = $Family; DLLName = $Dll } -Manifest $manifest
        $info.Error    | Should -Not -BeNullOrEmpty
        $info.DeviceNr | Should -BeNullOrEmpty
    }

    It 'falls back to CNCType when AssetFamily is empty' {
        (Get-CNCDeviceInfo -Machine @{ MachineName = 'X_2'; CNCType = 'CITIZEN_L20X_IV'; DLLName = 'citizenm.dll' } -Manifest $manifest).DeviceNr | Should -Be '1002'
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

Describe 'Get-RunModeSkipSteps' {
    It 'skips nothing in a full run' {
        Get-RunModeSkipSteps -Manifest $manifest -Mode Full | Should -BeNullOrEmpty
    }
    It 'skips every step not reviewed yet' {
        Get-RunModeSkipSteps -Manifest $manifest -Mode Reviewed | Should -Be @(2, 4, 5, 6, 7, 11, 12)
    }
    It 'skips the system steps in test mode' {
        Get-RunModeSkipSteps -Manifest $manifest -Mode Test | Should -Be @(2, 4, 5, 6, 7, 11, 12)
    }
    It 'follows the reviewed list in the manifest' {
        $m = $manifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $m.RunModes.ReviewedSteps = @(1, 2, 3)
        (Get-RunModeSkipSteps -Manifest $m -Mode Reviewed) | Should -Be @(4..13)
    }
}

Describe 'Test-LocalFixedPath' {
    It 'treats UNC shares as network: <Path>' -ForEach @(@{ Path = '\\sjum1bfile05\CMMprograms\REPORTS' }, @{ Path = '//server/share/x' }) {
        Test-LocalFixedPath $Path | Should -BeFalse
    }
    It 'treats a drive letter that does not exist as not local' {
        $free = [char[]]'QRSTUVWXY' | Where-Object { -not (Test-Path "${_}:\") } | Select-Object -First 1
        Test-LocalFixedPath "${free}:\Reports\CSVCLC" | Should -BeFalse
    }
    It 'treats the test folder as local' {
        Test-LocalFixedPath (Join-Path $TestDrive 'x') | Should -BeTrue
    }
}

Describe 'Test-ShareServerReachable' {
    It 'is true for local paths' {
        Test-ShareServerReachable (Join-Path $TestDrive 'x') | Should -BeTrue
    }
    It 'is false, within seconds, for a server that does not exist' {
        $t = [Diagnostics.Stopwatch]::StartNew()
        Test-ShareServerReachable '\\apc-wizard-test.invalid\share\x' | Should -BeFalse
        $t.Elapsed.TotalSeconds | Should -BeLessThan 10
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
