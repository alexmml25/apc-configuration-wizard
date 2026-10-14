#Requires -Version 5.1
<#
.SYNOPSIS
    deviceWise helpers dot-sourced by the deviceWise steps (4, and later 5, 6, 8).
.DESCRIPTION
    The gateway (23.04.08) has no usable local API for configuration, so the steps use Telit's
    documented import folder, Gateway\staging\system\import (import.readme.txt in the install):
      import.dwx   a deviceWise export / Workbench backup, imported when dwcore starts;
                   outcome in import.result (the readme says import.results), file then deleted
      package.sup  a package; NOT usable with the approved .pkg files (encrypted: "Failed to
                   decrypt file", -7018). Packages are installed from an exported payload
                   by following their own install instructions (Get-DwPackagePlan).
    Rules found on the test VMs (2026-10-08 / 10-13):
      - dwts must be running during an import, or every transport / transaction fails (-4999);
        dwcore and dwts have no service dependency, so only dwcore is restarted.
      - Status 0 = imported. Certificates / Connections Log / Sessions are runtime lists (-1).
    The configuration comes from an approved baseline Workbench backup (.dbk, plain XML; baseline
    = SJUM7AAPPS0065, user decision 2026-10-13). This VM's values are patched in before the import.
    Values that are not part of an export (CNCnetPDM instance, gateway settings) live in
    Gateway\db\DWUSER.db, table persistence; they are read through the gateway's own sqlite3.dll.
#>

. (Join-Path $PSScriptRoot 'Common.ps1')

function Get-DwPaths {
    param([Parameter(Mandatory)] [object]$Manifest)
    $root = [string]$Manifest.DeviceWise.GatewayInstallDir
    # plain string paths: Join-Path fails when the drive does not exist (gateway not installed / other drive)
    $sub  = { param($p) $root.TrimEnd('\') + '\' + $p }
    return @{
        Root      = $root
        ImportDir = & $sub 'staging\system\import'
        Packages  = & $sub 'dwcore\packages'
        Db        = & $sub 'db'
        Sqlite    = & $sub 'dwcore\sqlite3.dll'
        # devices that must be Started after every dwcore restart (Restart-DwCore)
        KeepStarted = @(if ($Manifest.DeviceWise.PSObject.Properties['KeepStartedDevices']) { $Manifest.DeviceWise.KeepStartedDevices })
    }
}

function Get-DwRepoPath {
    # A manifest path that is absolute is used as is; otherwise it is under APC.RepositoryRoot
    param([Parameter(Mandatory)] [object]$Manifest, [Parameter(Mandatory)] [string]$SubPath)
    if ([IO.Path]::IsPathRooted($SubPath)) { return $SubPath }
    return Join-Path $Manifest.APC.RepositoryRoot $SubPath
}

#region -- Baseline -> import file -------------------------------------------

function Set-DwSystemName {
    # The 'system' item is base64 of: <length byte><gateway name><rest>, e.g. \x0eSJUM7AAPPS0065\x01 0 \x00\x03 1.0
    param([Parameter(Mandatory)] [string]$Base64, [Parameter(Mandatory)] [string]$Name)
    $bytes = [Convert]::FromBase64String($Base64.Trim())
    $len   = [int]$bytes[0]
    if ($len -lt 1 -or $len + 1 -gt $bytes.Length) { throw "Unexpected gateway name format in the baseline 'system' item." }
    if ($Name.Length -gt 255) { throw "Gateway name '$Name' is too long." }
    $rest  = New-Object byte[] ($bytes.Length - 1 - $len)
    [Array]::Copy($bytes, 1 + $len, $rest, 0, $rest.Length)
    $new = @([byte]$Name.Length) + [Text.Encoding]::ASCII.GetBytes($Name) + $rest
    return [Convert]::ToBase64String([byte[]]$new)
}

function Set-DwVariableDefault {
    # Adds/replaces default="..." on a top-level <VariableInfo name="$Variable"> in a device's
    # Variables property. The CNC devices have persist_values=false, so a default is what the
    # gateway sets again on every start.
    param([Parameter(Mandatory)] [string]$VariablesXml, [Parameter(Mandatory)] [string]$Variable, [string]$Value)
    $esc = [Security.SecurityElement]::Escape($Value)
    $pattern = '<VariableInfo\b[^>]*\bname="' + [regex]::Escape($Variable) + '"[^>]*?/?>'
    $m = [regex]::Match($VariablesXml, $pattern)
    if (-not $m.Success) { throw "Variable $Variable not found in the device definition." }
    $tag = $m.Value -replace '\s+default="[^"]*"', ''
    $tag = $tag -replace '(\s*/?>)$', (' default="' + $esc.Replace('$', '$$') + '"$1')
    return $VariablesXml.Substring(0, $m.Index) + $tag + $VariablesXml.Substring($m.Index + $m.Length)
}

function Get-DwBaseline {
    # The approved baseline backup (Manifest.DeviceWise.BaselineRepoSubPath) as a FileInfo
    param([Parameter(Mandatory)] [object]$Manifest)
    $p = Get-DwRepoPath -Manifest $Manifest -SubPath $Manifest.DeviceWise.BaselineRepoSubPath
    if (-not (Test-Path $p -PathType Leaf)) { throw "Baseline backup not found: $p" }
    return Get-Item $p
}

function New-DwImportFromBaseline {
    <#
        Loads the baseline backup and keeps only the <exportcontent> items for which $Keep (param $type,
        $name) returns true. The licence voucher (lease issued to the source VM) is always removed.
        Returns @{ Xml = [xml]; Items = [string[]] 'type/name' }.
    #>
    param([Parameter(Mandatory)] [string]$BaselinePath, [Parameter(Mandatory)] [scriptblock]$Keep)
    $xml = New-Object Xml.XmlDocument
    $xml.PreserveWhitespace = $true
    $xml.Load($BaselinePath)
    if ($xml.DocumentElement.Name -ne 'export') { throw "$BaselinePath is not a deviceWise export/backup (root <$($xml.DocumentElement.Name)>)." }
    $items = New-Object System.Collections.Generic.List[string]
    foreach ($ec in @($xml.DocumentElement.SelectNodes('exportcontent'))) {
        $type = $ec.GetAttribute('type'); $name = $ec.GetAttribute('name')
        if (& $Keep $type $name) { $items.Add("$type/$name") } else { [void]$xml.DocumentElement.RemoveChild($ec) }
    }
    foreach ($v in @($xml.SelectNodes("//exportcontent[@type='license.pool']//PersistenceEntry[@name='voucher']"))) { [void]$v.ParentNode.RemoveChild($v) }
    # Table rows (dbtabledata) must come after their table (dbtable): the baseline has the rows first,
    # which fails with -7022 on a gateway that does not have the table yet (fresh VM, 2026-10-14)
    $tables = @($xml.DocumentElement.SelectNodes("exportcontent[@type='dbtable']"))
    if ($tables.Count) {
        $after = $tables[-1]
        foreach ($d in @($xml.DocumentElement.SelectNodes("exportcontent[@type='dbtabledata']"))) {
            [void]$xml.DocumentElement.InsertAfter($d, $after); $after = $d
        }
    }
    return @{ Xml = $xml; Items = [string[]]$items }
}

function New-DwBaseImport {
    <#
        Builds the Step 4 import from the baseline backup:
          keeps the item types in Manifest.DeviceWise.BaseImportTypes; of type 'device' only
          BaseDevices (CNC1-3), of type 'file' only the OPC UA device files of those devices;
          removes the licence voucher (lease issued to the source VM);
          sets the gateway name, the OPC UA endpoint host and CNCn CNCAsset / CNCType defaults.
        $Cncs: hashtables with CNCIndex, MachineName, CNCType (Get-AssignedCNCs).
        Returns @{ Xml = [xml]; Items = [string[]] 'type/name'; Changes = [string[]] }.
    #>
    param(
        [Parameter(Mandatory)] [string]$BaselinePath,
        [Parameter(Mandatory)] [object]$Manifest,
        [Parameter(Mandatory)] [object[]]$Cncs,
        [Parameter(Mandatory)] [string]$GatewayName
    )
    $dw      = $Manifest.DeviceWise
    $types   = @($dw.BaseImportTypes)
    $devices = @($dw.CNCNodes)
    $build = New-DwImportFromBaseline -BaselinePath $BaselinePath -Keep {
        param($type, $name)
        $keep = $types -contains $type
        if ($keep -and $type -eq 'device') { $keep = $devices -contains $name }
        if ($keep -and $type -eq 'file')   { $keep = @($devices | Where-Object { $name -eq "/uaserver/devices/$_.json" }).Count -gt 0 }
        $keep
    }
    $xml     = $build.Xml
    $items   = $build.Items
    $changes = New-Object System.Collections.Generic.List[string]
    $changes.Add('licence voucher of the source VM removed')

    $sys = $xml.SelectSingleNode("//exportcontent[@type='system']/exportitem")
    if ($sys) {
        $sys.InnerText = Set-DwSystemName -Base64 $sys.InnerText -Name $GatewayName
        $changes.Add("gateway name = $GatewayName")
    }

    $ep = $xml.SelectSingleNode("//exportcontent[@type='Endpoints']/exportitem")
    if ($ep) {
        $text = $ep.InnerText
        $new  = [regex]::Replace($text, '("endpoint_address"\s*:\s*"opc\.tcp://)[^:/"]+', { param($m) $m.Groups[1].Value + $GatewayName })
        if ($new -ne $text) { $changes.Add("OPC UA endpoint host = $GatewayName") }
        # SOP 2.1.1: all security policies except the last (Aes256Sha256RsaPss); the baseline differs
        if ($dw.PSObject.Properties['OpcUaSecurityPolicies']) {
            $pol  = @($dw.OpcUaSecurityPolicies) -join ','
            $new2 = [regex]::Replace($new, '("group_security_security_policies"\s*:\s*")[^"]*', { param($m) $m.Groups[1].Value + $pol })
            if ($new2 -ne $new) { $changes.Add("OPC UA security policies = $pol") }
            $new = $new2
        }
        $ep.InnerText = $new
    }

    foreach ($c in $Cncs) {
        $node = "CNC$($c.CNCIndex)"
        $prop = $xml.SelectSingleNode("//exportcontent[@type='device' and @name='$node']//DeviceDefinition/Properties/Property[@name='Variables']")
        if (-not $prop) { throw "Device $node is not in the baseline." }
        $vars = $prop.GetAttribute('value')
        $vars = Set-DwVariableDefault -VariablesXml $vars -Variable 'CNCAsset' -Value ([string]$c.MachineName)
        $vars = Set-DwVariableDefault -VariablesXml $vars -Variable 'CNCType'  -Value ([string]$c.CNCType)
        $prop.SetAttribute('value', $vars)
        $changes.Add("$node CNCAsset = $($c.MachineName), CNCType = $($c.CNCType)")
    }
    return @{ Xml = $xml; Items = [string[]]$items; Changes = [string[]]$changes }
}

function ConvertFrom-DwTableData {
    <#
        Decodes a 'dbtabledata' item: base64 of zlib (78 9C ... Adler-32) of a CSV where every field is
        wrapped in 0x0B and every row ends in CRLF. Returns @{ Columns = [string[]]; Rows = [string[][]] }.
    #>
    param([Parameter(Mandatory)] [string]$Base64)
    $bytes = [Convert]::FromBase64String($Base64.Trim())
    # ::new, not New-Object Type(a, b, c - 6): there the comma binds before the minus
    $in  = [IO.MemoryStream]::new($bytes, 2, $bytes.Length - 6)   # skip the zlib header and the Adler-32
    $def = [IO.Compression.DeflateStream]::new($in, [IO.Compression.CompressionMode]::Decompress)
    $out = [IO.MemoryStream]::new()
    try { $def.CopyTo($out) } finally { $def.Dispose() }
    $text = [Text.Encoding]::UTF8.GetString($out.ToArray())
    $vt = [char]0x0B
    $rows = @(foreach ($line in ($text -split "`r`n")) {
        if ($line -eq '') { continue }
        , @([regex]::Matches($line, "$vt([^$vt]*)$vt") | ForEach-Object { $_.Groups[1].Value })
    })
    return @{ Columns = [string[]]$rows[0]; Rows = @($rows | Select-Object -Skip 1) }
}

function ConvertTo-DwTableData {
    # The reverse of ConvertFrom-DwTableData: columns + rows -> base64 zlib, in the gateway's own format
    param([Parameter(Mandatory)] [string[]]$Columns, [object[]]$Rows = @())
    $vt = [char]0x0B
    $sb = New-Object Text.StringBuilder
    foreach ($r in @(, $Columns) + @($Rows)) {
        [void]$sb.Append((@($r | ForEach-Object { "$vt$_$vt" }) -join ',')).Append("`r`n")
    }
    $data = [Text.Encoding]::UTF8.GetBytes($sb.ToString())
    $ms = [IO.MemoryStream]::new()
    $ms.WriteByte(0x78); $ms.WriteByte(0x9C)
    $def = [IO.Compression.DeflateStream]::new($ms, [IO.Compression.CompressionMode]::Compress, $true)
    $def.Write($data, 0, $data.Length); $def.Dispose()
    [uint32]$a = 1; [uint32]$b = 0
    foreach ($x in $data) { $a = ($a + $x) % 65521; $b = ($b + $a) % 65521 }
    $adler = ([uint64]$b -shl 16) -bor $a
    foreach ($shift in 24, 16, 8, 0) { $ms.WriteByte([byte](($adler -shr $shift) -band 0xFF)) }
    return [Convert]::ToBase64String($ms.ToArray())
}

function Save-DwXml {
    param([Parameter(Mandatory)] [xml]$Xml, [Parameter(Mandatory)] [string]$Path)
    $w = New-Object IO.StreamWriter($Path, $false, (New-Object Text.UTF8Encoding($false)))
    try { $Xml.Save($w) } finally { $w.Close() }
}

#endregion

#region -- Gateway: services, import folder ------------------------------------

function Restart-DwCore {
    <#
        Stops dwcore, runs $WhileStopped, starts dwcore again whatever happened. dwts keeps running.
        With -Paths, devices keep their Started state: the gateway saves a device as Stopped when it stops
        during the shutdown (SINC's UA client loses the gateway's own OPC UA server, fresh VM 2026-10-14)
        and restores that at the next start. So the devices Started before the stop, and $Paths.KeepStarted
        (manifest DeviceWise.KeepStartedDevices), are set back to Started in DWCORE.db before the start.
    #>
    param([Parameter(Mandatory)] [scriptblock]$WhileStopped, [hashtable]$Paths, [int]$StopTimeoutSec = 180)
    if ((Get-Service 'dwts').Status -ne 'Running') { Write-Log INFO 'Starting dwts (needed during imports)'; Start-Service 'dwts' }
    $startedBefore = @()
    if ($Paths) {
        try { $b = Get-DwDeviceStates -Paths $Paths; $startedBefore = @($b.Keys | Where-Object { $b[$_] -eq 1 }) }
        catch { Write-Log WARN "Could not read the device states before the restart: $($_.Exception.Message)" }
    }
    Write-Log INFO 'Stopping dwcore'
    Stop-Service 'dwcore' -Force -WarningAction SilentlyContinue
    (Get-Service 'dwcore').WaitForStatus('Stopped', [TimeSpan]::FromSeconds($StopTimeoutSec))
    if ($Paths) {
        try {
            $a = Get-DwDeviceStates -Paths $Paths
            $fix = @(@($startedBefore) + @($Paths.KeepStarted) | Where-Object { $_ -and $a.ContainsKey($_) -and $a[$_] -ne 1 } | Sort-Object -Unique)
            if ($fix.Count) { Set-DwDeviceStarted -Paths $Paths -Names $fix; Write-Log INFO "Kept started: $($fix -join ', ')" }
        } catch { Write-Log WARN "Could not keep the devices started: $($_.Exception.Message)" }
    }
    try { & $WhileStopped }
    finally {
        Write-Log INFO 'Starting dwcore (imports run during startup and can take minutes)'
        Start-Service 'dwcore' -WarningAction SilentlyContinue
    }
}

function Wait-DwImportFile {
    # Waits until the gateway has consumed $Queued and written one of $ResultFiles; returns its path or $null
    param([string]$Queued, [string[]]$ResultFiles, [int]$TimeoutSec = 900)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Path $Queued)) {
            $r = $ResultFiles | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($r) { return $r }
        }
        Start-Sleep -Seconds 3
    }
    return $null
}

