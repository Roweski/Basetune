# ─────────────────────────────────────────────────────────────────────────────
# Export file names
#
# Intune allows several policies with the same name. Exporting them by name
# alone made them overwrite each other, so one of them silently disappeared
# from the export (and from any later offline compare). Names that collide —
# case-insensitive, because Windows file names are — get the first 8
# characters of the policy id appended: "Name_1a2b3c4d.json".
#
# Input : array of objects with Name and Id (Id may be empty for JSON sources)
# Output: string array of file names (without folder), same order as input;
#         $null for entries without a name
# ─────────────────────────────────────────────────────────────────────────────
function script:Get-ExportFileNames {
    param([array]$Policies)
    $safe = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $Policies) {
        if ($p.Name) { $safe.Add((([string]$p.Name) -replace '[\\/:*?"<>|]', '_')) } else { $safe.Add($null) }
    }
    $counts = @{}
    foreach ($v in $safe) {
        if (-not $v) { continue }
        $k = $v.ToLowerInvariant()
        $counts[$k] = 1 + $(if ($counts.ContainsKey($k)) { $counts[$k] } else { 0 })
    }
    $used  = @{}
    $names = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $safe.Count; $i++) {
        $base = $safe[$i]
        if (-not $base) { $names.Add($null); continue }
        if ($counts[$base.ToLowerInvariant()] -gt 1) {
            $id    = [string]$Policies[$i].Id
            $short = if ($id) { $id.Substring(0, [Math]::Min(8, $id.Length)) } else { "$($i + 1)" }
            $base  = "${base}_$short"
        }
        # Last-resort guard: never hand out the same file name twice.
        $candidate = $base; $n = 2
        while ($used.ContainsKey($candidate.ToLowerInvariant())) { $candidate = "${base}_$n"; $n++ }
        $used[$candidate.ToLowerInvariant()] = $true
        $names.Add("$candidate.json")
    }
    return ,$names.ToArray()
}

