BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $ModulesDir '08-CNCnetPDM.ps1')

    # Fake CNCnetPDM install folder from the default fixture files plus dummy driver files
    function New-PdmInstall {
        param([string[]]$Drivers = @('citizenm.dll', 'citizenm_CNC1.dll', 'citizenm_CNC2.dll', 'citizenm_CNC3.dll'))
        $dir = Join-Path $TestDrive "CNCnetPDM-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory -Path $dir | Out-Null
        Copy-Item (Get-Fixture 'CNCnetPDM/CNCnetPDM.ini') $dir
        Copy-Item (Get-Fixture 'CNCnetPDM/melcfg.ini') $dir
        foreach ($d in $Drivers) {
            if ($d -eq 'mitsubishim_CNC1.ini') { Copy-Item (Get-Fixture 'CNCnetPDM/mitsubishim_CNC1.ini') $dir }
            else { Set-Content (Join-Path $dir $d) 'driver' }
        }
        $dir
    }
    function New-PdmManifest {
        param([string]$Dir)
        $m = Get-TestManifest
        $m.CNCnetPDM.InstallDir = $Dir; $m.CNCnetPDM.FallbackDir = $Dir
        $m
    }
}

Describe 'Step 8 - CNCnetPDM (Humacao example)' {
    BeforeAll {
        Reset-StepResults
        $dir = New-PdmInstall
        Invoke-CNCnetPDM -Manifest (New-PdmManifest $dir) -State (New-HumState)
    }

    It 'produces the same CNCnetPDM.ini as the HUM example' {
        Get-NormalizedIni (Join-Path $dir 'CNCnetPDM.ini') | Should -Be (Get-NormalizedIni (Get-Fixture 'CNCnetPDM/CNCnetPDMHUM.ini'))
    }

    It 'produces the same melcfg.ini as the HUM example' {
        Get-NormalizedIni (Join-Path $dir 'melcfg.ini') | Should -Be (Get-NormalizedIni (Get-Fixture 'CNCnetPDM/melcfgHUM.ini'))
    }

    It 'renames citizenm_CNC{n}.dll to citizenm_<DeviceNr>.dll' {
        'citizenm_1001.dll', 'citizenm_1003.dll', 'citizenm_1008.dll', 'citizenm.dll' | ForEach-Object { Join-Path $dir $_ | Should -Exist }
        Get-ChildItem $dir -Filter '*_CNC*.dll' | Should -BeNullOrEmpty
    }

    It 'backs up both ini files and reports no failures' {
        (Get-ChildItem $dir -Filter '*.bak').Count | Should -Be 2
        Get-StepResults -Status FAIL | Should -BeNullOrEmpty
    }

    It 'restarts the CNCnetPDM service' {
        $global:ServiceActions | Should -Contain 'restart CNCnetPDM'
    }

    It 'changes nothing when run again' {
        $ini = Get-Content (Join-Path $dir 'CNCnetPDM.ini') -Raw
        $mel = Get-Content (Join-Path $dir 'melcfg.ini') -Raw
        Invoke-CNCnetPDM -Manifest (New-PdmManifest $dir) -State (New-HumState)
        Get-Content (Join-Path $dir 'CNCnetPDM.ini') -Raw | Should -Be $ini
        Get-Content (Join-Path $dir 'melcfg.ini') -Raw     | Should -Be $mel
    }
}