function Read-DwImportResult {
    # Parses import.result: 'Type[t] Item[n] import status[s]' lines and 'Overall import status[s]'
    param([Parameter(Mandatory)] [string]$Path)
    $items = @(); $overall = $null
    foreach ($line in Get-Content $Path) {
        if ($line -match '^Type\[(.*)\] Item\[(.*)\] import status\[(-?\d+)\]') {
            $items += [pscustomobject]@{ Type = $Matches[1]; Item = $Matches[2]; Status = [int]$Matches[3] }
        } elseif ($line -match 'Overall import status\[(-?\d+)\]') { $overall = [int]$Matches[1] }
    }
    return [pscustomobject]@{ Items = $items; Overall = $overall; Lines = @(Get-Content $Path) }
}

function Save-DwDatabases {
    # Safety copy of the configuration databases (dwcore must be stopped). Logs/reports are skipped.
    param([Parameter(Mandatory)] [hashtable]$Paths, [Parameter(Mandatory)] [string]$Dest)
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    foreach ($db in 'DWCORE.db', 'DWAPP.db', 'DWUSER.db', 'DWTS.db') {
        $src = Join-Path $Paths.Db $db
        if (Test-Path $src) { Copy-Item $src $Dest -Force }
    }
}

function Get-DwDeviceSignature {
    # A device definition reduced to what makes it the same device: type + every property, with the
    # VariableInfo default="..." attributes removed (per-VM CNCAsset/CNCType, not applied by the gateway)
    param([Parameter(Mandatory)] $Definition)
    $props = foreach ($p in @($Definition.SelectNodes('Properties/Property'))) {
        $v = [regex]::Replace([string]$p.GetAttribute('value'), '\s+default="[^"]*"', '')
        $v = [regex]::Replace($v, '>\s+<', '><')          # formatting between elements
        $v = [regex]::Replace($v, '\s+(/?>)', '$1')        # ' />' vs '/>'
        $v = [regex]::Replace($v, '\s+', ' ').Trim()
        "$($p.GetAttribute('name'))=$v"
    }
    return "$($Definition.GetAttribute('type'))|" + ((@($props) | Sort-Object) -join '|')
}

