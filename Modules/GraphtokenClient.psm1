# =============================================================================
# GraphtokenClient.psm1
# Multi-tenant Microsoft Graph module - Hardened Stateless Version
# Supports: ClientSecret, Certificate ONLY
# =============================================================================


Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
# Logging functions (Write-Log, Set-LogCallback, Set-LogFile) live in
# BasetuneHelpers.psm1 — loaded as the first nested module by the manifest
# so they're available to every module here. This file calls Write-Log
# freely; the binding is resolved at call time via the manifest's shared
# module scope.
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# Safe property read for tenant nodes.
# This module runs under Set-StrictMode -Version Latest, where reading a
# property that does not exist throws. Config.json can be edited by hand, so a
# tenant node may lack authMethod, clientSecret, displayName, ... Reading those
# through this helper returns $null instead of aborting the whole config load.
# Supports PSCustomObject (from JSON) and IDictionary (ordered hashtable).
# ─────────────────────────────────────────────────────────────────────────────
function script:Get-NodeValue {
    param($Node, [string]$Name)
    if ($null -eq $Node) { return $null }
    if ($Node -is [System.Collections.IDictionary]) {
        if ($Node.Contains($Name)) { return $Node[$Name] }
        return $null
    }
    $p = $Node.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# ─────────────────────────────────────────────────────────────────────────────
# Request timeouts
# Invoke-RestMethod waits forever by default (-TimeoutSec 0). When the network
# drops in the middle of a request (e.g. Wi-Fi switched off) the connection
# is not closed, so a Load hung on "Expand Settings: ..." until the network
# came back. With a timeout the request fails as a transport error, is
# retried, and finally reported.
# 30 s for normal requests (policy list/expand, export). The heavy definition
# download passes a longer timeout (60 s) itself.
# ─────────────────────────────────────────────────────────────────────────────
$script:RequestTimeoutSec = 30
$script:TokenTimeoutSec   = 30

# PowerShell 7.4+ changed the web cmdlets: -TimeoutSec became an alias of
# -ConnectionTimeoutSeconds and only covers connecting / receiving headers.
# A response body that stalls halfway (network dropped mid-download — the
# typical Wi-Fi-off case) is covered by -OperationTimeoutSeconds, per read.
# Without it the request still hung forever. Use it when available.
$script:HasOperationTimeout = (Get-Command Invoke-RestMethod).Parameters.ContainsKey('OperationTimeoutSeconds')

function script:Get-TimeoutParams {
    param([int]$Seconds)
    $p = @{ TimeoutSec = $Seconds }
    if ($script:HasOperationTimeout) { $p['OperationTimeoutSeconds'] = $Seconds }
    return $p
}

function script:Get-TokenExpiry {
    param([int]$ExpiresIn = 3600)
    # Subtract 60 seconds as a safety buffer so the token is refreshed
    # slightly before it actually expires, avoiding mid-request failures.
    return (Get-Date).AddSeconds($ExpiresIn - 60)
}

# ─────────────────────────────────────────────────────────────────────────────
# Read config file
# ─────────────────────────────────────────────────────────────────────────────

function Get-GraphConfig {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) {
        return [PSCustomObject]@{
            tenant        = $null
            __configError = "Config file not found: $Path"
        }
    }

    $repaired = $false
    try {
        $rawJson = Get-Content $Path -Raw
        $cfg = $rawJson | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $parseError = $_
        # A hand-typed maxthreads such as  "maxthreads": x  (no quotes) makes
        # the whole file invalid JSON. Replace an invalid maxthreads value with
        # the default and try once more; if the file is broken somewhere else
        # this does not help and the original error is reported.
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
                    Write-Log 'Config' "Invalid maxthreads '$mtRawText' in Config.json (not valid JSON); set to $mtDefault." 'WARN'
                } catch { $cfg = $null }
            }
        }
        if (-not $cfg) {
            return [PSCustomObject]@{
                tenant        = $null
                __configError = "Invalid JSON in config file: $parseError"
            }
        }
    }
    $cfg | Add-Member -NotePropertyName '__configError' -NotePropertyValue $null -Force

    # Detect legacy internal markers on disk. These should NEVER be persisted —
    # they're in-memory runtime state. Earlier versions of this function had
    # bugs that serialized them; auto-cleanup now so users don't have to edit
    # Config.json by hand. Triggers a sanitized re-save further down.
    $legacyMarkersOnDisk = ($rawJson -match '"__plaintextForSession"' -or
                            $rawJson -match '"__configError"')

    # ── Repair incomplete tenant entries ──────────────────────────────────────
    # A hand-edited Config.json can lack authMethod. The UI then showed the
    # tenant as "(JSON)" while its credentials were filled in. Derive the
    # method from what the entry contains:
    #   certThumbprint present              → Certificate
    #   clientSecret present                → ClientSecret
    #   only tenantId / clientId present    → ClientSecret (UI default)
    #   only path present                   → None (offline JSON tenant)
    # Online tenants also get an empty entry for every missing required field
    # (tenantId, clientId, clientSecret or certThumbprint), so the field shows
    # up in Tenant Configuration to be filled in. An authMethod that IS set is
    # never changed. Repairs are written back to Config.json (save below).
    # ($repaired may already be $true from the maxthreads JSON repair above.)
    if ($cfg.PSObject.Properties['tenant'] -and $cfg.tenant) {
        foreach ($tProp in @($cfg.tenant.PSObject.Properties)) {
            $node = $tProp.Value
            if (-not $node -or $node -is [System.Collections.IDictionary]) { continue }

            $auth    = Get-NodeValue $node 'authMethod'
            $label   = if (Get-NodeValue $node 'displayName') { Get-NodeValue $node 'displayName' } else { $tProp.Name }
            $derived = $false

            if (-not $auth) {
                # A path without any credential keeps meaning "offline JSON
                # tenant" (that was already valid without authMethod), even
                # when a tenantId/clientId is left over in the entry.
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
                Write-Log 'Config' "authMethod was missing for '$label'; set to $auth ($why)." 'WARN'
            }
            if ($missing.Count -gt 0) {
                Write-Log 'Config' "Added empty $($missing -join ', ') for '$label'. Fill in the value(s) in Tenant Configuration." 'WARN'
            }
        }
    }

    # ── Secrets stay encrypted in memory ──────────────────────────────────────
    # clientSecret values are NOT decrypted here. They stay as "DPAPI:<blob>"
    # in the config objects for the whole session and are decrypted only at
    # the moment they are needed:
    #   - New-GraphConnection (token request: definition download, loading
    #     source/target policies, the connection test in Tenant Configuration)
    #   - Tenant Configuration, when a tenant is selected in the list
    # Nothing in memory holds a plaintext secret that a save could write to
    # disk by mistake.
    #
    # Legacy plaintext secrets found on disk are encrypted and written back
    # (one-shot migration); the in-memory value becomes the encrypted form too.
    # ── Repair settings.maxthreads ────────────────────────────────────────────
    # An invalid value (0, negative, above the maximum, not a number) was
    # already replaced by the default at use time, but stayed wrong in the
    # file. Write the value that is actually used back to Config.json.
    if ($cfg.PSObject.Properties['settings'] -and $cfg.settings -and
        $cfg.settings.PSObject.Properties['maxthreads']) {
        $mtRaw = $cfg.settings.maxthreads
        if (-not (Test-MaxThreadsValue $mtRaw)) {
            $mtFixed = Get-ValidMaxThreads $mtRaw
            $cfg.settings.maxthreads = $mtFixed
            $repaired = $true
            $mtRange = Get-MaxThreadsRange
            Write-Log 'Config' "Invalid maxthreads '$mtRaw' in Config.json (allowed $($mtRange.Min)-$($mtRange.Max)); set to $mtFixed." 'WARN'
        }
    }

    # ── Repair settings.path.report ───────────────────────────────────────────
    # An invalid report path (C:dddd, \Reports, bad characters, a drive that
    # does not exist) is replaced by the default <Basetune>\Reports folder, the
    # folder that is used anyway. A valid full path is written back normalized
    # (C:\Reports\ -> C:\Reports). Relative paths are left as they are.
    if ($cfg.PSObject.Properties['settings'] -and $cfg.settings -and
        $cfg.settings.PSObject.Properties['path'] -and $cfg.settings.path -and
        $cfg.settings.path.PSObject.Properties['report'] -and
        $cfg.settings.path.report -and "$($cfg.settings.path.report)".Trim()) {
        $rpRaw   = "$($cfg.settings.path.report)"
        $btRoot  = Split-Path (Split-Path ([System.IO.Path]::GetFullPath($Path)) -Parent) -Parent
        $rpCheck = Resolve-FolderPath -Path $rpRaw -BasePath $btRoot
        if ($rpCheck.Error) {
            $rpDefault = (Resolve-FolderPath -Path 'Reports' -BasePath $btRoot).Path
            if (-not $rpDefault) { $rpDefault = "$btRoot\Reports" }
            $cfg.settings.path.report = $rpDefault
            $repaired = $true
            Write-Log 'Config' "Invalid report path '$($rpRaw.Trim())' in Config.json. Set to default: $rpDefault" 'WARN'
        } elseif ($rpRaw.Trim() -match '^([A-Za-z]:|\\\\|"|/)' -and $rpCheck.Path -cne $rpRaw) {
            $cfg.settings.path.report = $rpCheck.Path
            $repaired = $true
            Write-Log 'Config' "Report path in Config.json normalized: '$rpRaw' -> '$($rpCheck.Path)'." 'INFO'
        }
    }

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
                Write-Log 'Config' "Plaintext clientSecret detected for '$label'. Encrypted in place. External backups may still contain plaintext." 'WARN'
            } catch {
                Write-Log 'Config' "Failed to encrypt clientSecret for '$label'. Leaving plaintext (will retry next launch). $($_.Exception.Message)" 'ERROR'
            }
        }
    }

    # Write repairs / migrated secrets to disk. Best-effort: a failed write is
    # logged but doesn't block the session.
    #
    # Build a sanitized payload that omits all internal __* markers
    # (__configError, __invalid, and legacy __plaintextForSession from an
    # earlier buggy migration). Without this, ConvertTo-Json would serialize
    # those properties to disk.
    if ($configChanged -or $legacyMarkersOnDisk) {
        if ($legacyMarkersOnDisk -and -not $configChanged) {
            Write-Log 'Config' "Cleaning legacy internal markers from Config.json (no functional impact)." 'INFO'
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
            Write-Log 'Config' "Could not write Config.json: $($_.Exception.Message)" 'ERROR'
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
                # No secret at all. (A secret that exists but cannot be
                # decrypted on this machine is only detected when it is used:
                # New-GraphConnection reports it.) The UI keeps the tenant
                # visible so the secret can be entered.
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
# Resolve-TenantConfig
#
# Resolves source and target tenant nodes from the config using SourceId /
# TargetId. Both IDs must be provided explicitly — there is no default fallback.
# ─────────────────────────────────────────────────────────────────────────────
function Resolve-TenantConfig {
    param(
        [Parameter(Mandatory)]$Cfg,
        [string]$SourceId = "",
        [string]$TargetId = ""
    )

    $srcKey = if ($SourceId) { $SourceId } else { $null }
    $tgtKey = if ($TargetId) { $TargetId } else { $null }

    # Safe property lookup — avoids "property cannot be found" crash
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

# ─────────────────────────────────────────────────────────────────────────────
# Get-TenantList
#
# Returns an ordered list of tenant entries for UI population.
# Output: array of [PSCustomObject]@{ Key; Label; Node }
# ─────────────────────────────────────────────────────────────────────────────
function Get-TenantList {
    param([Parameter(Mandatory)]$Cfg)

    if (-not $Cfg -or -not ($Cfg.PSObject.Properties['tenant']) -or -not $Cfg.tenant) { return @() }

    return @($Cfg.tenant.PSObject.Properties | ForEach-Object {
        $node  = $_.Value
        $label = if ($node -and $node.PSObject.Properties['displayName'] -and $node.displayName) { $node.displayName } else { $_.Name }
        [PSCustomObject]@{ Key = $_.Name; Label = $label; Node = $node }
    })
}

# ─────────────────────────────────────────────────────────────────────────────
# Token acquisition
# ─────────────────────────────────────────────────────────────────────────────

function script:Get-TokenViaClientSecret {
    param($TenantId, $ClientId, $ClientSecret)

    $body = @{
        grant_type    = 'client_credentials'
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = 'https://graph.microsoft.com/.default'
    }

    $timeouts = Get-TimeoutParams $script:TokenTimeoutSec
    Invoke-RestMethod @timeouts `
        -Method Post `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body $body
}

function script:Get-TokenViaCertificate {
    param($TenantId, $ClientId, $CertThumbprint)

    $cert = Get-Item "Cert:\CurrentUser\My\$CertThumbprint" -ErrorAction SilentlyContinue
    if (-not $cert) {
        $cert = Get-Item "Cert:\LocalMachine\My\$CertThumbprint" -ErrorAction Stop
    }

    $now = [System.DateTimeOffset]::UtcNow

    $header = [Convert]::ToBase64String(
        [System.Text.Encoding]::UTF8.GetBytes(
            (ConvertTo-Json @{ alg="RS256"; typ="JWT"; x5t=[Convert]::ToBase64String($cert.GetCertHash()) } -Compress)
        )
    ).TrimEnd('=').Replace('+','-').Replace('/','_')

    $payload = [Convert]::ToBase64String(
        [System.Text.Encoding]::UTF8.GetBytes(
            (ConvertTo-Json @{
                aud="https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
                exp=$now.AddMinutes(10).ToUnixTimeSeconds()
                iss=$ClientId
                nbf=$now.ToUnixTimeSeconds()
                sub=$ClientId
                jti=[System.Guid]::NewGuid().ToString()
            } -Compress)
        )
    ).TrimEnd('=').Replace('+','-').Replace('/','_')

    $toSign = "$header.$payload"

    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)

    $signature = [Convert]::ToBase64String(
        $rsa.SignData(
            [System.Text.Encoding]::UTF8.GetBytes($toSign),
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
        )
    ).TrimEnd('=').Replace('+','-').Replace('/','_')

    $assertion = "$toSign.$signature"

    $body = @{
        grant_type            = 'client_credentials'
        client_id             = $ClientId
        client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        client_assertion      = $assertion
        scope                 = 'https://graph.microsoft.com/.default'
    }

    $timeouts = Get-TimeoutParams $script:TokenTimeoutSec
    Invoke-RestMethod @timeouts `
        -Method Post `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body $body
}

# ─────────────────────────────────────────────────────────────────────────────
# Connection
# ─────────────────────────────────────────────────────────────────────────────

function New-GraphConnection {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Label
    )

    $authMethod = Get-NodeValue $Config 'authMethod'
    $tenantId   = Get-NodeValue $Config 'tenantId'
    $clientId   = Get-NodeValue $Config 'clientId'

    # Offline (JSON) tenants and unknown auth methods have no token endpoint.
    # Say so explicitly instead of the generic "returned no response" below.
    if ($authMethod -notin @('ClientSecret', 'Certificate')) {
        $shown = if ($authMethod) { $authMethod } else { 'None' }
        Write-Log $Label "Cannot connect: authMethod '$shown' is not an online method (ClientSecret or Certificate)." "WARN"
        return $null
    }
    if (-not $tenantId -or -not $clientId) {
        Write-Log $Label "Cannot connect: tenantId or clientId is missing in the configuration." "WARN"
        return $null
    }

    # Just-in-time decryption: the secret is stored encrypted (DPAPI) in the
    # config objects and decrypted only here, for this one token request. The
    # plaintext lives in local variables only and is never written back to
    # the node. A plaintext value (legacy) is accepted as-is.
    $secret = $null
    if ($authMethod -eq 'ClientSecret') {
        $storedSecret = [string](Get-NodeValue $Config 'clientSecret')
        if (-not $storedSecret) {
            Write-Log $Label "Cannot connect: clientSecret is empty. Enter it in Tenant Configuration." "WARN"
            return $null
        }
        $secret = Unprotect-Secret $storedSecret
        if (-not $secret) {
            Write-Log $Label "Cannot decrypt the clientSecret (encrypted by another Windows user or on another PC). Re-enter the secret in Tenant Configuration." "ERROR"
            return $null
        }
    }

    $authMethodLabel = if ($authMethod -eq 'ClientSecret') { 'Client Secret' } else { $authMethod }
    Write-Log $Label "Requesting access token ($authMethodLabel)..."

    try {
        $token = switch ($authMethod) {
            'ClientSecret' {
                Get-TokenViaClientSecret $tenantId $clientId $secret
            }
            'Certificate' {
                Get-TokenViaCertificate $tenantId $clientId (Get-NodeValue $Config 'certThumbprint')
            }
        }
    }
    catch {
        Write-Log $Label "Token acquisition failed. $($_.Exception.Message)" "WARN"
        return $null
    }

    # Guard: token may be null or an OAuth error object (no exception thrown by Invoke-RestMethod)
    if (-not $token) {
        Write-Log $Label "Token acquisition returned no response. Check tenant credentials." "WARN"
        return $null
    }
    if ($token.PSObject.Properties['error'] -and $token.error) {
        $errDesc = if ($token.PSObject.Properties['error_description'] -and $token.error_description) { $token.error_description } else { $token.error }
        Write-Log $Label "Token acquisition failed. $errDesc" "WARN"
        return $null
    }
    if (-not ($token.PSObject.Properties['access_token']) -or -not $token.access_token) {
        Write-Log $Label "Token acquisition failed. Response did not contain an access token." "WARN"
        return $null
    }

    $expiresIn = if ($token.PSObject.Properties['expires_in'] -and $token.expires_in) { [int]$token.expires_in } else { 3600 }
    $expiresAt = Get-TokenExpiry $expiresIn
    Write-Log $Label "Access token acquired. Expires at $($expiresAt.ToString('HH:mm:ss'))." "OK"

    [PSCustomObject]@{
        Label       = $Label
        TenantId    = $tenantId
        ClientId    = $clientId
        AccessToken = $token.access_token
        ExpiresAt   = $expiresAt
        _Config     = $Config
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Token check — returns a NEW connection object if the token has expired.
# Connections are immutable; this function never mutates the input object.
# ─────────────────────────────────────────────────────────────────────────────

function script:Update-Connection {
    param($Connection)

    if ($null -eq $Connection) {
        throw "No Graph connection available."
    }

    if ($null -eq $Connection.ExpiresAt -or (Get-Date) -ge $Connection.ExpiresAt) {
        Write-Log $Connection.Label "Token expired. Refreshing..." "WARN"
        $fresh = New-GraphConnection -Config $Connection._Config -Label $Connection.Label
        # New-GraphConnection returns $null on failure. Returning that would
        # surface later as "The property 'AccessToken' cannot be found" (strict
        # mode), which tells the user nothing. Fail here with the real reason.
        if (-not $fresh) {
            throw "Token refresh failed for '$($Connection.Label)'. Check the tenant credentials."
        }
        return $fresh
    }

    return $Connection
}

# ─────────────────────────────────────────────────────────────────────────────
# Graph request
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-IntuneGraphRequest {
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = "GET",
        [object]$Body = $null,
        [string]$ApiVersion = "v1.0",
        [int]$MaxRetries = 3,
        [int]$MaxThrottleRetries = 5,
        [int]$TimeoutSec = $script:RequestTimeoutSec,
        # Network/transport errors (no DNS, no route, timeout): wait a fixed
        # $NetworkRetryDelaySec between attempts, $NetworkRetries times.
        # Parallel workers pass 0 so the parent handles an outage once,
        # instead of every worker retrying and logging on its own.
        [int]$NetworkRetries = 3,
        [int]$NetworkRetryDelaySec = 10
    )

    [int]$retry = 0
    [int]$throttleCount = 0
    [int]$netRetry = 0

    $conn = Update-Connection $Connection

    if ($Uri -notmatch '^https://') {
        $Uri = "https://graph.microsoft.com/$ApiVersion/$Uri"
    }

    $headers = @{
        Authorization    = "Bearer $($conn.AccessToken)"
        'Content-Type'   = 'application/json'
        ConsistencyLevel = 'eventual'
    }

    $params = @{
        Method  = $Method
        Uri     = $Uri
        Headers = $headers
    }
    $params += (Get-TimeoutParams $TimeoutSec)

    if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
    }

    while ($retry -lt $MaxRetries) {
        try {
            $response = Invoke-RestMethod @params

            # ─────────────────────────────────────────────
            # Intune proxy transient error — the call
            # returned HTTP 200 but the body contains an
            # error object (e.g. code: "UnknownError").
            # Retry with exponential back-off.
            # ─────────────────────────────────────────────
            if ($response.PSObject.Properties['error'] -and $response.error) {
                $errCode = $response.error.code
                if ($retry -lt ($MaxRetries - 1)) {
                    $wait = [math]::Pow(2, $retry + 1)   # 2s, 4s, 8s …
                    $retry++
                    Write-Log $conn.Label "Transient API error ('$errCode'). Retrying in $wait sec... [$retry/$MaxRetries]" "WARN"
                    Start-Sleep -Seconds $wait
                    continue
                }
                Write-Log $conn.Label "Transient API error ('$errCode') persisted after $MaxRetries attempts. Giving up." "ERROR"
                throw "Graph API returned error: $errCode"
            }

            return $response
        }
        catch {
            # Not every failure is an HttpResponseException. Client-side
            # timeouts and dropped connections throw HttpRequestException /
            # TaskCanceledException, which have no .Response -- and because
            # this module runs under Set-StrictMode -Version Latest, reading a
            # non-existent property throws instead of returning $null. That
            # turned every network hiccup into a confusing "The property
            # 'Response' cannot be found" error AND skipped the retry logic
            # entirely. Status 0 means transport-level failure: retryable.
            $status = 0
            $_exc = $_.Exception
            if ($_exc.PSObject.Properties['Response'] -and $_exc.Response -and
                $_exc.Response.PSObject.Properties['StatusCode']) {
                try { $status = [int]$_exc.Response.StatusCode } catch { $status = 0 }
            }

            # ─────────────────────────────────────────────
            # Throttling (429 / 503)
            # ─────────────────────────────────────────────
            if ($status -in @(429, 503)) {
                if ($throttleCount -ge $MaxThrottleRetries) {
                    Write-Log $conn.Label "Max throttle retries ($MaxThrottleRetries) reached (HTTP $status). Giving up." "ERROR"
                    throw
                }

                $retryAfter = $null
                try {
                    $retryAfter = $_.Exception.Response.Headers.GetValues('Retry-After')[0]
                } catch { }

                $parsed = 0
                $wait = if ($retryAfter -and [int]::TryParse($retryAfter, [ref]$parsed)) {
                    $parsed
                } else {
                    10
                }

                $throttleCount++
                Write-Log $conn.Label "Throttled (HTTP $status). Waiting $wait sec... [$throttleCount/$MaxThrottleRetries]" "WARN"
                Start-Sleep -Seconds $wait
                continue
            }

            # ─────────────────────────────────────────────
            # HTTP 500 / 502 / 504 — generic server faults
            # that are worth retrying with back-off
            # ─────────────────────────────────────────────
            # Network / transport error (status 0): fixed delay, own counter.
            if ($status -eq 0) {
                if ($netRetry -lt $NetworkRetries) {
                    $netRetry++
                    # One uniform message: the underlying reason ("No such host is
                    # known", timeout, reset) differs per situation and adds nothing.
                    Write-Log $conn.Label "Network unavailable. Retrying in $NetworkRetryDelaySec sec... [$netRetry/$NetworkRetries]" "WARN"
                    Start-Sleep -Seconds $NetworkRetryDelaySec
                    continue
                }
                # Still an HttpRequestException (so callers and
                # Test-GraphNetworkError recognise it as a network error), with
                # a readable message; the original error is kept as inner.
                throw [System.Net.Http.HttpRequestException]::new("Network connection lost.", $_exc)
            }

            if ($status -in @(500, 502, 504) -and $retry -lt ($MaxRetries - 1)) {
                $wait = [math]::Pow(2, $retry + 1)   # 2s, 4s …
                $retry++
                Write-Log $conn.Label "Server error (HTTP $status). Retrying in $wait sec... [$retry/$($MaxRetries - 1)]" "WARN"
                Start-Sleep -Seconds $wait
                continue
            }

            # ─────────────────────────────────────────────
            # Unauthorized → refresh token once
            # ─────────────────────────────────────────────
            if ($status -eq 401 -and $retry -eq 0) {
                $fresh = New-GraphConnection -Config $conn._Config -Label $conn.Label
                if (-not $fresh) {
                    throw "HTTP 401 and token refresh failed for '$($conn.Label)'. Check the tenant credentials."
                }
                $conn = $fresh
                $params.Headers.Authorization = "Bearer $($conn.AccessToken)"
                $retry++
                continue
            }

            throw
        }
    }

    # Only reachable when the retry budget ran out on a path that does not
    # throw by itself (e.g. -MaxRetries 1 combined with a 401 refresh). Never
    # fall through silently: the caller would treat $null as "no data".
    throw "Graph request failed after $MaxRetries attempts: $Uri"
}

# ─────────────────────────────────────────────────────────────────────────────
# Paging
# ─────────────────────────────────────────────────────────────────────────────


# ─────────────────────────────────────────────────────────────────────────────
# Network helpers
#
# Test-GraphNetworkError : $true when an exception is a transport problem
#                          (no DNS, no route, connection dropped, timeout) and
#                          not an HTTP error answered by Graph.
# Test-GraphReachable    : quick connectivity probe — resolves the Graph host
#                          name (max 5 s). Used to wait for the network to come
#                          back before retrying a batch.
# ─────────────────────────────────────────────────────────────────────────────
function Test-GraphNetworkError {
    param($Exception)
    $e = $Exception
    while ($e) {
        if ($e.PSObject.Properties['Response'] -and $e.Response) { return $false }  # Graph answered
        if ($e -is [System.Net.Http.HttpRequestException] -or
            $e -is [System.Net.Sockets.SocketException] -or
            $e -is [System.TimeoutException] -or
            $e -is [System.Threading.Tasks.TaskCanceledException] -or
            $e -is [System.IO.IOException]) { return $true }
        $e = $e.InnerException
    }
    return $false
}

function Test-GraphReachable {
    param([string]$HostName = 'graph.microsoft.com', [int]$TimeoutMs = 5000)
    try {
        $t = [System.Net.Dns]::GetHostAddressesAsync($HostName)
        return ($t.Wait($TimeoutMs) -and $t.Result.Count -gt 0)
    } catch { return $false }
}

function Get-GraphPagedResults {
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Uri,
        [string]$ApiVersion = "v1.0",
        # Heavy endpoints (configurationSettings) need more retries than the
        # default. This was never passed through, so every paged call was
        # capped at the default regardless of how expensive the endpoint is.
        [int]$MaxRetries = 3,
        [int]$TimeoutSec = $script:RequestTimeoutSec
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    $conn = $Connection

    while ($next) {
        $conn = Update-Connection $conn 
        $response = Invoke-IntuneGraphRequest -Connection $conn -Uri $next -ApiVersion $ApiVersion -MaxRetries $MaxRetries -TimeoutSec $TimeoutSec

        if ($response.value) {
            foreach ($i in $response.value) {
                $results.Add($i)
            }
        }

        Write-Log $conn.Label "Fetched $($results.Count) items..."
        $nextProp = $response.PSObject.Properties['@odata.nextLink']
        $next = if ($nextProp) { $nextProp.Value } else { $null }
    }

    Write-Log $conn.Label "Total: $($results.Count) items fetched." "OK"
    return $results
}



# ─────────────────────────────────────────────────────────────────────────────
# Export
# ─────────────────────────────────────────────────────────────────────────────

Export-ModuleMember -Function @(
    'Get-GraphConfig',
    'Resolve-TenantConfig',
    'Get-TenantList',
    'New-GraphConnection',
    'Invoke-IntuneGraphRequest',
    'Get-GraphPagedResults',
    'Test-GraphNetworkError',
    'Test-GraphReachable'
)