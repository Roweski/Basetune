# =============================================================================
# BasetuneDefinitions.psm1
# Settings Catalog definitions and categories (settings.json /
# categories.json in the Definitions folder), for CLI and UI:
#   - which file to read (downloaded or the shipped .default) and whether the
#     download is recent (Get-DefinitionFile, Test-DefinitionsRecent)
#   - read them into lookups (Import-SettingDefinitions / -Categories,
#     ConvertTo-SettingDefinitionLookup / -CategoryMap)
#   - download them from Graph (Invoke-DefinitionDownload)
# Using the lookups during a compare is in BasetunePolicies (resolve context).
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# DEFINITION / CATEGORY FILES
#
# One loader for settings.json and categories.json (CLI, UI cache, UI compare
# runspace).
#   Import-SettingDefinitions : hashtable keyed by lower-cased, trimmed id
#   Import-SettingCategories  : hashtable keyed by category id
# Both return $null when the file does not exist and THROW when it cannot be
# parsed, so callers can tell "not downloaded yet" from "file is corrupt".
# ─────────────────────────────────────────────────────────────────────────────
# ConvertTo-* build the lookups from objects in memory (the download, which
# need not re-read the 60+ MB file); Import-* read the files and use them too.
function ConvertTo-SettingDefinitionLookup {
    param([AllowNull()][AllowEmptyCollection()][array]$Definitions)
    $lookup = @{}
    foreach ($d in $Definitions) {
        if ($d -and $d.id) { $lookup[$d.id.Trim().ToLowerInvariant()] = $d }
    }
    return $lookup
}

function ConvertTo-SettingCategoryMap {
    param([AllowNull()][AllowEmptyCollection()][array]$Categories)
    $catMap = @{}
    foreach ($c in $Categories) {
        # Skip the "[Unresolved Category]"/"[Unknown Category]" placeholders older
        # versions wrote to categories.json, so the category is looked up again.
        if ($c -and $c.id -and $c.displayName -notin @('[Unresolved Category]','[Unknown Category]')) { $catMap[$c.id] = $c }
    }
    return $catMap
}

# Which definition file to read. A release ships settings.default.json /
# categories.default.json; a download writes settings.json / categories.json
# next to them and never touches the .default files. Read order: downloaded,
# then default. The older names (settingDefinitions.json /
# settingCategories.json, and their .default files) are read as a fallback.
# Exists = $false: none of them is there (Path = the downloaded name).
function Get-DefinitionFile {
    param(
        [Parameter(Mandatory)][string]$DefinitionsPath,
        [Parameter(Mandatory)][ValidateSet('Definitions','Categories')][string]$Kind
    )
    $base   = if ($Kind -eq 'Definitions') { 'settings' }           else { 'categories' }
    $legacy = if ($Kind -eq 'Definitions') { 'settingDefinitions' } else { 'settingCategories' }
    foreach ($name in "$base.json", "$legacy.json", "$base.default.json", "$legacy.default.json") {
        $p = Join-Path $DefinitionsPath $name
        if (Test-Path -LiteralPath $p) {
            return [PSCustomObject]@{ Path = $p; Name = $name; IsDefault = ($name -like '*.default.json'); Exists = $true }
        }
    }
    return [PSCustomObject]@{ Path = (Join-Path $DefinitionsPath "$base.json"); Name = "$base.json"; IsDefault = $false; Exists = $false }
}

# Downloaded definitions less than 24 hours old: downloading again will not
# resolve more settings, so the compare does not suggest it. The default file
# (shipped with the release) never counts as recent.
function Test-DefinitionsRecent {
    param([Parameter(Mandatory)][string]$DefinitionsPath)
    $f = Get-DefinitionFile -DefinitionsPath $DefinitionsPath -Kind Definitions
    if (-not $f.Exists -or $f.IsDefault) { return $false }
    return ((Get-Item -LiteralPath $f.Path).LastWriteTime -gt (Get-Date).AddHours(-24))
}

function Import-SettingDefinitions {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $defs = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    return (ConvertTo-SettingDefinitionLookup -Definitions @($defs))
}