function Remove-DwUnchangedDevices {
    <#
        Takes out of the import every device that already exists in the gateway with the same definition
        (Get-DwDeviceSignature), logging it. Returns the names of those meant to be started (exportproperty
        state = started) as Start, and all of them as Kept. Devices that exist with a different definition
        stay in the import (it reports -6401 for them).
    #>
    param([Parameter(Mandatory)] [hashtable]$Paths, [Parameter(Mandatory)] [xml]$Xml)
    $start = New-Object System.Collections.Generic.List[string]
    $kept  = New-Object System.Collections.Generic.List[string]
    foreach ($ec in @($Xml.DocumentElement.SelectNodes("exportcontent[@type='device']"))) {
        $name = $ec.GetAttribute('name')
        $mine = $ec.SelectSingleNode('.//DeviceDefinition')
        if (-not $mine) { continue }
        $have = $null
        try { $have = Get-DwXml -Paths $Paths -Table devices -Name $name } catch { Write-Log WARN "Could not read device $name from the gateway: $($_.Exception.Message)" }
        if (-not $have) { continue }
        $haveDef = if ($have.DocumentElement.Name -eq 'DeviceDefinition') { $have.DocumentElement } else { $have.SelectSingleNode('//DeviceDefinition') }
        if ($haveDef -and (Get-DwDeviceSignature $haveDef) -eq (Get-DwDeviceSignature $mine)) {
            $st = $ec.SelectSingleNode("exportproperty[@key='state']")
            if (-not $st -or $st.GetAttribute('value') -eq 'started') { $start.Add($name) }
            [void]$Xml.DocumentElement.RemoveChild($ec)
            $kept.Add($name)
        } else {
            Write-Log WARN "Device $name exists with a different definition; the import cannot replace it (-6401)."
        }
    }
    if ($kept.Count) { Write-Log INFO "Already in the gateway, unchanged (not re-imported): $($kept -join ', ')" }
    return @{ Start = $start.ToArray(); Kept = $kept.ToArray() }
}

