# ─────────────────────────────────────────────────────────────────────────────
# COMPARE RAW SETTINGS
#
# Compares two flat arrays of SettingObjects (source vs target) and returns
# one result row per source setting / target match combination.
#
# Platform aware: a setting only matches a setting of the same platform
# (~1,100 definitions exist on several platforms: Edge on Windows and macOS,
# Apple payloads on iOS and macOS, ...). Unknown platform ('', JSON exports
# without "platforms") matches any platform.
#
# Result Status values:
#   Match   — DefinitionId found in target and RawValue is identical
#   Diff    — DefinitionId found in target but RawValue differs
#   Missing — DefinitionId not found in target at all
#   Extra   — DefinitionId present in target but absent from source
#
# Input  : two arrays of SettingObjects as produced by ConvertTo-SettingObjects
# Output : array of result objects (Status, DefinitionId, Source/TargetPolicy,
#          Source/TargetValue, ParentDefinitionId)
# ─────────────────────────────────────────────────────────────────────────────
function Compare-RawSettings {
    param(
        [array]$Source,
        [array]$Target
    )

    # DefinitionId -> target settings with that id, in target order. Extended
    # with + to avoid a ContainsKey / List.Add .NET call per setting; an id is
    # in a few target policies at most, so the copies stay tiny.
    $targetIndex = @{}

    foreach ($t in $Target) {
        if (-not $t.DefinitionId) { continue }

        $key = $t.DefinitionId.ToLower()

        $list = $targetIndex[$key]
        if ($null -eq $list) { $targetIndex[$key] = @($t) }
        else                 { $targetIndex[$key] = $list + $t }
    }

    # DefinitionId -> platforms of its source settings ('' = unknown), for the
    # Extra check below: a case-sensitive Dictionary (platform -> $true), set
    # by index to avoid a method call per source setting.
    $sourcePlatforms = @{}

    $results = foreach ($s in $Source) {

        if (-not $s.DefinitionId) { continue }

        $key   = $s.DefinitionId.ToLower()
        $sPlat = [string]$s.Platform
        $sp    = $sourcePlatforms[$key]
        if ($null -eq $sp) {
            $sp = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
            $sourcePlatforms[$key] = $sp
        }
        $sp[$sPlat] = $true

        # Same platform, or unknown ('') on either side. Inline: a function
        # call per candidate is costly on a large set.
        $matched = @(foreach ($t in @($targetIndex[$key])) {
            if (-not $t) { continue }
            $tPlat = [string]$t.Platform
            if (-not $sPlat -or -not $tPlat -or $sPlat -eq $tPlat) { $t }
        })

        if ($matched.Count -eq 0) {
            [PSCustomObject]@{
                Status             = "Missing"
                DefinitionId       = $s.DefinitionId
                ParentDefinitionId = $s.ParentDefinitionId
                SourcePolicyId     = $s.PolicyId
                SourcePolicyName   = $s.PolicyName
                SourceValue        = $s.RawValue
                TargetPolicyId     = $null
                TargetPolicyName   = $null
                TargetValue        = $null
                SourcePlatform     = $sPlat
                TargetPlatform     = $null
            }
            continue
        }

        foreach ($t in $matched) {

            $status = if ($s.RawValue -eq $t.RawValue) { "Match" } else { "Diff" }

            [PSCustomObject]@{
                Status             = $status
                DefinitionId       = $s.DefinitionId
                ParentDefinitionId = $s.ParentDefinitionId
                SourcePolicyId     = $s.PolicyId
                SourcePolicyName   = $s.PolicyName
                TargetPolicyId     = $t.PolicyId
                TargetPolicyName   = $t.PolicyName
                SourceValue        = $s.RawValue
                TargetValue        = $t.RawValue
                SourcePlatform     = $sPlat
                TargetPlatform     = [string]$t.Platform
            }
        }
    }

    # Extra: no source setting with the same DefinitionId on the same platform
    # (or with an unknown platform on either side).
    $extra = foreach ($t in $Target) {
        if (-not $t.DefinitionId) { continue }
        $tPlat = [string]$t.Platform
        $sp    = $sourcePlatforms[$t.DefinitionId.ToLower()]
        if ($null -ne $sp -and (-not $tPlat -or $sp[$tPlat] -or $sp[''])) { continue }

        [PSCustomObject]@{
            Status             = "Extra"
            DefinitionId       = $t.DefinitionId
            ParentDefinitionId = $t.ParentDefinitionId
            SourcePolicyId     = $null
            SourcePolicyName   = $null
            TargetPolicyId     = $t.PolicyId
            TargetPolicyName   = $t.PolicyName
            SourceValue        = $null
            TargetValue        = $t.RawValue
            SourcePlatform     = $null
            TargetPlatform     = $tPlat
        }
    }

    return @($results) + @($extra)
}


