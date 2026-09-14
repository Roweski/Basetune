# =============================================================================
# IntuneGraphLoad.psm1
# Policy loading — JSON, Tenant, and source resolution with fallback
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# READ POLICIES FROM JSON
#
# Loads policies from a folder of JSON files previously exported by
# Export-PoliciesToJson. Each file becomes one policy object.
#
# Input  : Path    — folder containing *.json policy files
#          Filter  — optional name filter (wildcard, default: all files)
#          Label   — log label shown in Write-Log output
# Output : array of [PSCustomObject]@{ PolicyId; Name; Settings }
# ─────────────────────────────────────────────────────────────────────────────
function Read-PoliciesFromJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Filter = "",
        [Parameter(Mandatory)][string]$Label
    )

    $files = Get-ChildItem -Path $Path -Filter "*.json" |
             Where-Object { $_.BaseName -like "*$Filter*" }

    if ($files.Count -eq 0) {
        Write-Log $Label "No JSON files found matching '*$Filter*' in $Path." "WARN"
        return @()
    }

    $policies = foreach ($file in $files) {
        $p = Get-Content $file.FullName -Raw | ConvertFrom-Json
        [PSCustomObject]@{
            PolicyId = $p.id
            Name     = $p.name
            Settings = $p.settings
        }
    }

    Write-Log $Label "$($policies.Count) policies loaded (JSON)" "OK"
    return $policies
}

# ─────────────────────────────────────────────────────────────────────────────
# READ POLICIES FROM TENANT
#
# Fetches configuration policies directly from the Graph API and expands
# their settings in parallel. Used for Online mode.
#
# Input  : Connection  — Graph connection object (from New-GraphConnection)
#          Filter      — optional name filter (wildcard, default: all policies)
#          Label       — log label shown in Write-Log output
#          GraphBeta   — base URI for the Graph beta endpoint
#          ModulesPath — folder containing GraphTokenClient.psm1 (needed
#                        inside the parallel runspaces)
#          MaxThreads  — parallel throttle limit (default: 8)
#          LogQueue    — optional ConcurrentQueue for GUI log forwarding;
#                        falls back to Write-Log when $null
#          LogFile     — optional path to mirror parallel-block log lines to,
#                        since parallel runspaces can't see the parent's
#                        Set-LogFile state. Best-effort; never throws.
# Output : array of [PSCustomObject]@{ PolicyId; Name; Settings }
# ─────────────────────────────────────────────────────────────────────────────
function Read-PoliciesFromTenant {
    param(
        [Parameter(Mandatory)]$Connection,
        [string]$Filter = "",
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$GraphBeta,
        [Parameter(Mandatory)][string]$ModulesPath,
        [int]$MaxThreads = 8,
        $LogQueue = $null,
        [string]$LogFile = $null
    )

    Write-Log $Label "Fetching policies from Graph API..." "INFO"
    $all = Get-GraphPagedResults -Connection $Connection `
        -Uri "$GraphBeta/deviceManagement/configurationPolicies?`$select=id,name,description,platforms,technologies,templateReference"

    $selected = if ($Filter) {
        $all | Where-Object { $_.name -like "*$Filter*" }
    } else {
        $all
    }

    Write-Log $Label "$($selected.Count) policies selected (filter: '$Filter')" "OK"

    Write-Log $Label "Fetching settings from Graph API..." "INFO"
    $expanded = $selected | ForEach-Object -Parallel {
        # Parallel runspaces don't inherit the parent's module imports, so any
        # call to Write-Log here (e.g. via the CLI branch below) would fail
        # with "command not recognised". Import BasetuneHelpers explicitly —
        # it's a leaf module (no further dependencies) so this is safe and
        # fast. GraphTokenClient is imported for Invoke-IntuneGraphRequest.
        Import-Module "$using:ModulesPath\BasetuneHelpers.psm1" -Force
        Import-Module "$using:ModulesPath\GraphTokenClient.psm1" -Force

        $r = Invoke-IntuneGraphRequest -Connection $using:Connection `
            -Uri "$using:GraphBeta/deviceManagement/configurationPolicies/$($_.Id)?`$expand=settings"

        # Log to UI queue if available, otherwise via Write-Log (CLI)
        $_lq    = $using:LogQueue
        $_lf    = $using:LogFile
        $_label = $using:Label
        $_name  = $_.Name
        $_msg   = "[INFO][$_label] Expand Settings: $_name"
        if ($_lq) {
            $_lq.Enqueue($_msg)
        } else {
            Write-Log $_label "Expand Settings: $_name" "INFO"
        }
        # Mirror to log file so disk log matches what the UI shows. The
        # parent's Set-LogFile state isn't visible in parallel runspaces, so
        # we write directly here. Add-Content from multiple threads in
        # parallel can interleave or truncate lines, so a named system mutex
        # serialises the write. Best-effort; file errors never break the run.
        if ($_lf) {
            $_stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            # Mutex name must be deterministic per log-file path so all
            # parallel threads share the same lock. Session-scoped (no
            # 'Global\' prefix) since everything runs in one process.
            $_mutexName = 'Basetune_LogFile_' + ([System.IO.Path]::GetFileNameWithoutExtension($_lf))
            $_mutex = $null
            try {
                $_mutex = [System.Threading.Mutex]::new($false, $_mutexName)
                [void]$_mutex.WaitOne()
                try { Add-Content -LiteralPath $_lf -Value "$_stamp $_msg" -Encoding UTF8 } catch {}
            } catch {} finally {
                if ($_mutex) {
                    try { $_mutex.ReleaseMutex() } catch {}
                    $_mutex.Dispose()
                }
            }
        }

        # $_ carries the list-call fields (id, name, description, platforms,
        # technologies, templateReference). $r carries the expanded settings.
        # Both are combined so Export-CachedPoliciesToJson needs no extra calls.
        [PSCustomObject]@{
            PolicyId          = $_.Id
            Name              = $_.Name
            Description       = $_.description
            Platforms         = $_.platforms
            Technologies      = $_.technologies
            TemplateReference = $_.templateReference
            Settings          = $r.settings
        }
    } -ThrottleLimit $MaxThreads

    Write-Log $Label "$($expanded.Count) policies expanded" "OK"
    return $expanded
}