function Invoke-DwImport {
    <#
        Imports an export document through the import folder: saves it, stops dwcore (dwts keeps
        running), optionally copies the gateway databases to $SafetyDir first, queues import.dwx,
        starts dwcore and waits for import.result. A copy of the result goes to $SafetyDir as
        <Label>-import.result. $WhileStopped runs after the safety copy, before the import is queued
        (e.g. a DWUSER.db write that belongs to the same restart). Returns Read-DwImportResult's
        object; throws when no result arrives.
    #>
    param([Parameter(Mandatory)] [hashtable]$Paths, [Parameter(Mandatory)] [xml]$Xml, [Parameter(Mandatory)] [string]$Label,
          [string]$SafetyDir, [switch]$SaveDatabases, [int]$TimeoutSec = 900, [scriptblock]$WhileStopped)
    if (-not (Test-Path $Paths.ImportDir)) { New-Item -ItemType Directory -Path $Paths.ImportDir -Force | Out-Null }
    $target = Join-Path $Paths.ImportDir 'import.dwx'
    $result = Join-Path $Paths.ImportDir 'import.result'
    if (Test-Path $target) { throw "An import.dwx is already waiting in $($Paths.ImportDir)." }
    foreach ($old in $result, "${result}s") { if (Test-Path $old) { Remove-Item $old -Force } }
    $staged = Join-Path $env:TEMP ("dw-{0}-{1}.dwx" -f $Label, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    # Restart-DwCore has a parameter named $WhileStopped too; inside its block that name would resolve to
    # Restart-DwCore's own block and call itself endlessly (Step 8, 2026-10-14). Keep ours under its own name.
    $dwImportExtraAction = $WhileStopped
    # Existing devices with the same definition are left out: the gateway does not replace an existing
    # CNC device (-6401, even when stopped; SJUM7AAPPS0048 2026-10-14). They are only (re)started.
    $unchanged = Remove-DwUnchangedDevices -Paths $Paths -Xml $Xml
    $dwImportStartDevices = @($unchanged.Start)
    if (-not $Xml.DocumentElement.SelectNodes('exportcontent').Count) {
        Write-Log INFO 'Nothing left to import (all items unchanged).'
        if ($dwImportStartDevices.Count) { Restart-DwCore -Paths $Paths -WhileStopped { Set-DwDeviceState -Paths $Paths -Names $dwImportStartDevices -State 1 } }
        return [pscustomobject]@{ Items = @(); Overall = 0; Lines = @(); Unchanged = @($unchanged.Kept) }
    }
    Save-DwXml -Xml $Xml -Path $staged
    try {
        Restart-DwCore -Paths $Paths -WhileStopped {
            if ($SaveDatabases -and $SafetyDir) {
                Save-DwDatabases -Paths $Paths -Dest $SafetyDir
                Write-Log INFO "Safety copy of the gateway databases: $SafetyDir"
            }
            if ($dwImportExtraAction) { & $dwImportExtraAction }
            # Devices the import cannot replace were taken out before the restart (Remove-DwUnchangedDevices);
            # make sure those are Started as the import wanted them
            if ($dwImportStartDevices.Count) {
                $st = @{}
                try { $st = Get-DwDeviceStates -Paths $Paths } catch { }
                $start = @($dwImportStartDevices | Where-Object { $st.ContainsKey($_) -and $st[$_] -ne 1 })
                if ($start.Count) {
                    try { Set-DwDeviceState -Paths $Paths -Names $start -State 1; Write-Log INFO "Started (unchanged devices): $($start -join ', ')" }
                    catch { Write-Log WARN "Could not start $($start -join ', '): $($_.Exception.Message)" }
                }
            }
            Copy-Item $staged $target
        }
        $done = Wait-DwImportFile -Queued $target -ResultFiles @($result, "${result}s") -TimeoutSec $TimeoutSec
    } finally { Remove-Item $staged -ErrorAction SilentlyContinue }
    if (-not $done) { throw "The gateway did not process the import ($Label) within $TimeoutSec s." }
    if ($SafetyDir) {
        New-Item -ItemType Directory -Path $SafetyDir -Force | Out-Null
        Copy-Item $done (Join-Path $SafetyDir "$Label-import.result") -Force
    }
    $res = Read-DwImportResult -Path $done
    $res | Add-Member -NotePropertyName Unchanged -NotePropertyValue @($unchanged.Kept)
    return $res
}

function Add-DwImportResults {
    <#
        One result line per imported item (status 0 = PASS) plus a summary line; returns the failed count.
        $Tolerate: @{ 'type/item' = 'reason' } - a non-zero status there is a WARN (the step makes up
        for it another way) and does not count as failed.
    #>
    param([Parameter(Mandatory)] [string]$Phase, [Parameter(Mandatory)] $Result, [Parameter(Mandatory)] [string]$Summary,
          [hashtable]$Tolerate = @{})
    if ($Result.PSObject.Properties['Unchanged']) {
        foreach ($n in @($Result.Unchanged)) { Add-Result -Phase $Phase -Check "Import device $n" -Status PASS -Detail 'already in the gateway, unchanged - kept and started' }
    }
    foreach ($i in $Result.Items) {
        $key = "$($i.Type)/$($i.Item)"
        if ($i.Status -eq 0)                  { Add-Result -Phase $Phase -Check "Import $($i.Type) $($i.Item)" -Status PASS -Detail 'status 0' }
        elseif ($Tolerate.ContainsKey($key))  { Add-Result -Phase $Phase -Check "Import $($i.Type) $($i.Item)" -Status WARN -Detail "status $($i.Status) - $($Tolerate[$key])" }
        else                                  { Add-Result -Phase $Phase -Check "Import $($i.Type) $($i.Item)" -Status FAIL -Detail "status $($i.Status)" }
    }
    $bad = @($Result.Items | Where-Object { $_.Status -ne 0 -and -not $Tolerate.ContainsKey("$($_.Type)/$($_.Item)") })
    Add-Result -Phase $Phase -Check $Summary -Status $(if ($bad.Count) { 'FAIL' } else { 'PASS' }) `
        -Detail ("{0} item(s), {1} failed, overall status {2}" -f $Result.Items.Count, $bad.Count, $Result.Overall)
    return $bad.Count
}

function Get-DwPackagePlan {
    <#
        Reads the approved package payload (Manifest.DeviceWise.PackagesRepoSubPath, made by
        tools\Export-DwPackagePayload.ps1 from a gateway installed through Workbench):
          <dir>\<key>\<key>.xml   the package's own install instructions (DWPackage/Install)
          <dir>\<key>\<from>      each file the instructions add
          <dir>\SHA256SUMS.txt    checksums of all of them
        The .pkg files themselves are encrypted; the gateway rejects them as package.sup (-7018).
        Returns one entry per key: @{ Key; Name; Version; Xml; Copies = @(@{ Src; Dest }); Installed }.
        Throws on a missing file, a checksum mismatch or an install action the wizard does not know.
    #>
    param([Parameter(Mandatory)] [hashtable]$Paths, [Parameter(Mandatory)] [string]$PayloadDir, [Parameter(Mandatory)] [string[]]$Keys)
    $sumFile = Join-Path $PayloadDir 'SHA256SUMS.txt'
    if (-not (Test-Path $sumFile)) { throw "SHA256SUMS.txt not found in $PayloadDir" }
    $sums = @{}
    foreach ($line in Get-Content $sumFile) { if ($line -match '^([0-9A-Fa-f]{64})\s+(.+)$') { $sums[$Matches[2].Trim()] = $Matches[1].ToUpper() } }
    $check = {
        param([string]$rel)
        $file = Join-Path $PayloadDir ($rel -replace '/', '\')
        if (-not (Test-Path $file)) { throw "Package payload file missing: $file" }
        if (-not $sums.ContainsKey($rel)) { throw "No checksum for $rel in SHA256SUMS.txt" }
        if ((Get-FileHash $file -Algorithm SHA256).Hash -ne $sums[$rel]) { throw "Checksum mismatch: $file" }
        return $file
    }
    $plan = foreach ($key in $Keys) {
        $xmlFile = & $check "$key/$key.xml"
        [xml]$pkg = Get-Content $xmlFile -Raw
        $copies = @()
        foreach ($a in @($pkg.DocumentElement.SelectNodes('Install/*'))) {
            switch ($a.LocalName) {
                { $_ -in 'StopRuntime', 'StartRuntime' } { continue }   # dwcore is stopped/started around all packages
                'AddFile'        { $copies += @{ Src = (& $check "$key/$($a.GetAttribute('from'))"); Dest = Join-Path $Paths.Root ('dwcore\'  + ($a.GetAttribute('to') -replace '/', '\')) } }
                'AddStagingFile' { $copies += @{ Src = (& $check "$key/$($a.GetAttribute('from'))"); Dest = Join-Path $Paths.Root ('staging\' + ($a.GetAttribute('to') -replace '/', '\')) } }
                default          { throw "Package $key uses install action <$($a.LocalName)>, which the wizard does not support." }
            }
        }
        @{ Key = $key; Name = $pkg.DocumentElement.GetAttribute('name'); Version = $pkg.DocumentElement.GetAttribute('version'); Xml = $xmlFile; Copies = $copies
           Installed = Test-Path (Join-Path $Paths.Packages "$key.xml") }
    }
    return ,@($plan)
}

function Install-DwPackages {
    # Installs the plan's packages that are not installed yet, in one dwcore stop: the files from
    # their install instructions, then <key>.xml into dwcore\packages (how the gateway records an
    # installed package). $BeforeCopy runs first while dwcore is stopped. Returns the keys installed.
    param([Parameter(Mandatory)] [hashtable]$Paths, [Parameter(Mandatory)] [object[]]$Plan, [scriptblock]$BeforeCopy)
    $todo = @($Plan | Where-Object { -not $_.Installed })
    if (-not $todo.Count) { return @() }
    Restart-DwCore -Paths $Paths -WhileStopped {
        if ($BeforeCopy) { & $BeforeCopy }
        foreach ($p in $todo) {
            foreach ($c in $p.Copies) {
                New-Item -ItemType Directory -Path (Split-Path $c.Dest) -Force | Out-Null
                Copy-Item $c.Src $c.Dest -Force
                Write-Log INFO "  $($p.Key): $(Split-Path $c.Src -Leaf) -> $($c.Dest)"
            }
            Copy-Item $p.Xml (Join-Path $Paths.Packages "$($p.Key).xml") -Force
        }
    }
    return @($todo | ForEach-Object { $_.Key })
}

#endregion

#region -- OPC UA client (the gateway's own OPC UA server) ---------------------

function Open-DwUaSession {
    <#
        Opens an anonymous OPC UA session (security mode None) to the gateway's OPC UA server, using
        the OPC Foundation .NET stack that 800xA installs (1.4.370 on SJUM7AAPPS0048). The DLLs it needs
        are copied to C:\APC_Config\OpcUaStack and loaded from there, so 800xA's files are never held
        open. The client certificate store is C:\APC_Config\pki (not ABB's).
        Returns the session; close it with $session.Close().
    #>
    param([Parameter(Mandatory)] [object]$Manifest)
    $ua = $Manifest.DeviceWise.OpcUaClient
    if (-not (Test-Path (Join-Path $ua.StackDir 'Opc.Ua.Client.dll'))) { throw "OPC UA client library not found in $($ua.StackDir)" }
    $Global:DwUaStackSource = $ua.StackDir
    $Global:DwUaStackCopy   = 'C:\APC_Config\OpcUaStack'
    if (-not ('Opc.Ua.Client.Session' -as [type])) {
        # start from an empty copy each run, so it always matches 800xA's current stack version
        if (Test-Path $Global:DwUaStackCopy) { Remove-Item (Join-Path $Global:DwUaStackCopy '*') -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $Global:DwUaStackCopy -Force | Out-Null
        # dependencies (e.g. Newtonsoft.Json) are copied and loaded on demand the same way
        [AppDomain]::CurrentDomain.add_AssemblyResolve([ResolveEventHandler]{
            param($sender, $e)
            $name = (New-Object Reflection.AssemblyName($e.Name)).Name
            $src  = Join-Path $Global:DwUaStackSource "$name.dll"
            if (-not (Test-Path $src)) { return $null }
            $dst = Join-Path $Global:DwUaStackCopy "$name.dll"
            if (-not (Test-Path $dst)) { Copy-Item $src $dst -Force }
            return [Reflection.Assembly]::LoadFrom($dst)
        })
        foreach ($dll in 'Opc.Ua.Core.dll', 'Opc.Ua.Client.dll') {
            $dst = Join-Path $Global:DwUaStackCopy $dll
            Copy-Item (Join-Path $ua.StackDir $dll) $dst -Force
            [void][Reflection.Assembly]::LoadFrom($dst)
        }
    }
    $wait = { param($r) if ($r -is [Threading.Tasks.Task]) { $r.GetAwaiter().GetResult() } else { $r } }

    $pki = 'C:\APC_Config\pki'
    $cfg = New-Object Opc.Ua.ApplicationConfiguration
    $cfg.ApplicationName = 'APC Config Wizard'
    $cfg.ApplicationUri  = "urn:$($env:COMPUTERNAME):APCConfigWizard"
    $cfg.ApplicationType = [Opc.Ua.ApplicationType]::Client
    $sec = New-Object Opc.Ua.SecurityConfiguration
    $sec.ApplicationCertificate = New-Object Opc.Ua.CertificateIdentifier
    $sec.ApplicationCertificate.StoreType = 'Directory'; $sec.ApplicationCertificate.StorePath = "$pki\own"
    $sec.ApplicationCertificate.SubjectName = 'CN=APC Config Wizard'
    foreach ($store in @{ TrustedPeerCertificates = 'trusted'; TrustedIssuerCertificates = 'issuer'; RejectedCertificateStore = 'rejected' }.GetEnumerator()) {
        $s = New-Object Opc.Ua.CertificateTrustList
        $s.StoreType = 'Directory'; $s.StorePath = Join-Path $pki $store.Value
        $sec.($store.Key) = $s
    }
    $sec.AutoAcceptUntrustedCertificates = $true
    $cfg.SecurityConfiguration = $sec
    $cfg.TransportQuotas = New-Object Opc.Ua.TransportQuotas
    $cfg.TransportQuotas.OperationTimeout = 15000
    $cfg.ClientConfiguration = New-Object Opc.Ua.ClientConfiguration
    $cfg.ClientConfiguration.DefaultSessionTimeout = 60000
    [void](& $wait ($cfg.Validate([Opc.Ua.ApplicationType]::Client)))
    $cfg.CertificateValidator.add_CertificateValidation([Opc.Ua.CertificateValidationEventHandler]{ param($s, $e) $e.Accept = $true })

    $epDesc = [Opc.Ua.Client.CoreClientUtils]::SelectEndpoint($ua.Endpoint, $false, 15000)
    $cep    = New-Object Opc.Ua.ConfiguredEndpoint($null, $epDesc, ([Opc.Ua.EndpointConfiguration]::Create($cfg)))
    return (& $wait ([Opc.Ua.Client.Session]::Create($cfg, $cep, $false, 'APC Config Wizard', 60000, (New-Object Opc.Ua.UserIdentity), $null)))
}

function Get-DwUaNodeId {
    # 'CNC1.CNCAsset' -> NodeId in the deviceWise namespace (looked up by URI, not assumed to be 2)
    param([Parameter(Mandatory)] $Session, [Parameter(Mandatory)] [string]$Namespace, [Parameter(Mandatory)] [string]$Path)
    $ns = $Session.NamespaceUris.GetIndex($Namespace)
    if ($ns -lt 0) { throw "Namespace $Namespace not on the OPC UA server." }
    return New-Object Opc.Ua.NodeId($Path, [uint16]$ns)
}

function Set-DwUaValues {
    # Writes string values ('CNC1.CNCAsset' = 'Citizen 01', ...) and returns @{ path = StatusCode text }
    param([Parameter(Mandatory)] $Session, [Parameter(Mandatory)] [string]$Namespace,
          [Parameter(Mandatory)] [System.Collections.IDictionary]$Values)
    $wvc  = New-Object Opc.Ua.WriteValueCollection
    $keys = @($Values.Keys)
    foreach ($k in $keys) {
        $w = New-Object Opc.Ua.WriteValue
        $w.NodeId      = Get-DwUaNodeId -Session $Session -Namespace $Namespace -Path $k
        $w.AttributeId = [Opc.Ua.Attributes]::Value
        $w.Value       = New-Object Opc.Ua.DataValue(New-Object Opc.Ua.Variant([string]$Values[$k]))
        $wvc.Add($w)
    }
    $results = $null; $diag = $null
    [void]$Session.Write($null, $wvc, [ref]$results, [ref]$diag)
    $out = [ordered]@{}
    for ($i = 0; $i -lt $keys.Count; $i++) { $out[$keys[$i]] = [string]$results[$i] }
    return $out
}

function Get-DwUaValue {
    param([Parameter(Mandatory)] $Session, [Parameter(Mandatory)] [string]$Namespace, [Parameter(Mandatory)] [string]$Path)
    return $Session.ReadValue((Get-DwUaNodeId -Session $Session -Namespace $Namespace -Path $Path))
}

function Set-DwCncAssetValues {
    <#
        Writes CNCn.CNCAsset (Site DB machine name) and CNCn.CNCType through the gateway's OPC UA server
        and reads them back; one result line per CNC. The CNC devices do not persist values, so every
        dwcore restart empties them: each step that restarts dwcore calls this at its end.
        KNOWN LIMITATION (user, 2026-10-13): empty again after any later dwcore restart.
        Waits up to $WaitSec for the OPC UA port first. On any OPC UA problem the lines are MANUAL.
    #>
    param([Parameter(Mandatory)] [object]$Manifest, [Parameter(Mandatory)] [object[]]$Cncs,
          [Parameter(Mandatory)] [string]$Phase, [int]$WaitSec = 120)
    $ua = $Manifest.DeviceWise.OpcUaClient
    $port = [int]$Manifest.DeviceWise.OpcUaEndpointPort
    $wanted = [ordered]@{}
    foreach ($c in $Cncs) {
        $wanted["CNC$($c.CNCIndex).CNCAsset"] = [string]$c.MachineName
        $wanted["CNC$($c.CNCIndex).CNCType"]  = [string]$c.CNCType
    }
    $session = $null
    try {
        $deadline = (Get-Date).AddSeconds($WaitSec)
        while (-not (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)) {
            if ((Get-Date) -gt $deadline) { throw "the OPC UA server is not listening on port $port" }
            Start-Sleep -Seconds 5
        }
        $session = Open-DwUaSession -Manifest $Manifest
        # Right after a dwcore start the server can listen before the devices answer (BadCommunicationError on
        # SJUM7AAPPS0048 2026-10-14): retry the write for up to a minute until every value is Good
        $retryUntil = (Get-Date).AddSeconds(60)
        do {
            $written = Set-DwUaValues -Session $session -Namespace $ua.Namespace -Values $wanted
            $notGood = @($written.Keys | Where-Object { $written[$_] -notmatch '^Good' })
            if ($notGood.Count -and (Get-Date) -lt $retryUntil) { Start-Sleep -Seconds 5 }
        } while ($notGood.Count -and (Get-Date) -lt $retryUntil)
        foreach ($c in $Cncs) {
            $node = "CNC$($c.CNCIndex)"
            $got  = @("$node.CNCAsset", "$node.CNCType" | ForEach-Object { [string](Get-DwUaValue -Session $session -Namespace $ua.Namespace -Path $_).Value })
            $ok   = ($got[0] -eq $wanted["$node.CNCAsset"]) -and ($got[1] -eq $wanted["$node.CNCType"])
            Add-Result -Phase $Phase -Check "$node CNCAsset / CNCType" -Status $(if ($ok) { 'PASS' } else { 'FAIL' }) `
                -Detail ("read back '{0}' / '{1}' (write: {2} / {3}); lost on the next dwcore restart (known limitation)" -f `
                         $got[0], $got[1], $written["$node.CNCAsset"], $written["$node.CNCType"])
        }
    } catch {
        foreach ($c in $Cncs) {
            Add-Result -Phase $Phase -Check "CNC$($c.CNCIndex) CNCAsset / CNCType" -Status MANUAL `
                -Detail "OPC UA write not possible ($($_.Exception.Message)). Workbench > Devices > CNC$($c.CNCIndex) > Variables: CNCAsset = $($c.MachineName), CNCType = $($c.CNCType)"
        }
    } finally {
        if ($session) { [void]$session.Close() }
    }
}

