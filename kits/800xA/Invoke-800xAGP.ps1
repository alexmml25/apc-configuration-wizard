# Helper functions to read/write 800xA General Properties from a PowerShell wizard.
# Uses GPWrite3.vbs via 32-bit cscript (the OPC DA automation layer is 32-bit, and
# calling it directly from PowerShell's COM adapter proved unreliable in the POC).
# Works from 32- or 64-bit PowerShell. Dot-source it:  . "$PSScriptRoot\Invoke-800xAGP.ps1"

$script:GP_Cscript = Join-Path $env:WINDIR 'SysWOW64\cscript.exe'

function Invoke-800xAGP {
    param(
        [Parameter(Mandatory)][string]$ItemId,
        [string]$Value,                                   # omit to read only
        [string]$Server     = 'ABB.AfwOpcDaSurrogate.1',
        [string]$ScriptPath = (Join-Path $PSScriptRoot 'GPWrite3.vbs')
    )
    $ErrorActionPreference = 'Continue'   # native stderr must not abort the caller
    if (-not (Test-Path $ScriptPath)) { throw "VBScript not found: $ScriptPath" }
    if ($Value -match '"') { throw "Values containing double quotes are not supported." }

    $argz = @('//nologo', $ScriptPath, "/server:$Server", "/item:$ItemId")
    if ($PSBoundParameters.ContainsKey('Value')) { $argz += "/value:$Value" }

    $out = & $script:GP_Cscript @argz 2>&1
    $rc  = $LASTEXITCODE
    $text = $out -join "`n"

    $before = if ($text -match "Before: value='(.*?)' quality=") { $Matches[1] }
    $after  = if ($text -match "After:  value='(.*?)' quality=") { $Matches[1] }
    $err    = if ($text -match "(ERROR at step .*)") { $Matches[1] }

    [pscustomobject]@{
        ItemId   = $ItemId
        Before   = $before
        After    = $after
        Success  = ($rc -eq 0 -and -not $err)
        ExitCode = $rc
        Error    = $err
        Output   = $text
    }
}

# Examples:
#   $r = Invoke-800xAGP -ItemId 'Cell_1:URL1'                         # read
#   $r = Invoke-800xAGP -ItemId 'Cell_1:URL1' -Value 'C:\new\path.png' # write + verify
#   if (-not $r.Success) { Write-Warning "800xA write failed: $($r.Error)" }
#   "$($r.ItemId): '$($r.Before)' -> '$($r.After)'" | Add-Content "$PSScriptRoot\800xA_changes.log"
