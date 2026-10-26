# ─────────────────────────────────────────────────────────────────────────────
# Export file names
#
# Intune allows several policies with the same name; by name alone their
# files would overwrite each other. Colliding names (case-insensitive, like
# Windows file names) get the full policy id, as the report shows it:
#     "Name_fc96b86b-65b8-4a1a-915c-a5acb84a196d.json"
# Two with the same name AND id (copied files in a JSON folder): "_2" after
# the second one.
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
            # A GUID has no invalid file name characters; replaced anyway.
            $id     = ([string]$Policies[$i].Id) -replace '[\\/:*?"<>|]', '_'
            $suffix = if ($id) { $id } else { "$($i + 1)" }
            $base   = "${base}_$suffix"
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

        [int]$MaxThreads = 8,

        # Platform keys to export (windows, macos, ...); empty = all platforms.
        [string[]]$Platforms = @()
    )

    # Guard against drive roots (C:\): New-Item on one throws a terminating error
    $resolvedOut = $OutputPath.TrimEnd('\', '/')
    if ($resolvedOut -match '^[A-Za-z]:$') {
        Write-Log "Export" "Cannot export to a drive root ($OutputPath). Choose a subfolder" "ERROR"
        return
    }

    # Existing files are NOT cleared: each policy overwrites only its own file.
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
        Write-Log "Export" "No policies found matching '*$Filter*'" "WARN"
        return
    }

    # Other platforms than selected (-Platforms): skipped, one line in the log.
    $skipped  = @{}
    $selected = @($selected | Where-Object { Test-PolicyPlatform $_.platforms $Platforms $skipped })
    Write-PlatformSkipLog -Label 'Export' -Skipped $skipped
    if ($selected.Count -eq 0) {
        Write-Log "Export" "No policies match the selected platforms ($(Get-PlatformsText $Platforms))" "WARN"
        return
    }

    Write-Log "Export" "Found policies ($($selected.Count), filter: '$Filter')"

    # File names decided up front over the whole selection (Get-ExportFileNames).
    $fileNames = Get-ExportFileNames -Policies @($selected | ForEach-Object { [PSCustomObject]@{ Name = $_.name; Id = $_.id } })
    $work = for ($i = 0; $i -lt $selected.Count; $i++) {
        [PSCustomObject]@{ Policy = $selected[$i]; FileName = $fileNames[$i] }
    }
    $MaxThreads = Get-ValidMaxThreads $MaxThreads

    # Network outage: the first worker with a network error raises this flag
    # and the others skip their request (no 30 s retry and log line each).
    $netState = [hashtable]::Synchronized(@{ Down = $false })

    # ── Expand settings + write JSON in parallel ───────────────
    # Each worker fetches its policy detail, builds the payload and writes its
    # file directly: a crash keeps the policies already done, and memory stays
    # low on large tenants. Workers emit a small status object; the downstream
    # ForEach-Object logs each one as it completes.
    #
    # Logging there, not in the worker: a -Parallel runspace has no
    # LogCallback, so Write-Log would miss the UI log. The downstream block
    # runs in the PARENT runspace, where Set-LogCallback is wired.
    #
    # $PSScriptRoot (Modules\Core) does not cross the runspace boundary:
    # captured here.
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
            # BasetuneHelpers too: Invoke-IntuneGraphRequest calls Write-Log on
            # retries, throttling and token refresh. Once per (reused) runspace.
            if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
                Import-Module "$modulesPath\BasetuneHelpers.psm1"
            }
            if (-not (Get-Command Invoke-IntuneGraphRequest -ErrorAction SilentlyContinue)) {
                Import-Module "$modulesPath\BasetuneGraph.psm1"
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

            # A payload the Intune portal's Import Policy accepts:
            #   - [ordered]: ConvertTo-Json keeps the field order.
            #   - id included: the portal ignores it, the offline compare
            #     groups on it.
            #   - technologies as a comma-separated string (Graph returns a
            #     string or an array, depending on the policy type).
            #   - templateReference only when present (endpoint security
            #     templates); an empty one can break the portal import.
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
        # $_ copied to $result first: inside a switch clause $_ is the matched
        # value (the string 'Written'), so $_.File would be $null.
        $result = $_
        switch ($result.Status) {
            'Written' {
                Write-Log "Export" "Saved: $($result.File)"
                $written++
            }
            'Skipped' {
                Write-Log "Export" "Skipping policy with empty name (id: $($result.Id))" "WARN"
                $skipped++
            }
            'Failed' {
                Write-Log "Export" "Could not export '$($result.Name)'. See the log file for details" "ERROR"
                Write-Log "Export" "Details: '$($result.Name)' (id: $($result.Id)): $($result.Error)" "ERROR" -FileOnly
                $failed++
            }
        }
    }

    $level = if ($failed -gt 0) { "WARN" } else { "INFO" }
    Write-Log "Export" "Export folder: $OutputPath" "INFO"
    Write-Log "Export" "Export completed. $written written, $skipped skipped, $failed failed" $level
    return [PSCustomObject]@{ Written = $written; Skipped = $skipped; Failed = $failed }
}

function Export-CachedPoliciesToJson {
    <#
    .SYNOPSIS
        Exports already-loaded policies to JSON files, without Graph calls
        (data from Read-PoliciesFromTenant / Read-PoliciesFromJson).
        Output is compatible with the Intune portal import and offline compare.

    .PARAMETER Policies
        Array of policy objects as cached by the Load runspace.
        Each object must carry: PolicyId, Name, Description, Platforms,
        Technologies, TemplateReference, Settings.

    .PARAMETER SelectedNames
        Optional, legacy. Policy names to export; $null or empty = every
        object in -Policies. The UI passes the selected objects as -Policies
        (by name would also export same-named policies that are not ticked).

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
        Write-Log "Export" "Cannot export to a drive root ($OutputPath). Choose a subfolder" "ERROR"
        return
    }

    # Existing files are NOT cleared: each policy overwrites only its own file
    # (a UI export is usually a selection).
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
        Write-Log "Export" "No policies to export" "WARN"
        return
    }

    Write-Log "Export" "Selected policies for export ($($toExport.Count))"

    $written = 0
    $skipped = 0
    $failed  = 0

    # Unique file names over the whole selection (same-named policies).
    $fileNames = Get-ExportFileNames -Policies @($toExport | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; Id = $_.PolicyId } })

    for ($i = 0; $i -lt $toExport.Count; $i++) {
        $policy = $toExport[$i]
        try {
            if (-not $policy.Name) {
                Write-Log "Export" "Skipping policy with empty name (id: $($policy.PolicyId))" "WARN"
                $skipped++
                continue
            }

            # Same payload as Export-PoliciesToJson (interchangeable output).
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

            Write-Log "Export" "Saved: $fileName"
            $written++
        }
        catch {
            Write-Log "Export" "Could not export '$($policy.Name)'. See the log file for details" "ERROR"
            Write-Log "Export" "Details: $($_.Exception.Message)" "ERROR" -FileOnly
            $failed++
        }
    }

    $level = if ($failed -gt 0) { "WARN" } else { "INFO" }
    Write-Log "Export" "Export folder: $OutputPath" "INFO"
    Write-Log "Export" "Export completed. $written written, $skipped skipped, $failed failed" $level
    return [PSCustomObject]@{ Written = $written; Skipped = $skipped; Failed = $failed }
}

Export-ModuleMember -Function @(
    'Export-PoliciesToJson',
    'Export-CachedPoliciesToJson'
)