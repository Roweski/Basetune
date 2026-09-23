# =============================================================================
# IntuneGraphPolicies.psm1
# Canonical SettingObject, raw extraction, category resolution, resolve
# =============================================================================
# ─────────────────────────────────────────────────────────────────────────────
# CANONICAL SETTING STRUCTURE
# From the moment of expand — one structure throughout the entire pipeline
#
# SettingObject = @{
#     PolicyId           = <string>
#     PolicyName         = <string>
#     DefinitionId       = <string>
#     ParentDefinitionId = <string|null>   # only set when child has no displayName
#     RawValue           = <string>
#     Source             = "Source" | "Target"
# }
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# COLLECTION INSTANCE KEYS
#
# Some setting collections hold several independent instances under one
# templated definition, e.g. firewall rules:
#     vendor_msft_firewall_mdmstore_firewallrules_{firewallrulename}_protocol
# Without a key, every rule in every policy shares that DefinitionId: rules of
# one policy are joined into "17 | 6", and different rules in different
# policies are reported as a Conflict on the "same" setting.
#
# The instance name is appended to the DefinitionId as "baseId@@instanceKey".
# Nested instances append further keys, outermost first:
#     baseId@@outerKey@@innerKey
# Resolve-RawValue and Get-SettingPath strip the keys before looking up the
# definition; Get-SettingPath shows them as path segments.
# ─────────────────────────────────────────────────────────────────────────────
$script:InstanceKeySeparator = '@@'

function Get-CollectionInstanceKey {
    param(
        [string]$CollectionDefinitionId,
        $Group
    )
    if (-not $CollectionDefinitionId -or -not $Group) { return $null }
    $nameId = ($CollectionDefinitionId + '_name').ToLowerInvariant()
    $nameChild = $Group.children | Where-Object {
        $_.settingDefinitionId -and $_.settingDefinitionId.ToLowerInvariant() -eq $nameId
    } | Select-Object -First 1
    if (-not $nameChild -or -not $nameChild.simpleSettingValue) { return $null }
    $value = "$($nameChild.simpleSettingValue.value)".Trim()
    if (-not $value) { return $null }
    # The separator must never occur inside a key.
    return $value.Replace($script:InstanceKeySeparator, '@')
}

function Add-InstanceKey {
    param(
        [string]$DefinitionId,
        [string]$InstanceKey
    )
    $sep = $script:InstanceKeySeparator
    $i = $DefinitionId.IndexOf($sep)
    if ($i -lt 0) { return $DefinitionId + $sep + $InstanceKey }
    # Called from the outer collection after the inner one already added its
    # key: insert this (outer) key first so the order reads outer -> inner.
    return $DefinitionId.Substring(0, $i) + $sep + $InstanceKey + $DefinitionId.Substring($i)
}

function Split-InstanceKey {
    param([string]$DefinitionId)
    $sep = $script:InstanceKeySeparator
    if (-not $DefinitionId) { return [PSCustomObject]@{ BaseId = $DefinitionId; Keys = @() } }
    $i = $DefinitionId.IndexOf($sep)
    if ($i -lt 0) { return [PSCustomObject]@{ BaseId = $DefinitionId; Keys = @() } }
    $keys = @($DefinitionId.Substring($i + $sep.Length) -split [regex]::Escape($sep) | Where-Object { $_ })
    return [PSCustomObject]@{ BaseId = $DefinitionId.Substring(0, $i); Keys = $keys }
}

