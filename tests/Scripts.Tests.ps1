BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Scripts' {
    It '<Name> has no syntax errors' -ForEach @(
        (Get-ChildItem (Split-Path $PSScriptRoot -Parent) -Filter '*.ps1') + (Get-ChildItem (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules') -Filter '*.ps1') |
            ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
    ) {
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        @($errors | ForEach-Object { "L$($_.Extent.StartLineNumber): $($_.Message)" }) | Should -BeNullOrEmpty
    }

    It 'manifest is valid JSON' {
        { Get-TestManifest } | Should -Not -Throw
    }

    It 'every step function named by <Runner> exists in its module' -ForEach @(
        @{ Runner = 'APC_ConfigWizard.ps1'; Pattern = "File = '(?<file>[^']+)';\s*Fn = '(?<fn>[^']+)'" }
        @{ Runner = 'APC_Config.ps1';       Pattern = "File = '(?<file>[^']+)';\s*Fn = '(?<fn>[^']+)'" }
    ) {
        $src = Get-Content (Join-Path $RepoRoot $Runner) -Raw
        $defs = [regex]::Matches($src, $Pattern)
        $defs.Count | Should -Be 13
        foreach ($d in $defs) {
            $module = Get-Content (Join-Path $ModulesDir $d.Groups['file'].Value) -Raw
            $module | Should -Match "(?m)^function $([regex]::Escape($d.Groups['fn'].Value)) \{" -Because "$Runner -> $($d.Groups['file'].Value)"
        }
    }

    It 'the checklist template Step 13 fills is in templates\' {
        Join-Path $RepoRoot 'templates/D01555624_A_EN.docx' | Should -Exist
    }
}

Describe 'Wizard window (XAML)' {
    BeforeAll {
        # Build the XAML exactly as the wizard does: the here-string plus the generated instrument rows
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'APC_ConfigWizard.ps1'), [ref]$null, [ref]$null)
        $assign = { param($name) $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq $name }, $true) | Select-Object -First 1 }
        $xamlText = (& $assign '$xamlText').Right.Expression.Value
        $manifest = Get-TestManifest
        $instFrag = & ([scriptblock]::Create((& $assign '$instFrag').Right.Extent.Text))
        $xaml = [xml]$xamlText.Replace('<!--DATAAPPS_INSTRUMENTS-->', ($instFrag -join "`n"))
        $names = @($xaml.SelectNodes("//*[@*[local-name()='Name']]") | ForEach-Object { $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml') })
    }

    It 'is well-formed XML' {
        $xaml.DocumentElement.LocalName | Should -Be 'Window'
    }

    It 'has no duplicate control names' {
        @($names | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name) | Should -BeNullOrEmpty
    }

    It 'has the <Control> control the code uses' -ForEach @(
        'ChkTestMode', 'ChkDefaultLicense', 'TxtLicense', 'TxtDataRoot', 'CmbDOCCount', 'CmbStartStep', 'BtnConfigure' | ForEach-Object { @{ Control = $_ } }
    ) {
        $names | Should -Contain $Control
    }

    It 'has instrument controls for <Type>' -ForEach @('CMM', 'CTSCAN', 'BENCH', 'CONTRACER' | ForEach-Object { @{ Type = $_ } }) {
        foreach ($c in "CmbInstQty_$Type", "ChkInst_${Type}_1", "ChkInst_${Type}_2", "ChkInst_${Type}_3", "TxtInstSrc_$Type", "TxtInstErr_$Type", "TxtInstBc_$Type") {
            $names | Should -Contain $c
        }
    }

    It 'every $controls[...] name used in the wizard exists in the XAML' {
        $src = Get-Content (Join-Path $RepoRoot 'APC_ConfigWizard.ps1') -Raw
        $used = [regex]::Matches($src, "(?:\`$controls|\`$capControls)\['(?<n>[A-Za-z0-9_]+)'\]") | ForEach-Object { $_.Groups['n'].Value } | Select-Object -Unique
        @($used | Where-Object { $_ -notin $names }) | Should -BeNullOrEmpty
    }
}
