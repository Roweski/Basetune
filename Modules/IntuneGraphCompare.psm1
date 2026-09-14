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
        [array]$Diff
    )

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
# Single entry point for the full compare pipeline — used by both
# CLI and GUI runspace.
# Keeping the logic here means bugfixes only need to happen in one place.
#
# Steps:
#   1. Flatten source + target policies (ConvertTo-SettingObjects)
#   2. Merge collection settings (Merge-CollectionSettings)
#   3. Compare (Compare-RawSettings + Add-IssueColumn)
#   4. Resolve setting names + values (Resolve-DiffForExport + Merge-EnabledWithChildren)
#      — skipped when $bHasDefinitions is $false
#   5. Export diff.csv, overlap.csv, summary.csv, report.html to $ExportPath
#   6. Flush category cache if dirty
#
# Input:
#   SourcePolicies   — array of policy objects (PolicyId, Name, Settings)
#   TargetPolicies   — array of policy objects
#   ExportPath       — output folder (must exist)
#   bHasDefinitions  — whether setting definitions are available for name resolution
#
# Output: none (side-effects: files written to ExportPath)
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-BaselineCompare {
    param(
        [Parameter(Mandatory)]
        [array]$SourcePolicies,

        [Parameter(Mandatory)]
        [array]$TargetPolicies,

        [Parameter(Mandatory)]
        [string]$ExportPath,

        # If provided, HTML is written to this specific file path (for timestamped reports).
        # If omitted, falls back to "$ExportPath\report.html" for backwards compatibility.
        [string]$ReportFile = "",

        [bool]$bHasDefinitions = $false,

        [string]$SourceLabel = "",
        [string]$TargetLabel = ""
    )

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

    # ── 3. Compare ────────────────────────────────────────────────────────────
    Write-Log "Compare" "Comparing..." "INFO"
    $diff = @(Compare-RawSettings -Source $sourceFlat -Target $targetFlat)
    $diff = @(Add-IssueColumn -Diff $diff)

    # ── 4. Resolve ────────────────────────────────────────────────────────────
    if ($bHasDefinitions) {
        $resolved = Resolve-DiffForExport -Diff $diff
        $resolved = Merge-EnabledWithChildren -Resolved $resolved
    } else {
        Write-Log "Resolve" "Skipped — using raw setting IDs and values" "WARN"
        $resolved = $diff | ForEach-Object {
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
        }
    }

    # ── 5. Export ─────────────────────────────────────────────────────────────
    # DefinitionId is exported so diff.csv is self-contained for
    # downstream tooling. With definitions loaded, Setting holds the
    # friendly path and the raw id would otherwise be lost — keywords
    # such as TamperProtection or LocalAdminPassword only occur in the
    # id, so anything matching on diff.csv would silently miss them.
    $resolved |
        Sort-Object { if ($_.SourcePolicyName) { "0_$($_.SourcePolicyName)" } else { "1_" } }, Setting |
        Select-Object SourcePolicyName, Setting, Status, Issue, SourceValue, TargetPolicyName, TargetValue, DefinitionId |
        Export-Csv "$ExportPath\diff.csv" -NoTypeInformation -Encoding UTF8 -Delimiter ";"
    Write-Log "Done" "Export ready: $ExportPath\diff.csv" "OK"

    Get-OverlapSummary -Rows $resolved |
        Export-Csv "$ExportPath\overlap.csv" -NoTypeInformation -Encoding UTF8 -Delimiter ";"
    Write-Log "Done" "Overlap ready: $ExportPath\overlap.csv" "OK"

    Get-BaselineSummary -Rows $resolved |
        Export-Csv "$ExportPath\summary.csv" -NoTypeInformation -Encoding UTF8 -Delimiter ";"
    Write-Log "Done" "Summary ready: $ExportPath\summary.csv" "OK"

    $htmlOutputPath = if ($ReportFile) { $ReportFile } else { "$ExportPath\report.html" }
    Get-HtmlReport -Rows $resolved -OutputPath $htmlOutputPath -SourceLabel $SourceLabel -TargetLabel $TargetLabel

    # ── 6. Flush category cache ───────────────────────────────────────────────
    if ($global:CategoryCacheDirty -and $global:CategoriesFilePath) {
        try {
            $global:CategoryById.Values | ConvertTo-Json -Depth 10 |
                Out-File $global:CategoriesFilePath -Encoding UTF8
            Write-Log "Categories" "Cache updated: $($global:CategoryById.Count) categories saved." "OK"
        } catch {
            Write-Log "Categories" "Could not update categories cache file. $_" "WARN"
        }
    }
}


Export-ModuleMember -Function Compare-RawSettings, Add-IssueColumn, Invoke-BaselineCompare
