#Requires -Version 5.1
<#
.SYNOPSIS
    Operator e-mail when the draft D01555624 checklist is ready (the APC Installation Manager's Notify.ps1 pattern).
.DESCRIPTION
    Event ConfigComplete (Step 13): verification done, draft checklist created. Wording from the manifest
    Notifications.Templates.ConfigComplete (Subject, Intro, Stage, Status, Actions, Closing; built-in defaults for
    anything missing); the layout (greeting, Configuration Status, Action Required, Configuration Reference) is built
    here, as HTML with a plain-text copy. Template text may use <b>, <code> and {placeholders}: {VM} {Site} {Time}
    {Operator} {WindowsAccount} {RunFolder} {ConfigType} {Passed} {Warnings} {Failed} {ReportPath} {ChecklistPath}.
    Recipient: the signed-in operator - State.OperatorEmail / OperatorFirstName (AD, read at run start), AD search
    as fallback. Mail server: Notifications SmtpServer, Port, From, optional Cc, UseSsl. Not configured, no address
    or a send error: logged, never stops the run.
#>

. (Join-Path $PSScriptRoot 'Common.ps1')   # Get-OperatorAdInfo

if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    function Write-Log { param([string]$Level, [string]$Message) Write-Host "[$Level] $Message" }
}

$Script:ConfigNoticeDefaults = @{
    Subject = '[APC Configuration] Configuration Complete - Draft Checklist Ready | {VM}'
    Intro   = 'The APC Configuration Manager has completed the configuration and its verification. The draft D01555624 Configuration Verification Checklist is ready for your review.'
    Stage   = 'Verification and Report'
    Status  = 'Draft Checklist Ready for Review'
    Actions = @('Open the draft checklist: <code>{ChecklistPath}</code>.', 'Review the automated results and address any reported failures.')
    Closing = ''
}

