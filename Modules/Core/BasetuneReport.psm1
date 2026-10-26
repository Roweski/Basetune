# ─────────────────────────────────────────────────────────────────────────────
# BasetuneReport.psm1
#
#   Get-BaselineSummary  — per-policy compliance summary (Summary.csv)
#   Get-HtmlReport       — HTML report from resolved diff rows, built from
#                          Templates\Report.html / .css / .js
# ─────────────────────────────────────────────────────────────────────────────

# Write-Log comes from BasetuneHelpers.psm1, loaded first by BasetuneCore.psd1.

# ─────────────────────────────────────────────────────────────────────────────
# AGGREGATE STATUS
#
# One setting can have several result rows (one per target policy). The HTML
# report and summary.csv both collapse them with these rules, so they agree:
#   - Issue Conflict            → Diff  (target policies disagree)
#   - any row Diff              → Diff
#   - any row Match             → Match (configured and equal in the target)
#   - any row Missing           → Missing
#   - otherwise                 → status of the first row
# ─────────────────────────────────────────────────────────────────────────────
function script:Get-AggregateStatus {
    param([array]$Group)
    $first = $Group[0]
    if ($first.Issue -eq 'Conflict') { return 'Diff' }
    $hasMatch = $false; $hasMissing = $false
    foreach ($r in $Group) {
        if ($r.Status -eq 'Diff') { return 'Diff' }
        if ($r.Status -eq 'Match')   { $hasMatch = $true }
        if ($r.Status -eq 'Missing') { $hasMissing = $true }
    }
    if ($hasMatch)   { return 'Match' }
    if ($hasMissing) { return 'Missing' }
    return $first.Status
}

# Unique target policy + value pairs of a group, sorted on policy name (the
# detail rows in the report). One row - the usual case - needs no sort.
function script:Get-ReportTargets {
    param([array]$Group)
    if ($Group.Count -eq 1) {
        if ($Group[0].TargetPolicyName) { return , @([ordered]@{ name = $Group[0].TargetPolicyName; value = $Group[0].TargetValue }) }
        return , @()
    }
    # Unique per target policy id (two policies can share a name), sorted on
    # name. Only the sort is a cmdlet: a cmdlet per step is slow on large sets.
    $named = @(foreach ($r in $Group) { if ($r.TargetPolicyName) { $r } })
    if ($named.Count -eq 0) { return , @() }
    return , @(foreach ($r in ($named | Sort-Object { "$($_.TargetPolicyName)`0$($_.TargetPolicyId)" } -Unique)) {
        [ordered]@{ name = $r.TargetPolicyName; value = $r.TargetValue }
    })
}

function Get-BaselineSummary {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Rows
    )

    # A plain loop instead of Where-Object (50,000+ rows on a large set).
    $sourceRows = @(foreach ($r in $Rows) { if ($r.SourcePolicyName) { $r } })

    # Per policy id (two policies can share a name: one line each).
    $byPolicy = $sourceRows | Group-Object -Property { if ($_.SourcePolicyId) { $_.SourcePolicyId } else { $_.SourcePolicyName } }

    $platformLabels = @{}   # platform key -> label, looked up once per key
    $summary = foreach ($pg in $byPolicy) {

        # Per setting name + DefinitionId (same name, other id counts twice).
        $byDef   = $pg.Group | Group-Object -Property Setting, DefinitionId
        $total   = 0
        $match   = 0
        $missing = 0
        $diff    = 0

        foreach ($dg in $byDef) {
            $total++
            # One row (the usual case): Get-AggregateStatus's rules inline (a
            # function call per setting is slow on a large set).
            $aggStatus = if ($dg.Count -eq 1) {
                             $r1 = $dg.Group[0]
                             if ($r1.Issue -eq 'Conflict' -or $r1.Status -eq 'Diff') { 'Diff' }
                             elseif ($r1.Status -eq 'Match')   { 'Match' }
                             elseif ($r1.Status -eq 'Missing') { 'Missing' }
                             else { $r1.Status }
                         } else { Get-AggregateStatus -Group @($dg.Group) }
            switch ($aggStatus) {
                'Match'   { $match++   }
                'Missing' { $missing++ }
                default   { $diff++    }
            }
        }

        $compliance = if ($total -gt 0) { [math]::Round(($match / $total) * 100, 2) } else { 0 }

        # Platform of the source policy (one per policy: the first row with one
        # tells it). First column.
        $pk = $null
        foreach ($r in $pg.Group) { if ($r.SourcePlatform) { $pk = $r.SourcePlatform; break } }
        $pLabel = ''
        if ($pk) {
            $pLabel = $platformLabels[$pk]
            if ($null -eq $pLabel) { $pLabel = Get-PlatformLabel $pk; $platformLabels[$pk] = $pLabel }
        }
        [PSCustomObject]@{
            Platform         = $pLabel
            Policy           = $pg.Group[0].SourcePolicyName
            Total            = $total
            Match            = $match
            Missing          = $missing
            Diff             = $diff
            'Compliance (%)' = $compliance
        }
    }

    return $summary | Sort-Object Platform, Policy
}