function Get-RawSettings {
    param(
        [Parameter(Mandatory)]
        $Instance,
        [string]$ParentDefinitionId = $null
    )
    # Pure raw extraction — no definition lookup, no path building, no value resolution.
    # ParentDefinitionId is passed so Resolve-DiffForExport can use the parent displayName
    # when a child has no displayName of its own (e.g. _l_empty pattern).
    if (-not $Instance) { return }

    $defId = $Instance.settingDefinitionId

    if (-not $defId) { return }

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    $type    = $Instance.'@odata.type'
    switch -Wildcard ($type) {
        '*ChoiceSettingInstance' {
            if ($null -ne $Instance.choiceSettingValue.value) {
                $results.Add([PSCustomObject]@{
                    DefinitionId       = $defId
                    ParentDefinitionId = $ParentDefinitionId
                    RawValue           = $Instance.choiceSettingValue.value
                })
            }
            foreach ($child in $Instance.choiceSettingValue.children) {
                foreach ($r in (Get-RawSettings -Instance $child -ParentDefinitionId $defId)) {
                    $results.Add($r)
                }
            }
        }
        '*SimpleSettingInstance' {
            if ($null -ne $Instance.simpleSettingValue.value) {
                $results.Add([PSCustomObject]@{
                    DefinitionId       = $defId
                    ParentDefinitionId = $ParentDefinitionId
                    RawValue           = "$($Instance.simpleSettingValue.value)"
                })
            }
        }
        '*GroupSettingInstance' {
            foreach ($child in $Instance.groupSettingValue.children) {
                foreach ($r in (Get-RawSettings -Instance $child -ParentDefinitionId $defId)) {
                    $results.Add($r)
                }
            }
        }
        '*GroupSettingCollectionInstance' {
            foreach ($group in $Instance.groupSettingCollectionValue) {
                # Detect key/value pattern
                # Example: hardeneduncpaths_key + hardeneduncpaths_value
                # The key is appended to the DefinitionId so that each
                # key/value combination gets a unique row in the output.
                # Setting path becomes: ...Hardened UNC Paths > \\*\NETLOGON
                # RawValue becomes:     RequireMutualAuthentication=1,RequireIntegrity=1
                $keyChild   = $group.children | Where-Object { $_.settingDefinitionId -match '_key$'   } | Select-Object -First 1
                $valueChild = $group.children | Where-Object { $_.settingDefinitionId -match '_value$' } | Select-Object -First 1
                if ($keyChild -and $valueChild) {
                    $keyVal = if ($keyChild.simpleSettingValue)     { "$($keyChild.simpleSettingValue.value)"  }
                              elseif ($keyChild.choiceSettingValue) { $keyChild.choiceSettingValue.value }
                              else { $null }
                    $valVal = if ($valueChild.simpleSettingValue)     { "$($valueChild.simpleSettingValue.value)"  }
                              elseif ($valueChild.choiceSettingValue) { $valueChild.choiceSettingValue.value }
                              else { $null }
                    if ($keyVal -and $valVal) {
                        # Extend DefinitionId with the key — unique row per key
                        # Format: "realDefinitionId||keyVal"
                        $results.Add([PSCustomObject]@{
                            DefinitionId       = "$defId||$keyVal"
                            ParentDefinitionId = $defId
                            RawValue           = $valVal
                        })
                    }
                    # Process remaining children (non key/value) normally
                    foreach ($child in $group.children) {
                        if ($child.settingDefinitionId -match '_key$' -or
                            $child.settingDefinitionId -match '_value$') { continue }
                        foreach ($r in (Get-RawSettings -Instance $child -ParentDefinitionId $defId)) {
                            $results.Add($r)
                        }
                    }
                } else {
                    # No key/value pattern. When the instance names itself
                    # through a "<collection>_name" child (firewall rules), that
                    # name becomes part of every DefinitionId below it, so each
                    # instance is compared on its own instead of all instances
                    # sharing one templated DefinitionId.
                    $instanceKey = Get-CollectionInstanceKey -CollectionDefinitionId $defId -Group $group
                    foreach ($child in $group.children) {
                        foreach ($r in (Get-RawSettings -Instance $child -ParentDefinitionId $defId)) {
                            if ($instanceKey) {
                                $r.DefinitionId = Add-InstanceKey -DefinitionId $r.DefinitionId -InstanceKey $instanceKey
                                if ($r.ParentDefinitionId) {
                                    $r.ParentDefinitionId = Add-InstanceKey -DefinitionId $r.ParentDefinitionId -InstanceKey $instanceKey
                                }
                            }
                            $results.Add($r)
                        }
                    }
                }
            }
        }
        '*SimpleSettingCollectionInstance' {
            foreach ($item in $Instance.simpleSettingCollectionValue) {
                $results.Add([PSCustomObject]@{
                    DefinitionId       = $defId
                    ParentDefinitionId = $ParentDefinitionId
                    RawValue           = "$($item.value)"
                })
            }
        }
    }
    return $results
}


# ─────────────────────────────────────────────────────────────────────────────
# CANONICAL FLATTEN → SettingObjects
# ─────────────────────────────────────────────────────────────────────────────

function ConvertTo-SettingObjects {
    param(
        [Parameter(Mandatory)]$Policy,
        [Parameter(Mandatory)]
        [ValidateSet("Source","Target")]
        [string]$Source
    )
    foreach ($s in $Policy.Settings) {
        if (-not $s.settingInstance) { continue }
        $rawSettings = Get-RawSettings -Instance $s.settingInstance
        foreach ($r in $rawSettings) {
            [PSCustomObject]@{
                PolicyId           = $Policy.PolicyId
                PolicyName         = $Policy.Name
                DefinitionId       = $r.DefinitionId
                ParentDefinitionId = $r.ParentDefinitionId
                RawValue           = $r.RawValue
                Source             = $Source
            }
        }
    }
}



