#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only listing of the classes and methods in deviceWISE's Java API jar.
.DESCRIPTION
    Reads dwjavaapi.jar (a zip of Java .class files) and writes a plain-text summary,
    so the jar itself does not have to leave the VM:
      dw-javaapi-classes.txt  - jar manifest, sibling jars, then every public class with
                                its public/protected constructors, methods and constants
      dw-javaapi-strings.txt  - string literals per class (command names, error messages)
    No Java tools are needed; the class files are parsed directly. Nothing is changed.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Export-DwJavaApi.ps1
#>
param(
    [string]$JarPath = 'C:\Program Files\deviceWISE\Workbench\wbench\jars\dwjavaapi.jar',
    [string]$OutDir  = 'C:\APC_Config\Logs'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

#region -- Big-endian readers over the current class file ----------------------

$script:B = $null; $script:P = 0
function U1 { $v = [int]($script:B[$script:P]); $script:P += 1; $v }
function U2 { $v = ([int]($script:B[$script:P]) -shl 8) -bor [int]($script:B[$script:P + 1]); $script:P += 2; $v }
function U4 {
    $v = ([long]($script:B[$script:P]) -shl 24) -bor ([long]($script:B[$script:P + 1]) -shl 16) -bor
         ([long]($script:B[$script:P + 2]) -shl 8) -bor [long]($script:B[$script:P + 3])
    $script:P += 4; $v
}
function BE([int]$n) {
    $a = New-Object byte[] $n
    [Array]::Copy($script:B, $script:P, $a, 0, $n); [Array]::Reverse($a)
    $script:P += $n
    , $a
}

#endregion

#region -- Descriptor formatting ------------------------------------------------

function Format-TypeName([string]$Name) {
    ($Name -replace '/', '.') -replace '^java\.(lang|util|io)\.', ''
}

function Read-Type([string]$D, [ref]$I) {
    $dims = 0
    while ($D[$I.Value] -eq '[') { $dims++; $I.Value++ }
    $c = [string]$D[$I.Value]; $I.Value++
    switch -CaseSensitive ($c) {
        'B' { $t = 'byte' }
        'C' { $t = 'char' }
        'D' { $t = 'double' }
        'F' { $t = 'float' }
        'I' { $t = 'int' }
        'J' { $t = 'long' }
        'S' { $t = 'short' }
        'Z' { $t = 'boolean' }
        'V' { $t = 'void' }
        'L' {
            $end = $D.IndexOf(';', $I.Value)
            $t = Format-TypeName $D.Substring($I.Value, $end - $I.Value)
            $I.Value = $end + 1
        }
        default { $t = "?$c" }
    }
    $t + ('[]' * $dims)
}

function Format-Method([string]$Name, [string]$Desc) {
    $i = 1; $params = @()
    while ($Desc[$i] -ne ')') { $params += Read-Type $Desc ([ref]$i) }
    $i++
    $ret = Read-Type $Desc ([ref]$i)
    @{ Params = ($params -join ', '); Return = $ret }
}

function Format-Access([int]$F, [switch]$Member) {
    $s = @()
    if ($F -band 0x0001) { $s += 'public' } elseif ($F -band 0x0004) { $s += 'protected' }
    if ($F -band 0x0008) { $s += 'static' }
    if ($F -band 0x0400 -and -not ($F -band 0x0200)) { $s += 'abstract' }
    if ($F -band 0x0010) { $s += 'final' }
    $s -join ' '
}

#endregion

#region -- Class file parser ----------------------------------------------------

function Read-ClassFile([byte[]]$Bytes) {
    $script:B = $Bytes; $script:P = 0
    if ((U4) -ne 0xCAFEBABEL) { return $null }
    U2 | Out-Null; U2 | Out-Null              # minor, major version

    $n   = U2
    $tag = New-Object int[] $n
    $val = New-Object object[] $n
    for ($i = 1; $i -lt $n; $i++) {
        $t = U1; $tag[$i] = $t
        switch ($t) {
            1  { $len = U2; $val[$i] = [Text.Encoding]::UTF8.GetString($script:B, $script:P, $len); $script:P += $len }
            3  { $val[$i] = [BitConverter]::ToInt32((BE 4), 0) }
            4  { $val[$i] = [BitConverter]::ToSingle((BE 4), 0) }
            5  { $val[$i] = [BitConverter]::ToInt64((BE 8), 0); $i++ }
            6  { $val[$i] = [BitConverter]::ToDouble((BE 8), 0); $i++ }
            { $_ -in 7, 8, 16, 19, 20 }        { $val[$i] = U2 }
            { $_ -in 9, 10, 11, 12, 17, 18 }   { $script:P += 4 }
            15 { $script:P += 3 }
            default { throw "Unknown constant pool tag $t at offset $($script:P)" }
        }
    }

    $access   = U2
    $thisIdx  = U2
    $cls = @{
        Access     = $access
        Name       = (Format-TypeName $val[$val[$thisIdx]])
        Super      = $null
        Interfaces = @()
        Fields     = @()
        Methods    = @()
        Strings    = @()
    }
    $superIdx = U2
    if ($superIdx) { $cls.Super = Format-TypeName $val[$val[$superIdx]] }
    $ic = U2
    for ($i = 0; $i -lt $ic; $i++) { $cls.Interfaces += Format-TypeName $val[$val[(U2)]] }

    $fc = U2
    for ($i = 0; $i -lt $fc; $i++) {
        $acc = U2; $name = $val[(U2)]; $desc = $val[(U2)]; $const = $null
        $ac = U2
        for ($a = 0; $a -lt $ac; $a++) {
            $an = $val[(U2)]; $len = U4
            if ($an -eq 'ConstantValue') {
                $ci = U2
                $const = if ($tag[$ci] -eq 8) { '"' + $val[$val[$ci]] + '"' } else { $val[$ci] }
            } else { $script:P += $len }
        }
        if ($acc -band 0x0005) {
            $j = 0
            $cls.Fields += [pscustomobject]@{ Access = $acc; Name = $name; Type = (Read-Type $desc ([ref]$j)); Const = $const }
        }
    }

    $mc = U2
    for ($i = 0; $i -lt $mc; $i++) {
        $acc = U2; $name = $val[(U2)]; $desc = $val[(U2)]
        $ac = U2
        for ($a = 0; $a -lt $ac; $a++) { U2 | Out-Null; $len = U4; $script:P += $len }
        if (($acc -band 0x0005) -and -not ($acc -band 0x1040) -and $name -ne '<clinit>') {   # skip synthetic/bridge
            $cls.Methods += [pscustomobject]@{ Access = $acc; Name = $name; Sig = (Format-Method $name $desc) }
        }
    }

    for ($i = 1; $i -lt $n; $i++) { if ($tag[$i] -eq 8) { $cls.Strings += $val[$val[$i]] } }
    $cls
}

#endregion

#region -- Main -----------------------------------------------------------------

if (-not (Test-Path $JarPath)) { throw "Jar not found: $JarPath" }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$outClasses = Join-Path $OutDir 'dw-javaapi-classes.txt'
$outStrings = Join-Path $OutDir 'dw-javaapi-strings.txt'

$lines   = New-Object System.Collections.Generic.List[string]
$strings = New-Object System.Collections.Generic.List[string]
$lines.Add("Java API listing - $JarPath - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")

$lines.Add("`r`n===== Jars in $(Split-Path $JarPath) =====")
Get-ChildItem (Split-Path $JarPath) -File | Sort-Object Name |
    ForEach-Object { $lines.Add(("{0,10:N0}  {1}" -f $_.Length, $_.Name)) }

$zip = [IO.Compression.ZipFile]::OpenRead($JarPath)
try {
    $mf = $zip.Entries | Where-Object { $_.FullName -eq 'META-INF/MANIFEST.MF' }
    if ($mf) {
        $r = New-Object IO.StreamReader($mf.Open())
        $lines.Add("`r`n===== MANIFEST.MF =====")
        $lines.Add($r.ReadToEnd().Trim()); $r.Close()
    }

    $classes = @(); $failed = @()
    foreach ($e in @($zip.Entries | Where-Object { $_.FullName -like '*.class' })) {
        $ms = New-Object IO.MemoryStream
        $s = $e.Open(); $s.CopyTo($ms); $s.Close()
        try   { $c = Read-ClassFile $ms.ToArray(); if ($c) { $classes += $c } }
        catch { $failed += "$($e.FullName): $_" }
    }
} finally { $zip.Dispose() }

$lines.Add("`r`n===== Classes ($($classes.Count) parsed, $($failed.Count) failed) =====")
foreach ($c in $classes | Sort-Object { $_.Name }) {
    if ($c.Strings.Count) {
        $uniq = $c.Strings | Where-Object { $_.Length -ge 2 } | Select-Object -Unique |
                ForEach-Object { if ($_.Length -gt 120) { $_.Substring(0, 120) + '...' } else { $_ } }
        if ($uniq) { $strings.Add("$($c.Name): " + ($uniq -join ' | ')) }
    }
    if (-not ($c.Access -band 0x0001) -or $c.Name -match '\$\d+$') { continue }   # non-public, anonymous

    $kind = 'class'
    if     ($c.Access -band 0x2000) { $kind = '@interface' }
    elseif ($c.Access -band 0x0200) { $kind = 'interface' }
    elseif ($c.Access -band 0x4000) { $kind = 'enum' }
    $head = "$(Format-Access $c.Access) $kind $($c.Name)"
    if ($c.Super -and $c.Super -notin 'Object', 'Enum') { $head += " extends $($c.Super)" }
    if ($c.Interfaces) { $head += " implements $($c.Interfaces -join ', ')" }
    $lines.Add(''); $lines.Add($head)

    $simple = ($c.Name -split '[.$]')[-1]
    foreach ($f in $c.Fields) {
        $l = "    $(Format-Access $f.Access -Member) $($f.Type) $($f.Name)"
        if ($null -ne $f.Const) { $l += " = $($f.Const)" }
        $lines.Add($l)
    }
    foreach ($m in $c.Methods) {
        if ($m.Name -eq '<init>') { $lines.Add("    $(Format-Access $m.Access -Member) $simple($($m.Sig.Params))") }
        else { $lines.Add("    $(Format-Access $m.Access -Member) $($m.Sig.Return) $($m.Name)($($m.Sig.Params))") }
    }
}

if ($failed) {
    $lines.Add("`r`n===== Parse failures =====")
    $failed | ForEach-Object { $lines.Add($_) }
}

$lines   | Set-Content -Path $outClasses -Encoding UTF8
$strings | Set-Content -Path $outStrings -Encoding UTF8
"Classes: $outClasses ($($lines.Count) lines)"
"Strings: $outStrings ($($strings.Count) lines)"

#endregion
