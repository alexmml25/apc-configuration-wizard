#Requires -Version 5.1
<#
.SYNOPSIS
    Draft D01555624 (APC System Configuration Checklist, rev C) filled from the Step 13 results.
.DESCRIPTION
    Invoke-FillChecklist copies the template and fills it:
      - header: [System Name] = VM, [Document Number] / [X] = the record's number / revision when known
        (State.DocumentNumber / DocumentRevision), DRAFT watermark (Word's own watermark shape, removed with
        Design > Watermark > Remove Watermark - as the APC Installation Manager does for D01555616)
      - body placeholders: [System Name / VM Name], APC System V[X.X ], [APC Solution Name], and the conclusion
        [been / not been], [accepted / not accepted], [approved / not approved] from the overall result
      - System Identification: VM, version, solution, site, Installation Verification Record (D01555616 record,
        State.IVRDocumentId), Reason for Configuration ticked by label (Manifest.Checklist.ReasonLabels, rev C merges
        Component Configuration / Update into one box), Change ID
      - check tables: per row (T = table index, I = row) Pass / Fail / N/A ticked from the checks; several checks
        on one row are merged (any FAIL = Fail, any manual = left blank, all N/A = N/A). Performed By = operator
        account / AD employee number / date (16OCT2026), one per line, as the Installation Manager. The table's
        Comments row lists the failed items with their detail; the full evidence is in the HTML report.
    Template tables (0-based): 2 System Identification, 3 deviceWise, 4 TSDB, 5 DOC, 6 CNCnetPDM, 7 File Manager,
    8 Data Collector, 9 Data Analyzer, 10 CHMI, 11 Network, 12 APC UI Software Update / Import (always N/A until
    that type exists - user 2026-10-16), 13 Deviations, 14 References.
#>

. (Join-Path $PSScriptRoot 'Common.ps1')   # Get-OperatorAdInfo

function Get-ChecklistDate { (Get-Date).ToString('ddMMMyyyy', [Globalization.CultureInfo]::InvariantCulture).ToUpper() }   # 16OCT2026, English month on any VM locale