# Reads a file from Modules\Core\Templates (UTF-8), without its final newline.
function script:Read-ReportTemplate {
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path (Join-Path $PSScriptRoot 'Templates') $Name
    $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    # LF only, also when git checked the file out with CRLF.
    $text = $text.Replace("`r`n", "`n")
    if ($text.EndsWith("`n")) { $text = $text.Substring(0, $text.Length - 1) }
    return $text
}

# ─────────────────────────────────────────────────────────────────────────────
# GET HTML REPORT
#
# One report row per unique setting, from the resolved diff rows.
#
# Columns:
#   SourcePolicyName — baseline policy name
#   Setting          — human-readable setting name
#   SourceValue      — value in the baseline
#   Status           — Match / Diff / Missing (Get-AggregateStatus over the
#                      target rows); Extra = only in the target, these rows
#                      come last, without policy or source value
#   Issue            — None / Duplicate / Conflict
#
# Input  : resolved diff rows (from Invoke-BaselineCompare)
# Output : HTML file written to OutputPath
# ─────────────────────────────────────────────────────────────────────────────
function Get-HtmlReport {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Rows,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [string]$SourceLabel = "",
        [string]$TargetLabel = "",

        # Basetune's theme (settings.theme in Config.json): the report opens
        # in it; its own toggle still switches it.
        [string]$Theme = "light"
    )

    $bodyClass = if ("$Theme".Trim().ToLower() -eq 'dark') { ' class="dark-mode"' } else { '' }

    # Source rows only (a plain loop instead of Where-Object: 50,000+ rows on
    # a large set)
    $sourceRows = @(foreach ($r in $Rows) { if ($r.SourcePolicyName) { $r } })

    # One row per source policy (by id: same names stay apart) + Setting +
    # SourceValue + DefinitionId, so two settings with the same name and value
    # (e.g. two ADMX versions of Edge Update "Allow installation") stay two rows.
    $grouped = $sourceRows | Group-Object -Property { if ($_.SourcePolicyId) { $_.SourcePolicyId } else { $_.SourcePolicyName } }, Setting, SourceValue, DefinitionId

    $platformLabels = @{}   # platform key -> label, looked up once per key
    $settings = foreach ($g in $grouped) {
        $first  = $g.Group[0]
        $issue  = $first.Issue

        # Status by Get-AggregateStatus (as summary.csv), not the first row: a
        # group can hold several target policies in any order. Targets = the
        # unique target policy + value pairs (detail rows). One row (the usual
        # case): both inline (two function calls per setting are slow).
        if ($g.Count -eq 1) {
            $status = if ($first.Issue -eq 'Conflict' -or $first.Status -eq 'Diff') { 'Diff' }
                      elseif ($first.Status -eq 'Match')   { 'Match' }
                      elseif ($first.Status -eq 'Missing') { 'Missing' }
                      else { $first.Status }
            # Assigned in each branch: an if used as a value would unroll the
            # array (one item, or $null for none).
            if ($first.TargetPolicyName) { $targets = @([ordered]@{ name = $first.TargetPolicyName; value = $first.TargetValue }) }
            else                         { $targets = @() }
        } else {
            $status  = Get-AggregateStatus -Group @($g.Group)
            $targets = Get-ReportTargets -Group $g.Group
        }

        # Platform of the source policy (one platform per policy). Not shown
        # as a column; used by the Platform filter in the report.
        $pk = $null
        foreach ($r in $g.Group) { if ($r.SourcePlatform) { $pk = $r.SourcePlatform; break } }
        $pLabel = ''
        if ($pk) {
            $pLabel = $platformLabels[$pk]
            if ($null -eq $pLabel) { $pLabel = Get-PlatformLabel $pk; $platformLabels[$pk] = $pLabel }
        }

        [PSCustomObject]@{
            Platform         = $pLabel
            SourcePolicyName = $first.SourcePolicyName
            Setting          = $first.Setting
            SourceValue      = $first.SourceValue
            Status           = $status
            Issue            = $issue
            TargetCount      = $targets.Count
            Targets          = $targets
        }
    }

    $settings = @($settings | Sort-Object SourcePolicyName, Setting, SourceValue)

    # ── Extra settings: only in the target, not in the baseline ──────────────
    # One row per setting and platform (Windows and macOS are two groups of
    # devices), without a policy or source value; the target policies go in
    # the detail rows. Issue as in Merge-EnabledWithChildren (one target
    # policy = None, same values = Duplicate, different = Conflict), derived
    # here too because that merge does not run without definitions.
    $extraRows = @(foreach ($r in $Rows) { if (-not $r.SourcePolicyName -and $r.Status -eq 'Extra') { $r } })
    $extras = foreach ($g in ($extraRows | Group-Object -Property Setting, { [string]$_.TargetPlatform }, DefinitionId)) {
        $first   = $g.Group[0]
        $targets = Get-ReportTargets -Group $g.Group
        $values = @($targets | ForEach-Object { [string]$_.value } | Sort-Object -Unique)
        $issue  = if ($targets.Count -le 1) { 'None' }
                  elseif ($values.Count -le 1) { 'Duplicate' }
                  else { 'Conflict' }

        [PSCustomObject]@{
            Platform         = if ($first.TargetPlatform) { Get-PlatformLabel $first.TargetPlatform } else { '' }
            SourcePolicyName = ''
            Setting          = $first.Setting
            SourceValue      = ''
            Status           = 'Extra'
            Issue            = $issue
            TargetCount      = $targets.Count
            Targets          = $targets
        }
    }
    $settings = @($settings) + @($extras | Sort-Object Setting, Platform)

    # ── Build JSON data array for JS ─────────────────────────────────────────
    # One ConvertTo-Json for the whole array (much faster than one per row).
    $jsonRows = @(foreach ($s in $settings) {
        [ordered]@{
            platform = $s.Platform
            policy   = $s.SourcePolicyName
            setting  = $s.Setting
            value    = $s.SourceValue
            status   = $s.Status
            issue    = $s.Issue
            tcount   = $s.TargetCount
            targets  = $s.Targets
        }
    })
    $jsonData = ConvertTo-Json -InputObject $jsonRows -Compress -Depth 3

    # ConvertTo-Json leaves < > & as they are, and this JSON goes literally into
    # a <script> block (report-data in Report.html). Setting names contain >
    # and values free tenant text: a </script in there would close the block.
    # The \u notation parses to the same string. U+2028 / U+2029 too (valid in
    # JSON, not in a JavaScript literal).
    $jsonData = $jsonData.
        Replace('<', '\u003c').
        Replace('>', '\u003e').
        Replace('&', '\u0026').
        Replace([string][char]0x2028, '\u2028').
        Replace([string][char]0x2029, '\u2029')

    # Subtitle and log line; Report.js counts the tiles itself (updateTiles).
    $totalSettings = $settings.Count

    # ── Fill the report template ─────────────────────────────────────────────
    # Templates\Report.html holds the page, Report.css / Report.js are put
    # inline (the report stays one self-contained file). Placeholders:
    #   {{CSS}} {{JS}}        the two files
    #   {{BODY_CLASS}}        ' class="dark-mode"' or empty
    #   {{SUBTITLE}}          tenant labels (HTML-encoded), date, count
    #   {{VERSION}}           the Basetune version (footer, Get-BasetuneVersion)
    #   {{DATA}}              the JSON rows, in their own script block that
    #                         Report.js reads (filled last, so text inside
    #                         the data is never read as a placeholder)
    $subtitle = if ($SourceLabel -or $TargetLabel) {
        # Tenant names from Config.json: encoded, so & or < cannot break the page.
        $src = [System.Net.WebUtility]::HtmlEncode($(if ($SourceLabel) { $SourceLabel } else { 'Source' }))
        $tgt = [System.Net.WebUtility]::HtmlEncode($(if ($TargetLabel) { $TargetLabel } else { 'Target' }))
        "<p class=`"subtitle`">$src &nbsp;&rarr;&nbsp; $tgt &nbsp;&middot;&nbsp; Generated on $(Get-Date -Format 'yyyy-MM-dd HH:mm') &nbsp;&middot;&nbsp; $totalSettings settings</p>"
    } else {
        "<p class=`"subtitle`">Generated on $(Get-Date -Format 'yyyy-MM-dd HH:mm') &nbsp;&middot;&nbsp; $totalSettings settings</p>"
    }

    $html = (Read-ReportTemplate 'Report.html').
        Replace('{{CSS}}', (Read-ReportTemplate 'Report.css')).
        Replace('{{JS}}',  (Read-ReportTemplate 'Report.js')).
        Replace('{{BODY_CLASS}}',      $bodyClass).
        Replace('{{SUBTITLE}}',        $subtitle).
        Replace('{{VERSION}}',         [System.Net.WebUtility]::HtmlEncode((Get-BasetuneVersion)))
    # The data with -creplace and a scriptblock (text as is, no $ substitution),
    # not .Replace(): a .NET call with the JSON (many MB) as argument is slow.
    $html = $html -creplace '\{\{DATA\}\}', { $jsonData }

    $html | Out-File -FilePath $OutputPath -Encoding UTF8 -ErrorAction Stop
    Write-Log "Report" "Created $OutputPath ($totalSettings settings)"
    # The number of settings, for the summary at the end of compare.log.
    return $totalSettings
}

Export-ModuleMember -Function Get-BaselineSummary, Get-HtmlReport