# ─────────────────────────────────────────────────────────────────────────────
# CATEGORY RESOLUTION
# ─────────────────────────────────────────────────────────────────────────────
function Resolve-Category {
    param(
        [string]$CategoryId,
        $Connection = $null
    )
    if (-not $CategoryId -or $CategoryId -eq "00000000-0000-0000-0000-000000000000") {
        return $null
    }
    if ($global:CategoryById.ContainsKey($CategoryId)) {
        return $global:CategoryById[$CategoryId]
    }
    if (-not $Connection) {
        $Connection = $global:GraphConnection
    }
    # Skip entirely if no categories file loaded — API is only a fallback for unknown entries
    if (-not $global:bHasCategories) {
        return $null
    }
    if ($Connection) {
        try {
            $uri      = "https://graph.microsoft.com/beta/deviceManagement/configurationCategories/$CategoryId"
            $category = Invoke-IntuneGraphRequest -Connection $Connection -Uri $uri -ErrorAction Stop
            if ($category) {
                if (-not $global:CategoryById.ContainsKey($CategoryId)) {
                    $global:CategoryById[$CategoryId] = $category
                    # Mark cache as dirty — file will be written once at end of run
                    $global:CategoryCacheDirty = $true
                }
                Write-Log "Categories" "Fetched from API: $($category.displayName)." "INFO"
                return $global:CategoryById[$CategoryId]
            }
        }
        catch {
            Write-Log "Categories" "API call failed for category '$CategoryId'. $_" "WARN"
        }
    }
    $placeholder = [PSCustomObject]@{
        id               = $CategoryId
        displayName      = "[Unresolved Category]"
        parentCategoryId = $null
    }
    if (-not $global:CategoryById.ContainsKey($CategoryId)) {
        $global:CategoryById[$CategoryId] = $placeholder
    }
    return $global:CategoryById[$CategoryId]
}


function Get-CategoryPath {
    param(
        [string]$CategoryId,
        $Connection = $null
    )
    if (-not $CategoryId -or $CategoryId -eq "00000000-0000-0000-0000-000000000000") {
        return $null
    }
    # If no categories file was loaded, skip all lookups and API calls entirely
    if (-not $global:bHasCategories) {
        return $null
    }
    if (-not $Connection) {
        $Connection = $global:GraphConnection
    }
    if (-not $global:CategoryPathCache) { $global:CategoryPathCache = @{} }
    if ($global:CategoryPathCache.ContainsKey($CategoryId)) {
        return $global:CategoryPathCache[$CategoryId]
    }
    $parts     = [System.Collections.Generic.List[string]]::new()
    $currentId = $CategoryId
    $visited   = [System.Collections.Generic.HashSet[string]]::new()
    while ($currentId -and $currentId -ne "00000000-0000-0000-0000-000000000000") {
        if (-not $visited.Add($currentId)) {
            Write-Log "Categories" "Circular reference detected at '$currentId'." "WARN"
            break
        }
        if ($global:CategoryPathCache.ContainsKey($currentId)) {
            $cached = $global:CategoryPathCache[$currentId]
            if ($cached) {
                $parts.Insert(0, $cached)
            }
            break
        }
        $cat = Resolve-Category -CategoryId $currentId -Connection $Connection
        if (-not $cat) { break }
        if ($cat.displayName) { $parts.Insert(0, $cat.displayName) }
        $currentId = if ($cat.parentCategoryId -and
                        $cat.parentCategoryId -ne "00000000-0000-0000-0000-000000000000") {
            $cat.parentCategoryId
        } else { $null }
    }
    $fullPath = if ($parts.Count -gt 0) { $parts -join " > " } else { $null }
    # Only cache the requested CategoryId — no sub-caching of intermediate IDs
    $global:CategoryPathCache[$CategoryId] = $fullPath
    return $fullPath
}


