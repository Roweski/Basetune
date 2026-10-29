# =============================================================================
# BasetunePolicies.psm1
# Canonical SettingObject, raw extraction, category and value resolution,
# merge of collections and Enabled + child settings. Reading and downloading
# settings.json / categories.json: BasetuneDefinitions.psm1.
# =============================================================================
# ─────────────────────────────────────────────────────────────────────────────
# CANONICAL SETTING STRUCTURE
# One structure through the whole pipeline, from expand on
#
# SettingObject = @{
#     PolicyId           = <string>
#     PolicyName         = <string>
#     DefinitionId       = <string>
#     ParentDefinitionId = <string|null>   # set for child settings; used for the
#                                          # path when the child has no displayName
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

# ─────────────────────────────────────────────────────────────────────────────
# RESOLVE CONTEXT
# State of the resolve functions (Get-SettingPath, Resolve-Category, ...) for
# one compare run, in module scope. Invoke-BaselineCompare sets it with
# Initialize-ResolveContext and reads the category results from the returned
# hashtable.
# ─────────────────────────────────────────────────────────────────────────────
function Initialize-ResolveContext {
    param(
        [hashtable]$DefinitionLookup = $null,
        [hashtable]$CategoryById     = $null,
        [string]$CategoriesFilePath  = "",
        $Connection                  = $null
    )
    $hasCategories = ($null -ne $CategoryById -and $CategoryById.Count -gt 0)
    $script:Resolve = @{
        DefinitionLookup       = if ($null -ne $DefinitionLookup -and $DefinitionLookup.Count -gt 0) { $DefinitionLookup } else { @{} }
        # Clone: the UI passes its session cache by reference, and placeholders
        # of unresolved categories must not stay in it for the whole session.
        CategoryById           = if ($hasCategories) { $CategoryById.Clone() } else { @{} }
        HasCategories          = $hasCategories
        CategoriesFilePath     = $CategoriesFilePath
        CategoryPathCache      = @{}
        CategoryCacheDirty     = $false
        CategoryFetchedCount   = 0
        CategoryApiOffline     = $false
        CategoryNoTenantWarned = $false
        Connection             = $Connection
        # Setting instances of a type Get-RawSettings does not know (a new
        # Graph type): not compared, listed by Invoke-BaselineCompare.
        # Get-RawSettings adds DefinitionId and Type, ConvertTo-SettingObjects
        # the policy and side.
        SkippedSettings        = [System.Collections.Generic.List[object]]::new()
    }
    return $script:Resolve
}
[void](Initialize-ResolveContext)

# Collections whose instances have no "<collection>_name" child, with the
# child that tells the instances apart. Without a key, every field is joined
# over all instances on its own and the pairing is lost: Administrators -> Jan
# + Remote Desktop Users -> Piet compared as Match against Administrators ->
# Piet + Remote Desktop Users -> Jan.
$script:CollectionKeyChild = @{
    # Local user group membership: one rule per local group (or set of groups).
    'device_vendor_msft_policy_config_localusersandgroups_configure_groupconfiguration_accessgroup' =
        'device_vendor_msft_policy_config_localusersandgroups_configure_groupconfiguration_accessgroup_desc'
}

function Get-CollectionInstanceKey {
    param(
        [string]$CollectionDefinitionId,
        $Group
    )
    if (-not $CollectionDefinitionId -or -not $Group) { return $null }
    $collectionKey = $CollectionDefinitionId.ToLowerInvariant()
    $keyId = $script:CollectionKeyChild[$collectionKey]
    if (-not $keyId) { $keyId = $collectionKey + '_name' }
    # First matching child (a plain loop: a pipeline per group is slow).
    $keyChild = $null
    foreach ($c in $Group.children) {
        if ($c.settingDefinitionId -and $c.settingDefinitionId.ToLowerInvariant() -eq $keyId) { $keyChild = $c; break }
    }
    if (-not $keyChild) { return $null }
    # A name (simple value), or the option itemIds ticked in a choice
    # (collection), sorted and joined with "+" (Get-SettingPath shows names).
    $value = if ($keyChild.simpleSettingValue) {
                 "$($keyChild.simpleSettingValue.value)".Trim()
             } elseif ($keyChild.choiceSettingCollectionValue) {
                 (@($keyChild.choiceSettingCollectionValue | ForEach-Object { "$($_.value)" } | Where-Object { $_ } | Sort-Object)) -join '+'
             } elseif ($keyChild.choiceSettingValue) {
                 "$($keyChild.choiceSettingValue.value)"
             } else { '' }
    if (-not $value) { return $null }
    # The separator must never occur inside a key.
    return $value.Replace($script:InstanceKeySeparator, '@')
}