function Export-PoliciesToJson {
    <#
    .SYNOPSIS
        Exports Intune configuration policies to individual JSON files.
        Output is compatible with Intune portal import and offline comparison.

    .PARAMETER Connection
        Graph connection object (from New-GraphConnection).

    .PARAMETER Filter
        Only policies whose name contains this filter string are exported.

    .PARAMETER OutputPath
        Folder where JSON files will be written (e.g. .\JSON\Source).

    .PARAMETER GraphBeta
        Base URI for the Graph beta endpoint.

    .PARAMETER MaxThreads
        Parallel threads for settings expand. Default: 8.

    .EXAMPLE
        Export-PoliciesToJson -Connection $sourceConnection -Filter "Win-L" `
            -OutputPath ".\JSON\Source" -GraphBeta "https://graph.microsoft.com/beta"
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        $Connection,

        [Parameter(Mandatory=$false)]
        [string]$Filter = "",

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [string]$GraphBeta,

        [int]$MaxThreads = 8
    )

    # Guard against drive roots (e.g. C:\) — New-Item on an existing drive root throws a terminating error
    $resolvedOut = $OutputPath.TrimEnd('\', '/')
    if ($resolvedOut -match '^[A-Za-z]:$') {
        Write-Log "Export" "Cannot export to a drive root ($OutputPath). Choose a subfolder." "ERROR"
        return
    }

    # Ensure output folder exists. Existing files are NOT cleared — each
    # exported policy overwrites its own JSON file by name, leaving any
    # other files in the folder untouched.
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    # ── Fetch all matching policies ───────────────────────────
    $all = Get-GraphPagedResults -Connection $Connection `
        -Uri "$GraphBeta/deviceManagement/configurationPolicies?`$select=id,name,description,platforms,technologies,templateReference"

 
    $selected = if ($Filter) { 
       $all | Where-Object { $_.name -like "*$Filter*" }
    } else {
       $all
    }

    $selected = @($selected)
    if ($selected.Count -eq 0) {
        Write-Log "Export" "No policies found matching '*$Filter*'." "WARN"
        return
    }

    Write-Log "Export" "$($selected.Count) policies found matching '*$Filter*'" "OK"

    # File names are decided up front, over the whole selection, so policies
    # that share a name get distinct files (see Get-ExportFileNames).
    $fileNames = Get-ExportFileNames -Policies @($selected | ForEach-Object { [PSCustomObject]@{ Name = $_.name; Id = $_.id } })
    $work = for ($i = 0; $i -lt $selected.Count; $i++) {
        [PSCustomObject]@{ Policy = $selected[$i]; FileName = $fileNames[$i] }
    }
    $MaxThreads = Get-ValidMaxThreads $MaxThreads

    # Network outage: the first worker that hits a network error raises this
    # flag and the remaining workers skip their request, instead of every
    # worker retrying for 30 s and logging on its own.
    $netState = [hashtable]::Synchronized(@{ Down = $false })

    # ── Expand settings + write JSON in parallel ───────────────
    # Each parallel worker fetches its policy detail, builds the payload, and
    # writes its JSON file directly to disk. Workers emit small status objects
    # back into the pipeline; the downstream ForEach-Object then logs each one
    # AS IT COMPLETES — not after all workers finish.
    #
    # Why direct-to-disk instead of expand-then-write?
    #   1. Partial recovery: if the process crashes (network drop, throttle,
    #      Graph 5xx, host kill) the policies that already completed are on
    #      disk. The previous design held everything in $expanded and only
    #      wrote at the very end — a crash meant losing the whole batch.
    #   2. Lower peak memory: $expanded used to grow linearly with tenant
    #      size. On large tenants (1000+ policies) this stacked tens of MB
    #      of nested JSON-ready hashtables in RAM before any write happened.
    #
    # Why pipe through a second ForEach-Object instead of Write-Log inside
    # the parallel block?
    #   Write-Log inside -Parallel would run in the worker's own runspace,
    #   which has its own $script:LogCallback (= $null) — output would fall
    #   through to Write-Host and miss the UI log entirely. The downstream
    #   ForEach-Object runs in the PARENT runspace where Set-LogCallback
    #   was wired by the runspace work block. -Parallel streams items into
    #   that pipeline as workers complete, so each Saved/Failed message
    #   shows up in real time.
    #
    # $PSScriptRoot inside a module = the Modules folder itself; capture
    # before the parallel block since $PSScriptRoot doesn't survive the
    # runspace boundary.
    $modulesPath = $PSScriptRoot
    $written = 0
    $skipped = 0
    $failed  = 0

    $work | ForEach-Object -Parallel {
        $policy      = $_.Policy
        $fileName    = $_.FileName
        $modulesPath = $using:modulesPath
        $connection  = $using:Connection
        $graphBeta   = $using:GraphBeta
        $outputPath  = $using:OutputPath
        $detail      = $null

        try {
            # BasetuneHelpers is needed as well: Invoke-IntuneGraphRequest logs
            # through Write-Log on retries, throttling and token refresh. Without
            # it every retry failed with "Write-Log is not recognized" and the
            # policy was reported as Failed. Import once per (reused) runspace.
            if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
                Import-Module "$modulesPath\BasetuneHelpers.psm1"
            }
            if (-not (Get-Command Invoke-IntuneGraphRequest -ErrorAction SilentlyContinue)) {
                Import-Module "$modulesPath\GraphtokenClient.psm1"
            }

            $_net = $using:netState
            if ($_net.Down) { throw "skipped (network unavailable)" }
            try {
                $detail = Invoke-IntuneGraphRequest -Connection $connection `
                    -Uri "$graphBeta/deviceManagement/configurationPolicies/$($policy.Id)?`$expand=settings" `
                    -NetworkRetries 1
            } catch {
                if (Test-GraphNetworkError $_.Exception) { $_net.Down = $true }
                throw
            }

            if (-not $detail.name) {
                return [PSCustomObject]@{
                    Status = 'Skipped'
                    Name   = $null
                    Id     = $policy.Id
                    Reason = 'empty name'
                }
            }

            # Build the export payload in a shape the Intune portal's Import
            # Policy feature accepts. Notes:
            #   - [ordered]@{} so ConvertTo-Json keeps the field order below.
            #   - id IS included. The portal ignores it on import (generates
            #     a new one) and Basetune's own offline compare needs it for
            #     the dedup logic in IntuneGraphCompare.psm1.
            #   - technologies joined to comma-separated string (Graph returns
            #     either string or array depending on policy type).
            #   - templateReference only added when present. Endpoint security
            #     template policies have it; settings-catalog policies don't.
            #     A null/empty templateReference on a settings-catalog policy
            #     can break the portal import.
            $payload = [ordered]@{
                name         = [string]$detail.name
                id           = [string]$detail.id
                description  = [string]$detail.description
                platforms    = [string]$detail.platforms
                technologies = [string]($detail.technologies -join ",")
            }
            if ($null -ne $detail.templateReference) {
                $payload.templateReference = $detail.templateReference
            }
            $payload.settings = @(
                foreach ($s in $detail.settings) {
                    @{ settingInstance = $s.settingInstance }
                }
            )

            $filePath = Join-Path $outputPath $fileName
            $payload | ConvertTo-Json -Depth 50 | Out-File -LiteralPath $filePath -Encoding UTF8

            [PSCustomObject]@{
                Status = 'Written'
                Name   = $detail.name
                File   = $fileName
            }
        }
        catch {
            [PSCustomObject]@{
                Status = 'Failed'
                Name   = if ($detail -and $detail.name) { $detail.name } else { $policy.name }
                Id     = $policy.Id
                Error  = $_.Exception.Message
            }
        }
    } -ThrottleLimit $MaxThreads | ForEach-Object {
        # Runs in the PARENT runspace as each worker streams a result.
        # Write-Log here goes through the live LogCallback wired by the
        # runspace work block (export Start-Runspace -OnDone path).
        #
        # NB: stash $_ into $result BEFORE the switch. PowerShell rebinds $_
        # inside each switch clause to the matched value (e.g. the string
        # 'Written'), so $_.File from within the clause would resolve against
        # that string and produce $null — empty "Saved: " messages.
        $result = $_
        switch ($result.Status) {
            'Written' {
                Write-Log "Export" "Saved: $($result.File)" "OK"
                $written++
            }
            'Skipped' {
                Write-Log "Export" "Skipping policy with empty name (id: $($result.Id))." "WARN"
                $skipped++
            }
            'Failed' {
                Write-Log "Export" "Failed to export '$($result.Name)' (id: $($result.Id)). $($result.Error)" "ERROR"
                $failed++
            }
        }
    }

    $level = if ($failed -gt 0) { "WARN" } else { "OK" }
    Write-Log "Export" "Done. $written written, $skipped skipped, $failed failed. Output: $OutputPath" $level
    return [PSCustomObject]@{ Written = $written; Skipped = $skipped; Failed = $failed }
}