# ─────────────────────────────────────────────────────────────────────────────
# ADD ISSUE COLUMN
#
# Adds an 'Issue' column to the raw compare output ($diff).
# Logic per DefinitionId across all target matches:
#
#   None      — the source setting appears 0 or 1 time in the target
#               (Missing / one Match or one Diff row)
#   Duplicate — the setting appears more than once in the target,
#               and all target values are identical
#   Conflict  — the setting appears more than once in the target,
#               but the target values differ from each other
# Extra rows: the same, over the target policies that hold the setting on
# that platform (one policy: None).
#
# Input  : array of PSCustomObjects as returned by Compare-RawSettings
# Output : same array with an extra 'Issue' property per object
# ─────────────────────────────────────────────────────────────────────────────
function Add-IssueColumn {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Diff
    )

    if ($Diff.Count -eq 0) { return }

    # Group on DefinitionId + platform (a Windows and a macOS target policy
    # never meet on one device, so that is no Duplicate/Conflict). Matched
    # rows: 'M|<key>'; Extra rows: 'E|<key>' (see $extraMap below). Missing
    # rows have no target, so never an issue.
    #
    # Per group only the target policy ids with their target value are kept
    # (a hashtable, not case sensitive like Sort-Object -Unique). A target
    # policy holds a setting once (collections are merged), so all its rows in
    # a group share one value. Plain loops and hashtables, no Where-Object /
    # Group-Object / List.Add per row: costly at 50,000+ rows.
    $groupTargets = @{}   # group key -> @{ TargetPolicyId = TargetValue }
    foreach ($r in $Diff) {
        if ($r.SourcePolicyId -and $r.TargetPolicyId) {
            $p = if ($r.TargetPlatform) { $r.TargetPlatform } else { [string]$r.SourcePlatform }
            $k = "M|$($r.DefinitionId.ToLower())|$p"
        } elseif (-not $r.SourcePolicyId -and $r.TargetPolicyId -and $r.DefinitionId) {
            $k = "E|$($r.DefinitionId.ToLower())|$([string]$r.TargetPlatform)"
        } else { continue }
        $targets = $groupTargets[$k]
        if ($null -eq $targets) { $targets = @{}; $groupTargets[$k] = $targets }
        if ($null -eq $targets[$r.TargetPolicyId]) { $targets[$r.TargetPolicyId] = $r.TargetValue }
    }

    $issueMap = @{}
    $extraMap = @{}
    foreach ($gk in $groupTargets.Keys) {
        $targets = $groupTargets[$gk]
        $k       = $gk.Substring(2)
        if ($gk.StartsWith('E|')) {
            # Extra rows: the same rule over the target policies that hold the
            # setting. Merge-EnabledWithChildren recounts it the same way, so
            # the result does not depend on whether definitions are loaded.
            $extraMap[$k] = if ($targets.Count -le 1) { 'None' }
                            elseif (@($targets.Values | ForEach-Object { [string]$_ } | Sort-Object -Unique).Count -eq 1) { 'Duplicate' }
                            else { 'Conflict' }
            continue
        }
        # Deduplicate by TargetPolicyId — N source policies pointing to the
        # same single target policy must NOT count as Duplicate/Conflict.
        if ($targets.Count -le 1) {
            $issueMap[$k] = "None"
        } else {
            $distinctValues = $targets.Values | ForEach-Object { $_ } | Sort-Object -Unique
            if ($distinctValues.Count -eq 1) {
                $issueMap[$k] = "Duplicate"
            } else {
                $issueMap[$k] = "Conflict"
            }
        }
    }

    # Each row with Issue added. The maps hold no $null, so an index lookup
    # replaces ContainsKey.
    foreach ($d in $Diff) {
        $issue = $null
        if (-not $d.SourcePolicyId -and $d.DefinitionId) {
            $issue = $extraMap["$($d.DefinitionId.ToLower())|$([string]$d.TargetPlatform)"]
        } elseif ($d.DefinitionId) {
            $p     = if ($d.TargetPlatform) { $d.TargetPlatform } else { [string]$d.SourcePlatform }
            $issue = $issueMap["$($d.DefinitionId.ToLower())|$p"]
        }
        if ($null -eq $issue) { $issue = 'None' }

        [PSCustomObject]@{
            Status             = $d.Status
            Issue              = $issue
            DefinitionId       = $d.DefinitionId
            ParentDefinitionId = $d.ParentDefinitionId
            SourcePolicyId     = $d.SourcePolicyId
            SourcePolicyName   = $d.SourcePolicyName
            SourceValue        = $d.SourceValue
            TargetPolicyId     = $d.TargetPolicyId
            TargetPolicyName   = $d.TargetPolicyName
            TargetValue        = $d.TargetValue
            SourcePlatform     = $d.SourcePlatform
            TargetPlatform     = $d.TargetPlatform
        }
    }
}


# "Read 1240 settings from 45 source policies" (singular for 1).
function Format-ReadSettingsLine {
    param([int]$SettingCount, [int]$PolicyCount, [string]$Side)
    $settingWord = if ($SettingCount -eq 1) { 'setting' } else { 'settings' }
    $policyWord  = if ($PolicyCount  -eq 1) { 'policy' }  else { 'policies' }
    "Read $SettingCount $settingWord from $PolicyCount $Side $policyWord"
}

