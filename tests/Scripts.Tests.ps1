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

    It 'manifest has only the MCR and MPR sites' {
        $m = Get-TestManifest
        @($m.Sites) | Should -Be @('MCR', 'MPR')
        @($m.SiteServers.PSObject.Properties.Name) | Sort-Object | Should -Be @('MCR', 'MPR')
        @($m.SiteOpcProcessCodes.PSObject.Properties.Name) | Sort-Object | Should -Be @('MCR', 'MPR')
    }

    It '<Launcher> uses CRLF line endings and points at an existing script' -ForEach @(
        @{ Launcher = 'Start-Wizard.cmd'; Target = 'APC_ConfigWizard.ps1' }
        @{ Launcher = 'Run-Tests.cmd';    Target = 'tests\Run-Tests.ps1' }
    ) {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $RepoRoot $Launcher))
        $text  = [System.Text.Encoding]::ASCII.GetString($bytes)
        ($text -split "`r`n").Count | Should -BeGreaterThan 5
        $text -replace "`r`n", '' | Should -Not -Match "`n"
        $text | Should -Match ([regex]::Escape("%~dp0$Target"))
        Join-Path $RepoRoot ($Target -replace '\\', '/') | Should -Exist
    }

    It 'the checklist template Step 13 fills is in templates\' {
        Join-Path $RepoRoot 'templates/D01555624_A_EN.docx' | Should -Exist
    }
}

Describe 'Wizard window (XAML)' {
    BeforeAll {
        # Build the XAML exactly as the wizard does: the here-string plus the generated instrument and step rows
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'APC_ConfigWizard.ps1'), [ref]$null, [ref]$null)
        $assign = { param($name) $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq $name }, $true) | Select-Object -First 1 }
        $xamlText = (& $assign '$xamlText').Right.Expression.Value
        $manifest = Get-TestManifest
        $StepDefs = & ([scriptblock]::Create((& $assign '$StepDefs').Right.Extent.Text))
        $instFrag = & ([scriptblock]::Create((& $assign '$instFrag').Right.Extent.Text))
        $stepFrag = & ([scriptblock]::Create((& $assign '$stepFrag').Right.Extent.Text))
        $xaml = [xml]$xamlText.Replace('<!--DATAAPPS_INSTRUMENTS-->', ($instFrag -join "`n")).Replace('<!--STEP_ROWS-->', ($stepFrag -join "`n"))
        $wizardSrc = Get-Content (Join-Path $RepoRoot 'APC_ConfigWizard.ps1') -Raw
        $names = @($xaml.SelectNodes("//*[@*[local-name()='Name']]") | ForEach-Object { $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml') })
    }

    It 'is well-formed XML' {
        $xaml.DocumentElement.LocalName | Should -Be 'Window'
    }

    It 'has no duplicate control names' {
        @($names | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name) | Should -BeNullOrEmpty
    }

    It 'has the <Control> control the code uses' -ForEach @(
        'ChkDefaultLicense', 'TxtLicense', 'TxtDataRoot', 'CmbStartStep', 'BtnBack', 'BtnNext', 'NavList', 'TxtChangeID',
        'RbModeReviewed', 'RbModeFull', 'RbModeTest', 'RbDoc1', 'RbDoc2', 'RbDoc3',
        'CmbShift1Hour', 'TxtShiftHint', 'TxtCHMIBench', 'TxtCHMIPct' | ForEach-Object { @{ Control = $_ } }
    ) {
        $names | Should -Contain $Control
    }

    It 'has a page panel for every wizard page' {
        $block  = [regex]::Match($wizardSrc, '(?s)\$Script:PagePanels = @\{(.*?)\}').Groups[1].Value
        $panels = [regex]::Matches($block, "'(?<p>Page\w+)'") | ForEach-Object { $_.Groups['p'].Value }
        @($panels).Count | Should -Be 10
        @($panels | Where-Object { $_ -notin $names }) | Should -BeNullOrEmpty
    }

    It 'has a type card for every configuration type, and a checkbox for every component' {
        foreach ($id in 'initial', 'restore', 'component', 'update', 'sysupdate', 'verify') { $names | Should -Contain "RbType_$id" }
        foreach ($c in 'tsdb', 'sinc', 'dw', 'cnc', 'doc', 'da', 'chmi') { $names | Should -Contain "ChkComp_$c" }
        foreach ($i in 0..5) { $names | Should -Contain "RbReason$i" }
    }

    It 'has a CHMI (800xA) row for CNC<N> with a Button / Both choice' -ForEach (1..3 | ForEach-Object { @{ N = $_ } }) {
        foreach ($c in "GridCHMIRow$N", "TxtCHMIMachine$N", "TxtCHMICurrent$N", "CmbCHMITrigger$N") { $names | Should -Contain $c }
        $cmb = $xaml.SelectSingleNode("//*[@*[local-name()='Name']='CmbCHMITrigger$N']")
        @($cmb.ChildNodes | ForEach-Object { "$($_.Content)=$($_.Tag)" }) | Should -Be @('Button=False', 'Both=True')
    }

    It 'has a row, status, icon and re-run button for step <N>' -ForEach (1..13 | ForEach-Object { @{ N = $_ } }) {
        foreach ($c in "RowStep$N", "TxtStep${N}Icon", "TxtStep${N}Status", "BtnRerun$N") { $names | Should -Contain $c }
    }

    It 'keeps the source ASCII so Windows PowerShell 5.1 reads it correctly without a BOM' {
        $wizardSrc | Should -Not -Match '[^\x00-\x7F]'
    }

    It 'has instrument controls for <Type>' -ForEach @('CMM', 'CTSCAN', 'BENCH', 'CONTRACER' | ForEach-Object { @{ Type = $_ } }) {
        foreach ($c in "CmbInstQty_$Type", "ChkInst_${Type}_1", "ChkInst_${Type}_2", "ChkInst_${Type}_3", "TxtInstSrc_$Type", "TxtInstErr_$Type", "TxtInstBc_$Type",
                       "BtnInstMore_$Type", "PanelInstMore_$Type") {
            $names | Should -Contain $c
        }
    }

    It 'every $controls[...] name used in the wizard exists in the XAML' {
        $src = Get-Content (Join-Path $RepoRoot 'APC_ConfigWizard.ps1') -Raw
        $used = [regex]::Matches($src, "(?:\`$controls|\`$capControls)\['(?<n>[A-Za-z0-9_]+)'\]") | ForEach-Object { $_.Groups['n'].Value } | Select-Object -Unique
        @($used | Where-Object { $_ -notin $names }) | Should -BeNullOrEmpty
    }
}