function Export-CachedPoliciesToJson {
    <#
    .SYNOPSIS
        Exports a subset of already-loaded (cached) policies to JSON files.
        No Graph API calls are made — all data comes from the in-memory cache
        populated by Read-PoliciesFromTenant / Read-PoliciesFromJson.
        Output is compatible with the Intune portal import and offline compare.

    .PARAMETER Policies
        Array of policy objects as cached by the Load runspace.
        Each object must carry: PolicyId, Name, Description, Platforms,
        Technologies, TemplateReference, Settings.

    .PARAMETER SelectedNames
        Optional, legacy. Array of policy names to export. Pass $null or an
        empty array to export every object in -Policies. The UI now passes the
        selected policy objects directly as -Policies, because selecting by
        name also exported same-named policies that were not ticked.

    .PARAMETER OutputPath
        Folder where JSON files will be written.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Policies,

        [Parameter(Mandatory=$false)]
        [string[]]$SelectedNames = @(),

        [Parameter(Mandatory)]
        [string]$OutputPath
    )

    # Guard against drive roots
    $resolvedOut = $OutputPath.TrimEnd('\', '/')
    if ($resolvedOut -match '^[A-Za-z]:$') {
        Write-Log "Export" "Cannot export to a drive root ($OutputPath). Choose a subfolder." "ERROR"
        return
    }

    # Ensure output folder exists. Existing files are NOT cleared — each
    # exported policy overwrites its own JSON file by name, leaving any
    # other files in the folder untouched. The UI export is typically a
    # partial (selection-based) export, so wiping the folder would destroy
    # policies the user didn't intend to remove.
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    # Filter to selected names when provided
    $toExport = @(if ($SelectedNames -and $SelectedNames.Count -gt 0) {
        $Policies | Where-Object { $SelectedNames -contains $_.Name }
    } else {
        $Policies
    })

    if ($toExport.Count -eq 0) {
        Write-Log "Export" "No policies to export." "WARN"
        return
    }

    Write-Log "Export" "$($toExport.Count) policies selected for export" "OK"

    $written = 0
    $skipped = 0
    $failed  = 0

    # Unique file names over the whole selection (same-named policies).
    $fileNames = Get-ExportFileNames -Policies @($toExport | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; Id = $_.PolicyId } })

    for ($i = 0; $i -lt $toExport.Count; $i++) {
        $policy = $toExport[$i]
        try {
            if (-not $policy.Name) {
                Write-Log "Export" "Skipping policy with empty name (id: $($policy.PolicyId))." "WARN"
                $skipped++
                continue
            }

            # Build the export payload — same shape as Export-PoliciesToJson so
            # the output is interchangeable with a direct-API export.
            $payload = [ordered]@{
                name         = [string]$policy.Name
                id           = [string]$policy.PolicyId
                description  = [string]$policy.Description
                platforms    = [string]$policy.Platforms
                technologies = [string]($policy.Technologies -join ",")
            }
            if ($null -ne $policy.TemplateReference) {
                $payload.templateReference = $policy.TemplateReference
            }
            $payload.settings = @(
                foreach ($s in $policy.Settings) {
                    @{ settingInstance = $s.settingInstance }
                }
            )

            $fileName = $fileNames[$i]
            $filePath = Join-Path $OutputPath $fileName
            $payload | ConvertTo-Json -Depth 50 | Out-File -LiteralPath $filePath -Encoding UTF8

            Write-Log "Export" "Saved: $fileName" "OK"
            $written++
        }
        catch {
            Write-Log "Export" "Failed to export '$($policy.Name)'. $($_.Exception.Message)" "ERROR"
            $failed++
        }
    }

    $level = if ($failed -gt 0) { "WARN" } else { "OK" }
    Write-Log "Export" "Done. $written written, $skipped skipped, $failed failed. Output: $OutputPath" $level
    return [PSCustomObject]@{ Written = $written; Skipped = $skipped; Failed = $failed }
}

Export-ModuleMember -Function @(
    'Export-PoliciesToJson',
    'Export-CachedPoliciesToJson'
)