# ─────────────────────────────────────────────────────────────────────────────
# INVOKE BASELINE COMPARE
#
# Single entry point for the full compare pipeline, for both the CLI and the
# UI compare runspace.
#
# Steps:
#   0. Wire the compare context (definition lookup, categories, connection)
#      into the resolve context (Initialize-ResolveContext, BasetunePolicies)
#   1. Flatten source + target policies (ConvertTo-SettingObjects)
#   2. Merge collection settings (Merge-CollectionSettings)
#   3. Compare (Compare-RawSettings + Add-IssueColumn)
#   4. Resolve setting names + values (Resolve-DiffSettings + Merge-EnabledWithChildren)
#      — skipped when no definition lookup is available
#   5. Export Diff.csv, Summary.csv, Report.html to $ExportPath
#   6. Flush the category cache if new categories were fetched from the API
#
# Input:
#   SourcePolicies     — policy objects (PolicyId, Name, Settings). May be empty.
#   TargetPolicies     — policy objects. May be empty.
#   ExportPath         — output folder (must exist)
#   ReportFile         — HTML file path; default "$ExportPath\Report.html"
#   DefinitionLookup   — hashtable from Import-SettingDefinitions, or $null
#   CategoryById       — hashtable from Import-SettingCategories, or $null
#   CategoriesFilePath — where the category cache is flushed to (optional)
#   Connection         — Graph connection for on-demand category lookups (optional)
#   SourceLabel / TargetLabel — shown in the HTML header
#
# Output: [PSCustomObject]@{ Success; RowCount; ReportFile }
#   Success = $false when there is nothing to compare (no source policies).
#   Exceptions from the pipeline itself are NOT swallowed — the caller logs them.
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-BaselineCompare {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [array]$SourcePolicies,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [array]$TargetPolicies,

        [Parameter(Mandatory)]
        [string]$ExportPath,

        [string]$ReportFile = "",

        [hashtable]$DefinitionLookup = $null,
        [hashtable]$CategoryById     = $null,
        [string]$CategoriesFilePath  = "",
        $Connection                  = $null,

        [string]$SourceLabel = "",
        [string]$TargetLabel = "",

        # 'light' or 'dark': the theme the HTML report opens in.
        [string]$ReportTheme = "light",

        # Optional: runs just before the output files are written, so what the
        # caller logs comes before the report folder and file lines.
        [scriptblock]$OnBeforeExport = $null,

        # $true: the closing "could not be resolved" line also says to
        # download the definitions (caller decides, see Test-DefinitionsRecent).
        [bool]$SuggestDownload = $true
    )

    $SourcePolicies = @($SourcePolicies | Where-Object { $_ })
    $unresolvedCount = 0   # settings without a definition (only counted when definitions are loaded)
    $TargetPolicies = @($TargetPolicies | Where-Object { $_ })

    if ($SourcePolicies.Count -eq 0) {
        Write-Log "Compare" "No source policies to compare. Check the source filter or selection" "ERROR"
        return [PSCustomObject]@{ Success = $false; RowCount = 0; ReportFile = $null }
    }
    if ($TargetPolicies.Count -eq 0) {
        Write-Log "Compare" "No target policies loaded. Every baseline setting will be reported as Missing" "WARN"
    }

    # ── 0. Compare context ──────────────────────────────────────────────────
    # Read by the resolve functions (Get-SettingPath, Resolve-Category, ...,
    # BasetunePolicies); set here so every caller behaves the same.
    $bHasDefinitions = ($null -ne $DefinitionLookup -and $DefinitionLookup.Count -gt 0)
    $bHasCategories  = ($null -ne $CategoryById -and $CategoryById.Count -gt 0)

    $rc = Initialize-ResolveContext -DefinitionLookup $DefinitionLookup -CategoryById $CategoryById `
                                    -CategoriesFilePath $CategoriesFilePath -Connection $Connection

    # Missing definitions/categories are logged by the caller (UI / CLI) when
    # loading them: "Setting definitions: Not found (falling back to DefinitionId)".

    # ── 1+2. Flatten + merge collections ─────────────────────────────────────
    # Two policies of one side with the same id (a copied file in a JSON
    # folder) would be grouped as one below: each copy gets its own key
    # (<id>#2, ...). Listed at the end.
    $srcIds = Resolve-DuplicatePolicyIds -Policies $SourcePolicies
    $tgtIds = Resolve-DuplicatePolicyIds -Policies $TargetPolicies
    $SourcePolicies = $srcIds.Policies
    $TargetPolicies = $tgtIds.Policies

    # Same name on one side (a copy in Intune): shown with the id. Listed at
    # the end. The "Read 1240 settings from 45 source policies" line comes
    # after the merge, so it shows the result.
    $srcNames = Get-PolicyDisplayNames -Policies $SourcePolicies
    $tgtNames = Get-PolicyDisplayNames -Policies $TargetPolicies

    $sourceFlat = @(foreach ($p in $SourcePolicies) {
        if ($p.Settings) { ConvertTo-SettingObjects -Policy $p -Source 'Source' -PolicyName $srcNames.Names[[string]$p.PolicyId] }
    })
    $sourceFlat = @(Merge-CollectionSettings -Settings $sourceFlat)
    Write-Log "Compare" (Format-ReadSettingsLine $sourceFlat.Count $SourcePolicies.Count 'source') "INFO"

    $targetFlat = @(foreach ($p in $TargetPolicies) {
        if ($p.Settings) { ConvertTo-SettingObjects -Policy $p -Source 'Target' -PolicyName $tgtNames.Names[[string]$p.PolicyId] }
    })
    $targetFlat = @(Merge-CollectionSettings -Settings $targetFlat)
    if ($TargetPolicies.Count -gt 0) {
        Write-Log "Compare" (Format-ReadSettingsLine $targetFlat.Count $TargetPolicies.Count 'target') "INFO"
    }

    if ($sourceFlat.Count -eq 0) {
        Write-Log "Compare" "The selected source policies contain no settings" "WARN"
    }

    # ── 3. Compare ────────────────────────────────────────────────────────────
    Write-Log "Compare" "Comparing settings..." "INFO"
    $diff = @(Compare-RawSettings -Source $sourceFlat -Target $targetFlat)
    $diff = @(Add-IssueColumn -Diff $diff)

    # ── 4. Resolve ────────────────────────────────────────────────────────────
    # Categories need definitions (the category id comes from the definition).
    #   both:             Resolving display names and categories...
    #   definitions only: Skipping categories... / Resolving display names...
    #   no definitions:   Skipping display names and categories...
    if ($bHasDefinitions) {
        if ($bHasCategories) {
            Write-Log "Compare" "Resolving display names and categories..." "INFO"
        } else {
            Write-Log "Compare" "Skipping categories..." "INFO"
            Write-Log "Compare" "Resolving display names..." "INFO"
        }
        $resolved = @(Resolve-DiffSettings -Diff $diff)
        $resolved = @(Merge-EnabledWithChildren -Resolved $resolved)
        $unresolvedCount = Get-UnresolvedDefinitionCount -Diff $diff
    } else {
        Write-Log "Compare" "Skipping display names and categories..." "INFO"
        $resolved = @($diff | ForEach-Object {
            [PSCustomObject]@{
                DefinitionId     = $_.DefinitionId
                Setting          = $_.DefinitionId
                Status           = $_.Status
                Issue            = $_.Issue
                SourcePolicyId   = $_.SourcePolicyId
                TargetPolicyId   = $_.TargetPolicyId
                SourcePolicyName = $_.SourcePolicyName
                TargetPolicyName = $_.TargetPolicyName
                SourceValue      = $_.SourceValue
                TargetValue      = $_.TargetValue
                SourcePlatform   = $_.SourcePlatform
                TargetPlatform   = $_.TargetPlatform
            }
        })
    }
    # Row count is logged with "Comparison complete: n rows processed" below.

    # Categories fetched from the API go back into the caller's table (UI
    # session cache), so the next compare does not fetch them again.
    # Placeholders stay out.
    if ($null -ne $CategoryById -and $rc.CategoryCacheDirty) {
        foreach ($k in @($rc.CategoryById.Keys)) {
            $c = $rc.CategoryById[$k]
            if (-not $CategoryById.ContainsKey($k) -and -not $c.PSObject.Properties['__placeholder'] -and
                $c.displayName -notin @('[Unresolved Category]','[Unknown Category]')) {
                $CategoryById[$k] = $c
            }
        }
    }

    # ── 4b. Flush category cache ──────────────────────────────────────────────
    # Placeholders ("[Unknown Category]") are session-only and never
    # written: a temporary API failure must not become permanent on disk.
    if ($rc.CategoryCacheDirty -and $rc.CategoriesFilePath) {
        # Progress line (the write can take a moment), then the result line.
        Write-Log "Categories" "Updating category definitions..." "INFO"
        try {
            $toSave = @($rc.CategoryById.Values | Where-Object {
                -not $_.PSObject.Properties['__placeholder'] -and $_.displayName -notin @('[Unresolved Category]','[Unknown Category]')
            })
            $tmp    = "$($rc.CategoriesFilePath).tmp"
            $toSave | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $tmp -Encoding UTF8
            Move-Item -LiteralPath $tmp -Destination $rc.CategoriesFilePath -Force
            Write-Log "Categories" "Saved $($rc.CategoryFetchedCount) extra categories to $(Split-Path $rc.CategoriesFilePath -Leaf) ($($toSave.Count))" "OK"
        } catch {
            Write-Log "Categories" "Could not update categories cache file. See the log file for details" "WARN"
            Write-Log "Categories" "Details: $($_.Exception.Message)" "WARN" -FileOnly
        }
    }

    if ($OnBeforeExport) { & $OnBeforeExport }

    # ── 5. Export ─────────────────────────────────────────────────────────────
    # DefinitionId is exported too: with definitions loaded, Setting holds the
    # friendly path, and keywords such as TamperProtection or
    # LocalAdminPassword only occur in the id.
    # Separator: Get-CsvDelimiter (the Windows list separator of this PC).
    # utf8BOM: Excel only reads a CSV as UTF-8 with a BOM (else accents garble).
    $diffCsv    = Join-Path $ExportPath 'Diff.csv'
    $summaryCsv = Join-Path $ExportPath 'Summary.csv'
    $csvSep     = Get-CsvDelimiter
    $winSep     = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ListSeparator
    # Counts as "53,332 rows", whatever the culture of the PC.
    $inv        = [System.Globalization.CultureInfo]::InvariantCulture

    # A write error (folder not writable, file open in Excel, disk full) gives
    # one line; the cause goes to the log file. A progress line before the CSV
    # files and before the HTML report: each takes seconds on a large set
    # (dots animate in the UI, see UILogAnimRegex in BasetuneLogView.psm1).
    #   Comparison complete: 958 rows processed
    #   Report folder: C:\reports\Src_Tgt\20261010_113304
    #   Exporting CSV reports...
    #   (log file only: CSV separator: ';' (Windows list separator))
    #   Created C:\reports\...\Diff.csv (958 rows)
    #   Created C:\reports\...\Summary.csv
    #   Exporting HTML report...
    #   Created C:\reports\...\Report.html (522 settings)   (Get-HtmlReport)
    # The view shows the file names only, as links (Add-UILogLines).
    Write-Log "Compare" ("Comparison complete: {0} rows processed" -f $resolved.Count.ToString('N0', $inv)) "OK"
    Write-Log "Report" "Report folder: $ExportPath" "INFO"
    Write-Log "Report" "Exporting CSV reports..." "INFO"
    Write-Log 'Report' ("CSV separator: '$csvSep'" + $(if ("$csvSep" -eq $winSep) { ' (Windows list separator)' } else { " (Windows list separator '$winSep' is not supported)" })) 'INFO' -FileOnly
    try {
        # Platform key -> label, looked up once per key (Get-PlatformLabel
        # runs a pipeline).
        $platformLabels = @{}
        # Order: source policy (Extra rows last), setting, target policy,
        # DefinitionId, value: never depends on the input order (the policy id
        # keeps two policies with one name apart).
        $sortedRows = $resolved |
            Sort-Object { if ($_.SourcePolicyName) { "0_$($_.SourcePolicyName)`0$($_.SourcePolicyId)" } else { "1_" } }, Setting,
                        { "$($_.TargetPolicyName)`0$($_.TargetPolicyId)" }, DefinitionId, { [string]$_.TargetValue }
        # The CSV columns, in this order. One Platform column: Missing = source,
        # Extra = target, Match/Diff = the same on both sides; an unknown
        # platform (JSON export) takes the other side's. A plain loop, not
        # Select-Object with a calculated property: several times faster.
        $csvRows = foreach ($r in $sortedRows) {
            $pk = if ($r.SourcePlatform) { $r.SourcePlatform } else { $r.TargetPlatform }
            $pl = ''
            if ($pk) {
                $pl = $platformLabels[$pk]
                if ($null -eq $pl) { $pl = Get-PlatformLabel $pk; $platformLabels[$pk] = $pl }
            }
            [PSCustomObject]@{
                Platform         = $pl
                SourcePolicyName = $r.SourcePolicyName
                Setting          = $r.Setting
                Status           = $r.Status
                Issue            = $r.Issue
                SourceValue      = $r.SourceValue
                TargetPolicyName = $r.TargetPolicyName
                TargetValue      = $r.TargetValue
                DefinitionId     = $r.DefinitionId
            }
        }
        $csvRows | Export-Csv $diffCsv -NoTypeInformation -Encoding utf8BOM -Delimiter $csvSep -ErrorAction Stop
        Write-Log "Report" ("Created $diffCsv ({0} rows)" -f $resolved.Count.ToString('N0', $inv)) "OK"

        Get-BaselineSummary -Rows $resolved |
            Export-Csv $summaryCsv -NoTypeInformation -Encoding utf8BOM -Delimiter $csvSep -ErrorAction Stop
        Write-Log "Report" "Created $summaryCsv" "OK"

        $htmlOutputPath = if ($ReportFile) { $ReportFile } else { Join-Path $ExportPath 'Report.html' }
        Write-Log "Report" "Exporting HTML report..." "INFO"
        Get-HtmlReport -Rows $resolved -OutputPath $htmlOutputPath -SourceLabel $SourceLabel -TargetLabel $TargetLabel -Theme $ReportTheme
    } catch {
        Write-Log "Compare" "Could not write the comparison data. See the log file for details" "ERROR"
        Write-Log "Compare" "Details: $($_.Exception.Message)" "ERROR" -FileOnly
        return [PSCustomObject]@{ Success = $false; Logged = $true }
    }

    # Settings of an unknown type (not compared) and policies with the same
    # name on one side (Get-PolicyDisplayNames).
    $skippedSettings = @($rc.SkippedSettings)
    $sameName = @(
        foreach ($d in $srcNames.Duplicates) { [PSCustomObject]@{ Side = 'Source'; Name = $d.Name; PolicyId = $d.PolicyId; DisplayName = $d.DisplayName } }
        foreach ($d in $tgtNames.Duplicates) { [PSCustomObject]@{ Side = 'Target'; Name = $d.Name; PolicyId = $d.PolicyId; DisplayName = $d.DisplayName } }
    )
    # Policies with the same id on one side (Resolve-DuplicatePolicyIds), with
    # the name as shown in the report.
    $sameId = @(
        foreach ($d in $srcIds.Duplicates) { [PSCustomObject]@{ Side = 'Source'; Name = $d.Name; PolicyId = $d.PolicyId; Key = $d.Key; DisplayName = $srcNames.Names[$d.Key] } }
        foreach ($d in $tgtIds.Duplicates) { [PSCustomObject]@{ Side = 'Target'; Name = $d.Name; PolicyId = $d.PolicyId; Key = $d.Key; DisplayName = $tgtNames.Names[$d.Key] } }
    )

    # ── 5b. compare.log ───────────────────────────────────────────────────────
    # Next to the report: skipped settings, same-id and same-name policies
    # (only when any), then the compared policies. No log lines. A write error
    # does not undo the report.
    $compareLog = Join-Path $ExportPath 'compare.log'
    try {
        # Each block kept as its own list (the unary comma stops PowerShell
        # from joining them), an empty line between the blocks that have lines.
        $blocks = @(
            , @(Format-SkippedSettingList -SkippedSettings $skippedSettings)
            , @(Format-SameIdPolicyList -SameIdPolicies $sameId)
            , @(Format-SameNamePolicyList -SameNamePolicies $sameName)
            , @(Format-ComparedPolicyList -SourcePolicies $SourcePolicies -TargetPolicies $TargetPolicies)
        )
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($b in $blocks) {
            if ($b.Count -eq 0) { continue }
            if ($lines.Count -gt 0) { $lines.Add('') }
            foreach ($l in $b) { $lines.Add($l) }
        }
        Set-Content -LiteralPath $compareLog -Value $lines -Encoding utf8 -ErrorAction Stop
    } catch {
        Write-Log "Compare" "Could not write compare.log. See the log file for details" "WARN"
        Write-Log "Compare" "Details: $($_.Exception.Message)" "WARN" -FileOnly
    }

    # One line each in the view / console; the items one by one in the log file:
    #   Skipped 2 settings with an unknown setting type. See compare.log for details
    #   Details: Skipped in source policy 'Baseline - Windows': <id> (#microsoft.graph...Instance)
    #   Duplicate policy IDs detected. See compare.log for details
    #   Details: Same id, target policy 'Test 2': 16546809-... shown as 'Test 2 (16546809-...#2)'
    #   Duplicate policy names detected. See compare.log for details
    #   Details: Same name, source policy 'FED306 - test': fc96b86b-... shown as 'FED306 - test (fc96b86b-...)'
    if ($skippedSettings.Count -gt 0) {
        $what = if ($skippedSettings.Count -eq 1) { '1 setting' } else { "$($skippedSettings.Count) settings" }
        Write-Log "Compare" "Skipped $what with an unknown setting type. See compare.log for details" "WARN"
        foreach ($k in $skippedSettings) {
            Write-Log "Compare" "Details: Skipped in $("$($k.Side)".ToLower()) policy '$($k.PolicyName)': $($k.DefinitionId) ($($k.Type))" "WARN" -FileOnly
        }
    }
    if ($sameId.Count -gt 0) {
        Write-Log "Compare" "Duplicate policy IDs detected. See compare.log for details" "WARN"
        foreach ($d in $sameId) {
            Write-Log "Compare" "Details: Same id, $("$($d.Side)".ToLower()) policy '$($d.Name)': $($d.PolicyId) shown as '$($d.DisplayName)'" "WARN" -FileOnly
        }
    }
    if ($sameName.Count -gt 0) {
        Write-Log "Compare" "Duplicate policy names detected. See compare.log for details" "WARN"
        foreach ($d in $sameName) {
            Write-Log "Compare" "Details: Same name, $("$($d.Side)".ToLower()) policy '$($d.Name)': $($d.PolicyId) shown as '$($d.DisplayName)'" "WARN" -FileOnly
        }
    }

    # Last line: settings that are not in the setting definitions (new in
    # Intune since the definitions were downloaded, or removed by Microsoft).
    #   12 settings could not be resolved (no setting definition found). Download the latest setting definitions
    $suggested = $false
    if ($unresolvedCount -gt 0) {
        $what = if ($unresolvedCount -eq 1) { '1 setting' } else { "$unresolvedCount settings" }
        $msg  = "$what could not be resolved (no setting definition found)"
        if ($SuggestDownload) { $msg += '. Download the latest setting definitions'; $suggested = $true }
        Write-Log "Compare" $msg "WARN"
    }

    return [PSCustomObject]@{ Success = $true; RowCount = $resolved.Count; ReportFile = $htmlOutputPath
                              UnresolvedCount = $unresolvedCount; DownloadSuggested = $suggested
                              SkippedSettings = $skippedSettings; SameNamePolicies = $sameName
                              SameIdPolicies = $sameId }
}