function Import-SettingCategories {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $cats = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    return (ConvertTo-SettingCategoryMap -Categories @($cats))
}

# ─────────────────────────────────────────────────────────────────────────────
# Slim setting definition: only the fields Basetune reads (Get-SettingPath and
# Resolve-RawValue in BasetunePolicies.psm1):
#   id, name, displayName, rootDefinitionId, categoryId,
#   options[].itemId / options[].displayName
# Graph returns much more (description, helpText, infoUrls, keywords,
# applicability, dependencies, ... also per option). Leaving that out makes
# settings.json, the first compare and the UI cache much smaller. Need another
# field? Add it here and download again.
# ─────────────────────────────────────────────────────────────────────────────
function ConvertTo-SlimSettingDefinition {
    param([Parameter(Mandatory)]$Definition)
    $d    = $Definition
    $slim = [ordered]@{ id = $d.id }
    foreach ($p in 'name', 'displayName', 'rootDefinitionId', 'categoryId') {
        if ($d.PSObject.Properties[$p] -and $null -ne $d.$p) { $slim[$p] = $d.$p }
    }
    if ($d.PSObject.Properties['options'] -and $d.options) {
        $slim['options'] = @(foreach ($o in @($d.options)) {
            if ($null -eq $o) { continue }
            [PSCustomObject]@{ itemId = $o.itemId; displayName = $o.displayName }
        })
    }
    return [PSCustomObject]$slim
}

# Categories, the same way: the compare only uses id, displayName and
# parentCategoryId (Get-CategoryPath). Graph also returns description,
# categoryDescription, helpText, name, platforms, technologies, settingUsage,
# rootCategoryId and childCategoryIds.
function ConvertTo-SlimSettingCategory {
    param([Parameter(Mandatory)]$Category)
    $c    = $Category
    $slim = [ordered]@{ id = $c.id }
    foreach ($p in 'displayName', 'parentCategoryId') {
        if ($c.PSObject.Properties[$p] -and $null -ne $c.$p) { $slim[$p] = $c.$p }
    }
    return [PSCustomObject]$slim
}

