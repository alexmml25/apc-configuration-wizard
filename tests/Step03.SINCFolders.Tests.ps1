BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $ModulesDir '03-SINCFolders.ps1')
}

Describe 'Step 3 - SINC staging folders' {
    BeforeEach {
        Reset-StepResults
        $manifest = Get-TestManifest
        $staging  = Join-Path $TestDrive "SINC-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        $manifest.DeviceWise.SINCStaging = $staging
    }

    It 'creates exactly CNC1-3 x Processing/DoneSuccess/DoneError for 3 DOC instances' {
        Invoke-SINCFolders -Manifest $manifest -State (New-HumState)
        $dirs = Get-ChildItem $staging -Directory -Recurse | ForEach-Object { $_.FullName.Substring($staging.Length + 1) -replace '\\', '/' } | Sort-Object
        $expected = 1..3 | ForEach-Object { $n = $_; "CNC$n"; 'DoneError', 'DoneSuccess', 'Processing' | ForEach-Object { "CNC$n/$_" } } | Sort-Object
        $dirs | Should -Be $expected
        Get-StepResults -Status FAIL | Should -BeNullOrEmpty
    }

    It 'creates only CNC1-2 for 2 DOC instances and no machine-named folders' {
        Invoke-SINCFolders -Manifest $manifest -State (New-HumState -DocCount 2)
        (Get-ChildItem $staging -Directory).Name | Should -Be @('CNC1', 'CNC2')
    }

    It 'leaves existing folders alone on a re-run' {
        Invoke-SINCFolders -Manifest $manifest -State (New-HumState)
        Set-Content (Join-Path $staging 'CNC1/Processing/keep.csv') 'x'
        Invoke-SINCFolders -Manifest $manifest -State (New-HumState)
        Join-Path $staging 'CNC1/Processing/keep.csv' | Should -Exist
    }
}