#endregion

#region -- DWUSER.db through the gateway's sqlite3.dll -------------------------

function Initialize-DwSqlite {
    param([Parameter(Mandatory)] [hashtable]$Paths)
    if (-not [Environment]::Is64BitProcess) { throw 'The gateway sqlite3.dll is 64-bit; run the wizard in 64-bit PowerShell.' }
    if (-not ('DwSqlite' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class DwSqlite {
    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr LoadLibrary(string path);

    const string L = "sqlite3.dll";
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_open_v2(byte[] file, out IntPtr db, int flags, IntPtr vfs);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_close_v2(IntPtr db);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_busy_timeout(IntPtr db, int ms);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int n, out IntPtr stmt, IntPtr tail);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_bind_text(IntPtr stmt, int i, byte[] v, int n, IntPtr destructor);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_step(IntPtr stmt);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_column_count(IntPtr stmt);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr sqlite3_column_text(IntPtr stmt, int i);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_finalize(IntPtr stmt);
    [DllImport(L, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr sqlite3_errmsg(IntPtr db);

    const int ROW = 100, DONE = 101;
    static readonly IntPtr TRANSIENT = new IntPtr(-1);

    static byte[] Z(string s) { return Encoding.UTF8.GetBytes(s + "\0"); }
    static string S(IntPtr p) {
        if (p == IntPtr.Zero) return null;
        int n = 0; while (Marshal.ReadByte(p, n) != 0) n++;
        byte[] b = new byte[n]; Marshal.Copy(p, b, 0, n); return Encoding.UTF8.GetString(b);
    }
    static string Err(IntPtr db) { return S(sqlite3_errmsg(db)); }

    // flags: 1 = read only, 2 = read/write (never create)
    public static IntPtr Open(string path, bool write) {
        IntPtr db;
        int rc = sqlite3_open_v2(Z(path), out db, write ? 2 : 1, IntPtr.Zero);
        if (rc != 0) { string e = Err(db); sqlite3_close_v2(db); throw new Exception("sqlite open " + rc + ": " + e); }
        sqlite3_busy_timeout(db, 10000);
        return db;
    }
    public static void Close(IntPtr db) { sqlite3_close_v2(db); }

    public static List<string[]> Query(IntPtr db, string sql, params string[] args) {
        IntPtr st;
        if (sqlite3_prepare_v2(db, Z(sql), -1, out st, IntPtr.Zero) != 0) throw new Exception("sqlite prepare: " + Err(db));
        var rows = new List<string[]>();
        try {
            for (int i = 0; i < args.Length; i++) sqlite3_bind_text(st, i + 1, Z(args[i]), -1, TRANSIENT);
            int rc;
            while ((rc = sqlite3_step(st)) == ROW) {
                int n = sqlite3_column_count(st); var r = new string[n];
                for (int c = 0; c < n; c++) r[c] = S(sqlite3_column_text(st, c));
                rows.Add(r);
            }
            if (rc != DONE) throw new Exception("sqlite step " + rc + ": " + Err(db));
        } finally { sqlite3_finalize(st); }
        return rows;
    }
}
'@
    }
    if ([DwSqlite]::LoadLibrary($Paths.Sqlite) -eq [IntPtr]::Zero) { throw "Cannot load $($Paths.Sqlite)" }
}

function Set-DwPersistence {
    <#
        Writes DWUSER.db persistence rows of one group (dwcore must be stopped). The gateway stores
        each value with a leading marker byte (0x01 on 23.04.08); the marker is copied from a row
        already in the group, or from the 'system' group, so new rows look like the gateway's own.
    #>
    param([Parameter(Mandatory)] [hashtable]$Paths, [Parameter(Mandatory)] [string]$Group,
          [Parameter(Mandatory)] [System.Collections.IDictionary]$Values)
    if ((Get-Service 'dwcore').Status -ne 'Stopped') { throw 'dwcore must be stopped before writing DWUSER.db.' }
    Initialize-DwSqlite -Paths $Paths
    $h = [DwSqlite]::Open((Join-Path $Paths.Db 'DWUSER.db'), $true)
    try {
        $sample = [DwSqlite]::Query($h, "SELECT value FROM persistence WHERE grp = ? OR grp = 'system' ORDER BY (grp = ?) DESC LIMIT 1", $Group, $Group)
        $marker = ''
        if ($sample.Count -and $sample[0][0] -and [int][char]$sample[0][0][0] -lt 32) { $marker = [string]$sample[0][0][0] }
        foreach ($k in $Values.Keys) {
            [void][DwSqlite]::Query($h, 'INSERT OR REPLACE INTO persistence (name, grp, value) VALUES (?, ?, ?)', [string]$k, $Group, $marker + [string]$Values[$k])
        }
    } finally { [DwSqlite]::Close($h) }
}

function Get-DwTriggerStates {
    <#
        Reads the trigger table of DWCORE.db (read-only; dwcore may be running): name, project, state.
        state = 1 for triggers Workbench shows as Started (fresh VM, 2026-10-13). Returns @{ name = state }.
    #>
    param([Parameter(Mandatory)] [hashtable]$Paths, [Parameter(Mandatory)] [string]$Project)
    Initialize-DwSqlite -Paths $Paths
    $h = [DwSqlite]::Open((Join-Path $Paths.Db 'DWCORE.db'), $false)
    try {
        $out = @{}
        foreach ($r in [DwSqlite]::Query($h, 'SELECT name, state FROM triggers WHERE project = ?', $Project)) { $out[$r[0]] = [int]$r[1] }
        return $out
    } finally { [DwSqlite]::Close($h) }
}

function Get-DwDeviceStates {
    <#
        Reads the device table of DWCORE.db (read-only; dwcore may be running): @{ name = state }.
        state 1 = Started, 2 = Stopped in Workbench > Devices (fresh VM, 2026-10-14).
    #>
    param([Parameter(Mandatory)] [hashtable]$Paths)
    Initialize-DwSqlite -Paths $Paths
    $h = [DwSqlite]::Open((Join-Path $Paths.Db 'DWCORE.db'), $false)
    try {
        $out = @{}
        foreach ($r in [DwSqlite]::Query($h, 'SELECT name, state FROM devices')) { $out[$r[0]] = [int]$r[1] }
        return $out
    } finally { [DwSqlite]::Close($h) }
}

function Set-DwDeviceState {
    # Sets devices.state in DWCORE.db (1 = Started, 2 = Stopped); the gateway applies it at its next start.
    # dwcore must be stopped.
    param([Parameter(Mandatory)] [hashtable]$Paths, [Parameter(Mandatory)] [string[]]$Names, [Parameter(Mandatory)] [ValidateSet(1, 2)] [int]$State)
    if ((Get-Service 'dwcore').Status -ne 'Stopped') { throw 'dwcore must be stopped before writing DWCORE.db.' }
    Initialize-DwSqlite -Paths $Paths
    $h = [DwSqlite]::Open((Join-Path $Paths.Db 'DWCORE.db'), $true)
    try { foreach ($n in $Names) { [void][DwSqlite]::Query($h, 'UPDATE devices SET state = ? WHERE name = ?', [string]$State, $n) } }
    finally { [DwSqlite]::Close($h) }
}

function Set-DwDeviceStarted {
    param([Parameter(Mandatory)] [hashtable]$Paths, [Parameter(Mandatory)] [string[]]$Names)
    Set-DwDeviceState -Paths $Paths -Names $Names -State 1
}

function Test-DwDevicesStarted {
    # One result line per device that must be Started (devices.state 1), waiting up to $WaitSec
    param([Parameter(Mandatory)] [hashtable]$Paths, [Parameter(Mandatory)] [string[]]$Names, [Parameter(Mandatory)] [string]$Phase, [int]$WaitSec = 60)
    try {
        $deadline = (Get-Date).AddSeconds($WaitSec)
        do {
            $s = Get-DwDeviceStates -Paths $Paths
            $notYet = @($Names | Where-Object { $s.ContainsKey($_) -and $s[$_] -ne 1 })
            if ($notYet.Count) { Start-Sleep -Seconds 5 }
        } while ($notYet.Count -and (Get-Date) -lt $deadline)
        foreach ($n in $Names) {
            $v = if ($s.ContainsKey($n)) { $s[$n] } else { -1 }
            Add-Result -Phase $Phase -Check "$n started" -Status $(if ($v -eq 1) { 'PASS' } else { 'FAIL' }) `
                -Detail $(switch ($v) { 1 { 'Started' } 2 { 'Stopped - start it in Workbench > Devices' } -1 { 'not in the gateway' } default { "state $v" } })
        }
    } catch {
        foreach ($n in $Names) { Add-Result -Phase $Phase -Check "$n started" -Status MANUAL -Detail "could not read DWCORE.db ($($_.Exception.Message)). Workbench > Devices: $n Started" }
    }
}

function Invoke-DwDbQuery {
    # Read-only query on one gateway database (DWCORE.db, DWAPP.db, DWUSER.db, DWTS.db); rows as string[]
    param([Parameter(Mandatory)] [hashtable]$Paths, [Parameter(Mandatory)] [string]$Db, [Parameter(Mandatory)] [string]$Sql, [string[]]$Arguments = @())
    Initialize-DwSqlite -Paths $Paths
    $h = [DwSqlite]::Open((Join-Path $Paths.Db $Db), $false)
    try { return ,@([DwSqlite]::Query($h, $Sql, $Arguments)) } finally { [DwSqlite]::Close($h) }
}

function Get-DwXml {
    # The xml column of one row in DWCORE.db triggers / devices, as [xml]; $null when not found
    param([Parameter(Mandatory)] [hashtable]$Paths, [Parameter(Mandatory)] [ValidateSet('triggers', 'devices')] [string]$Table,
          [Parameter(Mandatory)] [string]$Name, [string]$Project)
    $sql  = "SELECT xml FROM $Table WHERE name = ?" + $(if ($Project) { ' AND project = ?' } else { '' })
    $qArgs = @($Name) + @(if ($Project) { $Project })
    $rows  = Invoke-DwDbQuery -Paths $Paths -Db 'DWCORE.db' -Sql $sql -Arguments $qArgs
    if (-not $rows.Count -or -not $rows[0][0]) { return $null }
    return [xml]$rows[0][0]
}

function Get-DwLocalTable {
    <#
        Rows of a deviceWise local table (e.g. CNC_SETTING) as objects. The table is looked for in every
        gateway database (localdb.path points at DWAPP.db, not confirmed on a VM). $null when not found.
    #>
    param([Parameter(Mandatory)] [hashtable]$Paths, [Parameter(Mandatory)] [string]$Table)
    foreach ($db in 'DWAPP.db', 'DWCORE.db', 'DWTS.db', 'DWUSER.db') {
        if (-not (Test-Path (Join-Path $Paths.Db $db))) { continue }
        $found = Invoke-DwDbQuery -Paths $Paths -Db $db -Sql "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?" -Arguments @($Table)
        if (-not $found.Count) { continue }
        $cols = @((Invoke-DwDbQuery -Paths $Paths -Db $db -Sql 'SELECT name FROM pragma_table_info(?)' -Arguments @($Table)) | ForEach-Object { $_[0] })
        $rows = Invoke-DwDbQuery -Paths $Paths -Db $db -Sql ('SELECT * FROM "{0}"' -f $Table.Replace('"', '""'))
        $out = foreach ($r in $rows) { $o = [ordered]@{}; for ($i = 0; $i -lt $cols.Count; $i++) { $o[$cols[$i]] = $r[$i] }; [pscustomobject]$o }
        return [pscustomobject]@{ Db = $db; Rows = @($out) }
    }
    return $null
}

function Test-DwCncnetpdmConnected {
    <#
        Workbench's 'Connected' for the CNCnetPDM instance = dwcore holds a TCP connection to CNCnetPDM's MTC
        Adapter port ([MTC Adapter] Port in CNCnetPDM.ini, 7889 on the APC VMs; CNCnetPDM default 7878).
        Returns @{ Connected = [bool]; Port = [int] }, waiting up to $WaitSec.
    #>
    param([string]$IniPath, [int]$WaitSec = 0)
    $port = 7878
    if ($IniPath -and (Test-Path $IniPath)) {
        $inMtc = $false
        foreach ($line in Get-Content $IniPath) {
            if ($line -match '^\s*\[(.+)\]') { $inMtc = ($Matches[1] -eq 'MTC Adapter'); continue }
            if ($inMtc -and $line -match '^\s*Port\s*=\s*(\d+)') { $port = [int]$Matches[1]; break }
        }
    }
    $dwPid = (Get-CimInstance Win32_Service -Filter "Name='dwcore'" -ErrorAction SilentlyContinue).ProcessId
    $deadline = (Get-Date).AddSeconds($WaitSec); $conn = $null
    do {
        $conn = Get-NetTCPConnection -RemotePort $port -State Established -ErrorAction SilentlyContinue |
                Where-Object { $_.OwningProcess -eq $dwPid } | Select-Object -First 1
        if (-not $conn -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
    } while (-not $conn -and (Get-Date) -lt $deadline)
    return @{ Connected = [bool]$conn; Port = $port }
}

function Get-DwPersistence {
    # Reads DWUSER.db persistence rows of one group (read-only; dwcore may be running).
    param([Parameter(Mandatory)] [hashtable]$Paths, [Parameter(Mandatory)] [string]$Group)
    Initialize-DwSqlite -Paths $Paths
    $h = [DwSqlite]::Open((Join-Path $Paths.Db 'DWUSER.db'), $false)
    try {
        $out = @{}
        foreach ($r in [DwSqlite]::Query($h, 'SELECT name, value FROM persistence WHERE grp = ?', $Group)) { $out[$r[0]] = $r[1] }
        return $out
    } finally { [DwSqlite]::Close($h) }
}

#endregion
