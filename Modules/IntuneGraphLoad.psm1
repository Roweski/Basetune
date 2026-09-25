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

    # -LiteralPath: folder names with [ ] would otherwise be read as wildcards.
    $files = @(Get-ChildItem -LiteralPath $Path -Filter "*.json" -File |
               Where-Object { $_.BaseName -like "*$Filter*" })

    if ($files.Count -eq 0) {
        Write-Log $Label "No JSON files found matching '*$Filter*' in $Path." "WARN"
        return @()
    }

    # One unreadable file must not stop the whole load, but it must not
    # disappear silently either: it is logged as an ERROR per file, and the
    # total is reported at the end.
    $failed   = 0
    $policies = @(foreach ($file in $files) {
        try {
            $p = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Log $Label "Cannot read '$($file.Name)': $($_.Exception.Message)" "ERROR"
            $failed++
            continue
        }
        if (-not $p -or -not $p.PSObject.Properties['name']) {
            Write-Log $Label "Skipped '$($file.Name)': not a policy export (no 'name' field)." "WARN"
            $failed++
            continue
        }
        [PSCustomObject]@{
            PolicyId = if ($p.PSObject.Properties['id']) { $p.id } else { $null }
            Name     = $p.name
            Settings = if ($p.PSObject.Properties['settings']) { $p.settings } else { $null }
        }
    })

    if ($failed -gt 0) {
        Write-Log $Label "$($policies.Count) policies loaded (JSON), $failed file(s) skipped — see errors above." "WARN"
    } else {
        Write-Log $Label "$($policies.Count) policies loaded (JSON)" "OK"
    }
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
#          ModulesPath — folder containing GraphtokenClient.psm1 (needed
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

    $selected = @($selected)
    if ($selected.Count -eq 0) {
        Write-Log $Label "No policies match the filter '$Filter'." "WARN"
        return @()
    }

    $MaxThreads = Get-ValidMaxThreads $MaxThreads

    Write-Log $Label "Fetching settings from Graph API..." "INFO"

    # ── Network outages ──────────────────────────────────────────────────────
    # Workers do NOT retry network errors themselves (-NetworkRetries 0): with
    # 8 workers and 100+ policies that produced a wall of retry warnings and
    # an ERROR per policy. Instead the first worker that hits a network error
    # raises $netState.Down; workers that start after that skip their request.
    # The parent then checks every $netWaitSec seconds, at most $netMaxWaits
    # times, whether Graph is reachable again, and re-runs only the policies
    # that were not fetched yet.
    $netState    = [hashtable]::Synchronized(@{ Down = $false })
    $netWaitSec  = 10
    $netMaxWaits = 3
    $netWaits    = 0
    $expanded    = [System.Collections.Generic.List[object]]::new()
    $pending     = $selected

    while ($true) {
        $netState.Down = $false
        $batch = $pending | ForEach-Object -Parallel {
            # Parallel runspaces don't inherit the parent's module imports, so any
            # call to Write-Log here (e.g. via the CLI branch below) would fail
            # with "command not recognised". Import BasetuneHelpers explicitly —
            # it's a leaf module (no further dependencies) so this is safe and
            # fast. GraphtokenClient is imported for Invoke-IntuneGraphRequest.
            #
            # Runspaces are reused between items, so import only once per
            # runspace instead of -Force re-importing for every single policy.
            if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
                Import-Module "$using:ModulesPath\BasetuneHelpers.psm1"
            }
            if (-not (Get-Command Invoke-IntuneGraphRequest -ErrorAction SilentlyContinue)) {
                Import-Module "$using:ModulesPath\GraphtokenClient.psm1"
            }
            # Route Write-Log from this worker (retries, throttling, token
            # refresh inside Invoke-IntuneGraphRequest) to the UI log queue.
            # Without this those messages went to the worker's own host and the
            # UI showed nothing while a request was being retried.
            if ($using:LogQueue) {
                $_q = $using:LogQueue
                $_lfPath = $using:LogFile
                # Also write to the log file (the worker has no Set-LogFile of
                # its own), serialised with the same mutex as the
                # "Expand Settings" lines below.
                Set-LogCallback ({
                    param($m)
                    $_q.Enqueue($m)
                    if ($_lfPath) {
                        $mx = $null
                        try {
                            $mx = [System.Threading.Mutex]::new($false, 'Basetune_LogFile_' + [System.IO.Path]::GetFileNameWithoutExtension($_lfPath))
                            [void]$mx.WaitOne()
                            Add-Content -LiteralPath $_lfPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" -Encoding UTF8
                        } catch {} finally {
                            if ($mx) { try { $mx.ReleaseMutex() } catch {}; $mx.Dispose() }
                        }
                    }
                }.GetNewClosure())
            }

            # A policy that cannot be fetched (after all retries) must not vanish:
            # a throw here used to drop just this item while the rest carried on,
            # so the compare ran without it and reported its settings as Missing.
            # Emit a failure marker instead; the parent decides what to do.
            $policy = $_   # inside catch, $_ becomes the error record
            $_net   = $using:netState

            # Network already known to be down: don't even try, the parent will
            # re-run this policy once the connection is back.
            if ($_net.Down) {
                return [PSCustomObject]@{
                    __loadError = $true; Network = $true; Source = $policy
                    Name = $policy.Name; PolicyId = $policy.Id; Error = 'skipped (network unavailable)'
                }
            }

            try {
                $r = Invoke-IntuneGraphRequest -Connection $using:Connection `
                    -Uri "$using:GraphBeta/deviceManagement/configurationPolicies/$($policy.Id)?`$expand=settings" `
                    -NetworkRetries 0
            } catch {
                $isNet = Test-GraphNetworkError $_.Exception
                if ($isNet) {
                    # Only the first worker to notice logs it, right away. The
                    # parent's "Retrying in 10 sec" messages come later, once
                    # the requests still in flight have finished.
                    $first = $false
                    [System.Threading.Monitor]::Enter($_net.SyncRoot)
                    try {
                        if (-not $_net.Down) { $_net.Down = $true; $first = $true }
                    } finally {
                        [System.Threading.Monitor]::Exit($_net.SyncRoot)
                    }
                    # UI: the network watcher already reports the outage right
                    # away ("[WARN][Network] Network connection lost..."). The
                    # CLI has no watcher, so report it here for the CLI only.
                    if ($first -and -not $using:LogQueue) {
                        Write-Log $using:Label "Network unavailable. Waiting for requests in progress to time out (max 30 seconds)..." "WARN"
                    }
                }
                return [PSCustomObject]@{
                    __loadError = $true
                    Network     = $isNet
                    Source      = $policy
                    Name        = $policy.Name
                    PolicyId    = $policy.Id
                    # Innermost message is the useful one ("No such host is
                    # known", "Connection reset") for network errors.
                    Error       = $(if ($isNet) { $_.Exception.GetBaseException().Message } else { $_.Exception.Message })
                }
            }

            # Log to UI queue if available, otherwise via Write-Log (CLI)
            $_lq    = $using:LogQueue
            $_lf    = $using:LogFile
            $_label = $using:Label
            $_name  = $policy.Name
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

            # $policy carries the list-call fields (id, name, description, platforms,
            # technologies, templateReference). $r carries the expanded settings.
            # Both are combined so Export-CachedPoliciesToJson needs no extra calls.
            [PSCustomObject]@{
                PolicyId          = $policy.Id
                Name              = $policy.Name
                Description       = $policy.description
                Platforms         = $policy.platforms
                Technologies      = $policy.technologies
                TemplateReference = $policy.templateReference
                Settings          = $r.settings
            }
        } -ThrottleLimit $MaxThreads

        $batch    = @($batch)
        foreach ($b in $batch) { if (-not $b.PSObject.Properties['__loadError']) { $expanded.Add($b) } }
        $failures = @($batch | Where-Object { $_.PSObject.Properties['__loadError'] })
        $netFail  = @($failures | Where-Object { $_.Network })
        $hardFail = @($failures | Where-Object { -not $_.Network })

        if ($hardFail.Count -gt 0) {
            foreach ($f in $hardFail) {
                Write-Log $Label "Could not fetch settings for '$($f.Name)'. $($f.Error)" "ERROR"
            }
            # Abort instead of returning a partial set: comparing without these
            # policies would report their settings as Missing, which looks like a
            # real finding. A retry usually succeeds once throttling has passed.
            $msg = "$($hardFail.Count + $netFail.Count) of $($selected.Count) policies could not be loaded. Load aborted to avoid an incomplete comparison — try again."
        Write-Log $Label "Expand settings failed: $msg" "ERROR"
        $ex = [System.Exception]::new($msg)
        $ex.Data['BasetuneLogged'] = $true
        throw $ex
        }
        if ($netFail.Count -eq 0) { break }

        # Network outage: wait for the connection, then re-run what is left.
            $reachable  = $false
        while ($netWaits -lt $netMaxWaits) {
            $netWaits++
            Write-Log $Label "Network unavailable. $($netFail.Count) policies pending. Retrying in $netWaitSec sec... [$netWaits/$netMaxWaits]" "WARN"
            Start-Sleep -Seconds $netWaitSec
            if (Test-GraphReachable) { $reachable = $true; break }
        }
        if (-not $reachable) {
            # One line per policy that could not be loaded (name only: the
            # reason is the same for all of them and is in the line below).
            Write-Log '' ''
            foreach ($f in $netFail) {
                Write-Log $Label "Could not fetch settings for '$($f.Name)'." "ERROR"
            }
            $msg = "Network unavailable: $($netFail.Count) of $($selected.Count) policies could not be loaded. Load aborted — check the connection and try again."
            Write-Log $Label "Expand settings failed: $msg" "ERROR"
            $ex = [System.Exception]::new($msg)
            $ex.Data['BasetuneLogged'] = $true   # already logged; callers don't log it again
            throw $ex
        }
        Write-Log $Label "Network is back. Fetching the remaining $($netFail.Count) policies..." "INFO"
        $pending = @($netFail | ForEach-Object { $_.Source })
    }

    Write-Log $Label "$($expanded.Count) policies expanded" "OK"
    return $expanded.ToArray()
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

    $definitionsFile = Join-Path $DefinitionsPath 'settingDefinitions.json'
    $categoriesFile  = Join-Path $DefinitionsPath 'settingCategories.json'

    # Do NOT add $top here. On configurationSettings, $top is treated as a
    # limit on the result set rather than a page size: the service returns
    # exactly that many items and omits @odata.nextLink, because it considers
    # the request fully answered. Paging then stops at the first page and the
    # rest of the catalog is silently lost ($top=500 capped this at 500 of
    # ~4000+ definitions).
    #
    # Without $top the service applies its own page size and returns a
    # nextLink per page, which Get-GraphPagedResults follows to the end.
    # MaxRetries 5 covers the occasional HTTP 504 this heavy endpoint throws;
    # TimeoutSec 60 (instead of the default 30) gives its large pages time.
    Write-Log "Download" "Downloading setting definitions..." "INFO"
    #
    # Both files are written to a .tmp file first and then moved over the old
    # one. An interrupted or failed write therefore never leaves a truncated
    # settingDefinitions.json behind, and an empty download never replaces a
    # good file.
    $definitions = @(Get-GraphPagedResults -Connection $Connection `
        -Uri "$GraphBeta/deviceManagement/configurationSettings" `
        -MaxRetries 5 -TimeoutSec 60)
    if ($definitions.Count -eq 0) {
        throw "The service returned 0 setting definitions. Existing files were left unchanged."
    }

    Write-Log "Download" "Downloading setting categories..." "INFO"
    $categories = @(Get-GraphPagedResults -Connection $Connection `
        -Uri "$GraphBeta/deviceManagement/configurationCategories" `
        -TimeoutSec 60)
    if ($categories.Count -eq 0) {
        throw "The service returned 0 setting categories. Existing files were left unchanged."
    }

    # Some categories are not returned by the configurationCategories list;
    # the compare fetches them one by one (Resolve-Category) and adds them to
    # settingCategories.json. A plain download used to overwrite the file with
    # the list only, so those categories were fetched again on the next
    # compare — after every download. Keep them.
    if (Test-Path -LiteralPath $categoriesFile) {
        try {
            $newIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@($categories | ForEach-Object { [string]$_.id }))
            $kept   = @(Get-Content -LiteralPath $categoriesFile -Raw -Encoding UTF8 | ConvertFrom-Json | Where-Object {
                $_ -and $_.id -and -not $newIds.Contains([string]$_.id) -and
                $_.displayName -ne '[Unresolved Category]' -and -not $_.PSObject.Properties['__placeholder']
            })
            if ($kept.Count -gt 0) {
                $categories += $kept
                Write-Log "Download" "Kept $($kept.Count) categories fetched earlier that are not in the category list." "INFO"
            }
        } catch {
            Write-Log "Download" "Could not read the existing settingCategories.json to keep extra categories: $($_.Exception.Message)" "WARN"
        }
    }

    # Serialising ~18k definitions to a 60+ MB file takes a while; say so,
    # otherwise the log goes quiet and it looks like nothing happens.
    Write-Log "Download" "Writing definition files to disk..." "INFO"
    # Unique temp names: a cancelled download can still be finishing in the
    # background while a new one starts; they must not share temp files.
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
    Write-Log "Download" "Saved to $definitionsFile ($($definitions.Count) definitions)" "OK"
    Write-Log "Download" "Saved to $categoriesFile ($($categories.Count) categories)" "OK"

    Write-Log "Done" "Download complete." "OK"

    # Return the lookups built from the objects that were just downloaded, so
    # the UI can refresh its cache without re-reading and parsing the file on
    # the UI thread (that froze the window for several seconds).
    return [PSCustomObject]@{
        DefinitionLookup = ConvertTo-SettingDefinitionLookup -Definitions $definitions
        CategoryById     = ConvertTo-SettingCategoryMap      -Categories  $categories
    }
}

Export-ModuleMember -Function @(
    'Read-PoliciesFromJson',
    'Read-PoliciesFromTenant',
    'Resolve-PolicySource',
    'Invoke-DefinitionDownload'
)