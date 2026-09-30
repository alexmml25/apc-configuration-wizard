BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $ModulesDir '08-CNCnetPDM.ps1')

    # Fake CNCnetPDM install folder from the default fixture files plus dummy driver files
    function New-PdmInstall {
        param([string[]]$Drivers = @('citizenm.dll', 'citizenm_CNC1.ini', 'citizenm_CNC2.ini', 'citizenm_CNC3.ini'))
        $dir = Join-Path $TestDrive "CNCnetPDM-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory -Path $dir | Out-Null
        Copy-Item (Get-Fixture 'CNCnetPDM/CNCnetPDM.ini') $dir
        Copy-Item (Get-Fixture 'CNCnetPDM/melcfg.ini') $dir
        Set-TestLogDir (Join-Path $dir 'CNCnetPDM.ini')
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
        $m.CNCnetPDM.DriverDllWaitSeconds = 0   # the service stub creates the .dll files and log lines immediately or never
        $m.CNCnetPDM.ConnectWaitSeconds   = 0
        $m.CNCnetPDM.PortCheckTimeoutMs   = 100
        $m
    }
}

Describe 'Step 8 - CNCnetPDM (Humacao example)' {
    BeforeAll {
        Reset-StepResults
        $dir = New-PdmInstall
        Set-ServiceCreatesDriverDlls $dir
        Invoke-CNCnetPDM -Manifest (New-PdmManifest $dir) -State (New-HumState)
    }

    It 'produces the same CNCnetPDM.ini as the HUM example' {
        Get-NormalizedIni (Join-Path $dir 'CNCnetPDM.ini') | Should -Be (Get-NormalizedIni (Get-Fixture 'CNCnetPDM/CNCnetPDMHUM.ini'))
    }

    It 'produces the same melcfg.ini as the HUM example' {
        Get-NormalizedIni (Join-Path $dir 'melcfg.ini') | Should -Be (Get-NormalizedIni (Get-Fixture 'CNCnetPDM/melcfgHUM.ini'))
    }

    It 'renames citizenm_CNC{n}.ini to citizenm_{DeviceNr}.ini' {
        'citizenm_1001.ini', 'citizenm_1003.ini', 'citizenm_1008.ini', 'citizenm.dll' | ForEach-Object { Join-Path $dir $_ | Should -Exist }
        Get-ChildItem $dir -Filter '*_CNC*' | Should -BeNullOrEmpty
    }

    It 'reports each device connected from its CNCnetPDM log' {
        foreach ($n in '1001', '1003', '1008') {
            (Get-StepResults | Where-Object Check -like "CNC* device $n connected*").Status | Should -Be 'PASS'
        }
    }

    It 'checks that the service created citizenm_{DeviceNr}.dll after the restart' {
        foreach ($n in '1001', '1003', '1008') {
            (Get-StepResults | Where-Object Check -eq "Driver citizenm_$n.dll created").Status | Should -Be 'PASS'
        }
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

    It 'uses the Site DB DLL and family digit, and renames .dll and .ini for a _V machine' {
        $dir = New-PdmInstall -Drivers @('mitsubishim.dll', 'mitsubishim_CNC1.ini', 'citizenm.dll', 'citizenm_CNC2.ini')
        $state = @{
            SiteCode = 'MCR'; DOCCount = 2; DOCMachineAssignments = @('MCR-CNC-0004', 'MCR-CNC-0011')
            CNCMachines = @(
                @{ MachineName = 'MCR-CNC-0004'; IPAddress = '10.1.1.4';  Port = '683'; AssetFamily = 'CITIZEN_L20E_V';  DLLName = 'mitsubishim.dll' },
                @{ MachineName = 'MCR-CNC-0011'; IPAddress = '10.1.1.11'; Port = '683'; AssetFamily = 'CITIZEN L20E_IV'; DLLName = 'citizenm.dll' })
        }
        Invoke-CNCnetPDM -Manifest (New-PdmManifest $dir) -State $state
        $lines = Get-Content (Join-Path $dir 'CNCnetPDM.ini') | Where-Object { $_ -match '^\d+ = ' }
        $lines | Should -Be @(
            '1 = 4004;19200;8;N;1;MCR-CNC-0004;10.1.1.4;683;0;localhost;1;0;none;none;0;mitsubishim.dll',
            '2 = 2011;19200;8;N;1;MCR-CNC-0011;10.1.1.11;683;0;localhost;2;0;none;none;0;citizenm.dll')
        'mitsubishim_4004.ini', 'citizenm_2011.ini' | ForEach-Object { Join-Path $dir $_ | Should -Exist }
        # driver ini content is only renamed, never changed
        Get-Content (Join-Path $dir 'mitsubishim_4004.ini') -Raw | Should -Be (Get-Content (Get-Fixture 'CNCnetPDM/mitsubishim_CNC1.ini') -Raw)
    }

    It 'stops before touching any file when a DeviceNr cannot be derived' {
        $dir = New-PdmInstall
        $before = Get-Content (Join-Path $dir 'CNCnetPDM.ini') -Raw
        $state = @{ DOCCount = 1; DOCMachineAssignments = @('Lathe-A')
                    CNCMachines = @(@{ MachineName = 'Lathe-A'; IPAddress = '10.1.1.4'; AssetFamily = 'CITIZEN_M32_IV'; DLLName = 'citizenm.dll' }) }
        { Invoke-CNCnetPDM -Manifest (New-PdmManifest $dir) -State $state } | Should -Throw '*DeviceNr*'
        Get-Content (Join-Path $dir 'CNCnetPDM.ini') -Raw | Should -Be $before
        Get-StepResults -Status FAIL | Should -Not -BeNullOrEmpty
    }

    It 'stops when two CNCs would get the same DeviceNr' {
        $dir = New-PdmInstall
        $state = @{ DOCCount = 2; DOCMachineAssignments = @('LineA_1', 'LineB_1')
                    CNCMachines = @(@{ MachineName = 'LineA_1'; IPAddress = '1.1.1.1'; AssetFamily = 'CITIZEN_L20X_IV'; DLLName = 'citizenm.dll' },
                                    @{ MachineName = 'LineB_1'; IPAddress = '1.1.1.2'; AssetFamily = 'CITIZEN_L20X_IV'; DLLName = 'citizenm.dll' }) }
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

    It 'warns when the service does not create a driver .dll' {
        $dir = New-PdmInstall
        Invoke-CNCnetPDM -Manifest (New-PdmManifest $dir) -State (New-HumState -DocCount 1)
        (Get-StepResults | Where-Object Check -eq 'Driver citizenm_1001.dll created').Status | Should -Be 'WARN'
    }

    It 'warns with the log line when a device is not connected' {
        $dir = New-PdmInstall
        Set-ServiceCreatesDriverDlls $dir -Connect NotConnected
        Invoke-CNCnetPDM -Manifest (New-PdmManifest $dir) -State (New-HumState -DocCount 1)
        $r = Get-StepResults | Where-Object Check -like 'CNC1 device 1001 connected*'
        $r.Status | Should -Be 'WARN'
        $r.Detail | Should -Match 'Not connected'
        $r.Detail | Should -Match '10\.101\.99\.47:683'
    }

    It 'ignores log lines written before the restart' {
        $dir = New-PdmInstall
        $logDir = Join-Path $dir 'log'
        Set-Content (Join-Path $logDir "log_1001_$(Get-Date -Format 'yyMMdd').txt") '2026-09-30 08:00:00.000 Success writing command: <1|1|0|1> to controller'
        Set-ServiceCreatesDriverDlls $dir -Connect None
        Invoke-CNCnetPDM -Manifest (New-PdmManifest $dir) -State (New-HumState -DocCount 1)
        $r = Get-StepResults | Where-Object Check -like 'CNC1 device 1001 connected*'
        $r.Status | Should -Be 'WARN'
        $r.Detail | Should -Match 'No connection result'
    }

    It 'warns when a CNC has no driver ini to rename' {
        $dir = New-PdmInstall -Drivers @('citizenm.dll')
        Invoke-CNCnetPDM -Manifest (New-PdmManifest $dir) -State (New-HumState -DocCount 1)
        (Get-StepResults | Where-Object Check -eq 'Driver ini citizenm_1001.ini').Status | Should -Be 'WARN'
    }

    It 'does not restart the service in test mode' {
        $dir = New-PdmInstall
        $state = New-HumState -DocCount 1
        $state.SandboxRoot = $TestDrive
        Invoke-CNCnetPDM -Manifest (New-PdmManifest $dir) -State $state
        $global:ServiceActions | Should -BeNullOrEmpty
        Get-StepResults | Where-Object Check -like '*connected*' | Should -BeNullOrEmpty
    }
}