# ─────────────────────────────────────────────────────────────────────────────
# VALUE RESOLUTION
# ─────────────────────────────────────────────────────────────────────────────
function Resolve-RawValue {
    param(
        [string]$DefinitionId,
        [string]$RawValue
    )
    # Instance keys (firewall rule names) are not part of the definition id.
    $DefinitionId = (Split-InstanceKey -DefinitionId $DefinitionId).BaseId

    # Key/value DefinitionIds contain '||' — they do not need to be resolved via options
    if ($DefinitionId -match '\|\|') { return $RawValue }

    # Collection values are joined with '|' by Merge-CollectionSettings.
    # Resolve each part individually and rejoin.
    if ($RawValue -match '\|') {
        $parts = $RawValue -split '\|'
        $key   = $DefinitionId.Trim().ToLowerInvariant()
        $def   = $global:SettingDefinitionLookup[$key]
        $resolved = $parts | ForEach-Object {
            # $partValue is required: inside the nested Where-Object below, $_
            # rebinds to the option object, so the original `$_.itemId -eq $_`
            # compared an option against itself and never matched -- collection
            # values were always rendered as raw itemIds.
            $partValue = $_
            if ($def -and $def.options) {
                $match = $def.options | Where-Object { $_.itemId -eq $partValue } | Select-Object -First 1
                if ($match) { $match.displayName } else { $partValue }
            } else { $partValue }
        }
        return $resolved -join " | "
    }

    $key = $DefinitionId.Trim().ToLowerInvariant()
    $def = $global:SettingDefinitionLookup[$key]
    if (-not $def) { return $RawValue }
    if ($def.options) {
        $match = $def.options | Where-Object { $_.itemId -eq $RawValue } | Select-Object -First 1
        if ($match) { return $match.displayName }
    }
    return $RawValue
}


# ─────────────────────────────────────────────────────────────────────────────
# HELPER: build setting path from a DefinitionId
# ─────────────────────────────────────────────────────────────────────────────

