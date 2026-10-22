# =============================================================================
# BasetuneConfig.psm1
# Basetune's own settings files, for CLI and UI:
#   Config.json   tenants (Get-BasetuneConfig, Resolve-TenantConfig; secrets
#                 stay encrypted, plaintext is migrated to DPAPI)
#   Options.json  report path, platforms, theme, max threads
#                 (Get-BasetuneOptions, Save-BasetuneOptions)
#
# Strict mode: a hand-edited file with a missing property must not slip
# through unnoticed.
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
# Read config file
# ─────────────────────────────────────────────────────────────────────────────

function Get-BasetuneConfig {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) {
        return [PSCustomObject]@{
            tenant        = $null
            __configError = "Config.json not found: $Path"
        }
    }

    $repaired = $false
    # Reading and parsing are separate steps: a locked or unreadable file is
    # "Could not read", not "not a valid JSON file".
    try {
        $rawJson = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    } catch {
        return [PSCustomObject]@{
            tenant              = $null
            __configError       = "Could not read Config.json. See the log file for details."
            __configErrorDetail = "$($_.Exception.Message)".Trim()
        }
    }
    try {
        $cfg = $rawJson | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $parseError = $_
        # A hand-typed  "maxthreads": x  (no quotes) makes the whole file
        # invalid JSON: set an invalid maxthreads to the default and parse
        # once more. Still broken: the original error is reported.
        $cfg = $null
        $mtPattern = '("maxthreads"\s*:\s*)([^,\}\r\n]*)'
        $mtMatch   = [regex]::Match($rawJson, $mtPattern)
        if ($mtMatch.Success) {
            $mtRawText = $mtMatch.Groups[2].Value.Trim()
            if (-not (Test-MaxThreadsValue ($mtRawText.Trim('"')))) {
                $mtDefault = (Get-MaxThreadsRange).Default
                $g2        = $mtMatch.Groups[2]
                $fixedJson = $rawJson.Substring(0, $g2.Index) + "$mtDefault" + $rawJson.Substring($g2.Index + $g2.Length)
                try {
                    $cfg = $fixedJson | ConvertFrom-Json -ErrorAction Stop
                    $rawJson  = $fixedJson
                    $repaired = $true
                    Write-Log 'Config' "Invalid max threads '$mtRawText' in Config.json (allowed: $((Get-MaxThreadsRange).Min)-$((Get-MaxThreadsRange).Max)). Set to default ($mtDefault)" 'WARN'
                } catch { $cfg = $null }
            }
        }
        if (-not $cfg) {
            # Short message for the log view; the full .NET parse error goes
            # to the log file only (__configErrorDetail).
            $detail = "$($parseError.Exception.Message)".Trim()
            $where  = if ($detail -match 'line (\d+), position (\d+)') { " (line $($Matches[1]), position $($Matches[2]))" } else { '' }
            return [PSCustomObject]@{
                tenant              = $null
                __configError       = "Config.json is not a valid JSON file$where. Fix the file and restart Basetune."
                __configErrorDetail = $detail
            }
        }
    }
    $cfg | Add-Member -NotePropertyName '__configError' -NotePropertyValue $null -Force

    # Internal markers (runtime state) found on disk, written by older
    # versions: removed by the sanitized re-save further down.
    $legacyMarkersOnDisk = ($rawJson -match '"__plaintextForSession"' -or
                            $rawJson -match '"__configError"')

    # ── Repair incomplete tenant entries ──────────────────────────────────────
    # A hand-edited entry without authMethod would show as "(JSON)" despite
    # its credentials. Derive the method from what the entry contains:
    #   certThumbprint present              → Certificate
    #   clientSecret present                → ClientSecret
    #   only tenantId / clientId present    → ClientSecret (UI default)
    #   only path present                   → None (offline JSON tenant)
    # API tenants also get an empty entry for every missing required field, so
    # it shows up in Tenant Configuration. A set authMethod is never changed.
    # Repairs are saved below ($repaired may already be $true from maxthreads).
    if ($cfg.PSObject.Properties['tenant'] -and $cfg.tenant) {
        foreach ($tProp in @($cfg.tenant.PSObject.Properties)) {
            $node = $tProp.Value
            if (-not $node -or $node -is [System.Collections.IDictionary]) { continue }

            $auth    = Get-NodeValue $node 'authMethod'
            $label   = if (Get-NodeValue $node 'displayName') { Get-NodeValue $node 'displayName' } else { $tProp.Name }
            $derived = $false

            if (-not $auth) {
                # A path without any credential means JSON tenant (valid
                # without authMethod), even with a leftover tenantId/clientId.
                if     (Get-NodeValue $node 'certThumbprint') { $auth = 'Certificate';  $why = 'certThumbprint is set' }
                elseif (Get-NodeValue $node 'clientSecret')   { $auth = 'ClientSecret'; $why = 'clientSecret is set' }
                elseif (Get-NodeValue $node 'path')           { $auth = 'None';         $why = 'a JSON path is set and no credentials' }
                elseif ((Get-NodeValue $node 'tenantId') -or (Get-NodeValue $node 'clientId')) {
                    $auth = 'ClientSecret'; $why = 'tenantId and/or clientId set, no certThumbprint'
                }
                else { continue }   # nothing to derive from; validation flags it below
                $derived = $true
            }

            $required = switch ($auth) {
                'ClientSecret' { @('tenantId', 'clientId', 'clientSecret') }
                'Certificate'  { @('tenantId', 'clientId', 'certThumbprint') }
                default        { @() }
            }
            $missing = @($required | Where-Object { -not $node.PSObject.Properties[$_] })

            if (-not $derived -and $missing.Count -eq 0) { continue }

            # Rebuild the node in a readable field order; keep every other
            # property that was already there.
            $order = @('displayName', 'authMethod') + $required + @('path')
            $new   = [ordered]@{}
            foreach ($f in $order) {
                if ($f -eq 'authMethod')        { $new['authMethod'] = $auth; continue }
                if ($node.PSObject.Properties[$f]) { $new[$f] = $node.$f; continue }
                if ($f -in $required)           { $new[$f] = '' }
            }
            foreach ($p in $node.PSObject.Properties) {
                if (-not $new.Contains($p.Name)) { $new[$p.Name] = $p.Value }
            }
            $tProp.Value = [PSCustomObject]$new
            $repaired    = $true

            if ($derived) {
                Write-Log 'Config' "Missing 'authMethod' for '$label'. Set to $auth ($why)" 'WARN'
            }
            if ($missing.Count -gt 0) {
                Write-Log 'Config' "Missing $(($missing | ForEach-Object { "'$_'" }) -join ', ') for '$label'. Update details in Tenant Configuration" 'WARN'
            }
        }
    }

    # ── settings block: moved to Options.json (v3.0.0) ───────────────────────
    # Config.json holds the tenants only; the options are in Options.json. A
    # settings block from before v3.0.0 is removed, not carried over
    # (Options.json starts with defaults).
    if ($cfg.PSObject.Properties['settings']) {
        $cfg.PSObject.Properties.Remove('settings')
        $repaired = $true
        Write-Log 'Config' "Settings moved from Config.json to Options.json with default values" 'INFO'
    }

    # ── Maximum field lengths (same as Tenant Configuration) ─────────────────
    # displayName > 64: shortened and saved (only a label). tenantId /
    # clientId / certThumbprint > 64: wrong anyway, only reported (shortening
    # would silently make another wrong value). clientSecret is encrypted, so
    # not checked.
    if ($cfg.PSObject.Properties['tenant'] -and $cfg.tenant) {
        foreach ($tProp in @($cfg.tenant.PSObject.Properties)) {
            $node = $tProp.Value
            if (-not $node -or $node -is [System.Collections.IDictionary]) { continue }
            $dn = [string](Get-NodeValue $node 'displayName')
            if ($dn.Length -gt 64) {
                $short = $dn.Substring(0, 64)
                $node.displayName = $short
                $repaired = $true
                $shown = if ($dn.Length -gt 40) { $dn.Substring(0, 40) + '...' } else { $dn }
                Write-Log 'Config' "Display name '$shown' in Config.json is longer than 64 characters. Shortened automatically" 'WARN'
            }
            $label = if (Get-NodeValue $node 'displayName') { Get-NodeValue $node 'displayName' } else { $tProp.Name }
            foreach ($f in @(@{ Key = 'tenantId'; Name = 'Tenant ID' }, @{ Key = 'clientId'; Name = 'Client ID' },
                             @{ Key = 'certThumbprint'; Name = 'Certificate Thumbprint' })) {
                $v = [string](Get-NodeValue $node $f.Key)
                if ($v.Length -gt 64) {
                    Write-Log 'Config' "$($f.Name) for '$label' in Config.json is longer than 64 characters. Update details in Tenant Configuration" 'WARN'
                }
            }
        }
    }

    # ── Secrets stay encrypted in memory ──────────────────────────────────────
    # clientSecret stays "DPAPI:<blob>" for the whole session, decrypted only
    # when needed (New-GraphConnection; Tenant Configuration on select), so no
    # save can write a plaintext secret by mistake. A legacy plaintext secret
    # on disk is encrypted here and written back, in memory too.
    $configChanged = $repaired   # repaired entries are saved together with any secret migration
    if ($cfg.PSObject.Properties['tenant'] -and $cfg.tenant) {
        foreach ($prop in $cfg.tenant.PSObject.Properties) {
            $node = $prop.Value
            if (-not $node) { continue }
            if ((Get-NodeValue $node 'authMethod') -ne 'ClientSecret') { continue }
            $stored = [string](Get-NodeValue $node 'clientSecret')
            if (-not $stored -or (Test-SecretEncrypted $stored)) { continue }

            $dn    = Get-NodeValue $node 'displayName'
            $label = if ($dn) { $dn } else { $prop.Name }
            try {
                $node.clientSecret = Protect-Secret $stored
                $configChanged = $true
                Write-Log 'Config' "Plaintext clientSecret for '$label' encrypted in Config.json. Older backups may still contain it in plaintext" 'WARN'
            } catch {
                Write-Log 'Config' "Could not encrypt clientSecret for '$label'. It stays in plaintext until the next start. See the log file for details" 'ERROR'
                Write-Log 'Config' "Details: $($_.Exception.Message)" 'ERROR' -FileOnly
            }
        }
    }

    # Write repairs / migrated secrets (best effort: a failed write is logged,
    # the session goes on). Internal __* markers (__configError, __invalid,
    # legacy __plaintextForSession) are left out of the payload.
    if ($configChanged -or $legacyMarkersOnDisk) {
        if ($legacyMarkersOnDisk -and -not $configChanged) {
            Write-Log 'Config' "Removing old internal markers from Config.json (no effect on tenants)" 'INFO'
        }
        try {
            $cleanCfg = [ordered]@{}
            foreach ($p in $cfg.PSObject.Properties) {
                if ($p.Name.StartsWith('__')) { continue }
                if ($p.Name -eq 'tenant' -and $p.Value) {
                    # Strip __* from every tenant node too.
                    $cleanTenants = [ordered]@{}
                    foreach ($tProp in $p.Value.PSObject.Properties) {
                        $tNode = $tProp.Value
                        if (-not $tNode) {
                            $cleanTenants[$tProp.Name] = $tNode
                            continue
                        }
                        $cleanNode = [ordered]@{}
                        foreach ($np in $tNode.PSObject.Properties) {
                            if ($np.Name.StartsWith('__')) { continue }
                            $cleanNode[$np.Name] = $np.Value
                        }
                        $cleanTenants[$tProp.Name] = $cleanNode
                    }
                    $cleanCfg['tenant'] = $cleanTenants
                } else {
                    $cleanCfg[$p.Name] = $p.Value
                }
            }
            $cleanCfg | ConvertTo-Json -Depth 8 | Out-File $Path -Encoding UTF8
        } catch {
            Write-Log 'Config' "Could not write Config.json. See the log file for details" 'ERROR'
            Write-Log 'Config' "Details: $($_.Exception.Message)" 'ERROR' -FileOnly
        }
    }

    # ── Validate tenant entries ───────────────────────────────────────────────
    if ($cfg.PSObject.Properties['tenant'] -and $cfg.tenant) {
        $tenantProps = @($cfg.tenant.PSObject.Properties)
        $tenantKeys  = @($tenantProps | ForEach-Object { $_.Name })
        foreach ($key in $tenantKeys) {
            $prop = $cfg.tenant.PSObject.Properties[$key]
            $node = if ($prop) { $prop.Value } else { $null }
            if (-not $node) { continue }
            $invalid = $false
            $nAuth   = Get-NodeValue $node 'authMethod'
            # Offline-only tenants (authMethod 'None' or absent + path) are valid
            if ($nAuth -eq 'None' -or (-not $nAuth -and (Get-NodeValue $node 'path'))) {
                # valid offline entry
            } elseif (-not (Get-NodeValue $node 'tenantId') -or -not (Get-NodeValue $node 'clientId')) {
                $invalid = $true
            } elseif ($nAuth -eq 'ClientSecret' -and -not (Get-NodeValue $node 'clientSecret')) {
                # No secret at all (one that cannot be decrypted here is
                # reported by New-GraphConnection when used). The UI keeps the
                # tenant visible so the secret can be entered.
                $invalid = $true
            } elseif ($nAuth -eq 'Certificate' -and -not (Get-NodeValue $node 'certThumbprint')) {
                $invalid = $true
            } elseif ($nAuth -ne 'ClientSecret' -and $nAuth -ne 'Certificate' -and $nAuth -ne 'None') {
                $invalid = $true
            }
            if ($invalid) {
                try { $node | Add-Member -NotePropertyName '__invalid' -NotePropertyValue $true -Force -ErrorAction Stop } catch {}
            }
        }
        return $cfg
    }

    return $cfg
}

