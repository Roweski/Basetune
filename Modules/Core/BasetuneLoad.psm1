# =============================================================================
# BasetuneLoad.psm1
# Policy loading — JSON, Tenant, and source resolution with fallback.
# =============================================================================

# Nothing left after the platform filter. With a name filter:
# "No policies match the filter 'x'"; without: "No policies found for the
# selected platforms". Same text in the log and (UI) in the empty card.
function Get-PlatformNoMatchText {
    param([string]$Filter)
    if ($Filter) { "No policies match the filter '$Filter'" }
    else         { "No policies found for the selected platforms" }
}

# $true when the last Resolve-PolicySource (without name filter) found
# policies, but none for the selected platforms (read by the UI for the card).
$script:LoadPlatformSkipped = $false
function Test-LoadPlatformSkipped { return [bool]$script:LoadPlatformSkipped }

# ─────────────────────────────────────────────────────────────────────────────
# LOAD VALIDATION (shared by JSON and Graph)
# Required: platform, then the fields id, name, settings. One reason per item,
# the first failing check wins: 'platform' (missing or unknown) before 'fields'.
# Get-PolicyLoadProblem returns @{ Why; Detail } or $null when the item is fine.
# Write-SkipSummary logs one line per reason, e.g.
#   "Skipped 2 files due to missing or unknown platform"
# ─────────────────────────────────────────────────────────────────────────────
function script:Get-PolicyLoadProblem {
    param([string[]]$Names, [hashtable]$Values, $PlatformsValue)
    if (-not (Get-PlatformKey $PlatformsValue)) {
        $pv = "$PlatformsValue".Trim()
        return [PSCustomObject]@{
            Why    = 'platform'
            Detail = if ($pv) { "unknown platform '$pv'" } else { 'missing platform' }
        }
    }
    $missing = @(foreach ($f in $Names) {
        $v = $Values[$f]
        if ($null -eq $v -or ($v -is [string] -and -not $v.Trim())) { $f }
    })
    if ($missing.Count -gt 0) {
        return [PSCustomObject]@{
            Why    = 'fields'
            Detail = if ($missing.Count -eq 1) { "missing required field '$($missing[0])'" }
                     else                      { "missing required fields '$($missing -join ', ')'" }
        }
    }
    return $null
}