Describe 'Step 8 - CNCnetPDM rules' {
    BeforeEach { Reset-StepResults }

    It 'uses mitsubishim.dll and renames .dll and .ini for a _V machine' {
        $dir = New-PdmInstall -Drivers @('mitsubishim.dll', 'mitsubishim_CNC1.dll', 'mitsubishim_CNC1.ini', 'citizenm.dll', 'citizenm_CNC2.dll')
        $state = @{
            SiteCode = 'MCR'; DOCCount = 2; DOCMachineAssignments = @('MCR-CNC-0004', 'MCR-CNC-0011')
            CNCMachines = @(
                @{ MachineName = 'MCR-CNC-0004'; IPAddress = '10.1.1.4';  Port = '683'; AssetFamily = 'CITIZEN_L20E_V' },
                @{ MachineName = 'MCR-CNC-0011'; IPAddress = '10.1.1.11'; Port = '683'; AssetFamily = 'CITIZEN L20E_IV' })
        }
        Invoke-CNCnetPDM -Manifest (New-PdmManifest $dir) -State $state
        $lines = Get-Content (Join-Path $dir 'CNCnetPDM.ini') | Where-Object { $_ -match '^\d+ = ' }
        $lines | Should -Be @(
            '1 = 1104;19200;8;N;1;MCR-CNC-0004;10.1.1.4;683;0;localhost;1;0;none;none;0;mitsubishim.dll',
            '2 = 1011;19200;8;N;1;MCR-CNC-0011;10.1.1.11;683;0;localhost;2;0;none;none;0;citizenm.dll')
        'mitsubishim_1104.dll', 'mitsubishim_1104.ini', 'citizenm_1011.dll' | ForEach-Object { Join-Path $dir $_ | Should -Exist }
        # driver ini content is only renamed, never changed
        Get-Content (Join-Path $dir 'mitsubishim_1104.ini') -Raw | Should -Be (Get-Content (Get-Fixture 'CNCnetPDM/mitsubishim_CNC1.ini') -Raw)
    }

    It 'stops before touching any file when a DeviceNr cannot be derived' {
        $dir = New-PdmInstall
        $before = Get-Content (Join-Path $dir 'CNCnetPDM.ini') -Raw
        $state = @{ DOCCount = 1; DOCMachineAssignments = @('Lathe-A')
                    CNCMachines = @(@{ MachineName = 'Lathe-A'; IPAddress = '10.1.1.4'; AssetFamily = 'CITIZEN_M32_IV' }) }
        { Invoke-CNCnetPDM -Manifest (New-PdmManifest $dir) -State $state } | Should -Throw '*DeviceNr*'
        Get-Content (Join-Path $dir 'CNCnetPDM.ini') -Raw | Should -Be $before
        Get-StepResults -Status FAIL | Should -Not -BeNullOrEmpty
    }

    It 'stops when two CNCs would get the same DeviceNr' {
        $dir = New-PdmInstall
        $state = @{ DOCCount = 2; DOCMachineAssignments = @('LineA_1', 'LineB_1')
                    CNCMachines = @(@{ MachineName = 'LineA_1'; IPAddress = '1.1.1.1'; AssetFamily = 'CITIZEN_L20X_IV' },
                                    @{ MachineName = 'LineB_1'; IPAddress = '1.1.1.2'; AssetFamily = 'CITIZEN_M32_IV' }) }
        { Invoke-CNCnetPDM -Manifest (New-PdmManifest $dir) -State $state } | Should -Throw
        (Get-StepResults -Status FAIL).Check | Should -Contain 'DeviceNr 1001 unique'
    }

    It 'writes the manifest default license when none is entered' {
        $dir = New-PdmInstall
        $m = New-PdmManifest $dir
        $m.CNCnetPDM.DefaultLicense = 'DEFAULTKEY0001'
        Invoke-CNCnetPDM -Manifest $m -State (New-HumState -DocCount 1)
        @(Get-Content (Join-Path $dir 'CNCnetPDM.ini') | Where-Object { $_ -match '^License\s*=' }) | Should -Be @('License = DEFAULTKEY0001')
    }

    It 'writes a license entered in the wizard' {
        $dir = New-PdmInstall
        $state = New-HumState -DocCount 1
        $state.CNCnetPDMLicense = 'CUSTOMKEY0002'
        Invoke-CNCnetPDM -Manifest (New-PdmManifest $dir) -State $state
        @(Get-Content (Join-Path $dir 'CNCnetPDM.ini') | Where-Object { $_ -match '^License\s*=' }) | Should -Be @('License = CUSTOMKEY0002')
    }

    It 'does not restart the service in test mode' {
        $dir = New-PdmInstall
        $state = New-HumState -DocCount 1
        $state.SandboxRoot = $TestDrive
        Invoke-CNCnetPDM -Manifest (New-PdmManifest $dir) -State $state
        $global:ServiceActions | Should -BeNullOrEmpty
    }
}