# ─────────────────────────────────────────────────────────────────────────────
# SAME-ID POLICIES
# A JSON folder can hold a copied file: two policies with the same id, which
# the compare (grouping on id) would take as one. The first keeps its id;
# every next one (not case sensitive) is a shallow copy with PolicyId
# "<id>#2", "<id>#3", ... Compare only: loaded policies keep the real id.
# Numbers follow the policy name (A-Z), not the input order (UI sort, CLI
# file order); the same name keeps the input order.
# Returns @{ Policies = the policies, in the same order as given;
# Duplicates = list of @{ Name; PolicyId (the real id); Key } for every
# policy that shares its id, in name order: the first (Key = its id) and the
# copies (Key = "<id>#n") }.
# ─────────────────────────────────────────────────────────────────────────────
function Resolve-DuplicatePolicyIds {
    param([AllowNull()][AllowEmptyCollection()][array]$Policies)
    $all   = @($Policies | Where-Object { $_ })
    $seen  = @{}   # case-insensitive keys: GUIDs in another casing are the same id
    $first = @{}   # id -> index of the first policy with it, listed once a copy turns up
    $keyOf = @{}   # index -> new key, for the copies
    $dups  = [System.Collections.Generic.List[object]]::new()

    # Indexes in name order (Sort-Object is stable: the same name keeps the
    # order it came in).
    $order = @(0..($all.Count - 1) | Where-Object { $all.Count } | Sort-Object { [string]$all[$_].Name })
    foreach ($i in $order) {
        $p  = $all[$i]
        $id = [string]$p.PolicyId
        if (-not $id) { continue }
        if (-not $seen.ContainsKey($id)) { $seen[$id] = 1; $first[$id] = $i; continue }
        if ($seen[$id] -eq 1) {
            $f = $all[$first[$id]]
            $dups.Add([PSCustomObject]@{ Name = [string]$f.Name; PolicyId = [string]$f.PolicyId; Key = [string]$f.PolicyId })
        }
        $seen[$id]++
        $keyOf[$i] = "$id#$($seen[$id])"
        $dups.Add([PSCustomObject]@{ Name = [string]$p.Name; PolicyId = $id; Key = $keyOf[$i] })
    }

    # Back in the order given; the copies as a shallow copy with the new key.
    $out = @(for ($i = 0; $i -lt $all.Count; $i++) {
        if ($keyOf.ContainsKey($i)) {
            $copy = $all[$i].PSObject.Copy()
            $copy.PolicyId = $keyOf[$i]
            $copy
        } else { $all[$i] }
    })
    return @{ Policies = $out; Duplicates = $dups }
}