function Get-SettingPath {
    param(
        [string]$DefinitionId,
        $Connection = $null
    )
    # Key/value DefinitionIds use the format "realDefinitionId||keyVal"
    # The key is appended as an extra path segment at the end
    # Instance keys ("baseId@@ruleName") are shown as path segments, never
    # looked up as part of the definition id.
    $split        = Split-InstanceKey -DefinitionId $DefinitionId
    $instanceKeys = @($split.Keys)
    $DefinitionId = $split.BaseId

    $keySegment = $null
    $lookupId   = $DefinitionId
    if ($DefinitionId -match '^(.+)\|\|(.+)$') {
        $lookupId   = $Matches[1]
        $keySegment = $Matches[2]
    }

    $key = $lookupId.Trim().ToLowerInvariant()
    $def = $global:SettingDefinitionLookup[$key]
    # Graph sometimes returns a sub-element whose displayName is simply a copy
    # of its internal ADMX element name, e.g.
    #     "name":        "OSRecoveryKeyUsageDropDown_Name"
    #     "displayName": "OSRecoveryKeyUsageDropDown_Name"
    # That is not a label. Two things go wrong if it is treated as one: an
    # internal identifier ends up in the customer report, and — because the
    # child now has a name of its own — it no longer inherits the parent path,
    # so Merge-EnabledWithChildren stops merging it into "Enabled: <value>".
    #
    # Only sub-elements are affected (rootDefinitionId pointing at another
    # definition). A top-level setting keeps its displayName even when it
    # happens to equal its name, so its own path segment is never lost.
    $settingName = $null
    if ($def -and $def.displayName -and $def.displayName.Trim() -ne "") {
        $displayName = $def.displayName.Trim()
        $internalName = if ($def.PSObject.Properties['name'] -and $def.name) { $def.name.Trim() } else { $null }
        $isSubElement = ($def.PSObject.Properties['rootDefinitionId'] -and $def.rootDefinitionId -and
                         $def.rootDefinitionId.Trim().ToLowerInvariant() -ne $key)

        # Inside a keyed instance (firewall rule) plain labels such as
        # "Enabled" or "Protocol" legitimately equal their internal name; only
        # ADMX-style identifiers ("..._Name") are placeholders there.
        $isPlaceholder = $isSubElement -and $internalName -and $displayName -eq $internalName -and
                         -not ($instanceKeys.Count -gt 0 -and $internalName -notmatch '_')
        if ($isPlaceholder) {
            $settingName = $null      # placeholder label -> fall back to parent
        } else {
            $settingName = $displayName
        }
    }
    $pathParts = [System.Collections.Generic.List[string]]::new()
    if ($def -and $def.categoryId -and $global:SettingDefinitionLookup.Count -gt 0) {
        $categoryPath = Get-CategoryPath -CategoryId $def.categoryId -Connection $Connection
        if ($categoryPath) {
            foreach ($part in ($categoryPath -split " > ")) {
                $trimmed = $part.Trim()
                if ($trimmed) { $pathParts.Add($trimmed) }
            }
        }
    }
    # Keyed instance without a usable label: derive one from the id suffix
    # ("..._{firewallrulename}_protocol" -> "Protocol") so every field of a
    # rule gets its own row instead of collapsing onto the parent path.
    if (-not $settingName -and $instanceKeys.Count -gt 0 -and $def -and
        $def.PSObject.Properties['rootDefinitionId'] -and $def.rootDefinitionId -and
        $def.rootDefinitionId.Trim().ToLowerInvariant() -ne $key) {
        $suffix = ($lookupId -split '_')[-1]
        if ($suffix -and $suffix -notmatch '[{}]') {
            $settingName = [System.Globalization.CultureInfo]::InvariantCulture.TextInfo.ToTitleCase($suffix.ToLowerInvariant())
        }
    }
    # Root group intermediate layer — only when child of another setting
    $rootIndex = -1
    if ($def -and $def.rootDefinitionId) {
        $rootKey = $def.rootDefinitionId.Trim().ToLowerInvariant()
        if ($rootKey -ne $key) {
            $rootDef = $global:SettingDefinitionLookup[$rootKey]
            if ($rootDef -and $rootDef.displayName -and $rootDef.displayName.Trim() -ne "") {
                $rootName = $rootDef.displayName.Trim()
                if ($pathParts.Count -eq 0 -or $pathParts[$pathParts.Count - 1] -ne $rootName) {
                    $pathParts.Add($rootName)
                }
                $rootIndex = $pathParts.Count - 1
            }
        }
    }
    if ($settingName -and ($pathParts.Count -eq 0 -or $pathParts[$pathParts.Count - 1] -ne $settingName)) {
        $pathParts.Add($settingName)
    }
    # Append key segment as the last path part
    if ($keySegment -and ($pathParts.Count -eq 0 -or $pathParts[$pathParts.Count - 1] -ne $keySegment)) {
        $pathParts.Add($keySegment)
    }
    # Instance keys go right after the collection (root) segment:
    #   Firewall > Firewall Rule Name > WMI_INBOUND > Protocol
    # For the collection itself (no root layer) they are appended.
    if ($instanceKeys.Count -gt 0) {
        $insertAt = if ($rootIndex -ge 0) { $rootIndex + 1 } else { $pathParts.Count }
        foreach ($ik in $instanceKeys) {
            $pathParts.Insert($insertAt, $ik)
            $insertAt++
        }
    }

    return [PSCustomObject]@{
        PathParts   = $pathParts
        SettingName = if ($keySegment) { $keySegment } else { $settingName }
        Def         = $def
    }
    
}
# ─────────────────────────────────────────────────────────────────────────────
# DIFF RESOLVE FOR EXPORT
# ─────────────────────────────────────────────────────────────────────────────
function Resolve-DiffForExport {
    param(
        [Parameter(Mandatory)]
        [array]$Diff,
        $Connection = $null
    )
    foreach ($d in $Diff) {
        $resolved = Get-SettingPath -DefinitionId $d.DefinitionId -Connection $Connection
        # No displayName — try to use parent
        if (-not $resolved.SettingName) {
            if ($d.ParentDefinitionId) {
                $parentResolved = Get-SettingPath -DefinitionId $d.ParentDefinitionId -Connection $Connection
                if ($parentResolved.SettingName) {
                    $fullSetting = $parentResolved.PathParts -join " > "
                } else {
                    $fullSetting = $d.DefinitionId
                }
            } else {
                $fullSetting = $d.DefinitionId
            }
            $resolvedSource = if ($d.SourceValue) {
                Resolve-RawValue -DefinitionId $d.DefinitionId -RawValue $d.SourceValue
            } else { $null }
            $resolvedTarget = if ($d.TargetValue) {
                Resolve-RawValue -DefinitionId $d.DefinitionId -RawValue $d.TargetValue
            } else { $null }
            [PSCustomObject]@{
                DefinitionId     = $d.DefinitionId
                Setting          = $fullSetting
                Status           = $d.Status
                Issue            = $d.Issue
                SourcePolicyName = $d.SourcePolicyName
                TargetPolicyName = $d.TargetPolicyName
                SourceValue      = $resolvedSource
                TargetValue      = $resolvedTarget
            }
            continue
        }
        $fullSetting = if ($resolved.PathParts.Count -gt 0) {
            $resolved.PathParts -join " > "
        } else {
            $d.DefinitionId
        }
        $resolvedSource = if ($d.SourceValue) {
            Resolve-RawValue -DefinitionId $d.DefinitionId -RawValue $d.SourceValue
        } else { $null }
        $resolvedTarget = if ($d.TargetValue) {
            Resolve-RawValue -DefinitionId $d.DefinitionId -RawValue $d.TargetValue
        } else { $null }
        [PSCustomObject]@{
            DefinitionId     = $d.DefinitionId
            Setting          = $fullSetting
            Status           = $d.Status
            Issue            = $d.Issue
            SourcePolicyName = $d.SourcePolicyName
            TargetPolicyName = $d.TargetPolicyName
            SourceValue      = $resolvedSource
            TargetValue      = $resolvedTarget
        }
    }
}
# ─────────────────────────────────────────────────────────────────────────────
# MERGE ENABLED + CHILDREN → "Enabled: value" / "Disabled"
#
# After Resolve-DiffForExport we have rows like:
#   Setting: VBA Macro Notification Settings   SourceValue: Enabled
#   Setting: VBA Macro Notification Settings   SourceValue: Disable all except digitally signed macros
#
# This function merges them into a single row:
#   Setting: VBA Macro Notification Settings   SourceValue: Enabled: Disable all except digitally signed macros
#
# Rules:
#   - Parent = row whose SourceValue or TargetValue is "enabled" / "true" / "disabled" / "false"
#     AND at least one child exists with the same Setting + same policy combination
#   - If parent is "disabled" / "false" → value becomes "Disabled" (no child expected)
#   - If parent is "enabled" / "true"  → value becomes "Enabled: <child value>"
#   - Rows without an enabled/disabled pattern remain unchanged
# ─────────────────────────────────────────────────────────────────────────────
function Merge-EnabledWithChildren {
    param(
        [Parameter(Mandatory)]
        [array]$Resolved
    )
    $enabledLike  = @('enabled', 'true')
    $disabledLike = @('disabled', 'false')
    $toggleLike   = $enabledLike + $disabledLike
    # --- Align children with every target policy ----------------------------
    # The grouping below keys on TargetPolicyName, so a parent and its child
    # only merge when both carry the same target policy. Two situations break
    # that, and both leave the baseline sub-value stranded:
    #
    #   * The target has the parent Disabled. Intune omits children of a
    #     disabled ADMX parent, so the child has no target policy at all.
    #   * Several target policies configure the setting and only some of them
    #     carry the child. The policies without it keep a bare parent row
    #     rendering as "Enabled", while the policies with it render the full
    #     "Enabled: <value>" -- the same baseline setting shown two ways.
    #
    # The source side of a child does not depend on which target policy it is
    # compared against, so each target policy holding the parent gets a copy of
    # every child, with an empty target value where that policy has none.
    # Settings whose parent is absent from the target entirely are left alone:
    # there is nothing to merge into, and they must stay Missing.
    $aligned = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($sg in ($Resolved | Group-Object -Property Setting, SourcePolicyName)) {
        $sgRows = @($sg.Group)

        $sgParents = @($sgRows | Where-Object {
            ($_.SourceValue -and $_.SourceValue.Trim().ToLower() -in $toggleLike) -or
            ($_.TargetValue -and $_.TargetValue.Trim().ToLower() -in $toggleLike)
        })
        $sgChildren = @($sgRows | Where-Object { $_ -notin $sgParents })

        # Target policies that actually carry the parent toggle.
        $parentTargets = @($sgParents | Where-Object { $_.TargetPolicyName } |
                           ForEach-Object { $_.TargetPolicyName } | Sort-Object -Unique)

        # Alignment copies the SOURCE side of a child to every target policy.
        # Rows without a source policy (Extra) have no source side: grouping on
        # an empty SourcePolicyName lumps every target policy together, so a
        # child held by one policy would be fabricated as an empty "Missing"
        # row for all the others -- which the merge then turns into a false
        # "Diff" showing a bare "Enabled".
        $noSource = -not $sgRows[0].SourcePolicyName
        if ($noSource -or $sgParents.Count -eq 0 -or $sgChildren.Count -eq 0 -or $parentTargets.Count -eq 0) {
            foreach ($r in $sgRows) { $aligned.Add($r) }
            continue
        }

        foreach ($r in $sgParents) { $aligned.Add($r) }

        # One representative per child definition, for its source-side value.
        $childTemplates = @($sgChildren | Group-Object DefinitionId | ForEach-Object { $_.Group[0] })

        foreach ($t in $parentTargets) {
            foreach ($tpl in $childTemplates) {
                $existing = $sgChildren | Where-Object {
                    $_.DefinitionId -eq $tpl.DefinitionId -and $_.TargetPolicyName -eq $t
                } | Select-Object -First 1

                if ($existing) {
                    $aligned.Add($existing)
                } else {
                    $aligned.Add([PSCustomObject]@{
                        DefinitionId     = $tpl.DefinitionId
                        Setting          = $tpl.Setting
                        Status           = 'Missing'
                        Issue            = $tpl.Issue
                        SourcePolicyName = $tpl.SourcePolicyName
                        TargetPolicyName = $t
                        SourceValue      = $tpl.SourceValue
                        TargetValue      = $null
                    })
                }
            }
        }

        # Child rows pointing at a target policy that has no parent toggle are
        # not represented above; keep them so nothing is silently dropped.
        foreach ($c in $sgChildren) {
            if ($c.TargetPolicyName -and $c.TargetPolicyName -notin $parentTargets) { $aligned.Add($c) }
        }
    }
    $Resolved = @($aligned)

    # Group by Setting + SourcePolicyName + TargetPolicyName
    $groups = $Resolved | Group-Object -Property Setting, SourcePolicyName, TargetPolicyName
    $output = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($g in $groups) {
        $rows = @($g.Group)
        if ($rows.Count -eq 1) {
            # Single row — only normalise Enabled/Disabled if there is no child
            $r = $rows[0]
            $sv = if ($r.SourceValue) { $r.SourceValue.Trim().ToLower() } else { $null }
            $tv = if ($r.TargetValue) { $r.TargetValue.Trim().ToLower() } else { $null }
            $newSource = if ($sv -in $enabledLike)      { "Enabled" }
                         elseif ($sv -in $disabledLike) { "Disabled" }
                         else { $r.SourceValue }
            $newTarget = if ($tv -in $enabledLike)      { "Enabled" }
                         elseif ($tv -in $disabledLike) { "Disabled" }
                         else { $r.TargetValue }
            $output.Add([PSCustomObject]@{
                DefinitionId     = $r.DefinitionId
                Setting          = $r.Setting
                Status           = $r.Status
                Issue            = $r.Issue
                SourcePolicyName = $r.SourcePolicyName
                TargetPolicyName = $r.TargetPolicyName
                SourceValue      = $newSource
                TargetValue      = $newTarget
            })
            continue
        }
        # Multiple rows — find the parent (enabled/disabled toggle)
        $parentRows = $rows | Where-Object {
            ($_.SourceValue -and $_.SourceValue.Trim().ToLower() -in $toggleLike) -or
            ($_.TargetValue -and $_.TargetValue.Trim().ToLower() -in $toggleLike)
        }
        $childRows = $rows | Where-Object { $_ -notin $parentRows }
        if (-not $parentRows -or -not $childRows) {
            # No clear parent/child pattern — pass all rows through unchanged
            foreach ($r in $rows) { $output.Add($r) }
            continue
        }
        # Take the first parent (normally there is only one)
        $parent = $parentRows | Select-Object -First 1
        $sv = if ($parent.SourceValue) { $parent.SourceValue.Trim().ToLower() } else { $null }
        $tv = if ($parent.TargetValue) { $parent.TargetValue.Trim().ToLower() } else { $null }
        $sourceEnabled  = $sv -in $enabledLike
        $sourceDisabled = $sv -in $disabledLike
        $targetEnabled  = $tv -in $enabledLike
        $targetDisabled = $tv -in $disabledLike
        foreach ($child in $childRows) {
            # "Enabled: <value>" only when there is a value. A parent that is
            # Enabled while its sub-setting is not configured on that side
            # would otherwise render as a trailing "Enabled: " -- which reads
            # like a blank value rather than "on, sub-setting unset".
            $newSource = if ($sourceEnabled)       { if ($child.SourceValue) { "Enabled: $($child.SourceValue)" } else { "Enabled" } }
                         elseif ($sourceDisabled)  { "Disabled" }
                         else                      { $child.SourceValue }
            $newTarget = if ($targetEnabled)       { if ($child.TargetValue) { "Enabled: $($child.TargetValue)" } else { "Enabled" } }
                         elseif ($targetDisabled)  { "Disabled" }
                         else                      { $child.TargetValue }
            # Re-evaluate Status based on merged values.
            #
            # The previous version fell back to $child.Status when the merged
            # values differed. That produced a FALSE MATCH whenever the parent
            # toggle differed (baseline Enabled / tenant Disabled) while the
            # child value happened to be identical: the child row was "Match",
            # so the merged row inherited "Match" even though the effective
            # configuration clearly differs -- and the parent row carrying the
            # real "Diff" is consumed by this merge.
            #
            # Missing/Extra must survive: a setting absent from the target is
            # not a value difference, and demoting it to "Diff" would hide the
            # fact that it is not configured at all.
            # Missing/Extra only survives when the merged row really has no
            # counterpart. An adopted orphan does get one -- the parent exists
            # in the target, it is simply Disabled -- so that row is a genuine
            # difference, not an absent setting.
            $mergedStatus = if ($newSource -eq $newTarget) {
                                "Match"
                            } elseif ($child.Status -eq 'Missing' -and -not $newTarget) {
                                'Missing'
                            } elseif ($child.Status -eq 'Extra' -and -not $newSource) {
                                'Extra'
                            } else {
                                "Diff"
                            }
            $output.Add([PSCustomObject]@{
                DefinitionId     = $child.DefinitionId
                Setting          = $child.Setting
                Status           = $mergedStatus
                Issue            = $child.Issue
                SourcePolicyName = $child.SourcePolicyName
                TargetPolicyName = $child.TargetPolicyName
                SourceValue      = $newSource
                TargetValue      = $newTarget
            })
        }
        # Remaining parent rows (edge case: multiple parents) pass through unchanged
        foreach ($p in ($parentRows | Select-Object -Skip 1)) {
            $output.Add($p)
        }
    }
    # --- Recompute Issue over the merged rows --------------------------------
    # Add-IssueColumn runs before this merge and keys on DefinitionId, so it
    # judged the parent and the child separately. A parent seen by three target
    # policies as Enabled/Enabled/Disabled was Conflict, while its child, held
    # by only the two Enabled policies with the same value, was Duplicate. The
    # merge keeps the child row -- and with it the stale "Duplicate", even
    # though the merged target values now read
    # "Enabled: <value>" / "Enabled: <value>" / "Disabled".
    #
    # The merged rows are the ones the report and the CSV show, so the issue is
    # derived from their target values here: several target policies with
    # differing values is a Conflict, with identical values a Duplicate.
    $final = @($output)
    foreach ($ig in ($final | Group-Object -Property SourcePolicyName, DefinitionId)) {
        $withTarget = @($ig.Group | Where-Object { $_.TargetPolicyName })
        $policies   = @($withTarget | ForEach-Object { $_.TargetPolicyName } | Sort-Object -Unique)

        $issue = if ($policies.Count -le 1) {
            'None'
        } else {
            $values = @($withTarget | Sort-Object TargetPolicyName -Unique |
                        ForEach-Object { [string]$_.TargetValue } | Sort-Object -Unique)
            if ($values.Count -le 1) { 'Duplicate' } else { 'Conflict' }
        }

        foreach ($r in $ig.Group) { $r.Issue = $issue }
    }

    return $final
}