function script:Write-SkipSummary {
    param([string]$Label, [hashtable]$Counts, [ValidateSet('file', 'policy')][string]$Noun)
    $text = @{
        read     = 'read errors'
        platform = 'missing or unknown platform'
        fields   = 'missing required fields (id, name or settings)'
    }
    foreach ($r in 'read', 'platform', 'fields') {
        $n = [int]$Counts[$r]
        if ($n -le 0) { continue }
        $w = if ($Noun -eq 'file') { if ($n -eq 1) { 'file' } else { 'files' } }
             else                  { if ($n -eq 1) { 'policy' } else { 'policies' } }
        Write-Log $Label "Skipped $n $w due to $($text[$r])" "WARN"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# READ POLICIES FROM JSON
#
# One policy object per JSON file (as written by Export-PoliciesToJson).
#
# Input  : Path    — folder containing *.json policy files
#          Filter  — optional name filter (wildcard, default: all files)
#          Label   — log label shown in Write-Log output
#          Platforms — platform keys to load (windows, macos, ...); empty = all
# Output : array of [PSCustomObject]@{ PolicyId; Name; Settings (+ export metadata) }
# ─────────────────────────────────────────────────────────────────────────────
function Read-PoliciesFromJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Filter = "",
        [Parameter(Mandatory)][string]$Label,
        [string[]]$Platforms = @()
    )

    # -LiteralPath: folder names with [ ] would otherwise be read as wildcards.
    $allFiles = @(Get-ChildItem -LiteralPath $Path -Filter "*.json" -File)
    # After the "Platform filter: ..." header: JSON files before the name filter.
    $fw = if ($allFiles.Count -eq 1) { 'file' } else { 'files' }
    Write-Log $Label "Found $($allFiles.Count) $fw in policy folder" "INFO"
    $files = @($allFiles | Where-Object { $_.BaseName -like "*$Filter*" })

    if ($files.Count -eq 0) {
        $msg = if ($Filter) { "No policies match the filter '$Filter'" } else { "No policies found in '$Path'" }
        Write-Log $Label $msg "WARN"
        return @()
    }

    # An unreadable file must not stop the load, nor disappear silently: one
    # ERROR per file, the total at the end.
    $failed     = 0
    # One reason per failed file (first failing check wins); one
    # "Skipped N files due to <reason>" line per reason.
    $failCounts = @{}
    $skipped    = @{}
    # Two passes. Pass 1 reads and checks the files that pass the name filter,
    # without logging; then "N files match the selected filters" (name +
    # platform filter); pass 2 logs one line per file with its position
    # "[3/22]" among those N. Other platforms are only counted
    # (Write-PlatformSkipLog), not listed.
    $checked = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        $rec = @{ File = $file; Status = 'ok'; Detail = $null; Why = $null; P = $null; Error = $null }
        try {
            # [IO.File]::ReadAllText: UTF-8 (BOM honoured), literal path, about
            # 5x faster than Get-Content -Raw.
            $p = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($file.FullName)) -ErrorAction Stop
        } catch {
            $rec.Status = 'read'; $rec.Error = $_.Exception.Message
            $checked.Add($rec); continue
        }
        # Required: platform, id, name, settings. Type (templateReference) is optional.
        $pf   = if ($p -and $p.PSObject.Properties['platforms']) { $p.platforms } else { $null }
        $vals = @{}
        foreach ($f in 'id', 'name', 'settings') { $vals[$f] = if ($p -and $p.PSObject.Properties[$f]) { $p.$f } else { $null } }
        $prob = Get-PolicyLoadProblem -Names 'id', 'name', 'settings' -Values $vals -PlatformsValue $pf
        if ($prob) {
            $rec.Status = 'problem'; $rec.Why = $prob.Why; $rec.Detail = $prob.Detail
            $checked.Add($rec); continue
        }
        # Other platform than selected (settings.platforms): skipped, counted.
        if (-not (Test-PolicyPlatform $pf $Platforms $skipped)) { continue }
        $rec.P = $p
        $checked.Add($rec)
    }

    $matchWord = if ($checked.Count -eq 1) { 'file matches' } else { 'files match' }
    Write-Log $Label "$($checked.Count) $matchWord the selected filters" "INFO"

    $fileIdx   = 0
    $fileTotal = $checked.Count
    $policies = @(foreach ($rec in $checked) {
        $fileIdx++
        $pos  = " [$fileIdx/$fileTotal]"
        $file = $rec.File
        if ($rec.Status -eq 'read') {
            Write-Log $Label "Could not read '$($file.Name)'. See the log file for details$pos" "ERROR"
            Write-Log $Label "Details: $($rec.Error)" "ERROR" -FileOnly
            $failed++
            $failCounts['read'] = 1 + [int]$failCounts['read']
            continue
        }
        if ($rec.Status -eq 'problem') {
            Write-Log $Label "Skipped '$($file.Name)': $($rec.Detail)$pos" "WARN"
            $failed++
            $failCounts[$rec.Why] = 1 + [int]$failCounts[$rec.Why]
            continue
        }
        $p = $rec.P
        # One line per policy, like "Expanded settings: <name>" for API tenants.
        Write-Log $Label "Loaded policy: $($p.name)$pos" "INFO"
        # Description/Platforms/Technologies/TemplateReference: for Export only
        # (same file shape as an API tenant); the compare uses Name and Settings.
        [PSCustomObject]@{
            PolicyId          = if ($p.PSObject.Properties['id']) { $p.id } else { $null }
            Name              = $p.name
            Description       = if ($p.PSObject.Properties['description'])       { $p.description }       else { $null }
            Platforms         = if ($p.PSObject.Properties['platforms'])         { $p.platforms }         else { $null }
            Technologies      = if ($p.PSObject.Properties['technologies'])      { $p.technologies }      else { $null }
            TemplateReference = if ($p.PSObject.Properties['templateReference']) { $p.templateReference } else { $null }
            Settings          = if ($p.PSObject.Properties['settings']) { $p.settings } else { $null }
        }
    })

    # Failed files first, then other platforms, then the Loaded line (result).
    Write-SkipSummary -Label $Label -Counts $failCounts -Noun 'file'
    Write-PlatformSkipLog -Label $Label -Skipped $skipped
    if ($policies.Count -eq 0 -and $skipped.Count -gt 0 -and $failed -eq 0) {
        Write-Log $Label (Get-PlatformNoMatchText -Filter $Filter) "WARN"
        $script:LoadPlatformSkipped = -not $Filter   # card text in the UI (Test-LoadPlatformSkipped)
        return @()
    }

    # Same line as for API tenants: "Loaded 24 policies with filter 'x'".
    $loadedMsg = Format-LoadedMessage -Count $policies.Count -Filter $Filter -Policies $policies -Platforms $Platforms
    Write-Log $Label $loadedMsg "OK"
    return $policies
}