# ─────────────────────────────────────────────────────────────────────────────
# RESOLVE POLICY SOURCE
#
# Single entry point for policy loading. Selects the correct data origin
# based on $Origin:
#
#   "Online"  — fetches policies from the Graph API via Read-PoliciesFromTenant.
#               Requires a valid Connection; returns an empty array and logs
#               an error if none is provided.
#   "Offline" — loads policies from JSON files via Read-PoliciesFromJson.
#               JsonPath must already be fully resolved by the caller.
#
# The values match what Get-TenantMode (BasetuneConfig.psm1) returns, so the
# caller can pipe straight from one to the other.
#
# Input  : see individual parameters
# Output : array of [PSCustomObject]@{ PolicyId; Name; Settings }
# ─────────────────────────────────────────────────────────────────────────────
function Resolve-PolicySource {
    param(
        [Parameter(Mandatory)][string]$Origin,
        $Connection,
        [string]$Filter = "",
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$GraphBeta,
        [Parameter(Mandatory)][string]$ModulesPath,
        [string]$JsonPath = "",
        [string]$TenantLabel = "",
        [int]$MaxThreads = 8,
        $LogQueue = $null,
        [string]$LogFile = $null
    )

    # Online origin — but no connection available, hard stop
    if ($Origin -eq "Online" -and -not $Connection) {
        $tenantPart = if ($TenantLabel) { " '$TenantLabel'" } else { "" }
        Write-Log $Label "Could not connect to tenant$tenantPart. Check credentials in the configuration." "ERROR"
        return @()
    }

    if ($Origin -eq "Offline") {
        if (-not $JsonPath -or -not (Test-Path $JsonPath)) {
            Write-Log $Label "No valid JSON path available. No policies loaded." "ERROR"
            return @()
        }

        Write-Log $Label "Using path: $JsonPath" "INFO"
        return Read-PoliciesFromJson -Path $JsonPath -Filter $Filter -Label $Label
    }

    # Online origin with connection
    return Read-PoliciesFromTenant -Connection $Connection -Filter $Filter `
        -Label $Label -GraphBeta $GraphBeta -ModulesPath $ModulesPath `
        -MaxThreads $MaxThreads -LogQueue $LogQueue -LogFile $LogFile
}

# ─────────────────────────────────────────────────────────────────────────────
# DOWNLOAD SETTING DEFINITIONS & CATEGORIES
#
# Fetches the full configurationSettings and configurationCategories catalogs
# from Graph and writes them to the local Definitions folder. These files
# back the friendly-name lookups used by the compare engine.
#
# Input  : Connection      — Graph connection (online tenant required)
#          DefinitionsPath — target folder for settingDefinitions.json
#                            and settingCategories.json
#          GraphBeta       — base URI for the Graph beta endpoint
#          LogQueue        — reserved for API symmetry with Read-PoliciesFromTenant;
#                            this function calls Graph serially in the caller's
#                            runspace, so Write-Log already routes through
#                            Set-LogCallback — no per-call enqueue needed.
# Output : none (writes two JSON files)
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

    $definitionsFile = Join-Path $DefinitionsPath 'settingDefinitions.json'
    $categoriesFile  = Join-Path $DefinitionsPath 'settingCategories.json'

    # $top=500 keeps each page small. configurationSettings is one of the
    # heaviest read endpoints in Graph beta (the full Settings Catalog); asking
    # for the default page size regularly makes the backend exceed the gateway
    # window, which surfaces as HTTP 504. Smaller pages also mean less lost
    # work when a single page does fail.
    Write-Log "Download" "Downloading setting definitions..." "INFO"
    $definitions = Get-GraphPagedResults -Connection $Connection `
        -Uri "$GraphBeta/deviceManagement/configurationSettings?`$top=500" `
        -MaxRetries 5
    $definitions | ConvertTo-Json -Depth 20 | Out-File $definitionsFile -Encoding UTF8
    Write-Log "Download" "Saved to $definitionsFile ($($definitions.Count) definitions)" "OK"

    Write-Log "Download" "Downloading setting categories..." "INFO"
    $categories = Get-GraphPagedResults -Connection $Connection `
        -Uri "$GraphBeta/deviceManagement/configurationCategories"
    $categories | ConvertTo-Json -Depth 20 | Out-File $categoriesFile -Encoding UTF8
    Write-Log "Download" "Saved to $categoriesFile ($($categories.Count) categories)" "OK"

    Write-Log "Done" "Download complete." "OK"
}

Export-ModuleMember -Function @(
    'Read-PoliciesFromJson',
    'Read-PoliciesFromTenant',
    'Resolve-PolicySource',
    'Invoke-DefinitionDownload'
)