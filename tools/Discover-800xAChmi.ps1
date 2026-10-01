#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only look at the 800xA OPC UA certificates and the UA Management Portal (Step 11, SOP sub-steps 1-2).
.DESCRIPTION
    The UA Management Portal decides whether a root certificate exists by looking for its private key in
    the Windows Certificate Store. This lists:
      1. every 800xA certificate in the LocalMachine and CurrentUser stores (store, thumbprint, private key)
      2. every .der file under the OPC UA Connect / Management Portal pki folders (subject, issuer, thumbprint)
      3. the UA Management Portal Start Menu shortcut, its target and the program folder's exe/config files
    Nothing is changed and the portal is not started.
    Output: C:\APC_Config\Logs\chmi-step1.txt
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Discover-800xAChmi.ps1
#>
param(
    [string]$PkiRoot = 'C:\ProgramData\ABB\Process Portal A',
    [string]$OutDir  = 'C:\APC_Config\Logs'
)

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$outFile = Join-Path $OutDir 'chmi-step1.txt'
$report = New-Object System.Collections.Generic.List[string]
$report.Add("800xA CHMI discovery - $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - user $env:USERDOMAIN\$env:USERNAME")
$report.Add('')

$report.Add('== 1. Windows certificate store: 800xA certificates ==')
$storeCerts = @(Get-ChildItem Cert:\LocalMachine, Cert:\CurrentUser -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509Certificate2] -and ($_.Subject -match '800xA' -or $_.Issuer -match '800xA') })
if ($storeCerts) {
    $report.Add(($storeCerts | Select-Object PSParentPath, Subject, Issuer, Thumbprint, HasPrivateKey, NotBefore, NotAfter |
        Format-List | Out-String -Width 300))
} else { $report.Add('  (none found)') }

$report.Add('== 2. pki .der files ==')
$derFiles = @(Get-ChildItem -LiteralPath $PkiRoot -Recurse -Filter *.der -File -ErrorAction SilentlyContinue)
if ($derFiles) {
    $rows = foreach ($f in $derFiles) {
        try {
            $c = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($f.FullName)
            [pscustomobject]@{ File = $f.FullName; Subject = $c.Subject; Issuer = $c.Issuer; Thumbprint = $c.Thumbprint; NotBefore = $c.NotBefore; NotAfter = $c.NotAfter }
        } catch {
            [pscustomobject]@{ File = $f.FullName; Subject = "(could not read: $($_.Exception.Message))"; Issuer = ''; Thumbprint = ''; NotBefore = ''; NotAfter = '' }
        }
    }
    $report.Add(($rows | Format-List | Out-String -Width 300))
} else { $report.Add("  (no .der files under $PkiRoot)") }

$report.Add('== 3. UA Management Portal shortcut and program folder ==')
$shell = New-Object -ComObject WScript.Shell
$links = @(Get-ChildItem "$env:ProgramData\Microsoft\Windows\Start Menu" -Recurse -Filter *.lnk -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'UA Management|Management Portal' })
if (-not $links) {
    $report.Add('  No "UA Management Portal" shortcut found. Shortcuts with UA or Portal in the name:')
    Get-ChildItem "$env:ProgramData\Microsoft\Windows\Start Menu" -Recurse -Filter *.lnk -ErrorAction SilentlyContinue |
        Where-Object Name -match 'UA|Portal' | ForEach-Object { $report.Add("    $($_.FullName)") }
}
foreach ($lnk in $links) {
    $l = $shell.CreateShortcut($lnk.FullName)
    $report.Add(([pscustomobject]@{ Shortcut = $lnk.FullName; Target = $l.TargetPath; Arguments = $l.Arguments; WorkDir = $l.WorkingDirectory } |
        Format-List | Out-String -Width 300))
    if ($l.TargetPath -and (Test-Path -LiteralPath $l.TargetPath)) {
        $report.Add(("Program folder: " + (Split-Path $l.TargetPath)))
        $report.Add((Get-ChildItem -LiteralPath (Split-Path $l.TargetPath) -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.exe', '.config', '.xml', '.json' } |
            Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize | Out-String -Width 300))
    }
}

$report | Out-File -FilePath $outFile -Width 300 -Encoding UTF8
"Written: $outFile"