# "Loaded 24 policies with filter 'x'" (or "Loaded 24 policies"), for JSON and
# API tenants. With a platform selected, the count per platform is added for
# platforms with policies plus the selected ones (also with 0):
# "Loaded 207 policies (Windows: 207, macOS: 0)".
# "Other" is only a safe fallback: policies without a known platform are never
# loaded (Test-PolicyPlatform).
function script:Get-LoadedPlatformCounts {
    param($Policies)
    $counts = @{}
    foreach ($p in @($Policies)) {
        $pv  = if ($p -and $p.PSObject.Properties['Platforms']) { $p.Platforms } else { $null }
        $key = Get-PlatformKey $pv
        if (-not $key) { $key = 'other' }
        $counts[$key] = 1 + [int]$counts[$key]
    }
    return $counts
}

function Format-LoadedMessage {
    param([int]$Count, [string]$Filter, $Policies, [string[]]$Platforms)
    $noun = if ($Count -eq 1) { 'policy' } else { 'policies' }
    $msg  = if ($Filter) { "Loaded $Count $noun with filter '$Filter'" } else { "Loaded $Count $noun" }
    if ($Count -gt 0 -and @($Platforms).Count -ge 1) {
        $counts = Get-LoadedPlatformCounts $Policies
        # Platforms with policies, plus every selected platform (also with 0).
        $parts  = @(Get-PlatformOptions | Where-Object { $counts[$_.Key] -or $_.Key -in $Platforms } |
                    ForEach-Object { "$($_.Label): $([int]$counts[$_.Key])" })
        if ($counts['other']) { $parts += "Other: $($counts['other'])" }
        if ($parts.Count) { $msg += " ($($parts -join ', '))" }
    }
    return $msg
}

