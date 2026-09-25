# ─────────────────────────────────────────────────────────────────────────────
# COMPARE RAW SETTINGS
#
# Compares two flat arrays of SettingObjects (source vs target) and returns
# one result row per source setting / target match combination.
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

    $targetIndex = @{}

    foreach ($t in $Target) {
        if (-not $t.DefinitionId) { continue }

        $key = $t.DefinitionId.ToLower()

        if (-not $targetIndex.ContainsKey($key)) {
            $targetIndex[$key] = [System.Collections.Generic.List[object]]::new()
        }

        $targetIndex[$key].Add($t)
    }

    $sourceKeys = [System.Collections.Generic.HashSet[string]]::new()

    $results = foreach ($s in $Source) {

        if (-not $s.DefinitionId) { continue }

        $key = $s.DefinitionId.ToLower()
        [void]$sourceKeys.Add($key)

        $matched = $targetIndex[$key]

        if (-not $matched) {
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
            }
        }
    }

    # extras — only present in target
    $extra = foreach ($t in $Target) {
        if (-not $t.DefinitionId) { continue }
        if ($sourceKeys.Contains($t.DefinitionId.ToLower())) { continue }

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
#               (Missing / Extra / one Match or one Diff row)
#   Duplicate — the setting appears more than once in the target,
#               and all target values are identical
#   Conflict  — the setting appears more than once in the target,
#               but the target values differ from each other
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

    # Group by DefinitionId — only rows with a target match are considered.
    # Missing rows (TargetPolicyId = $null) and Extra rows (SourcePolicyId = $null)
    # can never produce a Duplicate or Conflict by definition.
    $issueMap = @{}

    $matchedRows = $Diff | Where-Object {
        $_.SourcePolicyId -and $_.TargetPolicyId
    }

    $grouped = $matchedRows | Group-Object -Property { $_.DefinitionId.ToLower() }

foreach ($g in $grouped) {
    # Deduplicate by TargetPolicyId — N source policies pointing to the
    # same single target policy must NOT count as Duplicate/Conflict.
    $uniqueTargets = @($g.Group | Sort-Object -Property TargetPolicyId -Unique)

    if ($uniqueTargets.Count -le 1) {
        # Only one distinct target policy — no issue
        $issueMap[$g.Name] = "None"
    } else {
        # More than one distinct target policy carries this setting
        $distinctValues = $uniqueTargets | ForEach-Object { $_.TargetValue } | Sort-Object -Unique
        if ($distinctValues.Count -eq 1) {
            $issueMap[$g.Name] = "Duplicate"
        } else {
            $issueMap[$g.Name] = "Conflict"
        }
    }
}

    # Return each row with the Issue column added
    foreach ($d in $Diff) {
        $key   = if ($d.DefinitionId) { $d.DefinitionId.ToLower() } else { $null }
        $issue = if ($key -and $issueMap.ContainsKey($key)) { $issueMap[$key] } else { "None" }

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
        }
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# INVOKE BASELINE COMPARE
#
# Single entry point for the full compare pipeline — used by BOTH the CLI and
# the UI compare runspace. Bugfixes happen in one place only.
#
# Steps:
#   0. Wire the compare context (definition lookup, categories, connection)
#      into the globals the resolve functions read
#   1. Flatten source + target policies (ConvertTo-SettingObjects)
#   2. Merge collection settings (Merge-CollectionSettings)
#   3. Compare (Compare-RawSettings + Add-IssueColumn)
#   4. Resolve setting names + values (Resolve-DiffForExport + Merge-EnabledWithChildren)
#      — skipped when no definition lookup is available
#   5. Export diff.csv, overlap.csv, summary.csv, report.html to $ExportPath
#   6. Flush the category cache if new categories were fetched from the API
#
# Input:
#   SourcePolicies     — policy objects (PolicyId, Name, Settings). May be empty.
#   TargetPolicies     — policy objects. May be empty.
#   ExportPath         — output folder (must exist)
#   ReportFile         — HTML file path; default "$ExportPath\report.html"
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
        [string]$TargetLabel = ""
    )

    $SourcePolicies = @($SourcePolicies | Where-Object { $_ })
    $TargetPolicies = @($TargetPolicies | Where-Object { $_ })

    if ($SourcePolicies.Count -eq 0) {
        Write-Log "Compare" "No source policies to compare. Check the source filter or selection." "ERROR"
        return [PSCustomObject]@{ Success = $false; RowCount = 0; ReportFile = $null }
    }
    if ($TargetPolicies.Count -eq 0) {
        Write-Log "Compare" "No target policies loaded. Every baseline setting will be reported as Missing." "WARN"
    }

    # ── 0. Compare context ──────────────────────────────────────────────────
    # The resolve functions (Get-SettingPath, Resolve-Category, ...) read these
    # globals. Set them here so every caller gets identical behaviour.
    $bHasDefinitions = ($null -ne $DefinitionLookup -and $DefinitionLookup.Count -gt 0)
    $bHasCategories  = ($null -ne $CategoryById -and $CategoryById.Count -gt 0)

    $global:SettingDefinitionLookup = if ($bHasDefinitions) { $DefinitionLookup } else { @{} }
    # Clone: the UI passes its session cache in by reference. Placeholders
    # for categories that failed to resolve must not end up in that cache,
    # otherwise they stay unresolved for the rest of the session.
    $global:CategoryById            = if ($bHasCategories)  { $CategoryById.Clone() } else { @{} }
    $global:bHasCategories          = $bHasCategories
    $global:CategoriesFilePath      = $CategoriesFilePath
    $global:CategoryPathCache       = @{}
    $global:CategoryCacheDirty      = $false
    $global:GraphConnection         = $Connection

    # ── 1+2. Flatten + merge collections ─────────────────────────────────────
    Write-Log "Compare" "Flattening $($SourcePolicies.Count) source policies..." "INFO"
    $sourceFlat = @(foreach ($p in $SourcePolicies) {
        if ($p.Settings) { ConvertTo-SettingObjects -Policy $p -Source 'Source' }
    })
    $sourceFlat = @(Merge-CollectionSettings -Settings $sourceFlat)

    Write-Log "Compare" "Flattening $($TargetPolicies.Count) target policies..." "INFO"
    $targetFlat = @(foreach ($p in $TargetPolicies) {
        if ($p.Settings) { ConvertTo-SettingObjects -Policy $p -Source 'Target' }
    })
    $targetFlat = @(Merge-CollectionSettings -Settings $targetFlat)

    if ($sourceFlat.Count -eq 0) {
        Write-Log "Compare" "The selected source policies contain no settings." "WARN"
    }

    # ── 3. Compare ────────────────────────────────────────────────────────────
    Write-Log "Compare" "Comparing..." "INFO"
    $diff = @(Compare-RawSettings -Source $sourceFlat -Target $targetFlat)
    $diff = @(Add-IssueColumn -Diff $diff)

    # ── 4. Resolve ────────────────────────────────────────────────────────────
    if ($bHasDefinitions) {
        $resolved = @(Resolve-DiffForExport -Diff $diff)
        $resolved = @(Merge-EnabledWithChildren -Resolved $resolved)
    } else {
        Write-Log "Resolve" "No setting definitions — using raw setting IDs and values" "WARN"
        $resolved = @($diff | ForEach-Object {
            [PSCustomObject]@{
                DefinitionId     = $_.DefinitionId
                Setting          = $_.DefinitionId
                Status           = $_.Status
                Issue            = $_.Issue
                SourcePolicyName = $_.SourcePolicyName
                TargetPolicyName = $_.TargetPolicyName
                SourceValue      = $_.SourceValue
                TargetValue      = $_.TargetValue
            }
        })
    }
    Write-Log "Compare" "Compared: $($resolved.Count) result rows." "OK"

    # ── 5. Export ─────────────────────────────────────────────────────────────
    # DefinitionId is exported so diff.csv is self-contained for
    # downstream tooling. With definitions loaded, Setting holds the
    # friendly path and the raw id would otherwise be lost — keywords
    # such as TamperProtection or LocalAdminPassword only occur in the
    # id, so anything matching on diff.csv would silently miss them.
    #
    # utf8BOM: Excel only recognises UTF-8 in a semicolon CSV when the file
    # starts with a BOM. Without it, accented characters in policy names and
    # values are shown garbled.
    $diffCsv    = Join-Path $ExportPath 'diff.csv'
    $overlapCsv = Join-Path $ExportPath 'overlap.csv'
    $summaryCsv = Join-Path $ExportPath 'summary.csv'

    $resolved |
        Sort-Object { if ($_.SourcePolicyName) { "0_$($_.SourcePolicyName)" } else { "1_" } }, Setting |
        Select-Object SourcePolicyName, Setting, Status, Issue, SourceValue, TargetPolicyName, TargetValue, DefinitionId |
        Export-Csv $diffCsv -NoTypeInformation -Encoding utf8BOM -Delimiter ";"
    Write-Log "Done" "Export ready: $diffCsv" "OK"

    Get-OverlapSummary -Rows $resolved |
        Export-Csv $overlapCsv -NoTypeInformation -Encoding utf8BOM -Delimiter ";"
    Write-Log "Done" "Overlap ready: $overlapCsv" "OK"

    Get-BaselineSummary -Rows $resolved |
        Export-Csv $summaryCsv -NoTypeInformation -Encoding utf8BOM -Delimiter ";"
    Write-Log "Done" "Summary ready: $summaryCsv" "OK"

    $htmlOutputPath = if ($ReportFile) { $ReportFile } else { Join-Path $ExportPath 'report.html' }
    Get-HtmlReport -Rows $resolved -OutputPath $htmlOutputPath -SourceLabel $SourceLabel -TargetLabel $TargetLabel

    # Give categories fetched from the API during this run back to the caller's
    # table (the UI session cache), so the next compare in the same session
    # does not fetch them again. Placeholders stay out.
    if ($null -ne $CategoryById -and $global:CategoryCacheDirty) {
        foreach ($k in @($global:CategoryById.Keys)) {
            $c = $global:CategoryById[$k]
            if (-not $CategoryById.ContainsKey($k) -and -not $c.PSObject.Properties['__placeholder'] -and
                $c.displayName -ne '[Unresolved Category]') {
                $CategoryById[$k] = $c
            }
        }
    }

    # ── 6. Flush category cache ───────────────────────────────────────────────
    # Placeholders ("[Unresolved Category]") are session-only and never
    # written: a temporary API failure must not become permanent on disk.
    if ($global:CategoryCacheDirty -and $global:CategoriesFilePath) {
        try {
            $toSave = @($global:CategoryById.Values | Where-Object {
                -not $_.PSObject.Properties['__placeholder'] -and $_.displayName -ne '[Unresolved Category]'
            })
            $tmp    = "$($global:CategoriesFilePath).tmp"
            $toSave | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $tmp -Encoding UTF8
            Move-Item -LiteralPath $tmp -Destination $global:CategoriesFilePath -Force
            Write-Log "Categories" "Cache updated: $($toSave.Count) categories saved." "OK"
        } catch {
            Write-Log "Categories" "Could not update categories cache file. $($_.Exception.Message)" "WARN"
        }
    }

    return [PSCustomObject]@{ Success = $true; RowCount = $resolved.Count; ReportFile = $htmlOutputPath }
}


Export-ModuleMember -Function Compare-RawSettings, Add-IssueColumn, Invoke-BaselineCompare
