#Requires -Version 5.1
<#
.SYNOPSIS
    Makes the manifest check for a standard password (salted PBKDF2-SHA256 hash), so the wizard can
    tell whether a typed password is the standard one without the password being stored anywhere.
.DESCRIPTION
    Asks for the password twice (hidden), makes a random salt and prints the JSON to paste into the
    manifest, e.g. PostgreSQL.LocalUserPasswordCheck for the standard local apcuser password.
    Run it as a file (not pasted), because it reads from the console.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\New-PasswordCheck.ps1
#>
param([int]$Iterations = 200000)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\Common.ps1')

$p1 = Read-Host 'Standard password' -AsSecureString
$p2 = Read-Host 'Same password again' -AsSecureString
$salt = New-Object byte[] 16
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($salt) } finally { $rng.Dispose() }
$h1 = Get-PasswordHash -Password $p1 -Salt $salt -Iterations $Iterations
$h2 = Get-PasswordHash -Password $p2 -Salt $salt -Iterations $Iterations
if ($h1 -cne $h2) { throw 'The two entries differ. Nothing was made.' }

Write-Host "`r`nPaste these lines into the manifest check (e.g. PostgreSQL.LocalUserPasswordCheck):" -ForegroundColor Cyan
Write-Host ('      "Iterations":  {0},' -f $Iterations)
Write-Host ('      "Salt":        "{0}",' -f [Convert]::ToBase64String($salt))
Write-Host ('      "Hash":        "{0}"' -f $h1)