# ─────────────────────────────────────────────────────────────────────────────
# DUPLICATE IDS / DUPLICATE NAMES (compare.log)
# The policies that share an id or a name with another policy of the same
# side (Invoke-BaselineCompare results SameIdPolicies / SameNamePolicies), one
# group per id or name, the source and the target side below it, each policy
# with the name it has in the report. Nothing when there are none.
#   Policies with duplicate IDs:
#     ID: 56546809-18df-4f3e-a468-5034ee4307c2
#       Source:
#         'Test 2' shown as 'Test 2 (56546809-...-07c2)'
#         'Test 4' shown as 'Test 4 (56546809-...-07c2#2)'
#   Policies with duplicate names:
#     Name: 'test'
#       Target:
#         16546809-...-07c2 shown as 'test (16546809-...-07c2)'
#         16546809-...-07c2 shown as 'test (16546809-...-07c2#2)'
# ─────────────────────────────────────────────────────────────────────────────
function script:Format-DuplicateGroups {
    param([array]$List, [scriptblock]$GroupKey, [string]$GroupLabel, [scriptblock]$Item)
    # Groups in the order of their key; ids are not case sensitive.
    $groups = [ordered]@{}
    foreach ($d in ($List | Sort-Object { & $GroupKey $_ })) {
        $k = (& $GroupKey $d).ToLowerInvariant()
        if (-not $groups.Contains($k)) { $groups[$k] = [System.Collections.Generic.List[object]]::new() }
        $groups[$k].Add($d)
    }
    foreach ($g in $groups.Values) {
        "  $($GroupLabel): $(& $GroupKey $g[0])"
        foreach ($side in 'Source', 'Target') {
            # In the order of the name in the report (the #n numbers follow it).
            $items = @($g | Where-Object { "$($_.Side)" -eq $side } | Sort-Object { [string]$_.DisplayName })
            if ($items.Count -eq 0) { continue }
            "    $($side):"
            foreach ($d in $items) { "      $(& $Item $d) shown as '$($d.DisplayName)'" }
        }
    }
}