function Merge-CollectionSettings {
    param(
        [Parameter(Mandatory)]
        [array]$Settings
    )

    # Group by PolicyId + DefinitionId
    $grouped = $Settings | Group-Object -Property PolicyId, DefinitionId

    foreach ($g in $grouped) {
        if ($g.Count -eq 1) {
            # Single row — pass through as-is
            $g.Group[0]
        } else {
            # Multiple rows for the same policy + setting → collection
            # Sort values for deterministic comparison, join with "|"
            $first        = $g.Group[0]
            $sortedValues = ($g.Group | ForEach-Object { $_.RawValue } | Sort-Object) -join "|"

            [PSCustomObject]@{
                PolicyId           = $first.PolicyId
                PolicyName         = $first.PolicyName
                DefinitionId       = $first.DefinitionId
                ParentDefinitionId = $first.ParentDefinitionId
                RawValue           = $sortedValues
                Source             = $first.Source
            }
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# EXPORTS
# ─────────────────────────────────────────────────────────────────────────────
Export-ModuleMember -Function @(
    'Get-RawSettings',
    'ConvertTo-SettingObjects',
    'Merge-CollectionSettings',
    'Resolve-Category',
    'Get-CategoryPath',
    'Get-SettingPath',
    'Resolve-RawValue',
    'Resolve-DiffForExport',
    'Merge-EnabledWithChildren'
)