# ─────────────────────────────────────────────────────────────────────────────
# Options.json — Basetune options (UI Options window, also read by the CLI)
#
#   {
#     "reportPath": "C:\\Basetune\\Reports",
#     "platforms":  ["windows"],
#     "theme":      "dark",
#     "maxThreads": 8
#   }
#
# A missing, unreadable or invalid JSON file is replaced by the defaults.
# Missing or invalid values get the default and are written back (same rules
# as the Options window). Relative report paths are relative to the Basetune
# folder.
#
# Returns [PSCustomObject]@{ ReportPath; Platforms; Theme; MaxThreads }
#   ReportPath — as stored (may be relative); the caller resolves it.
# ─────────────────────────────────────────────────────────────────────────────
function Get-BasetuneOptions {
    param([Parameter(Mandatory)][string]$Path)

    $btRoot    = Split-Path (Split-Path ([System.IO.Path]::GetFullPath($Path)) -Parent) -Parent
    $mtRange   = Get-MaxThreadsRange
    $rpDefault = (Resolve-FolderPath -Path 'Reports' -BasePath $btRoot).Path
    if (-not $rpDefault) { $rpDefault = "$btRoot\Reports" }
    $defaults  = [ordered]@{
        reportPath = $rpDefault
        platforms  = [string[]](Get-DefaultPlatforms)
        theme      = 'dark'
        maxThreads = $mtRange.Default
    }
    $toResult = {
        param($o)
        [PSCustomObject]@{
            ReportPath = $o.reportPath
            Platforms  = [string[]]$o.platforms
            Theme      = $o.theme
            MaxThreads = $o.maxThreads
        }
    }

    $write = $false
    $opt   = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) {
        foreach ($k in $defaults.Keys) { $opt[$k] = $defaults[$k] }
        $write = $true
        # Log file only: on a first start the view shows one line ("Click the
        # gear icon ..."), not one per file created.
        Write-Log 'Config' "Options.json created with default values" 'INFO' -FileOnly
    } else {
        $raw = $null
        try {
            $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $raw = $null
            Write-Log 'Config' "Details: $($_.Exception.Message)" 'WARN' -FileOnly
        }
        # Unreadable or not a JSON object: replaced by the defaults (nothing
        # that cannot be set again in Options).
        if ($raw -isnot [System.Management.Automation.PSCustomObject]) {
            Write-Log 'Config' "Options.json was not valid and has been replaced with default values" 'WARN'
            try { Save-BasetuneOptions -Path $Path -ReportPath $defaults.reportPath -Platforms $defaults.platforms -Theme $defaults.theme -MaxThreads $defaults.maxThreads }
            catch {
                Write-Log 'Config' "Could not write Options.json. See the log file for details" 'ERROR'
                Write-Log 'Config' "Details: $($_.Exception.Message)" 'ERROR' -FileOnly
            }
            return (& $toResult $defaults)
        }
        $has = { param($n) [bool]$raw.PSObject.Properties[$n] }

        # Report path
        if (-not ((& $has 'reportPath') -and "$($raw.reportPath)".Trim())) {
            $opt.reportPath = $rpDefault; $write = $true
            Write-Log 'Config' "Options.json is missing report path setting. Set to default ($rpDefault)" 'INFO'
        } else {
            $rpRaw   = "$($raw.reportPath)"
            $rpCheck = Resolve-FolderPath -Path $rpRaw -BasePath $btRoot
            if ($rpCheck.Error) {
                $opt.reportPath = $rpDefault; $write = $true
                # Network paths (\\server\share) are not supported (UI and CLI).
                $rpWhat = if ($rpRaw.Trim() -match '^[\\/]{2}') { 'Network report path (not supported)' } else { 'Invalid report path' }
                Write-Log 'Config' "$rpWhat '$($rpRaw.Trim())' in Options.json. Set to default ($rpDefault)" 'WARN'
            } elseif ($rpRaw.Trim() -match '^([A-Za-z]:|"|/)' -and $rpCheck.Path -ne $rpRaw) {
                # Full path written back normalized (C:\Reports\ -> C:\Reports);
                # relative paths stay as typed.
                $opt.reportPath = $rpCheck.Path; $write = $true
            } else {
                $opt.reportPath = $rpRaw
            }
        }

        # Platforms (windows, macos, ios, android, linux)
        $pfAllowed = @(Get-PlatformOptions | ForEach-Object { $_.Key })
        $pfRaw     = if (& $has 'platforms') { @($raw.platforms) } else { @() }
        $pfValid   = [string[]](Get-ValidPlatforms $pfRaw)
        $pfTyped   = @($pfRaw | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        $pfBad     = @($pfTyped | Where-Object { $_.ToLowerInvariant() -notin $pfAllowed })
        $opt.platforms = $pfValid
        if (-not (& $has 'platforms')) {
            $write = $true
            Write-Log 'Config' "Options.json is missing platforms setting. Set to default ($($pfValid -join ', '))" 'INFO'
        } else {
            if ($pfBad.Count -gt 0) {
                Write-Log 'Config' "Invalid platforms '$($pfBad -join ', ')' in Options.json (allowed: $($pfAllowed -join ', ')). Set to: $($pfValid -join ', ')" 'WARN'
            }
            if ($pfBad.Count -gt 0 -or $raw.platforms -isnot [System.Array] -or (($pfTyped -join ',') -cne ($pfValid -join ','))) {
                $write = $true
            }
        }

        # Theme: light / dark
        $thRaw  = if (& $has 'theme') { "$($raw.theme)" } else { $null }
        $thNorm = "$thRaw".Trim().ToLower()
        if ($thNorm -notin @('light', 'dark')) {
            $opt.theme = 'dark'; $write = $true
            if ($null -eq $thRaw) {
                Write-Log 'Config' "Options.json is missing theme setting. Set to default (dark)" 'INFO'
            } else {
                Write-Log 'Config' "Invalid theme '$thRaw' in Options.json (allowed: light, dark). Set to default (dark)" 'WARN'
            }
        } else {
            $opt.theme = $thNorm
            if ($thRaw -cne $thNorm) { $write = $true }
        }

        # Max threads
        if (-not (& $has 'maxThreads')) {
            $opt.maxThreads = $mtRange.Default; $write = $true
            Write-Log 'Config' "Options.json is missing max threads setting. Set to default ($($mtRange.Default))" 'INFO'
        } elseif (-not (Test-MaxThreadsValue $raw.maxThreads)) {
            $opt.maxThreads = Get-ValidMaxThreads $raw.maxThreads; $write = $true
            Write-Log 'Config' "Invalid max threads '$($raw.maxThreads)' in Options.json (allowed: $($mtRange.Min)-$($mtRange.Max)). Set to default ($($opt.maxThreads))" 'WARN'
        } else {
            $opt.maxThreads = [int]"$($raw.maxThreads)".Trim()
            if ($raw.maxThreads -isnot [int] -and $raw.maxThreads -isnot [long]) { $write = $true }
        }
    }

    if ($write) {
        try { Save-BasetuneOptions -Path $Path -ReportPath $opt.reportPath -Platforms $opt.platforms -Theme $opt.theme -MaxThreads $opt.maxThreads }
        catch {
            Write-Log 'Config' "Could not write Options.json. See the log file for details" 'ERROR'
            Write-Log 'Config' "Details: $($_.Exception.Message)" 'ERROR' -FileOnly
        }
    }
    return (& $toResult $opt)
}