function Invoke-FillChecklist {
    param(
        [Parameter(Mandatory)] [string]    $TemplatePath,
        [Parameter(Mandatory)] [string]    $OutputPath,
        [Parameter(Mandatory)] [object]    $Manifest,
        [Parameter(Mandatory)] [hashtable] $State,
        [Parameter(Mandatory)] $Checks,
        # values for the blanks / blue examples of the Expected Results cells: 'T|R' -> @(@{ Match = text in the
        # paragraph; Values = @(one per blank, in order) }, ...)
        [hashtable]$Fills = @{},
        # extra Comments text per table: T -> text (e.g. the N/A statement of the APC UI update table)
        [hashtable]$Comments = @{}
    )
    foreach ($asm in 'System.IO.Compression', 'System.IO.Compression.FileSystem') {
        if (-not ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq $asm })) {
            [void][Reflection.Assembly]::Load("$asm, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089")
        }
    }
    $W   = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
    $cfg = $Manifest.Checklist

    # -- who / when ------------------------------------------------------------------------------------
    $op = [string]$State['OperatorName']; if (-not $op) { $op = "$env:USERDOMAIN\$env:USERNAME" }
    $emp = [string]$State['EmployeeNumber']
    if (-not $emp) { $ad = Get-OperatorAdInfo $op; $emp = $ad.EmployeeNumber; if ($ad.Mail -and -not $State['OperatorEmail']) { $State['OperatorEmail'] = $ad.Mail; $State['OperatorFirstName'] = $ad.GivenName } }
    $performed = @(($op -split '\\')[-1]) + @(if ($emp) { $emp }) + @(Get-ChecklistDate)
    $hasFail = @($Checks | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0
    $vm  = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [Environment]::MachineName }
    $ver = [string]$Manifest.APC.Version
    $solution = if ($cfg -and $cfg.SolutionName) { [string]$cfg.SolutionName } else { 'Closed-Loop Correction (CLC)' }

    # -- read the template parts ----------------------------------------------------------------------
    $zin = [System.IO.Compression.ZipFile]::OpenRead($TemplatePath)
    $parts = @{}
    try {
        foreach ($e in $zin.Entries) {
            if ($e.FullName -eq 'word/document.xml' -or $e.FullName -match '^word/header\d*\.xml$') {
                $sr = New-Object System.IO.StreamReader($e.Open(), [System.Text.Encoding]::UTF8); $parts[$e.FullName] = $sr.ReadToEnd(); $sr.Close()
            }
        }
    } finally { $zin.Dispose() }

    $xml = New-Object System.Xml.XmlDocument; $xml.PreserveWhitespace = $true; $xml.LoadXml($parts['word/document.xml'])
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('w', $W); $ns.AddNamespace('w14', 'http://schemas.microsoft.com/office/word/2010/wordml')

    # paragraph text helpers ----------------------------------------------------------------------------
    $pText = { param($p) (@($p.SelectNodes('.//w:t', $ns)) | ForEach-Object { $_.InnerText }) -join '' }
    $setParaText = {
        # the paragraph's whole text into its first run (placeholders are often split over runs); blue/italic off
        param($p, [string[]]$Lines)
        $runs = @($p.SelectNodes('w:r', $ns))
        $first = $runs | Where-Object { $_.SelectSingleNode('w:t', $ns) } | Select-Object -First 1
        if (-not $first) {
            $first = $xml.CreateElement('w', 'r', $W); [void]$p.AppendChild($first)
        } else { foreach ($r in $runs) { if ($r -ne $first) { [void]$p.RemoveChild($r) } } }
        foreach ($c in @($first.ChildNodes)) { if ($c.LocalName -ne 'rPr') { [void]$first.RemoveChild($c) } }
        $rPr = $first.SelectSingleNode('w:rPr', $ns)
        if ($rPr) { foreach ($n in 'w:color', 'w:i', 'w:iCs') { $x = $rPr.SelectSingleNode($n, $ns); if ($x) { [void]$rPr.RemoveChild($x) } } }
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($i) { [void]$first.AppendChild($xml.CreateElement('w', 'br', $W)) }
            $t = $xml.CreateElement('w', 't', $W); $t.InnerText = $Lines[$i]
            [void]$t.SetAttribute('space', 'http://www.w3.org/XML/1998/namespace', 'preserve')
            [void]$first.AppendChild($t)
        }
    }
    $replaceInParas = {
        param([string]$Old, [string]$New)
        foreach ($p in @($xml.SelectNodes('//w:body//w:p', $ns))) {
            $t = & $pText $p
            if ($t.Contains($Old)) { & $setParaText $p @($t.Replace($Old, $New)) }
        }
    }
    $tick = {
        param($para)
        $chk = $para.SelectSingleNode('.//w14:checkbox/w14:checked', $ns)
        if ($chk) { $chk.SetAttribute('val', 'http://schemas.microsoft.com/office/word/2010/wordml', '1') }
        $t = $para.SelectSingleNode('.//w:sdtContent//w:t', $ns)
        if ($t) { $t.InnerText = [string][char]0x2612 }
    }

    # fills the blanks of one paragraph in order: a run of 3+ underscores, or a group of blue / placeholder runs
    # (one value per group, label runs such as a bold 'Device Nr:' are kept); blue/italic removed from filled runs
    $isBlue = { param($r) $c = $r.SelectSingleNode('w:rPr/w:color', $ns); $c -and ($c.GetAttribute('val', $W) -in '4F81BD', '0070C0', '4472C4' -or $c.GetAttribute('themeColor', $W) -eq 'accent1') }
    $fillBlanks = {
        param($p, [object[]]$Vals)
        $i = 0; $prevBlue = $false; $keepGroup = $false
        foreach ($r in @($p.SelectNodes('w:r', $ns))) {
            $t = $r.SelectSingleNode('w:t', $ns)
            if (-not $t) { continue }
            if (& $isBlue $r) {
                if (-not $prevBlue -and -not $t.InnerText.Trim()) { continue }   # a blue space before the placeholder stays
                if ($prevBlue) { if ($keepGroup) { continue }; [void]$p.RemoveChild($r); continue }   # rest of the same blue group
                $prevBlue = $true; $keepGroup = $false
                if ($i -ge $Vals.Count) { $keepGroup = $true; continue }
                if ($null -eq $Vals[$i]) { $i++; $keepGroup = $true; continue }                       # $null: leave this one
                $t.InnerText = [string]$Vals[$i]; $i++
                $rPr = $r.SelectSingleNode('w:rPr', $ns)
                foreach ($n in 'w:color', 'w:i', 'w:iCs') { $x = $rPr.SelectSingleNode($n, $ns); if ($x) { [void]$rPr.RemoveChild($x) } }
                [void]$t.SetAttribute('space', 'http://www.w3.org/XML/1998/namespace', 'preserve')
            } else {
                $prevBlue = $false
                $txt = $t.InnerText
                while ($i -lt $Vals.Count -and $txt -match '_{3,}') { $txt = ([regex]'_{3,}').Replace($txt, ([string]$Vals[$i]).Replace('$', '$$'), 1); $i++ }
                if ($txt -ne $t.InnerText) { $t.InnerText = $txt; [void]$t.SetAttribute('space', 'http://www.w3.org/XML/1998/namespace', 'preserve') }
            }
        }
    }

    # -- body placeholders ----------------------------------------------------------------------------
    & $replaceInParas '[System Name / VM Name]' $vm
    & $replaceInParas 'APC System V[X.X ]' "APC System V$ver"
    & $replaceInParas '[APC Solution Name]' $solution
    & $replaceInParas '[been / not been]' $(if ($hasFail) { 'not been' } else { 'been' })
    & $replaceInParas '[accepted / not accepted]' $(if ($hasFail) { 'not accepted' } else { 'accepted' })
    & $replaceInParas '[approved / not approved]' $(if ($hasFail) { 'not approved' } else { 'approved' })

    $tables = $xml.SelectNodes('//w:body/w:tbl', $ns)

    # -- System Identification (table 2) ---------------------------------------------------------------
    $sys = $tables[2]
    if ($sys) {
        $rows = $sys.SelectNodes('w:tr', $ns)
        $siteNames = @{ MCR = 'Medtronic Costa Rica'; MPR = 'Medtronic Puerto Rico' }
        $site = if ($siteNames[$State['SiteCode']]) { $siteNames[$State['SiteCode']] } else { [string]$State['SiteCode'] }
        # plain hashtable: an [ordered] one indexes integer keys by position
        $values = @{ 0 = $vm; 1 = "APC System V$ver"; 2 = $solution; 3 = $site; 4 = [string]$State['IVRDocumentId']; 6 = [string]$State['ChangeID'] }   # the ID only (user 2026-10-16)
        foreach ($k in @($values.Keys | Sort-Object)) {
            if (-not $values[$k] -or $k -ge $rows.Count) { continue }
            $cells = $rows[$k].SelectNodes('w:tc', $ns)
            if ($cells.Count -ge 2) { & $setParaText ($cells[1].SelectSingleNode('w:p', $ns)) @($values[$k]) }
        }
        # Reason for Configuration: the box whose label matches the run's type
        $labels = if ($cfg) { $cfg.ReasonLabels } else { $null }
        # Verification picks its reason on the last page (State.ReasonType = a type id); otherwise the run's type
        $type = if ($State['ReasonType']) { [string]$State['ReasonType'] } else { [string]$State['ConfigType'] }
        $label = if ($labels -and $type -and $labels.PSObject.Properties[$type]) { [string]$labels.$type } else { '' }
        if ($label -and $rows.Count -gt 5) {
            $cell = $rows[5].SelectNodes('w:tc', $ns)[1]
            foreach ($p in @($cell.SelectNodes('w:p', $ns))) {
                if ((& $pText $p) -like "*$label*") {
                    & $tick $p
                    if ($label -eq 'Other' -and $State['ConfigReasonOther']) {
                        $lt = @($p.SelectNodes('.//w:t', $ns)) | Where-Object { $_.InnerText -match 'Other' } | Select-Object -First 1
                        if ($lt) { $lt.InnerText = " Other: $($State['ConfigReasonOther'])" }
                    }
                    break
                }
            }
        }
    }

    # -- check tables: merge the checks of each row ------------------------------------------------------
    $rowsOf = @{}
    foreach ($c in $Checks) { if ($c.T -ge 3 -and $c.I -ge 1) { $k = "$($c.T)|$($c.I)"; if (-not $rowsOf[$k]) { $rowsOf[$k] = @() }; $rowsOf[$k] += $c } }
    $fails = @{}; $rowStatus = @{}
    foreach ($k in $rowsOf.Keys) {
        $t, $i = $k -split '\|' | ForEach-Object { [int]$_ }
        $table = $tables[$t]; if (-not $table) { continue }
        $rows = $table.SelectNodes('w:tr', $ns); if ($i -ge $rows.Count) { continue }
        $cells = $rows[$i].SelectNodes('w:tc', $ns); if ($cells.Count -lt 5) { continue }
        $grp = @($rowsOf[$k])
        $status = if (@($grp | Where-Object { $_.Status -eq 'FAIL' }).Count) { 'FAIL' }
                  elseif (@($grp | Where-Object { $_.Status -eq 'BLANK' }).Count) { 'BLANK' }
                  elseif (-not @($grp | Where-Object { $_.Status -ne 'NA' }).Count) { 'NA' }
                  else { 'PASS' }
        $rowStatus[$k] = $status
        $idx = @{ PASS = 0; FAIL = 1; NA = 2 }[$status]
        if ($null -eq $idx) { continue }
        $paras = $cells[3].SelectNodes('w:p', $ns)
        if ($idx -lt $paras.Count) { & $tick $paras[$idx] }
        & $setParaText ($cells[4].SelectSingleNode('w:p', $ns)) $performed
        if ($status -eq 'FAIL') {
            if (-not $fails[$t]) { $fails[$t] = @() }
            $fails[$t] += "Item ${i}: " + ((@($grp | Where-Object { $_.Status -eq 'FAIL' }) | ForEach-Object { "$($_.Name) - $($_.Detail)" }) -join '; ')
        }
    }
    $commentTables = @($fails.Keys) + @($Comments.Keys) | ForEach-Object { [int]$_ } | Select-Object -Unique
    foreach ($t in $commentTables) {
        $lines = @(if ($Comments.ContainsKey($t)) { $Comments[$t] } elseif ($Comments.ContainsKey("$t")) { $Comments["$t"] }) + @($fails[$t])
        $lines = @($lines | Where-Object { $_ })
        if (-not $lines) { continue }
        $cm = @($tables[$t].SelectNodes('w:tr', $ns)) | Where-Object { (& $pText $_) -like 'Comments:*' } | Select-Object -Last 1
        if ($cm) { $cells = $cm.SelectNodes('w:tc', $ns); if ($cells.Count -ge 2) { & $setParaText ($cells[1].SelectSingleNode('w:p', $ns)) $lines } }
    }

    # -- blanks and blue examples in the Expected Results cells (Step 13 values) ------------------------------
    # only where the row passed: a value in a failed row would read as verified
    # (Always = an operator input such as the IT ticket: written whatever the row's result)
    foreach ($k in $Fills.Keys) {
        if ($rowStatus[$k] -ne 'PASS' -and -not @($Fills[$k] | Where-Object { $_.Always }).Count) { continue }
        $t, $r = $k -split '\|' | ForEach-Object { [int]$_ }
        if (-not $tables[$t]) { continue }
        $rows = $tables[$t].SelectNodes('w:tr', $ns); if ($r -ge $rows.Count) { continue }
        $cells = $rows[$r].SelectNodes('w:tc', $ns); if ($cells.Count -lt 3) { continue }
        foreach ($f in @($Fills[$k] | Where-Object { $_.Always -or $rowStatus[$k] -eq 'PASS' })) {
            # the paragraph with the text that still has a blank or a blue example ('APC VM IP address documented:'
            # also contains 'VM IP')
            $p = @($cells[2].SelectNodes('.//w:p', $ns)) | Where-Object {
                $pp = $_; (& $pText $pp).Contains([string]$f.Match) -and ((& $pText $pp) -match '_{3,}' -or @($pp.SelectNodes('w:r', $ns) | Where-Object { & $isBlue $_ }).Count)
            } | Select-Object -First 1
            if ($p) { & $fillBlanks $p @($f.Values) }
        }
    }

    # -- Deviations: N/A when nothing failed; References: N/A (none are produced) -------------------------------
    foreach ($p in @($xml.SelectNodes('//w:body/w:p', $ns))) {
        $pt = & $pText $p
        if (($pt -like '*No Deviations applicable*' -and -not $hasFail) -or $pt -like '*No References applicable*') { & $tick $p }
    }

    # -- headers: placeholders + DRAFT watermark -------------------------------------------------------------
    $wm = '<w:r><w:rPr><w:noProof/></w:rPr><w:pict>' +
          '<v:shapetype id="_x0000_t136" coordsize="21600,21600" o:spt="136" adj="10800" path="m@7,l@8,m@5,21600l@6,21600e">' +
          '<v:formulas><v:f eqn="sum #0 0 10800"/><v:f eqn="prod #0 2 1"/><v:f eqn="sum 21600 0 @1"/><v:f eqn="sum 0 0 @2"/>' +
          '<v:f eqn="sum 21600 0 @3"/><v:f eqn="if @0 @3 0"/><v:f eqn="if @0 21600 @1"/><v:f eqn="if @0 0 @2"/>' +
          '<v:f eqn="if @0 @4 21600"/><v:f eqn="mid @5 @6"/><v:f eqn="mid @8 @5"/><v:f eqn="mid @7 @8"/>' +
          '<v:f eqn="mid @6 @7"/><v:f eqn="sum @6 0 @5"/></v:formulas>' +
          '<v:path textpathok="t" o:connecttype="custom" o:connectlocs="@9,0;@10,10800;@11,21600;@12,10800" o:connectangles="270,180,90,0"/>' +
          '<v:textpath on="t" fitshape="t"/><v:handles><v:h position="#0,bottomRight" xrange="6629,14971"/></v:handles>' +
          '<o:lock v:ext="edit" text="t" shapetype="t"/></v:shapetype>' +
          '<v:shape id="PowerPlusWaterMarkObject1" o:spid="_x0000_s2049" type="#_x0000_t136" ' +
          'style="position:absolute;margin-left:0;margin-top:0;width:412.4pt;height:247.45pt;rotation:315;z-index:-251657216;' +
          'mso-position-horizontal:center;mso-position-horizontal-relative:margin;mso-position-vertical:center;mso-position-vertical-relative:margin" ' +
          'o:allowincell="f" fillcolor="silver" stroked="f"><v:fill opacity=".5"/>' +
          '<v:textpath style="font-family:&quot;Calibri&quot;;font-size:1pt" string="DRAFT"/>' +
          '<w10:wrap anchorx="margin" anchory="margin"/></v:shape></w:pict></w:r>'
    $esc = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }
    $xs0 = New-Object System.Xml.XmlWriterSettings; $xs0.Encoding = New-Object System.Text.UTF8Encoding($false)
    $revision = if ($State['DocumentRevision']) { [string]$State['DocumentRevision'] } elseif ($cfg -and $cfg.Revision) { [string]$cfg.Revision } else { '' }
    foreach ($h in @($parts.Keys | Where-Object { $_ -ne 'word/document.xml' })) {
        # placeholders are blue and split over runs ('[System' 'Name]'): filled per paragraph like the table blanks
        $hx = New-Object System.Xml.XmlDocument; $hx.PreserveWhitespace = $true; $hx.LoadXml($parts[$h])
        $docSave = $xml; $nsSave = $ns; $xml = $hx
        $ns = New-Object System.Xml.XmlNamespaceManager($hx.NameTable); $ns.AddNamespace('w', $W)
        $known = @{ '[System Name]' = $vm; '[Document Number]' = $(if ($State['DocumentNumber']) { [string]$State['DocumentNumber'] }); '[X]' = $revision }
        foreach ($p in @($hx.SelectNodes('//w:p', $ns))) {
            $pt = & $pText $p
            # one value per placeholder, in the order they appear ($null = not known yet, left as it is)
            $found = @($known.Keys | Where-Object { $pt.Contains($_) } | Sort-Object { $pt.IndexOf($_) })
            if ($found) {
                $vals = New-Object System.Collections.Generic.List[object]       # (ForEach-Object would drop the $null entries)
                foreach ($f in $found) { if ($known[$f]) { $vals.Add($known[$f]) } else { $vals.Add($null) } }
                & $fillBlanks $p $vals.ToArray()
            }
        }
        $xml = $docSave; $ns = $nsSave
        $hms = New-Object System.IO.MemoryStream; $hw = [System.Xml.XmlWriter]::Create($hms, $xs0); $hx.Save($hw); $hw.Close()
        $hdr = [System.Text.Encoding]::UTF8.GetString($hms.ToArray())
        if ($hdr -notmatch 'PowerPlusWaterMarkObject') {
            # the VML namespaces the shape needs
            foreach ($nsDecl in @('xmlns:v="urn:schemas-microsoft-com:vml"', 'xmlns:o="urn:schemas-microsoft-com:office:office"', 'xmlns:w10="urn:schemas-microsoft-com:office:word"')) {
                if ($hdr -notmatch [regex]::Escape(($nsDecl -split '=')[0] + '=')) { $hdr = [regex]::Replace($hdr, '<w:hdr ', "<w:hdr $nsDecl ", 1) }
            }
            $firstP = $hdr.IndexOf('</w:p>')
            if ($firstP -ge 0) { $hdr = $hdr.Insert($firstP, $wm) }
        }
        $parts[$h] = $hdr
    }

    # -- write the copy ------------------------------------------------------------------------------------
    # straight to UTF-8 bytes: a StringWriter would declare encoding="utf-16" (Word then reports unreadable content)
    $ms = New-Object System.IO.MemoryStream
    $xs = New-Object System.Xml.XmlWriterSettings; $xs.Encoding = New-Object System.Text.UTF8Encoding($false)
    $xw = [System.Xml.XmlWriter]::Create($ms, $xs); $xml.Save($xw); $xw.Close()
    $parts['word/document.xml'] = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())

    $out = [System.IO.File]::Open($OutputPath, [System.IO.FileMode]::Create)
    $zout = New-Object System.IO.Compression.ZipArchive($out, [System.IO.Compression.ZipArchiveMode]::Create)
    $zin = [System.IO.Compression.ZipFile]::OpenRead($TemplatePath)
    try {
        foreach ($e in $zin.Entries) {
            $d = $zout.CreateEntry($e.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
            $ds = $d.Open()
            if ($parts.ContainsKey($e.FullName)) { $b = [System.Text.Encoding]::UTF8.GetBytes($parts[$e.FullName]); $ds.Write($b, 0, $b.Length) }
            else { $ss = $e.Open(); $ss.CopyTo($ds); $ss.Close() }
            $ds.Close()
        }
    } finally { $zin.Dispose(); $zout.Dispose(); $out.Dispose() }
    return @{ Path = $OutputPath; Failed = $hasFail; Performed = ($performed -join ' / ') }
}
