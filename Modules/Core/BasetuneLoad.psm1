# =============================================================================
# BasetuneLoad.psm1
# Policy loading — JSON, Tenant, and source resolution with fallback.
# =============================================================================

# Nothing left after the name filter and the platform filter, while the tenant
# or folder does have policies. One text for both filters: the filters
# themselves are logged at the start of the load ("Policy name filter: 'x'",
# "Platform filter: Windows, macOS"). Same text in the log and (UI) in the
# empty card. An empty tenant or folder has its own line ("No policies found ...").
function Get-LoadNoMatchText { 'No policies match the selected filters' }

# $true when the last Resolve-PolicySource found policies, but none that match
# the selected filters (read by the UI for the card text).
$script:LoadNoMatch = $false
function Test-LoadNoMatch { return [bool]$script:LoadNoMatch }

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
        fields   = 'missing required fields (id, name, or settings)'
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
    $fw = if ($allFiles.Count -eq 1) { 'JSON file' } else { 'JSON files' }
    Write-Log $Label "Found $($allFiles.Count) $fw in policy folder" "INFO"

    if ($allFiles.Count -eq 0) {
        Write-Log $Label "No policies found in folder '$Path'" "WARN"
        return @()
    }

    # An unreadable or incomplete file must not stop the load, nor disappear
    # silently: one line per file, then one "Skipped N files due to <reason>"
    # line per reason (first failing check wins). These files are not counted
    # as matches.
    $failCounts = @{}
    $skipped    = @{}
    # Pass 1 reads and checks every file, also the ones that fail the name
    # filter: the skip lines (other platforms, unreadable or incomplete files)
    # show the totals of the folder. A file of another platform than selected
    # is only counted, not checked or listed. The others go to $problems
    # (unreadable, missing or unknown platform, missing fields) or, when the
    # name matches, to $checked (the matches). Then the skip lines, "N policies
    # match the selected filters" and one line per match with its position
    # "[3/22]".
    $problems = [System.Collections.Generic.List[object]]::new()
    $checked  = [System.Collections.Generic.List[object]]::new()
    # Pass 1 logs nothing and takes seconds on a large folder: this line
    # shows the load is busy (animated in the UI log view, UILogAnimRegex).
    Write-Log $Label "Reading $($allFiles.Count) $fw..." "INFO"
    foreach ($file in $allFiles) {
        try {
            # [IO.File]::ReadAllText: UTF-8 (BOM honoured), literal path, about
            # 5x faster than Get-Content -Raw.
            $p = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($file.FullName)) -ErrorAction Stop
        } catch {
            $problems.Add(@{ File = $file; Why = 'read'; Error = $_.Exception.Message })
            continue
        }
        $pf = if ($p -and $p.PSObject.Properties['platforms']) { $p.platforms } else { $null }
        Add-OtherPlatformCount $pf $Platforms $skipped
        # Known platform, not selected: counted above, nothing else to report.
        $key = Get-PlatformKey $pf
        if ($key -and @($Platforms).Count -gt 0 -and $key -notin $Platforms) { continue }
        # Required: platform, id, name, settings. Type (templateReference) is optional.
        $vals = @{}
        foreach ($f in 'id', 'name', 'settings') { $vals[$f] = if ($p -and $p.PSObject.Properties[$f]) { $p.$f } else { $null } }
        $prob = Get-PolicyLoadProblem -Names 'id', 'name', 'settings' -Values $vals -PlatformsValue $pf
        if ($prob) {
            $problems.Add(@{ File = $file; Why = $prob.Why; Detail = $prob.Detail })
            continue
        }
        if ($file.BaseName -like "*$Filter*") { $checked.Add($p) }
    }

    # Other platforms, then the skipped files, then the result. One INFO line
    # per skipped file; the WARN is the summary per reason (Write-SkipSummary).
    Write-PlatformSkipLog -Label $Label -Skipped $skipped
    foreach ($rec in $problems) {
        if ($rec.Why -eq 'read') {
            Write-Log $Label "Could not read '$($rec.File.Name)'. See Basetune.log for details" "ERROR"
            Write-Log $Label "Details: $($rec.Error)" "ERROR" -FileOnly
        } else {
            Write-Log $Label "Skipped '$($rec.File.Name)' ($($rec.Detail))" "INFO"
        }
        $failCounts[$rec.Why] = 1 + [int]$failCounts[$rec.Why]
    }
    Write-SkipSummary -Label $Label -Counts $failCounts -Noun 'file'

    if ($checked.Count -eq 0) {
        Write-Log $Label (Get-LoadNoMatchText) "WARN"
        $script:LoadNoMatch = $true   # card text in the UI (Test-LoadNoMatch)
        return @()
    }

    $matchWord = if ($checked.Count -eq 1) { 'policy matches' } else { 'policies match' }
    Write-Log $Label "$($checked.Count) $matchWord the selected filters" "INFO"

    $fileIdx   = 0
    $fileTotal = $checked.Count
    $policies = @(foreach ($p in $checked) {
        $fileIdx++
        # One line per policy, like "Expanded settings: <name>" for online
        # tenants; the log view overwrites it (-Replace), the file keeps all.
        Write-Log $Label "[$fileIdx/$fileTotal] Loaded policy: $($p.name)" "INFO" -Replace 'PolicyProgress'
        # Description/Platforms/Technologies/TemplateReference: for Export only
        # (same file shape as an online tenant); the compare uses Name and Settings.
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

    # Same line as for online tenants: "Loaded 24 policies with name filter 'x'".
    $loadedMsg = Format-LoadedMessage -Count $policies.Count -Filter $Filter -Policies $policies -Platforms $Platforms
    Write-Log $Label $loadedMsg
    return $policies
}

# "Loaded 24 policies with name filter 'x'" (or "Loaded 24 policies"), for JSON and
# online tenants. With a platform selected, the count per platform is added for
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
    $msg  = if ($Filter) { "Loaded $Count $noun with name filter '$Filter'" } else { "Loaded $Count $noun" }
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

    # The Graph endpoint first, on its own line (without the $select).
    Write-Log $Label "Uri: $GraphBeta/deviceManagement/configurationPolicies" "INFO"
    Write-Log $Label "Fetching policies from Graph API..." "INFO"
    $all = @(Get-GraphPagedResults -Connection $Connection -Quiet `
        -Uri "$GraphBeta/deviceManagement/configurationPolicies?`$select=id,name,description,platforms,technologies,templateReference")
    $noun = if ($all.Count -eq 1) { 'policy' } else { 'policies' }
    Write-Log $Label "Fetched $($all.Count) $noun from Graph API"

    if ($all.Count -eq 0) {
        Write-Log $Label "No policies found in the tenant" "WARN"
        return @()
    }

    # Other platforms are counted over the whole tenant, not only the name
    # filter matches: the skip line shows the totals. Logged here, before
    # "N policies match the selected filters" (or the no-match line).
    $skipped = @{}
    foreach ($pol in $all) { Add-OtherPlatformCount $pol.platforms $Platforms $skipped }
    Write-PlatformSkipLog -Label $Label -Skipped $skipped

    # Same checks as for JSON: platform, id, name (settings after the expand),
    # over the whole tenant like the platform count, also for policies that
    # fail the name filter. A failing policy is skipped and counted, one line
    # each, and is not a match. A known platform that is not selected is only
    # counted (above). The name filter applies to the valid policies.
    $failCounts = @{}
    $valid = [System.Collections.Generic.List[object]]::new()
    foreach ($pol in $all) {
        $key = Get-PlatformKey $pol.platforms
        if ($key -and @($Platforms).Count -gt 0 -and $key -notin $Platforms) { continue }
        $prob = Get-PolicyLoadProblem -Names 'id', 'name' -Values @{ id = $pol.id; name = $pol.name } -PlatformsValue $pol.platforms
        if ($prob) {
            $shownName = if ($pol.name) { $pol.name } else { $pol.id }
            Write-Log $Label "Skipped '$shownName' ($($prob.Detail))" "INFO"
            $failCounts[$prob.Why] = 1 + [int]$failCounts[$prob.Why]
            continue
        }
        if ($pol.name -like "*$Filter*") { $valid.Add($pol) }
    }
    # Other platforms are dropped before the settings are fetched.
    $selected = @($valid)
    # Like JSON: the skipped policies before the match line.
    Write-SkipSummary -Label $Label -Counts $failCounts -Noun 'policy'
    if ($selected.Count -eq 0) {
        Write-Log $Label (Get-LoadNoMatchText) "WARN"
        $script:LoadNoMatch = $true   # card text in the UI (Test-LoadNoMatch)
        return @()
    }

    $MaxThreads = Get-ValidMaxThreads $MaxThreads

    # Same wording as for JSON: policies that pass the filters and checks
    # (the N of "[i/N]" below).
    $matchWord = if ($selected.Count -eq 1) { 'policy matches' } else { 'policies match' }
    Write-Log $Label "$($selected.Count) $matchWord the selected filters" "INFO"
    Write-Log $Label "Expanding policy settings from Graph API..." "INFO"

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
    # Shared (thread-safe) counter for "[i/N]" before each "Expanded settings".
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
                    param($entry)
                    $_q.Enqueue($entry)
                    if ($_lfPath) { Add-LogFileLine -Path $_lfPath -Entry $entry -Source $_lfSrc }
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
                    # it ("Network connection lost...").
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
            # Number and write the line under one lock: taking the number
            # inside and writing outside it lets another worker's line get
            # ahead ("[11/46]" before "[10/46]"). The positions count the
            # policies done, so the names follow the order the workers finish.
            [System.Threading.Monitor]::Enter($_prog.SyncRoot)
            try {
                $_prog.N = [int]$_prog.N + 1
                $_pos = "[$($_prog.N)/$($_prog.Total)] "
                # -Replace: the log view overwrites the previous one (New-LogEntry).
                $_entry = New-LogEntry $_label "$($_pos)Expanded settings: $_name" -Replace 'PolicyProgress'
                if ($_lq) {
                    $_lq.Enqueue($_entry)
                } else {
                    Write-Log $_label "$($_pos)Expanded settings: $_name" "INFO" -Replace 'PolicyProgress'
                }
                # Mirror to the log file directly (the parent's Set-LogFile is
                # not visible here). Best-effort; file errors never break the
                # run. Add-LogFileLine serialises with a named mutex (shared
                # with the UI, its runspaces and the CLI); always taken after
                # this lock, never before it.
                if ($_lf) {
                    Add-LogFileLine -Path $_lf -Entry $_entry -Source $using:LogSource
                }
            }
            finally { [System.Threading.Monitor]::Exit($_prog.SyncRoot) }

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
                Write-Log $Label "Could not fetch settings for '$($f.Name)'. See Basetune.log for details" "ERROR"
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
    # Only known after the expand, so its own summary here, before "Loaded ...".
    $settingsFail = @{}
    $loaded = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $expanded) {
        if (@($e.Settings).Count -eq 0) {   # null or empty, like JSON
            Write-Log $Label "Skipped '$($e.Name)' (missing required field 'settings')" "INFO"
            $settingsFail['fields'] = 1 + [int]$settingsFail['fields']
            continue
        }
        $loaded.Add($e)
    }

    Write-SkipSummary -Label $Label -Counts $settingsFail -Noun 'policy'
    Write-Log $Label (Format-LoadedMessage -Count $loaded.Count -Filter $Filter -Policies $loaded -Platforms $Platforms)
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

    $script:LoadNoMatch = $false

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
    'Get-LoadNoMatchText',
    'Test-LoadNoMatch'
)