# Writes Options.json (always all four values, in a fixed order). Throws on a
# write error; the caller reports it.
function Save-BasetuneOptions {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ReportPath,
        [string[]]$Platforms,
        [string]$Theme,
        $MaxThreads
    )
    $out = [ordered]@{
        reportPath = $ReportPath
        platforms  = [string[]](Get-ValidPlatforms $Platforms)   # always an array, also with one platform
        theme      = if ($Theme -eq 'light') { 'light' } else { 'dark' }
        maxThreads = Get-ValidMaxThreads $MaxThreads
    }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $out | ConvertTo-Json -Depth 4 | Out-File -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
}

# ─────────────────────────────────────────────────────────────────────────────
# Resolve-TenantConfig
#
# Source and target tenant nodes by SourceId / TargetId (no default; an
# invalid entry gives $null).
# ─────────────────────────────────────────────────────────────────────────────
function Resolve-TenantConfig {
    param(
        [Parameter(Mandatory)]$Cfg,
        [string]$SourceId = "",
        [string]$TargetId = ""
    )

    $srcKey = if ($SourceId) { $SourceId } else { $null }
    $tgtKey = if ($TargetId) { $TargetId } else { $null }

    # Safe lookup: strict mode throws on a missing property
    $srcNode = $null
    $tgtNode = $null
    if ($srcKey -and $Cfg.tenant) {
        $prop = $Cfg.tenant.PSObject.Properties[$srcKey]
        if ($prop) { $srcNode = $prop.Value }
    }
    if ($tgtKey -and $Cfg.tenant) {
        $prop = $Cfg.tenant.PSObject.Properties[$tgtKey]
        if ($prop) { $tgtNode = $prop.Value }
    }

    if ($srcNode -and $srcNode.PSObject.Properties['__invalid'] -and $srcNode.__invalid) { $srcNode = $null }
    if ($tgtNode -and $tgtNode.PSObject.Properties['__invalid'] -and $tgtNode.__invalid) { $tgtNode = $null }

    return [PSCustomObject]@{
        source = $srcNode
        target = $tgtNode
        tenant = $Cfg.tenant
    }
}

Export-ModuleMember -Function @(
    'Get-BasetuneConfig',
    'Get-BasetuneOptions',
    'Save-BasetuneOptions',
    'Resolve-TenantConfig'
)