# ─────────────────────────────────────────────────────────────────────────────
# READ POLICIES FROM TENANT
#
# Online mode: fetches the policies from Graph and expands their settings in
# parallel.
#
# Input  : Connection  — Graph connection object (from New-GraphConnection)
#          Filter      — optional name filter (wildcard, default: all policies)
#          Label       — log label shown in Write-Log output
#          GraphBeta   — base URI for the Graph beta endpoint
#          ModulesPath — folder containing BasetuneGraph.psm1 (needed
#                        inside the parallel runspaces)
#          MaxThreads  — parallel throttle limit (default: 8)
#          LogQueue    — optional ConcurrentQueue for GUI log forwarding;
#                        falls back to Write-Log when $null
#          LogFile     — optional log file for the parallel workers (they
#                        don't see the parent's Set-LogFile). Best-effort.
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
        [string]$LogFile = $null,
        [string[]]$Platforms = @()
    )

    Write-Log $Label "Fetching policies from Graph API..." "INFO"
    $all = @(Get-GraphPagedResults -Connection $Connection -Quiet `
        -Uri "$GraphBeta/deviceManagement/configurationPolicies?`$select=id,name,description,platforms,technologies,templateReference")
    $noun = if ($all.Count -eq 1) { 'policy' } else { 'policies' }
    Write-Log $Label "Fetched $($all.Count) $noun from Graph API" "OK"

    $selected = if ($Filter) {
        $all | Where-Object { $_.name -like "*$Filter*" }
    } else {
        $all
    }

    $selected = @($selected)
    if ($selected.Count -eq 0) {
        $msg = if ($Filter) { "No policies match the filter '$Filter'" } else { "No policies found in the tenant" }
        Write-Log $Label $msg "WARN"
        return @()
    }

    # Same checks as for JSON: platform, id, name (settings after the expand).
    # A failing policy is skipped and counted, one line each.
    $failCounts = @{}
    $valid = [System.Collections.Generic.List[object]]::new()
    foreach ($pol in $selected) {
        $prob = Get-PolicyLoadProblem -Names 'id', 'name' -Values @{ id = $pol.id; name = $pol.name } -PlatformsValue $pol.platforms
        if ($prob) {
            $shownName = if ($pol.name) { $pol.name } else { $pol.id }
            Write-Log $Label "Skipped '$shownName': $($prob.Detail)" "WARN"
            $failCounts[$prob.Why] = 1 + [int]$failCounts[$prob.Why]
            continue
        }
        $valid.Add($pol)
    }
    $selected = @($valid)

    # Other platforms are dropped before the settings are fetched.
    $skipped  = @{}
    $selected = @($selected | Where-Object { Test-PolicyPlatform $_.platforms $Platforms $skipped })
    # Skip lines go just before "Loaded ..." (like JSON), or here when nothing
    # is left to load.
    if ($selected.Count -eq 0) {
        Write-SkipSummary -Label $Label -Counts $failCounts -Noun 'policy'
        Write-PlatformSkipLog -Label $Label -Skipped $skipped
        if ($failCounts.Count -eq 0) {
            Write-Log $Label (Get-PlatformNoMatchText -Filter $Filter) "WARN"
            $script:LoadPlatformSkipped = -not $Filter   # card text in the UI (Test-LoadPlatformSkipped)
        }
        return @()
    }

    $MaxThreads = Get-ValidMaxThreads $MaxThreads

    # Same wording as for JSON: policies that pass the filters and checks
    # (the N of "[i/N]" below).
    $matchWord = if ($selected.Count -eq 1) { 'policy matches' } else { 'policies match' }
    Write-Log $Label "$($selected.Count) $matchWord the selected filters" "INFO"
    Write-Log $Label "Loading settings from Graph API..." "INFO"

    # ── Network outages ──────────────────────────────────────────────────────
    # Workers do NOT retry network errors (-NetworkRetries 0): with 8 workers
    # and 100+ policies that would give a wall of retry warnings and an ERROR
    # per policy. The first worker that hits one raises $netState.Down; later
    # workers skip their request. The parent checks every $netWaitSec seconds
    # (max $netMaxWaits per outage) whether Graph is reachable and re-runs only
    # the policies not fetched yet. After $netMaxOutages outages in one load,
    # the next one aborts right away.
    $netState    = [hashtable]::Synchronized(@{ Down = $false })
    $netWaitSec  = 10
    $netMaxWaits = 3
    $netWaits    = 0
    $netMaxOutages = 3
    $netOutages    = 0
    # Shared (thread-safe) counter for "[i/N]" after each "Expanded settings".
    $expandProg  = [hashtable]::Synchronized(@{ N = 0; Total = $selected.Count })
    $expanded    = [System.Collections.Generic.List[object]]::new()
    $pending     = $selected

    # 'UI' / 'CLI' for the workers' log file lines (no Set-LogFile there).
    $LogSource = Get-LogSource

    while ($true) {
        $netState.Down = $false
        $batch = $pending | ForEach-Object -Parallel {
            # Parallel runspaces don't inherit the parent's imports: Write-Log
            # would be "not recognised". BasetuneHelpers is a leaf module (safe
            # and fast); BasetuneGraph for Invoke-IntuneGraphRequest.
            # Runspaces are reused between items: import once per runspace.
            if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
                Import-Module "$using:ModulesPath\BasetuneHelpers.psm1"
            }
            if (-not (Get-Command Invoke-IntuneGraphRequest -ErrorAction SilentlyContinue)) {
                Import-Module "$using:ModulesPath\BasetuneGraph.psm1"
            }
            # Route Write-Log from this worker (retries, throttling, token
            # refresh in Invoke-IntuneGraphRequest) to the UI log queue;
            # otherwise it goes to the worker's own host and the UI shows
            # nothing while a request is retried.
            if ($using:LogQueue) {
                $_q = $using:LogQueue
                $_lfPath = $using:LogFile
                $_lfSrc  = $using:LogSource
                # Also to the log file (no Set-LogFile in the worker), same
                # mutex as the "Expanded settings" lines below.
                Set-LogCallback ({
                    param($m)
                    $_q.Enqueue($m)
                    if ($_lfPath) { Add-LogFileLine -Path $_lfPath -Line $m -Source $_lfSrc }
                }.GetNewClosure())
            }

            # A policy that cannot be fetched must not vanish: a throw here
            # would drop just this item while the rest carries on (the compare
            # would then report its settings as Missing). Emit a failure marker
            # instead; the parent decides.
            $policy = $_   # inside catch, $_ becomes the error record
            $_net   = $using:netState

            # Network known to be down: skip; the parent re-runs it later.
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
                    # Only the first worker to notice logs it, right away (the
                    # parent's "Retrying in 10 sec" comes once requests in
                    # flight have finished).
                    $first = $false
                    [System.Threading.Monitor]::Enter($_net.SyncRoot)
                    try {
                        if (-not $_net.Down) { $_net.Down = $true; $first = $true }
                    } finally {
                        [System.Threading.Monitor]::Exit($_net.SyncRoot)
                    }
                    # CLI only: in the UI the network watcher already reports
                    # it ("[WARN][Network] Network connection lost...").
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
                    # Network errors: the innermost message is the useful one
                    # ("No such host is known", "Connection reset").
                    Error       = $(if ($isNet) { $_.Exception.GetBaseException().Message } else { $_.Exception.Message })
                }
            }

            # Log to UI queue if available, otherwise via Write-Log (CLI)
            $_lq    = $using:LogQueue
            $_lf    = $using:LogFile
            $_label = $using:Label
            $_name  = $policy.Name
            $_prog  = $using:expandProg
            [System.Threading.Monitor]::Enter($_prog.SyncRoot)
            try { $_prog.N = [int]$_prog.N + 1; $_pos = " [$($_prog.N)/$($_prog.Total)]" }
            finally { [System.Threading.Monitor]::Exit($_prog.SyncRoot) }
            $_msg   = "[INFO][$_label] Expanded settings: $_name$_pos"
            if ($_lq) {
                $_lq.Enqueue($_msg)
            } else {
                Write-Log $_label "Expanded settings: $_name$_pos" "INFO"
            }
            # Mirror to the log file directly (the parent's Set-LogFile is not
            # visible here). Best-effort; file errors never break the run.
            if ($_lf) {
                # Add-LogFileLine serialises with a named mutex (shared with
                # the UI, its runspaces and the CLI).
                Add-LogFileLine -Path $_lf -Line $_msg -Source $using:LogSource
            }

            # List-call fields ($policy) + expanded settings ($r): so
            # Export-CachedPoliciesToJson needs no extra calls.
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
                Write-Log $Label "Could not fetch settings for '$($f.Name)'. See the log file for details" "ERROR"
                Write-Log $Label "Details: $($f.Error)" "ERROR" -FileOnly
            }
            # Abort instead of returning a partial set: their settings would show
            # as Missing, which looks like a real finding. A retry usually
            # succeeds once throttling has passed.
            $msg = "Could not load $($hardFail.Count + $netFail.Count) of $($selected.Count) policies. Load aborted to avoid an incomplete comparison. Try again"
            Write-Log $Label $msg "ERROR"
            $ex = [System.Exception]::new($msg)
            $ex.Data['BasetuneLogged'] = $true   # already logged; callers don't log it again
            throw $ex
        }
        if ($netFail.Count -eq 0) { break }

        # Network outage: wait for the connection, then re-run what is left.
        # More than $netMaxOutages outages in one load: abort without waiting.
        $reachable  = $false
        $netOutages++
        if ($netOutages -gt $netMaxOutages) { $netWaits = $netMaxWaits }
        while ($netWaits -lt $netMaxWaits) {
            $netWaits++
            Write-Log $Label "Network unavailable. $($netFail.Count) policies pending. Retrying in $netWaitSec sec... [$netWaits/$netMaxWaits]" "WARN"
            Start-Sleep -Seconds $netWaitSec
            if (Test-GraphReachable) { $reachable = $true; break }
        }
        if (-not $reachable) {
            # The list goes to the log file only (long for a large tenant);
            # the view shows the summary below.
            foreach ($f in $netFail) {
                Write-Log $Label "Could not fetch settings for '$($f.Name)'" "ERROR" -FileOnly
            }
            $msg = "Could not load $($netFail.Count) of $($selected.Count) policies"
            Write-Log $Label $msg "ERROR"
            Write-Log $Label "Load aborted. Check the network connection and try again" "ERROR"
            $ex = [System.Exception]::new($msg)
            $ex.Data['BasetuneLogged'] = $true   # already logged; callers don't log it again
            throw $ex
        }
        Write-Log $Label "Network is back. Fetching the remaining $($netFail.Count) policies..." "INFO"
        # A next outage gets its own 3 attempts again: [1/3], [2/3], [3/3].
        $netWaits = 0
        $pending = @($netFail | ForEach-Object { $_.Source })
    }

    # settings is required too: a policy without it is skipped like the others.
    $loaded = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $expanded) {
        if (@($e.Settings).Count -eq 0) {   # null or empty, like JSON
            Write-Log $Label "Skipped '$($e.Name)': missing required field 'settings'" "WARN"
            $failCounts['fields'] = 1 + [int]$failCounts['fields']
            continue
        }
        $loaded.Add($e)
    }

    Write-SkipSummary -Label $Label -Counts $failCounts -Noun 'policy'
    Write-PlatformSkipLog -Label $Label -Skipped $skipped
    Write-Log $Label (Format-LoadedMessage -Count $loaded.Count -Filter $Filter -Policies $loaded -Platforms $Platforms) "OK"
    return $loaded.ToArray()
}