function Format-SameIdPolicyList {
    param([AllowNull()][AllowEmptyCollection()][array]$SameIdPolicies)
    $list = @($SameIdPolicies | Where-Object { $_ })
    if ($list.Count -eq 0) { return }
    'Policies with duplicate IDs:'
    Format-DuplicateGroups -List $list -GroupLabel 'ID' `
        -GroupKey { param($d) [string]$d.PolicyId } `
        -Item     { param($d) "'$($d.Name)'" }
}

function Format-SameNamePolicyList {
    param([AllowNull()][AllowEmptyCollection()][array]$SameNamePolicies)
    $list = @($SameNamePolicies | Where-Object { $_ })
    if ($list.Count -eq 0) { return }
    'Policies with duplicate names:'
    # PolicyId here is the compare key: the real id is shown, "#n" is in the
    # name in the report.
    Format-DuplicateGroups -List $list -GroupLabel 'Name' `
        -GroupKey { param($d) "'$($d.Name)'" } `
        -Item     { param($d) ([string]$d.PolicyId) -replace '#\d+$', '' }
}
# ─────────────────────────────────────────────────────────────────────────────
# POLICY DISPLAY NAMES
# Two policies of one side with the same name (a copy in Intune) get their
# full id after the name:
#     FED306 - test (fc96b86b-65b8-4a1a-915c-a5acb84a196d)
#     FED306 - test (7d3c2b1a-0f4e-4c5d-9a8b-6e7f80912345)
# Policies that share an id (key "<id>#n", Resolve-DuplicatePolicyIds) are
# all shown with it, also when their names differ:
#     test (fc96b86b-65b8-4a1a-915c-a5acb84a196d)
#     Test 2 (fc96b86b-65b8-4a1a-915c-a5acb84a196d#2)
# Other names stay as they are. Per side: a source and a target policy with
# the same name is normal (a tenant compared with itself).
# Returns @{ Names = @{ <PolicyId> = <display name> }; Duplicates = list of
# @{ Name; PolicyId; DisplayName } } for the policies with the same name
# (sorted on name and id).
# ─────────────────────────────────────────────────────────────────────────────
function Get-PolicyDisplayNames {
    param([AllowNull()][AllowEmptyCollection()][array]$Policies)
    $all   = @($Policies | Where-Object { $_ })
    $names = @{}
    $dups  = [System.Collections.Generic.List[object]]::new()

    # Real ids (without "#n") that more than one policy has; not case sensitive.
    $idCount = @{}
    foreach ($p in $all) {
        $real = ([string]$p.PolicyId) -replace '#\d+$', ''
        if ($real) { $idCount[$real] = 1 + [int]$idCount[$real] }
    }

    foreach ($g in ($all | Group-Object { [string]$_.Name } -CaseSensitive)) {
        $sameName = $g.Count -gt 1
        foreach ($p in ($g.Group | Sort-Object { [string]$_.PolicyId })) {
            $id       = [string]$p.PolicyId
            $sharedId = $idCount[($id -replace '#\d+$', '')] -gt 1
            $dn       = if ($sameName -or $sharedId) { "$($p.Name) ($id)" } else { [string]$p.Name }
            $names[$id] = $dn
            if ($sameName) { $dups.Add([PSCustomObject]@{ Name = [string]$p.Name; PolicyId = $id; DisplayName = $dn }) }
        }
    }
    return @{ Names = $names; Duplicates = $dups }
}

