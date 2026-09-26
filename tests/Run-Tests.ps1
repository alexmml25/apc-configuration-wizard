<#
.SYNOPSIS
    Runs the wizard's automated tests (Pester 5+).
.DESCRIPTION
    Tests use the sample files in tests\fixtures and a temporary folder; they never touch real
    install paths, services, the Site DB or deviceWise, so they are safe to run on the VM.

      .\tests\Run-Tests.ps1                 # all tests
      .\tests\Run-Tests.ps1 -Name Step08    # only tests/Step08*.Tests.ps1

    Installs Pester 5 for the current user if only the old built-in Pester 3 is present.
#>
param([string]$Name = '*')

$ErrorActionPreference = 'Stop'
$pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.5' } | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
    Write-Host 'Installing Pester 5 for the current user...' -ForegroundColor Cyan
    Install-Module Pester -MinimumVersion 5.5 -MaximumVersion 5.99 -Scope CurrentUser -Force -SkipPublisherCheck
}
Import-Module Pester -MinimumVersion 5.5

$config = New-PesterConfiguration
$config.Run.Path       = @(Get-ChildItem $PSScriptRoot -Filter "$Name*.Tests.ps1" | ForEach-Object FullName)
$config.Run.Exit       = $true
$config.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $config