# ─────────────────────────────────────────────────────────────────────────────
# DOWNLOAD SETTING DEFINITIONS & CATEGORIES
#
# Fetches the configurationSettings and configurationCategories catalogs from
# Graph into the Definitions folder (the friendly-name lookups of the compare).
#
# Input  : Connection      — Graph connection (API tenant required)
#          DefinitionsPath — target folder for settings.json / categories.json
#          GraphBeta       — base URI for the Graph beta endpoint
#          LogQueue        — unused, for symmetry with Read-PoliciesFromTenant:
#                            this runs serially in the caller's runspace, so
#                            Write-Log already goes through Set-LogCallback
# Output : [PSCustomObject]@{ DefinitionLookup; CategoryById } — the same
#          lookups Import-SettingDefinitions / Import-SettingCategories build
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-DefinitionDownload {
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$DefinitionsPath,
        [Parameter(Mandatory)][string]$GraphBeta,
        $LogQueue = $null
    )

    if (-not (Test-Path $DefinitionsPath)) {
        New-Item -ItemType Directory -Path $DefinitionsPath -Force | Out-Null
    }

    $definitionsFile = Join-Path $DefinitionsPath 'settings.json'
    $categoriesFile  = Join-Path $DefinitionsPath 'categories.json'

    # Do NOT add $top here: on configurationSettings it limits the result set
    # instead of setting a page size (no @odata.nextLink, the rest of the
    # catalog is silently lost). Without it the service pages by itself and
    # Get-GraphPagedResults follows every nextLink.
    # MaxRetries 5 covers the occasional HTTP 504 of this heavy endpoint;
    # TimeoutSec 60 (default 30) gives its large pages time.
    Write-Log "Download" "Downloading setting definitions..." "INFO"
    $definitions = @(Get-GraphPagedResults -Connection $Connection `
        -Uri "$GraphBeta/deviceManagement/configurationSettings" `
        -MaxRetries 5 -TimeoutSec 60)
    if ($definitions.Count -eq 0) {
        throw "Retrieved 0 settings. Existing files were left unchanged"
    }
    # Keep only the fields Basetune uses (see ConvertTo-SlimSettingDefinition).
    $definitions = @(foreach ($d in $definitions) {
        if ($d -and $d.id) { ConvertTo-SlimSettingDefinition -Definition $d }
    })

    Write-Log "Download" "Downloading category definitions..." "INFO"
    $categories = @(Get-GraphPagedResults -Connection $Connection `
        -Uri "$GraphBeta/deviceManagement/configurationCategories" `
        -TimeoutSec 60)
    if ($categories.Count -eq 0) {
        throw "Retrieved 0 categories. Existing files were left unchanged"
    }
    $categories = @(foreach ($c in $categories) {
        if ($c -and $c.id) { ConvertTo-SlimSettingCategory -Category $c }
    })
    Write-Log "Download" "Removed unused properties from the definitions" "INFO"

    # Some categories are missing from the configurationCategories list; the
    # compare fetches them one by one (Resolve-Category) and adds them to
    # categories.json. Keep them, or the next compare fetches them again.
    # Read from categories.json, else categories.default.json (may hold them
    # too); the result always goes to categories.json.
    $catsExisting = Get-DefinitionFile -DefinitionsPath $DefinitionsPath -Kind Categories
    if ($catsExisting.Exists) {
        try {
            $newIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@($categories | ForEach-Object { [string]$_.id }))
            $kept   = @(Get-Content -LiteralPath $catsExisting.Path -Raw -Encoding UTF8 | ConvertFrom-Json | Where-Object {
                $_ -and $_.id -and -not $newIds.Contains([string]$_.id) -and
                $_.displayName -notin @('[Unresolved Category]','[Unknown Category]') -and -not $_.PSObject.Properties['__placeholder']
            })
            if ($kept.Count -gt 0) {
                $categories += @(foreach ($k in $kept) { ConvertTo-SlimSettingCategory -Category $k })
                Write-Log "Download" "Kept $($kept.Count) extra categories from $($catsExisting.Name)" "INFO"
            }
        } catch {
            Write-Log "Download" "Could not read the existing $($catsExisting.Name) to keep extra categories. See the log file for details" "WARN"
            Write-Log "Download" "Details: $($_.Exception.Message)" "WARN" -FileOnly
        }
    }

    # Serialising ~18k definitions takes a while: say so, or the log goes quiet.
    Write-Log "Download" "Writing definition files to disk..." "INFO"
    # Write to a .tmp file, then move it over the old one: an interrupted write
    # never leaves a truncated file. Unique temp names: a cancelled download
    # can still be finishing while a new one starts.
    $tmpTag  = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $defsTmp = "$definitionsFile.$tmpTag.tmp"
    $catsTmp = "$categoriesFile.$tmpTag.tmp"
    try {
        $definitions | ConvertTo-Json -Depth 20 | Out-File -LiteralPath $defsTmp -Encoding UTF8
        $categories  | ConvertTo-Json -Depth 20 | Out-File -LiteralPath $catsTmp -Encoding UTF8
        Move-Item -LiteralPath $defsTmp -Destination $definitionsFile -Force
        Move-Item -LiteralPath $catsTmp -Destination $categoriesFile  -Force
    } finally {
        foreach ($t in @($defsTmp, $catsTmp)) {
            if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue }
        }
    }
    Write-Log "Download" "Saved definitions to $definitionsFile ($($definitions.Count))"
    Write-Log "Download" "Saved categories to $categoriesFile ($($categories.Count))"

    # Build the lookups from the downloaded objects, so the UI can refresh its
    # cache without parsing the file on the UI thread (freezes the window for
    # seconds). The UI takes them over in OnDone, hence the "Cached" lines here,
    # before "Download complete".
    $defLookup = ConvertTo-SettingDefinitionLookup -Definitions $definitions
    $catMap    = ConvertTo-SettingCategoryMap      -Categories  $categories
    Write-Log "Download" "Cached $($defLookup.Count) setting definitions from $(Split-Path $definitionsFile -Leaf)"
    Write-Log "Download" "Cached $($catMap.Count) category definitions from $(Split-Path $categoriesFile -Leaf)"

    Write-Log "Download" "Download complete"

    return [PSCustomObject]@{
        DefinitionLookup = $defLookup
        CategoryById     = $catMap
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Definitions for a compare, with the log lines both CLI and UI show:
#   Retrieving setting and category definitions...
#   [what is missing, if anything]
#   Loaded 18402 setting definitions from cache | from settings.json
#   Loaded 1037 category definitions from cache | from categories.json
# The UI passes its in-memory cache; the CLI passes nothing and reads the
# files (downloaded first, else the .default files, Get-DefinitionFile).
# A file that cannot be read is reported and left out (raw ids in the output).
# Output: [PSCustomObject]@{ DefinitionLookup; CategoryById } (either $null)
# ─────────────────────────────────────────────────────────────────────────────
function Get-CompareDefinitions {
    param(
        [Parameter(Mandatory)][string]$DefinitionsPath,
        [hashtable]$CachedLookup       = $null,
        [hashtable]$CachedCategoryById = $null
    )
    $defsFile = Get-DefinitionFile -DefinitionsPath $DefinitionsPath -Kind Definitions
    $catsFile = Get-DefinitionFile -DefinitionsPath $DefinitionsPath -Kind Categories
    $hasCachedDefs = ($null -ne $CachedLookup -and $CachedLookup.Count -gt 0)
    $hasCachedCats = ($null -ne $CachedCategoryById -and $CachedCategoryById.Count -gt 0)

    Write-Log 'Definitions' 'Retrieving setting and category definitions...' 'INFO'
    $defsAvail = $hasCachedDefs -or $defsFile.Exists
    $catsAvail = $hasCachedCats -or $catsFile.Exists
    # What is missing is reported first, right under the header.
    if (-not $defsAvail -and -not $catsAvail) {
        Write-Log 'Definitions' 'No setting and category definitions found. Display names will not be resolved' 'WARN'
    } elseif (-not $defsAvail) {
        Write-Log 'Definitions' 'No setting definitions found. Display names will not be resolved' 'WARN'
    } elseif (-not $catsAvail) {
        Write-Log 'Categories' 'No category definitions found. Categories will not be resolved' 'WARN'
    }

    $defLookup = $null
    if ($hasCachedDefs) {
        $defLookup = $CachedLookup
        Write-Log 'Definitions' "Loaded $($defLookup.Count) setting definitions from cache"
    } elseif ($defsFile.Exists) {
        try {
            $defLookup = Import-SettingDefinitions -Path $defsFile.Path
            Write-Log 'Definitions' "Loaded $($defLookup.Count) setting definitions from $($defsFile.Name)"
        } catch {
            $defLookup = $null
            Write-Log 'Definitions' 'Could not read setting definitions. Display names will not be resolved' 'WARN'
            Write-Log 'Definitions' "Details: $($_.Exception.Message)" 'WARN' -FileOnly
        }
    }

    $catMap = $null
    if ($hasCachedCats) {
        $catMap = $CachedCategoryById
        Write-Log 'Categories' "Loaded $($catMap.Count) category definitions from cache"
    } elseif ($catsFile.Exists) {
        try {
            $catMap = Import-SettingCategories -Path $catsFile.Path
            Write-Log 'Categories' "Loaded $($catMap.Count) category definitions from $($catsFile.Name)"
        } catch {
            $catMap = $null
            Write-Log 'Categories' 'Could not read category definitions. Categories will not be resolved' 'WARN'
            Write-Log 'Categories' "Details: $($_.Exception.Message)" 'WARN' -FileOnly
        }
    }

    return [PSCustomObject]@{ DefinitionLookup = $defLookup; CategoryById = $catMap }
}

Export-ModuleMember -Function @(
    'ConvertTo-SettingDefinitionLookup',
    'ConvertTo-SettingCategoryMap',
    'Get-DefinitionFile',
    'Test-DefinitionsRecent',
    'Import-SettingDefinitions',
    'Import-SettingCategories',
    'ConvertTo-SlimSettingDefinition',
    'ConvertTo-SlimSettingCategory',
    'Invoke-DefinitionDownload',
    'Get-CompareDefinitions'
)