# Display text of an instance key: option itemIds (from a choice key child,
# "<definitionId>_<option>") become their display name, several joined with
# " + ". Anything else (a firewall rule name) is shown as it is.
function script:Get-InstanceKeyLabel {
    param([string]$Key)
    $lookup = $script:Resolve.DefinitionLookup
    if (-not $lookup -or $lookup.Count -eq 0 -or $Key -notmatch '_') { return $Key }
    $anyResolved = $false
    $labels = foreach ($part in ($Key -split '\+')) {
        $label = $part
        $i = $part.LastIndexOf('_')
        if ($i -gt 0) {
            $def = $lookup[$part.Substring(0, $i).ToLowerInvariant()]
            $opt = if ($def) { Find-DefinitionOption $def $part } else { $null }
            if ($opt -and $opt.displayName) { $label = $opt.displayName; $anyResolved = $true }
        }
        $label
    }
    if ($anyResolved) { return $labels -join ' + ' }
    return $Key
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

# Most ids have no instance key; the hot callers (Get-SettingPath,
# Resolve-RawValue) check for "@@" themselves and skip this call.
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
    # Raw extraction only: no definition lookup, path or value resolution.
    # ParentDefinitionId lets Resolve-DiffSettings use the parent displayName
    # when a child has none (e.g. the _l_empty pattern).
    if (-not $Instance) { return }

    $defId = $Instance.settingDefinitionId

    if (-not $defId) { return }

    # Rows (also of child settings) are output as found: a List.Add per row and
    # per nesting level is slow on a large set.
    $type    = $Instance.'@odata.type'
    switch -Wildcard ($type) {
        '*ChoiceSettingInstance' {
            if ($null -ne $Instance.choiceSettingValue.value) {
                [PSCustomObject]@{
                    DefinitionId       = $defId
                    ParentDefinitionId = $ParentDefinitionId
                    RawValue           = $Instance.choiceSettingValue.value
                }
            }
            foreach ($child in $Instance.choiceSettingValue.children) {
                Get-RawSettings -Instance $child -ParentDefinitionId $defId
            }
        }
        '*ChoiceSettingCollectionInstance' {
            # Several options ticked in one setting (Defender Passive
            # Remediation, firewall rule Network Types, ...). One row per
            # option; Merge-CollectionSettings joins them sorted, so their
            # order does not matter. ('*ChoiceSettingInstance' above does not
            # match this type.)
            foreach ($item in $Instance.choiceSettingCollectionValue) {
                if ($null -ne $item.value) {
                    [PSCustomObject]@{
                        DefinitionId       = $defId
                        ParentDefinitionId = $ParentDefinitionId
                        RawValue           = $item.value
                    }
                }
                foreach ($child in $item.children) {
                    Get-RawSettings -Instance $child -ParentDefinitionId $defId
                }
            }
        }
        '*SimpleSettingInstance' {
            if ($null -ne $Instance.simpleSettingValue.value) {
                [PSCustomObject]@{
                    DefinitionId       = $defId
                    ParentDefinitionId = $ParentDefinitionId
                    RawValue           = "$($Instance.simpleSettingValue.value)"
                }
            }
        }
        '*GroupSettingInstance' {
            foreach ($child in $Instance.groupSettingValue.children) {
                Get-RawSettings -Instance $child -ParentDefinitionId $defId
            }
        }
        '*GroupSettingCollectionInstance' {
            foreach ($group in $Instance.groupSettingCollectionValue) {
                # Key/value pattern, e.g. hardeneduncpaths_key + _value: the key
                # is appended to the DefinitionId, one row per key.
                # Setting path becomes: ...Hardened UNC Paths > \\*\NETLOGON
                # RawValue becomes:     RequireMutualAuthentication=1,RequireIntegrity=1
                # (Plain loops, first match: pipelines per group are slow.)
                $keyChild   = $null
                $valueChild = $null
                foreach ($c in $group.children) { if ($c.settingDefinitionId -match '_key$')   { $keyChild   = $c; break } }
                foreach ($c in $group.children) { if ($c.settingDefinitionId -match '_value$') { $valueChild = $c; break } }
                if ($keyChild -and $valueChild) {
                    $keyVal = if ($keyChild.simpleSettingValue)     { "$($keyChild.simpleSettingValue.value)"  }
                              elseif ($keyChild.choiceSettingValue) { $keyChild.choiceSettingValue.value }
                              else { $null }
                    $valVal = if ($valueChild.simpleSettingValue)     { "$($valueChild.simpleSettingValue.value)"  }
                              elseif ($valueChild.choiceSettingValue) { $valueChild.choiceSettingValue.value }
                              else { $null }
                    if ($keyVal -and $valVal) {
                        # Format: "realDefinitionId||keyVal"
                        [PSCustomObject]@{
                            DefinitionId       = "$defId||$keyVal"
                            ParentDefinitionId = $defId
                            RawValue           = $valVal
                        }
                    }
                    # Process remaining children (non key/value) normally
                    foreach ($child in $group.children) {
                        if ($child.settingDefinitionId -match '_key$' -or
                            $child.settingDefinitionId -match '_value$') { continue }
                        Get-RawSettings -Instance $child -ParentDefinitionId $defId
                    }
                } else {
                    # No key/value pattern. An instance key (e.g. the
                    # "<collection>_name" child of a firewall rule) goes into
                    # every DefinitionId below it, so each instance is compared
                    # on its own (see COLLECTION INSTANCE KEYS).
                    $instanceKey = Get-CollectionInstanceKey -CollectionDefinitionId $defId -Group $group
                    foreach ($child in $group.children) {
                        foreach ($r in (Get-RawSettings -Instance $child -ParentDefinitionId $defId)) {
                            if ($instanceKey) {
                                $r.DefinitionId = Add-InstanceKey -DefinitionId $r.DefinitionId -InstanceKey $instanceKey
                                if ($r.ParentDefinitionId) {
                                    $r.ParentDefinitionId = Add-InstanceKey -DefinitionId $r.ParentDefinitionId -InstanceKey $instanceKey
                                }
                            }
                            $r
                        }
                    }
                }
            }
        }
        '*SimpleSettingCollectionInstance' {
            foreach ($item in $Instance.simpleSettingCollectionValue) {
                [PSCustomObject]@{
                    DefinitionId       = $defId
                    ParentDefinitionId = $ParentDefinitionId
                    RawValue           = "$($item.value)"
                }
            }
        }
        default {
            # A type not handled above (Microsoft adds one now and then): not
            # compared, but recorded so the compare can report it.
            $script:Resolve.SkippedSettings.Add([PSCustomObject]@{
                Side         = $null
                PolicyName   = $null
                DefinitionId = $defId
                Type         = if ($type) { "$type" } else { '(none)' }
            })
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# CANONICAL FLATTEN → SettingObjects
# ─────────────────────────────────────────────────────────────────────────────

function ConvertTo-SettingObjects {
    param(
        [Parameter(Mandatory)]$Policy,
        [Parameter(Mandatory)]
        [ValidateSet("Source","Target")]
        [string]$Source,
        # Name to show instead of $Policy.Name: "<name> (<id>)" when another
        # policy on the same side has that name (Get-PolicyDisplayNames).
        [string]$PolicyName = ''
    )
    $name = if ($PolicyName) { $PolicyName } else { $Policy.Name }
    # Platform of the policy (windows, macos, ios, android, linux; '' when
    # unknown, e.g. an older JSON export without "platforms"). The compare
    # only matches settings of the same platform (see Compare-RawSettings).
    $pv = if ($Policy.PSObject.Properties['Platforms']) { $Policy.Platforms } else { $null }
    $platform = [string](Get-PlatformKey $pv)
    $skipped = $script:Resolve.SkippedSettings
    foreach ($s in $Policy.Settings) {
        if (-not $s.settingInstance) { continue }
        $skippedBefore = $skipped.Count
        $rawSettings = Get-RawSettings -Instance $s.settingInstance
        # Settings of an unknown type found in this setting: add the policy.
        for ($i = $skippedBefore; $i -lt $skipped.Count; $i++) {
            $skipped[$i].Side       = $Source
            $skipped[$i].PolicyName = $name
        }
        foreach ($r in $rawSettings) {
            [PSCustomObject]@{
                PolicyId           = $Policy.PolicyId
                PolicyName         = $name
                Platform           = $platform
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
    if ($script:Resolve.CategoryById.ContainsKey($CategoryId)) {
        return $script:Resolve.CategoryById[$CategoryId]
    }
    # The context's connection wins over the one passed in: it holds the
    # token refreshed below, the callers (Get-CategoryPath) may still pass
    # the expired one.
    if ($script:Resolve.Connection) {
        $Connection = $script:Resolve.Connection
    }
    # Skip entirely if no categories file loaded — API is only a fallback for unknown entries
    if (-not $script:Resolve.HasCategories) {
        return $null
    }
    # No online tenant in the compare: nothing to fetch from. Warn once per run.
    if (-not $Connection -and -not $script:Resolve.CategoryNoTenantWarned) {
        $script:Resolve.CategoryNoTenantWarned = $true
        Write-Log "Categories" "Categories not found in the definitions will display as [Unknown Category]" "WARN"
    }
    # CategoryApiOffline: set on the first network error of a run, so the other
    # missing categories get a placeholder at once instead of each waiting on
    # retries. One category is a tiny request: 10 sec timeout (default 30).
    if ($Connection -and -not $script:Resolve.CategoryApiOffline) {
        # Expired token (e.g. the compare runs an hour after the load): signed
        # in again once, and the new connection is kept for the other missing
        # categories of this compare. A failed sign-in stops the fetches for
        # this compare, as a network error does.
        try {
            $fresh = Update-GraphConnection $Connection
            if (-not [object]::ReferenceEquals($fresh, $Connection)) {
                $Connection = $fresh
                if ($script:Resolve.Connection) { $script:Resolve.Connection = $fresh }
            }
        } catch {
            $script:Resolve.CategoryApiOffline = $true
            Write-Log "Categories" "Could not sign in again: missing categories are shown as [Unknown Category]. See Basetune.log for details" "WARN"
            Write-Log "Categories" "Details: $($_.Exception.Message)" "WARN" -FileOnly
        }
    }
    if ($Connection -and -not $script:Resolve.CategoryApiOffline) {
        try {
            $uri      = "https://graph.microsoft.com/beta/deviceManagement/configurationCategories/$CategoryId"
            $category = Invoke-IntuneGraphRequest -Connection $Connection -Uri $uri -NetworkRetries 0 -TimeoutSec 10 -ErrorAction Stop
            if ($category) {
                if (-not $script:Resolve.CategoryById.ContainsKey($CategoryId)) {
                    $script:Resolve.CategoryById[$CategoryId] = $category
                    # Mark cache as dirty — file will be written once at end of run
                    $script:Resolve.CategoryCacheDirty = $true
                    $script:Resolve.CategoryFetchedCount = 1 + [int]$script:Resolve.CategoryFetchedCount
                }
                Write-Log "Categories" "Fetched missing category from API: $($category.displayName)" "INFO"
                return $script:Resolve.CategoryById[$CategoryId]
            }
        }
        catch {
            if (Test-GraphNetworkError $_.Exception) {
                $script:Resolve.CategoryApiOffline = $true
                Write-Log "Categories" "Network unavailable: missing categories cannot be fetched and are shown as [Unknown Category]" "WARN"
            }
            else {
                Write-Log "Categories" "Could not fetch category '$CategoryId' from the API. See Basetune.log for details" "WARN"
                Write-Log "Categories" "Details: $($_.Exception.Message)" "WARN" -FileOnly
            }
        }
    }
    # __placeholder marks this entry as session-only: the category cache flush
    # (Invoke-BaselineCompare) skips it, so a temporary API failure is never
    # written to categories.json as a permanent "[Unknown Category]".
    $placeholder = [PSCustomObject]@{
        id               = $CategoryId
        displayName      = "[Unknown Category]"
        parentCategoryId = $null
        __placeholder    = $true
    }
    if (-not $script:Resolve.CategoryById.ContainsKey($CategoryId)) {
        $script:Resolve.CategoryById[$CategoryId] = $placeholder
    }
    return $script:Resolve.CategoryById[$CategoryId]
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
    if (-not $script:Resolve.HasCategories) {
        return $null
    }
    if (-not $Connection) {
        $Connection = $script:Resolve.Connection
    }
    if (-not $script:Resolve.CategoryPathCache) { $script:Resolve.CategoryPathCache = @{} }
    if ($script:Resolve.CategoryPathCache.ContainsKey($CategoryId)) {
        return $script:Resolve.CategoryPathCache[$CategoryId]
    }
    $parts     = [System.Collections.Generic.List[string]]::new()
    $currentId = $CategoryId
    $visited   = [System.Collections.Generic.HashSet[string]]::new()
    while ($currentId -and $currentId -ne "00000000-0000-0000-0000-000000000000") {
        if (-not $visited.Add($currentId)) {
            Write-Log "Categories" "Category '$currentId' refers to itself. Category path shortened" "WARN"
            break
        }
        if ($script:Resolve.CategoryPathCache.ContainsKey($currentId)) {
            $cached = $script:Resolve.CategoryPathCache[$currentId]
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
    $script:Resolve.CategoryPathCache[$CategoryId] = $fullPath
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
    # (Most ids have none: skip the call then, this runs for every value.)
    if ($DefinitionId.IndexOf('@@', [System.StringComparison]::Ordinal) -ge 0) {
        $DefinitionId = (Split-InstanceKey -DefinitionId $DefinitionId).BaseId
    }

    # Key/value DefinitionIds contain '||' — they do not need to be resolved via options
    if ($DefinitionId -match '\|\|') { return $RawValue }

    # Collection values are joined with '|' by Merge-CollectionSettings.
    # Resolve each part individually and rejoin.
    if ($RawValue -match '\|') {
        $parts = $RawValue -split '\|'
        $key   = $DefinitionId.Trim().ToLowerInvariant()
        $def   = $script:Resolve.DefinitionLookup[$key]
        $resolved = foreach ($partValue in $parts) {
            $match = if ($def) { Find-DefinitionOption $def $partValue } else { $null }
            if ($match) { $match.displayName } else { $partValue }
        }
        return $resolved -join " | "
    }

    $key = $DefinitionId.Trim().ToLowerInvariant()
    $def = $script:Resolve.DefinitionLookup[$key]
    if (-not $def) { return $RawValue }
    $match = Find-DefinitionOption $def $RawValue
    if ($match) { return $match.displayName }
    return $RawValue
}

# First option of a definition whose itemId equals the value (-eq: not case
# sensitive), or $null. A plain loop: a pipeline per value is slow on large sets.
function script:Find-DefinitionOption {
    param($Definition, [string]$Value)
    if (-not $Definition.options) { return $null }
    foreach ($o in $Definition.options) {
        if ($o.itemId -eq $Value) { return $o }
    }
    return $null
}

# ─────────────────────────────────────────────────────────────────────────────
# HELPER: build setting path from a DefinitionId
# ─────────────────────────────────────────────────────────────────────────────

function Get-SettingPath {
    param(
        [string]$DefinitionId,
        $Connection = $null,
        # The setting this one sits under in the policy (Get-RawSettings).
        # Used when it is not the root setting, see "Parent layer" below.
        [string]$ParentDefinitionId = $null
    )
    # Key/value ids ("realDefinitionId||keyVal"): the key is the last path
    # segment. Instance keys ("baseId@@ruleName") are path segments too, never
    # part of the lookup id. (Most ids have none: skip the call then.)
    $instanceKeys = @()
    if ($DefinitionId -and $DefinitionId.IndexOf('@@', [System.StringComparison]::Ordinal) -ge 0) {
        $split        = Split-InstanceKey -DefinitionId $DefinitionId
        $instanceKeys = @($split.Keys)
        $DefinitionId = $split.BaseId
    }

    $keySegment = $null
    $lookupId   = $DefinitionId
    if ($DefinitionId -match '^(.+)\|\|(.+)$') {
        $lookupId   = $Matches[1]
        $keySegment = $Matches[2]
    }

    $key = $lookupId.Trim().ToLowerInvariant()
    $def = $script:Resolve.DefinitionLookup[$key]
    # Graph sometimes returns a sub-element whose displayName is simply a copy
    # of its internal ADMX element name, e.g.
    #     "name":        "OSRecoveryKeyUsageDropDown_Name"
    #     "displayName": "OSRecoveryKeyUsageDropDown_Name"
    # That is not a label: used as one, an internal identifier shows in the
    # report and the child does not inherit the parent path, so
    # Merge-EnabledWithChildren cannot merge it into "Enabled: <value>".
    # Only sub-elements (rootDefinitionId pointing at another definition):
    # a top-level setting always keeps its displayName.
    $settingName = $null
    if ($def -and $def.displayName -and $def.displayName.Trim() -ne "") {
        $displayName = $def.displayName.Trim()
        $internalName = if ($def.PSObject.Properties['name'] -and $def.name) { $def.name.Trim() } else { $null }
        $isSubElement = ($def.PSObject.Properties['rootDefinitionId'] -and $def.rootDefinitionId -and
                         $def.rootDefinitionId.Trim().ToLowerInvariant() -ne $key)

        # A name without "_" is only a placeholder when the root setting
        # already carries it, as in the MSS (Legacy) settings:
        #     root  "MSS: (WarningLevel) Percentage threshold for ..."
        #     child "WarningLevel"  -> merged into "Enabled: <value>"
        # Otherwise it is a real label that equals its internal name ("Paint"
        # under Remove Default Microsoft Store packages, "Shielded" under
        # Enable Domain Network Firewall, the fields of a firewall rule): as a
        # placeholder it would take the parent's name and look like the parent.
        $isPlaceholder = $false
        if ($isSubElement -and $internalName -and $displayName -eq $internalName) {
            if ($internalName -match '_') {
                $isPlaceholder = $true
            } elseif ($instanceKeys.Count -eq 0) {
                # Spaces ignored: "MSS: (DisableIPSourceRouting IPv6) ..." holds
                # the child "DisableIPSourceRoutingIPv6".
                $rootDefP = $script:Resolve.DefinitionLookup[$def.rootDefinitionId.Trim().ToLowerInvariant()]
                $isPlaceholder = [bool]($rootDefP -and $rootDefP.displayName -and
                                        ($rootDefP.displayName -replace '\s', '').IndexOf(($internalName -replace '\s', ''),
                                            [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
            }
        }
        if ($isPlaceholder) {
            $settingName = $null      # placeholder label -> fall back to parent
        } else {
            $settingName = $displayName
        }
    }
    $pathParts = [System.Collections.Generic.List[string]]::new()
    if ($def -and $def.categoryId -and $script:Resolve.DefinitionLookup.Count -gt 0) {
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
            $rootDef = $script:Resolve.DefinitionLookup[$rootKey]
            if ($rootDef -and $rootDef.displayName -and $rootDef.displayName.Trim() -ne "") {
                $rootName = $rootDef.displayName.Trim()
                if ($pathParts.Count -eq 0 -or $pathParts[$pathParts.Count - 1] -ne $rootName) {
                    $pathParts.Add($rootName)
                }
                $rootIndex = $pathParts.Count - 1
            }
        }
    }
    # Parent layer: a setting under a parent that is itself not the root goes
    # below that parent, as in Intune:
    #     Outlook Security Mode (User)                                (root)
    #       > Configure Outlook object model prompt when sending mail (parent)
    #         > Guard behavior: (User)                                (this)
    # Otherwise the six "Guard behavior" settings of Outlook Security Mode get
    # one path and show as one row. Not inside keyed instances or key/value
    # collections: their path is built from the keys.
    if ($settingName -and $ParentDefinitionId -and $instanceKeys.Count -eq 0 -and -not $keySegment -and
        $def -and $def.rootDefinitionId) {
        $parentKey = (Split-InstanceKey -DefinitionId $ParentDefinitionId).BaseId.Trim().ToLowerInvariant()
        if ($parentKey -ne $key -and $parentKey -ne $def.rootDefinitionId.Trim().ToLowerInvariant()) {
            $parentPath = Get-SettingPath -DefinitionId $ParentDefinitionId -Connection $Connection
            if ($parentPath.SettingName -and $parentPath.PathParts.Count -gt 0) {
                $pathParts = [System.Collections.Generic.List[string]]::new([string[]]$parentPath.PathParts)
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
            $pathParts.Insert($insertAt, (Get-InstanceKeyLabel $ik))
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
# DIFF RESOLVE: SETTING NAMES AND VALUES
# Walks the compare rows and gives each one its full setting path and the
# display names of its source and target values (Diff.csv, Summary.csv and
# the report all use these rows).
# ─────────────────────────────────────────────────────────────────────────────
function Resolve-DiffSettings {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Diff,
        $Connection = $null
    )
    # Many rows (one per source/target policy pair) share a setting and a
    # value: path and values are resolved once per setting / setting + value
    # (Get-SettingPath is ~1 ms per call).
    # Ordinal (case-sensitive) keys: instance keys such as firewall rule names
    # are shown as typed, and an unmatched raw value is returned as is.
    # Read by index ($null when missing), not TryGetValue: a [ref] method call
    # per row is slow on 50,000+ rows. A $null result is just resolved again.
    $settingCache = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $valueCache   = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)

    foreach ($d in $Diff) {
        # Setting path: from the setting, or its parent when it has no name.
        $settingKey = "$($d.DefinitionId)`0$($d.ParentDefinitionId)"
        $fullSetting = $settingCache[$settingKey]
        if ($null -eq $fullSetting) {
            $resolved = Get-SettingPath -DefinitionId $d.DefinitionId -Connection $Connection -ParentDefinitionId $d.ParentDefinitionId
            if (-not $resolved.SettingName) {
                # No displayName — try to use parent
                $fullSetting = $d.DefinitionId
                if ($d.ParentDefinitionId) {
                    $parentResolved = Get-SettingPath -DefinitionId $d.ParentDefinitionId -Connection $Connection
                    if ($parentResolved.SettingName) { $fullSetting = $parentResolved.PathParts -join " > " }
                }
            } elseif ($resolved.PathParts.Count -gt 0) {
                $fullSetting = $resolved.PathParts -join " > "
            } else {
                $fullSetting = $d.DefinitionId
            }
            $settingCache[$settingKey] = $fullSetting
        }

        # Values: option itemIds -> display names (see Resolve-RawValue).
        $resolvedSource = $null
        if ($d.SourceValue) {
            $vk = "$($d.DefinitionId)`0$($d.SourceValue)"
            $resolvedSource = $valueCache[$vk]
            if ($null -eq $resolvedSource) {
                $resolvedSource = Resolve-RawValue -DefinitionId $d.DefinitionId -RawValue $d.SourceValue
                $valueCache[$vk] = $resolvedSource
            }
        }
        $resolvedTarget = $null
        if ($d.TargetValue) {
            $vk = "$($d.DefinitionId)`0$($d.TargetValue)"
            $resolvedTarget = $valueCache[$vk]
            if ($null -eq $resolvedTarget) {
                $resolvedTarget = Resolve-RawValue -DefinitionId $d.DefinitionId -RawValue $d.TargetValue
                $valueCache[$vk] = $resolvedTarget
            }
        }

        [PSCustomObject]@{
            DefinitionId     = $d.DefinitionId
            Setting          = $fullSetting
            Status           = $d.Status
            Issue            = $d.Issue
            # Ids: two policies can have the same name. Grouping (merge,
            # issue, summary, report) is done on the id, the name is shown.
            SourcePolicyId   = $d.SourcePolicyId
            TargetPolicyId   = $d.TargetPolicyId
            SourcePolicyName = $d.SourcePolicyName
            TargetPolicyName = $d.TargetPolicyName
            SourceValue      = $resolvedSource
            TargetValue      = $resolvedTarget
            SourcePlatform   = $d.SourcePlatform
            TargetPlatform   = $d.TargetPlatform
        }
    }
}
# ─────────────────────────────────────────────────────────────────────────────
# MERGE ENABLED + CHILDREN → "Enabled: value" / "Disabled"
#
# Resolve-DiffSettings gives rows like:
#   Setting: VBA Macro Notification Settings   SourceValue: Enabled
#   Setting: VBA Macro Notification Settings   SourceValue: Disable all except digitally signed macros
# merged here into one row:
#   Setting: VBA Macro Notification Settings   SourceValue: Enabled: Disable all except digitally signed macros
#
# Rules:
#   - Parent = row whose SourceValue or TargetValue is "enabled" / "true" / "disabled" / "false"
#     AND at least one child exists with the same Setting + same policy combination
#   - Parent "disabled" / "false" → "Disabled" (no child expected)
#   - Parent "enabled" / "true"   → "Enabled: <child value>"
#   - Rows without an enabled/disabled pattern remain unchanged
# ─────────────────────────────────────────────────────────────────────────────
function Merge-EnabledWithChildren {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Resolved
    )
    if ($Resolved.Count -eq 0) { return @() }
    $enabledLike  = @('enabled', 'true')
    $disabledLike = @('disabled', 'false')
    $toggleLike   = $enabledLike + $disabledLike
    # --- Align children with every target policy ----------------------------
    # The merge below groups on the target policy (id), so a parent and child
    # only merge when both carry the same target policy. That fails when:
    #   * the target has the parent Disabled: Intune omits the children of a
    #     disabled ADMX parent, so the child has no target policy at all;
    #   * only some of several target policies carry the child: the others
    #     show a bare "Enabled" next to "Enabled: <value>".
    # The source side of a child does not depend on the target policy, so each
    # target policy holding the parent gets a copy of every child (empty
    # target value where it has none). A parent absent from the target: left
    # alone, nothing to merge into, it stays Missing.
    # Rows are output by the loop into $aligned (a List.Add per row is slow on
    # 50,000+ rows). Policy ids, not names: two policies can share a name.
    $aligned = foreach ($sg in ($Resolved | Group-Object -Property Setting, SourcePolicyId)) {
        $sgRows = @($sg.Group)

        # Parent = enabled/disabled toggle row, child = every other row. Plain
        # loops instead of Where-Object: this runs for every setting.
        $sgParents  = @(foreach ($r in $sgRows) {
            if (($r.SourceValue -and $r.SourceValue.Trim().ToLower() -in $toggleLike) -or
                ($r.TargetValue -and $r.TargetValue.Trim().ToLower() -in $toggleLike)) { $r }
        })
        $sgChildren = @(foreach ($r in $sgRows) {
            if (-not (($r.SourceValue -and $r.SourceValue.Trim().ToLower() -in $toggleLike) -or
                      ($r.TargetValue -and $r.TargetValue.Trim().ToLower() -in $toggleLike))) { $r }
        })

        # Rows without a source policy (Extra) have no source side to copy, and
        # their group lumps every target policy together: copying would make a
        # fake "Missing" child for the others, merged into a false "Diff".
        $noSource = -not $sgRows[0].SourcePolicyId
        if ($noSource -or $sgParents.Count -eq 0 -or $sgChildren.Count -eq 0) {
            $sgRows
            continue
        }
        # Target policies that carry the parent toggle, and the first parent
        # row per target policy (name and platform for a copied child). One
        # target policy (the usual case) needs no sort.
        $parentByTarget = @{}
        $parentIds      = @(foreach ($p in $sgParents) {
            if (-not $p.TargetPolicyId) { continue }
            if ($null -eq $parentByTarget[$p.TargetPolicyId]) { $parentByTarget[$p.TargetPolicyId] = $p }
            $p.TargetPolicyId
        })
        $oneTarget = $true
        foreach ($id in $parentIds) { if ($id -cne $parentIds[0]) { $oneTarget = $false; break } }
        $parentTargets = if ($parentIds.Count -eq 0) { @() }
                         elseif ($oneTarget) { @($parentIds[0]) }
                         else { @($parentIds | Sort-Object -Unique) }
        if ($parentTargets.Count -eq 0) {
            $sgRows
            continue
        }

        $sgParents

        # One representative per child definition, for its source-side value.
        $childTemplates = if ($sgChildren.Count -eq 1) { @($sgChildren[0]) }
                          else { @($sgChildren | Group-Object DefinitionId | ForEach-Object { $_.Group[0] }) }

        # First child row per DefinitionId + target policy (not case
        # sensitive, like -eq): a lookup, not a scan per target and child.
        $childByKey = @{}
        foreach ($c in $sgChildren) {
            if (-not $c.TargetPolicyId) { continue }
            $ck = "$($c.DefinitionId)`0$($c.TargetPolicyId)"
            if ($null -eq $childByKey[$ck]) { $childByKey[$ck] = $c }
        }

        foreach ($t in $parentTargets) {
            foreach ($tpl in $childTemplates) {
                $existing = $childByKey["$($tpl.DefinitionId)`0$t"]

                if ($existing) {
                    $existing
                } else {
                    # Target name and platform: from the parent row of that policy.
                    $tParent = $parentByTarget[$t]
                    [PSCustomObject]@{
                        DefinitionId     = $tpl.DefinitionId
                        Setting          = $tpl.Setting
                        Status           = 'Missing'
                        Issue            = $tpl.Issue
                        SourcePolicyId   = $tpl.SourcePolicyId
                        TargetPolicyId   = $t
                        SourcePolicyName = $tpl.SourcePolicyName
                        TargetPolicyName = $tParent.TargetPolicyName
                        SourceValue      = $tpl.SourceValue
                        TargetValue      = $null
                        SourcePlatform   = $tpl.SourcePlatform
                        TargetPlatform   = $tParent.TargetPlatform
                    }
                }
            }
        }

        # Child rows pointing at a target policy that has no parent toggle are
        # not represented above; keep them so nothing is silently dropped.
        foreach ($c in $sgChildren) {
            if ($c.TargetPolicyId -and $c.TargetPolicyId -notin $parentTargets) { $c }
        }
    }
    $Resolved = @($aligned)

    # Group by Setting + source policy + target policy (ids); rows are output
    # into $output (no List.Add, see $aligned above).
    $groups = $Resolved | Group-Object -Property Setting, SourcePolicyId, TargetPolicyId
    $output = foreach ($g in $groups) {
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
            [PSCustomObject]@{
                DefinitionId     = $r.DefinitionId
                Setting          = $r.Setting
                Status           = $r.Status
                Issue            = $r.Issue
                SourcePolicyId   = $r.SourcePolicyId
                TargetPolicyId   = $r.TargetPolicyId
                SourcePolicyName = $r.SourcePolicyName
                TargetPolicyName = $r.TargetPolicyName
                SourceValue      = $newSource
                TargetValue      = $newTarget
                SourcePlatform   = $r.SourcePlatform
                TargetPlatform   = $r.TargetPlatform
            }
            continue
        }
        # Multiple rows — find the parent (enabled/disabled toggle)
        $parentRows = @(foreach ($r in $rows) {
            if (($r.SourceValue -and $r.SourceValue.Trim().ToLower() -in $toggleLike) -or
                ($r.TargetValue -and $r.TargetValue.Trim().ToLower() -in $toggleLike)) { $r }
        })
        $childRows  = @(foreach ($r in $rows) {
            if (-not (($r.SourceValue -and $r.SourceValue.Trim().ToLower() -in $toggleLike) -or
                      ($r.TargetValue -and $r.TargetValue.Trim().ToLower() -in $toggleLike))) { $r }
        })
        if ($parentRows.Count -eq 0 -or $childRows.Count -eq 0) {
            # No clear parent/child pattern — pass all rows through unchanged
            $rows
            continue
        }
        # Take the first parent (normally there is only one)
        $parent = $parentRows[0]
        $sv = if ($parent.SourceValue) { $parent.SourceValue.Trim().ToLower() } else { $null }
        $tv = if ($parent.TargetValue) { $parent.TargetValue.Trim().ToLower() } else { $null }
        $sourceEnabled  = $sv -in $enabledLike
        $sourceDisabled = $sv -in $disabledLike
        $targetEnabled  = $tv -in $enabledLike
        $targetDisabled = $tv -in $disabledLike
        foreach ($child in $childRows) {
            # "Enabled: <value>" only with a value; else "Enabled" (a trailing
            # "Enabled: " reads like a blank value, not "sub-setting unset").
            $newSource = if ($sourceEnabled)       { if ($child.SourceValue) { "Enabled: $($child.SourceValue)" } else { "Enabled" } }
                         elseif ($sourceDisabled)  { "Disabled" }
                         else                      { $child.SourceValue }
            $newTarget = if ($targetEnabled)       { if ($child.TargetValue) { "Enabled: $($child.TargetValue)" } else { "Enabled" } }
                         elseif ($targetDisabled)  { "Disabled" }
                         else                      { $child.TargetValue }
            # Status from the merged values, never the child's own Status: with
            # the parent toggle different (Enabled / Disabled) and the child
            # value equal, the child is "Match" but the merged row differs (and
            # this merge consumes the parent row with the real "Diff").
            # Missing/Extra stay only when the merged row has no counterpart
            # (not configured is not a value difference). A copied child under
            # a Disabled parent in the target does have one: that is a Diff.
            $mergedStatus = if ($newSource -eq $newTarget) {
                                "Match"
                            } elseif ($child.Status -eq 'Missing' -and -not $newTarget) {
                                'Missing'
                            } elseif ($child.Status -eq 'Extra' -and -not $newSource) {
                                'Extra'
                            } else {
                                "Diff"
                            }
            [PSCustomObject]@{
                DefinitionId     = $child.DefinitionId
                Setting          = $child.Setting
                Status           = $mergedStatus
                Issue            = $child.Issue
                SourcePolicyId   = $child.SourcePolicyId
                TargetPolicyId   = $child.TargetPolicyId
                SourcePolicyName = $child.SourcePolicyName
                TargetPolicyName = $child.TargetPolicyName
                SourceValue      = $newSource
                TargetValue      = $newTarget
                SourcePlatform   = $child.SourcePlatform
                TargetPlatform   = $child.TargetPlatform
            }
        }
        # Remaining parent rows (edge case: multiple parents) pass through unchanged
        for ($i = 1; $i -lt $parentRows.Count; $i++) {
            $parentRows[$i]
        }
    }
    # --- Recompute Issue over the merged rows --------------------------------
    # Add-IssueColumn runs before this merge, per DefinitionId, so parent and
    # child are judged apart: a parent Enabled/Enabled/Disabled in three target
    # policies is Conflict, its child (only in the two Enabled ones) Duplicate.
    # The kept child row would carry that stale Duplicate, so the issue is
    # derived again from the merged target values (what report and CSV show):
    # several target policies with different values = Conflict, same = Duplicate.
    # Per platform: rows without a source policy (Extra) are grouped per target
    # platform (a Windows and a macOS policy never reach the same device). Rows
    # with a source policy only hold target policies of its platform already.
    $final = @($output)
    foreach ($ig in ($final | Group-Object -Property SourcePolicyId, DefinitionId,
                                @{ Expression = { if ($_.SourcePolicyId) { '' } else { [string]$_.TargetPlatform } } })) {
        $withTarget = @(foreach ($r in $ig.Group) { if ($r.TargetPolicyId) { $r } })
        # One target policy (the usual case: one row, or rows of one policy
        # with exactly the same id): 'None' without a pipeline or a sort.
        $oneTarget = $true
        foreach ($r in $withTarget) { if ($r.TargetPolicyId -cne $withTarget[0].TargetPolicyId) { $oneTarget = $false; break } }
        $policies = if ($oneTarget) { @() }
                    else { @($withTarget | ForEach-Object { $_.TargetPolicyId } | Sort-Object -Unique) }

        $issue = if ($oneTarget -or $policies.Count -le 1) {
            'None'
        } else {
            $values = @($withTarget | Sort-Object TargetPolicyId -Unique |
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
        [AllowEmptyCollection()]
        [array]$Settings
    )

    # Policies without settings produce an empty flat list. That is a valid
    # state (everything on the other side becomes Missing/Extra), not an error.
    if ($Settings.Count -eq 0) { return }

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
                Platform           = $first.Platform
                DefinitionId       = $first.DefinitionId
                ParentDefinitionId = $first.ParentDefinitionId
                RawValue           = $sortedValues
                Source             = $first.Source
            }
        }
    }
}

# The different settings in the compare without a setting definition (shown
# with their DefinitionId instead of a name), each with the policies that hold
# it, for the log line and Compare.log. Instance keys (baseId@@ruleName) and
# key/value ids (id||key) count by their base id. Sorted on id.
# Returns a list of @{ DefinitionId; Policies = list of @{ Side; Name } }
# (Side 'Source' / 'Target', each policy once), empty when definitions are
# not loaded: then nothing is resolved and nothing is reported.
function Get-UnresolvedDefinitions {
    param([AllowNull()][AllowEmptyCollection()][array]$Diff)
    $lookup = $script:Resolve.DefinitionLookup
    if (-not $lookup -or $lookup.Count -eq 0) { return @() }
    # Row DefinitionId -> base id without definition, or '' (has one).
    # Worked out once per DefinitionId: many rows share one.
    $baseOf   = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    # Base id (lower case) -> @{ Id = first spelling seen; Policies = @{} }
    $missing  = @{}
    foreach ($d in $Diff) {
        if (-not $d -or -not $d.DefinitionId) { continue }
        $id   = [string]$d.DefinitionId
        $base = $baseOf[$id]
        if ($null -eq $base) {
            $b = $id
            if ($b -like '*@@*') { $b = (Split-InstanceKey -DefinitionId $id).BaseId }
            if ($b -match '^(.+?)\|\|') { $b = $Matches[1] }
            $b = $b.Trim()
            # The lookup read by index (its values are definitions, never $null).
            $base = if ($null -eq $lookup[$b.ToLowerInvariant()]) { $b } else { '' }
            $baseOf[$id] = $base
        }
        if (-not $base) { continue }
        $key = $base.ToLowerInvariant()
        $m = $missing[$key]
        if (-not $m) { $m = @{ Id = $base; Policies = [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::Ordinal) }; $missing[$key] = $m }
        # Key "Side<TAB>Name": each policy once (case sensitive names).
        if ($d.SourcePolicyName) { $m.Policies["Source`t$($d.SourcePolicyName)"] = $true }
        if ($d.TargetPolicyName) { $m.Policies["Target`t$($d.TargetPolicyName)"] = $true }
    }
    return @(foreach ($k in ($missing.Keys | Sort-Object)) {
        $pols = @(foreach ($p in $missing[$k].Policies.Keys) {
            $side, $name = $p -split "`t", 2
            [PSCustomObject]@{ Side = $side; Name = $name }
        })
        [PSCustomObject]@{ DefinitionId = $missing[$k].Id; Policies = $pols }
    })
}

# ─────────────────────────────────────────────────────────────────────────────
# EXPORTS
# ─────────────────────────────────────────────────────────────────────────────

Export-ModuleMember -Function @(
    'Initialize-ResolveContext',
    'Get-UnresolvedDefinitions',
    'Get-RawSettings',
    'ConvertTo-SettingObjects',
    'Merge-CollectionSettings',
    'Resolve-Category',
    'Get-CategoryPath',
    'Get-SettingPath',
    'Resolve-RawValue',
    'Resolve-DiffSettings',
    'Merge-EnabledWithChildren'
)