# ─────────────────────────────────────────────────────────────────────────────
# RESOLVE POLICY SOURCE
#
# Single entry point for policy loading; $Origin (as Get-TenantMode returns):
#   "Online"  — Read-PoliciesFromTenant. Without a Connection: logs an error
#               and returns an empty array.
#   "Offline" — Read-PoliciesFromJson. JsonPath must already be resolved.
#
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
        [string]$LogFile = $null,
        [string[]]$Platforms = @()
    )

    $script:LoadPlatformSkipped = $false

    # Online origin — but no connection available, hard stop
    if ($Origin -eq "Online" -and -not $Connection) {
        $tenantPart = if ($TenantLabel) { " '$TenantLabel'" } else { "" }
        Write-Log $Label "Could not connect to tenant$tenantPart. Check credentials in the configuration" "ERROR"
        return @()
    }

    if ($Origin -eq "Offline") {
        if (-not $JsonPath -or -not (Test-Path $JsonPath)) {
            Write-Log $Label "No valid policy folder available. No policies loaded" "ERROR"
            return @()
        }

        Write-Log $Label "Using path: $JsonPath" "INFO"
        return Read-PoliciesFromJson -Path $JsonPath -Filter $Filter -Label $Label -Platforms $Platforms
    }

    # Online origin with connection
    return Read-PoliciesFromTenant -Connection $Connection -Filter $Filter `
        -Label $Label -GraphBeta $GraphBeta -ModulesPath $ModulesPath `
        -MaxThreads $MaxThreads -LogQueue $LogQueue -LogFile $LogFile -Platforms $Platforms
}

Export-ModuleMember -Function @(
    'Read-PoliciesFromJson',
    'Read-PoliciesFromTenant',
    'Resolve-PolicySource',
    'Get-PlatformNoMatchText',
    'Test-LoadPlatformSkipped'
)