# ─────────────────────────────────────────────────────────────────────────────
# SKIPPED SETTINGS
# The settings of an unknown setting type (Invoke-BaselineCompare result
# SkippedSettings), for compare.log. Nothing when there are none.
#   Skipped settings (unknown setting type, not compared):
#     source policy 'Baseline - Windows': <id> (#microsoft.graph...Instance)
# ─────────────────────────────────────────────────────────────────────────────
function Format-SkippedSettingList {
    param([AllowNull()][AllowEmptyCollection()][array]$SkippedSettings)
    $list = @($SkippedSettings | Where-Object { $_ })
    if ($list.Count -eq 0) { return }
    'Skipped settings (unknown setting type, not compared):'
    foreach ($k in $list) {
        "  $("$($k.Side)".ToLower()) policy '$($k.PolicyName)': $($k.DefinitionId) ($($k.Type))"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# COMPARED POLICIES
# The compared policies, for the end of compare.log (too long for the view):
#   Source policies (2):
#     Baseline - macOS (macOS)
#     Baseline - Windows (Windows)
#
#   Target policies (0):
# Sorted on name; the platform in brackets when known.
# ─────────────────────────────────────────────────────────────────────────────
function Format-ComparedPolicyList {
    param(
        [AllowNull()][AllowEmptyCollection()][array]$SourcePolicies,
        [AllowNull()][AllowEmptyCollection()][array]$TargetPolicies
    )
    foreach ($side in @(@('Source', $SourcePolicies), @('Target', $TargetPolicies))) {
        if ($side[0] -eq 'Target') { '' }   # an empty line between the two lists
        # The names as in the report (same name or id: with the id).
        $names = (Get-PolicyDisplayNames -Policies $side[1]).Names
        $list  = @($side[1] | Where-Object { $_ } | ForEach-Object {
                     [PSCustomObject]@{ Policy = $_; Shown = [string]$names[[string]$_.PolicyId] }
                 } | Sort-Object Shown)
        "$($side[0]) policies ($($list.Count)):"
        foreach ($e in $list) {
            $p    = $e.Policy
            $pv   = if ($p.PSObject.Properties['Platforms']) { $p.Platforms } else { $null }
            $pk   = [string](Get-PlatformKey $pv)
            $plat = if ($pk) { " ($(Get-PlatformLabel $pk))" } else { '' }
            "  $($e.Shown)$plat"
        }
    }
}


Export-ModuleMember -Function Compare-RawSettings, Add-IssueColumn, Invoke-BaselineCompare, Get-PolicyDisplayNames,
                              Resolve-DuplicatePolicyIds, Format-SkippedSettingList, Format-SameIdPolicyList,
                              Format-SameNamePolicyList, Format-ComparedPolicyList