function Get-ConfigNoticeText {
    # Subject, HTML body and plain-text body, placeholders filled. $Extra: Passed, Warnings, Failed, ReportPath, ChecklistPath
    param([hashtable]$State, [object]$Manifest, [hashtable]$Extra = @{})
    $cfg = if ($Manifest -and $Manifest.PSObject.Properties['Notifications']) { $Manifest.Notifications } else { $null }
    $operator = [string]$State['OperatorName']
    $values = [ordered]@{
        VM             = $env:COMPUTERNAME
        Site           = [string]$State['SiteCode']
        Time           = (Get-Date).ToString('MMMM d, yyyy | h:mm tt', [Globalization.CultureInfo]::GetCultureInfo('en-US'))
        Operator       = $(if ($State['OperatorFirstName']) { [string]$State['OperatorFirstName'] }
                           elseif ($operator -and ($gn = (Get-OperatorAdInfo $operator).GivenName)) { $gn }
                           elseif ($operator) { ($operator -split '\\')[-1] } else { 'operator' })
        WindowsAccount = "$env:USERDOMAIN\$env:USERNAME"
        RunFolder      = [string]$State['RunRoot']
        ConfigType     = $(if ($State['ConfigTypeName']) { [string]$State['ConfigTypeName'] } else { [string]$State['ConfigType'] })
    }
    foreach ($k in $Extra.Keys) { $values[$k] = [string]$Extra[$k] }
    $tpl = if ($cfg -and $cfg.PSObject.Properties['Templates'] -and $cfg.Templates.PSObject.Properties['ConfigComplete']) { $cfg.Templates.ConfigComplete } else { $null }
    $field = { param([string]$Name) if ($tpl -and $tpl.PSObject.Properties[$Name] -and $null -ne $tpl.$Name) { $tpl.$Name } else { $Script:ConfigNoticeDefaults[$Name] } }
    $fill = {
        param([string]$Text, [bool]$Html)
        foreach ($k in $values.Keys) { $v = [string]$values[$k]; if ($Html) { $v = [System.Net.WebUtility]::HtmlEncode($v) }; $Text = $Text.Replace("{$k}", $v) }
        $Text
    }
    $plainOf = { param([string]$Html) [System.Net.WebUtility]::HtmlDecode(($Html -replace '<[^>]+>', '')) }
    $rows = [ordered]@{ VM = '{VM}'; Site = '{Site}'; 'Configuration Type' = '{ConfigType}'; Stage = (& $field 'Stage')
                        Verification = '{Passed} passed, {Warnings} warnings, {Failed} failed'; Status = (& $field 'Status'); Time = '{Time}' }
    $refs = [ordered]@{ 'Run Directory' = '{RunFolder}'; Report = '{ReportPath}'; 'Draft Checklist' = '{ChecklistPath}' }
    $actions = @(& $field 'Actions'); $intro = [string](& $field 'Intro'); $closing = [string](& $field 'Closing')

    $h = New-Object System.Text.StringBuilder
    $font = "font-family:'Segoe UI',Calibri,Arial,sans-serif;font-size:11pt;color:#1C2136"
    $hd   = 'font-size:12pt;font-weight:600;margin:16px 0 6px 0'
    $code = 'font-family:Consolas,monospace;background:#F1F5F9;padding:1px 4px'
    [void]$h.Append("<html><body style=`"$font`"><p>Hello {Operator},</p><p>$intro</p>")
    [void]$h.Append("<p style=`"$hd`">Configuration Status</p><ul style=`"margin-top:0`">")
    foreach ($k in $rows.Keys) { [void]$h.Append("<li><b>${k}:</b> $($rows[$k])</li>") }
    [void]$h.Append("</ul><p style=`"$hd`">Action Required</p><ol style=`"margin-top:0`">")
    foreach ($a in $actions) { [void]$h.Append("<li>$a</li>") }
    [void]$h.Append('</ol>')
    if ($closing) { [void]$h.Append("<p>$closing</p>") }
    [void]$h.Append("<p style=`"$hd`">Configuration Reference</p>")
    foreach ($k in $refs.Keys) { [void]$h.Append("<div style=`"margin-bottom:4px`">${k}: <code style=`"$code`">$($refs[$k])</code></div>") }
    [void]$h.Append('<p style="color:#64748B;font-size:9pt;margin-top:18px">Sent by the APC Configuration Manager. Do not reply to this message.</p></body></html>')
    $html = (& $fill $h.ToString() $true) -replace '<code>', "<code style=`"$code`">"

    $t = New-Object System.Collections.Generic.List[string]
    $t.Add('Hello {Operator},'); $t.Add(''); $t.Add((& $plainOf $intro)); $t.Add(''); $t.Add('CONFIGURATION STATUS')
    foreach ($k in $rows.Keys) { $t.Add("- ${k}: $(& $plainOf $rows[$k])") }
    $t.Add(''); $t.Add('ACTION REQUIRED'); $i = 0
    foreach ($a in $actions) { $i++; $t.Add("$i. $(& $plainOf $a)") }
    if ($closing) { $t.Add(''); $t.Add((& $plainOf $closing)) }
    $t.Add(''); $t.Add('CONFIGURATION REFERENCE')
    foreach ($k in $refs.Keys) { $t.Add("${k}: $($refs[$k])") }
    $t.Add(''); $t.Add('Sent by the APC Configuration Manager. Do not reply to this message.')
    return @{ Subject = (& $fill ([string](& $field 'Subject')) $false); Html = $html; Text = (& $fill ($t -join "`r`n") $false) }
}

function Send-ConfigNotice {
    # Sends the 'draft checklist ready' e-mail to the signed-in operator. Never throws.
    param([hashtable]$State, [object]$Manifest, [hashtable]$Extra = @{})
    $msg = $null; $smtp = $null
    try {
        $cfg = if ($Manifest -and $Manifest.PSObject.Properties['Notifications']) { $Manifest.Notifications } else { $null }
        if (-not $cfg -or -not $cfg.SmtpServer -or -not $cfg.From) { Write-Log INFO 'E-mail not sent: set Notifications.SmtpServer and Notifications.From in the manifest.'; return }
        $operator = [string]$State['OperatorName']
        $to = if ($State['OperatorEmail']) { [string]$State['OperatorEmail'] } else { (Get-OperatorAdInfo $operator).Mail }
        if (-not $to) { Write-Log WARN "E-mail not sent: no e-mail address in AD for '$operator'."; return }
        $text = Get-ConfigNoticeText -State $State -Manifest $Manifest -Extra $Extra
        $msg = New-Object System.Net.Mail.MailMessage([string]$cfg.From, $to)
        $msg.Subject = $text.Subject
        $msg.Body    = $text.Text
        $msg.AlternateViews.Add([System.Net.Mail.AlternateView]::CreateAlternateViewFromString($text.Html, [Text.Encoding]::UTF8, 'text/html'))
        if ($cfg.PSObject.Properties['Cc'] -and $cfg.Cc) { foreach ($cc in ([string]$cfg.Cc -split '[;,]')) { if ($cc.Trim()) { $msg.CC.Add($cc.Trim()) } } }
        $port = if ($cfg.PSObject.Properties['Port'] -and $cfg.Port) { [int]$cfg.Port } else { 25 }
        $smtp = New-Object System.Net.Mail.SmtpClient([string]$cfg.SmtpServer, $port)
        $smtp.EnableSsl             = ($cfg.PSObject.Properties['UseSsl'] -and [bool]$cfg.UseSsl)
        $smtp.UseDefaultCredentials = $true
        $smtp.Timeout               = 15000
        $smtp.Send($msg)
        Write-Log INFO "E-mail 'draft checklist ready' sent to $to."
    } catch {
        Write-Log WARN "E-mail 'draft checklist ready' failed: $($_.Exception.Message) - continuing."
    } finally {
        if ($msg)  { $msg.Dispose() }
        if ($smtp) { $smtp.Dispose() }
    }
}
