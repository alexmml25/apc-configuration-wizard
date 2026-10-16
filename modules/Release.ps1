#Requires -Version 5.1
<#
.SYNOPSIS
    APC release from the release workbook (APC Releases.xlsx), as the APC Installation Manager reads it.
.DESCRIPTION
    Manifest APC.ReleaseFile is relative to APC.RepositoryRoot (or absolute). The workbook's first sheet has a header
    row with 'Component ID' and 'Version'; the APC-System row's Version is the release. Without the workbook (share not
    reachable, no row) the manifest APC.ReleaseLabel is used and the reason is returned in Problem.
    Read-XlsxRows is the Installation Manager's reader (modules\02-WindowsSetup.ps1 there): no Excel needed.
#>

function Read-XlsxRows {
    # Reads all data rows from the first sheet of an xlsx/xlsm as string arrays.
    # Uses pure .NET ZipFile + XML -- no ACE.OLEDB or Excel required.
    param([string]$XlPath)

    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

    # FileShare.ReadWrite: ZipFile.OpenRead fails with a sharing violation while Excel has the file open
    $fs      = [System.IO.File]::Open($XlPath, 'Open', 'Read', 'ReadWrite')
    $zip     = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)
    $result  = @()
    try {
        # Load shared strings table (cell values stored as indices)
        $ssEntry = $zip.Entries | Where-Object FullName -eq 'xl/sharedStrings.xml'
        $shared  = @()
        if ($ssEntry) {
            $sr  = New-Object System.IO.StreamReader($ssEntry.Open())
            $ssXml = [xml]$sr.ReadToEnd()
            $sr.Close()
            # InnerText handles both plain <t> and rich-text <r><t> without property errors
            $shared = @($ssXml.GetElementsByTagName('si') | ForEach-Object { $_.InnerText })
        }

        # Try all worksheet files in order; use the first one with more than one data row.
        # GetElementsByTagName ignores namespace prefixes - avoids XPath namespace issues.
        $wsEntries = @($zip.Entries |
            Where-Object { $_.FullName -match '^xl/worksheets/sheet\d+\.xml$' } |
            Sort-Object { [int]($_.FullName -replace '[^\d]', '') })
        if (-not $wsEntries) { return @() }

        $wsXml = $null
        foreach ($wsEntry in $wsEntries) {
            $sr   = New-Object System.IO.StreamReader($wsEntry.Open())
            $test = [xml]$sr.ReadToEnd()
            $sr.Close()
            if ($test.GetElementsByTagName('row').Count -gt 1) { $wsXml = $test; break }
        }
        if (-not $wsXml) { return @() }

        foreach ($row in $wsXml.GetElementsByTagName('row')) {
            $cells  = @($row.GetElementsByTagName('c'))
            $maxCol = 0
            foreach ($c in $cells) {
                $ref = $c.GetAttribute('r') -replace '\d', ''
                $col = 0
                foreach ($ch in $ref.ToCharArray()) { $col = $col * 26 + ([int][char]$ch - 64) }
                if ($col -gt $maxCol) { $maxCol = $col }
            }
            $arr = @('') * $maxCol
            foreach ($c in $cells) {
                $ref = $c.GetAttribute('r') -replace '\d', ''
                $col = 0
                foreach ($ch in $ref.ToCharArray()) { $col = $col * 26 + ([int][char]$ch - 64) }
                if ($c.GetAttribute('t') -eq 'inlineStr') {
                    # Text stored in the cell itself (files written by tools other than Excel)
                    $isNode = $c.GetElementsByTagName('is') | Select-Object -First 1
                    if ($isNode) { $arr[$col - 1] = $isNode.InnerText }
                    continue
                }
                $vNode = $c.GetElementsByTagName('v') | Select-Object -First 1
                if ($null -eq $vNode) { continue }
                $arr[$col - 1] = if ($c.GetAttribute('t') -eq 's') { $shared[[int]$vNode.InnerText] } else { $vNode.InnerText }
            }
            $result += ,@($arr)
        }
    } finally {
        $zip.Dispose()
    }
    return $result
}

function Get-ApcRelease {
    # @{ Release; ReleaseLabel; Source; Problem } - never throws
    param([Parameter(Mandatory)] [object]$Manifest)
    $apc = $Manifest.APC
    $res = @{ Release = [string]$apc.Version; ReleaseLabel = [string]$apc.ReleaseLabel; Source = 'manifest'; Problem = '' }
    try {
        $rel = if ($apc.PSObject.Properties['ReleaseFile']) { [string]$apc.ReleaseFile } else { '' }
        if (-not $rel) { throw 'APC.ReleaseFile is not set in the manifest.' }
        # Path.Combine, not Join-Path: Join-Path tries to resolve the UNC share as a drive
        $path = if ([System.IO.Path]::IsPathRooted($rel)) { $rel } else { [System.IO.Path]::Combine([string]$apc.RepositoryRoot, $rel) }
        if (-not (Test-Path -LiteralPath $path)) { throw "Release workbook not found: $path" }
        $rows = @(Read-XlsxRows -XlPath $path)
        if ($rows.Count -lt 2) { throw "The release workbook has no rows: $path" }
        $head = @($rows[0] | ForEach-Object { ([string]$_).Trim() })
        $idCol = [array]::IndexOf(@($head | ForEach-Object { $_.ToLowerInvariant() }), 'component id')
        $vCol  = [array]::IndexOf(@($head | ForEach-Object { $_.ToLowerInvariant() }), 'version')
        if ($idCol -lt 0 -or $vCol -lt 0) { throw "The release workbook has no 'Component ID' / 'Version' columns." }
        $sys = $rows | Select-Object -Skip 1 | Where-Object { $idCol -lt @($_).Count -and ([string]@($_)[$idCol]).Trim() -eq 'APC-System' } | Select-Object -First 1
        $ver = if ($sys -and $vCol -lt @($sys).Count) { ([string]@($sys)[$vCol]).Trim() } else { '' }
        if (-not $ver) { throw 'The release workbook has no APC-System row with a Version.' }
        $res.Release = $ver; $res.ReleaseLabel = "APC System Release $ver"; $res.Source = $path
    } catch {
        $res.Problem = "$($_.Exception.Message)"
    }
    $res
}
