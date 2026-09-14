# =============================================================================
# GraphTokenClient.psm1
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

    try {
        $rawJson = Get-Content $Path -Raw
        $cfg = $rawJson | ConvertFrom-Json
    } catch {
        return [PSCustomObject]@{
            tenant        = $null
            __configError = "Invalid JSON in config file: $_"
        }
    }
    $cfg | Add-Member -NotePropertyName '__configError' -NotePropertyValue $null -Force

    # Detect legacy internal markers on disk. These should NEVER be persisted —
    # they're in-memory runtime state. Earlier versions of this function had
    # bugs that serialized them; auto-cleanup now so users don't have to edit
    # Config.json by hand. Triggers a sanitized re-save further down.
    $legacyMarkersOnDisk = ($rawJson -match '"__plaintextForSession"' -or
                            $rawJson -match '"__configError"')

    # ── Decrypt clientSecrets + auto-migrate plaintext ────────────────────────
    # For every ClientSecret tenant:
    #   - "DPAPI:<blob>" → decrypt in-place; if decrypt fails (wrong user/PC),
    #     log a re-enter message and leave the secret empty.
    #   - plaintext      → encrypt to disk + decrypt in-memory (one-shot
    #     migration). User keeps working; the disk version is now safe.
    #
    # The in-memory $node.clientSecret is ALWAYS plaintext after this point —
    # downstream code (New-GraphConnection, Get-TokenViaClientSecret) does not
    # need to know about encryption.
    #
    # Plaintext-for-session stash: when we migrate a plaintext secret, the
    # node temporarily holds the ENCRYPTED form (so ConvertTo-Json writes the
    # encrypted version to disk). We can't write the plaintext back to the
    # node BEFORE the save, otherwise we'd encrypt nothing. We also can't
    # stash plaintext as a property ON the node — ConvertTo-Json would
    # serialise that property too, defeating the whole point. Use a separate
    # hashtable keyed by tenant id and merge after the save.
    $configChanged = $false
    $plaintextForSession = @{}
    if ($cfg.PSObject.Properties['tenant'] -and $cfg.tenant) {
        foreach ($prop in $cfg.tenant.PSObject.Properties) {
            $node = $prop.Value
            if (-not $node) { continue }
            if ($node.authMethod -ne 'ClientSecret') { continue }
            if (-not $node.clientSecret) { continue }

            $stored = [string]$node.clientSecret
            $label  = if ($node.displayName) { $node.displayName } else { $prop.Name }

            if (Test-SecretEncrypted $stored) {
                # Try to decrypt — may fail if copied from another user/machine.
                $plain = Unprotect-Secret $stored
                if ($null -eq $plain) {
                    Write-Log 'Config' "Cannot decrypt clientSecret for '$label'. Open Tenant Configuration and re-enter the secret." 'ERROR'
                    $node.clientSecret = ''
                } else {
                    $node.clientSecret = $plain
                }
            } else {
                # Legacy plaintext — migrate. Encrypt for disk, stash plaintext
                # separately so the current session keeps working.
                try {
                    $encrypted = Protect-Secret $stored
                    $node.clientSecret = $encrypted   # what ConvertTo-Json sees
                    $plaintextForSession[$prop.Name] = $stored
                    $configChanged = $true
                    Write-Log 'Config' "Plaintext clientSecret detected for '$label'. Encrypted in place. External backups may still contain plaintext." 'WARN'
                } catch {
                    Write-Log 'Config' "Failed to encrypt clientSecret for '$label'. Leaving plaintext (will retry next launch). $($_.Exception.Message)" 'ERROR'
                }
            }
        }
    }

    # If we migrated any plaintext secrets, write the encrypted version to disk
    # before continuing. Best-effort: a failed write is logged but doesn't
    # block the session — the secret stays plaintext on disk for next launch.
    #
    # Build a sanitized payload that omits all internal __* markers
    # (__configError, __invalid, and legacy __plaintextForSession from an
    # earlier buggy migration). Without this, ConvertTo-Json would serialize
    # those properties to disk — defeating the whole point of the migration.
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
            Write-Log 'Config' "Could not write encrypted Config.json: $($_.Exception.Message)" 'ERROR'
        }
        # Restore the in-memory plaintext so the rest of the session works
        # against decrypted secrets. Done AFTER the save so disk sees encrypted.
        foreach ($key in $plaintextForSession.Keys) {
            $node = $cfg.tenant.PSObject.Properties[$key].Value
            if ($node) { $node.clientSecret = $plaintextForSession[$key] }
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
            # Offline-only tenants (authMethod 'None' or absent + path) are valid
            if ($node.authMethod -eq 'None' -or (-not $node.authMethod -and $node.path)) {
                # valid offline entry
            } elseif (-not $node.tenantId -or -not $node.clientId) {
                $invalid = $true
            } elseif ($node.authMethod -eq 'ClientSecret' -and -not $node.clientSecret) {
                # NOTE: an empty clientSecret here means decrypt failed (wrong
                # user/machine). UI flow keeps the tenant visible so the user
                # can re-enter the secret; CLI flow flags it __invalid (below)
                # because there's no interactive recovery path.
                $invalid = $true
            } elseif ($node.authMethod -eq 'Certificate' -and -not $node.certThumbprint) {
                $invalid = $true
            } elseif ($node.authMethod -ne 'ClientSecret' -and $node.authMethod -ne 'Certificate' -and $node.authMethod -ne 'None') {
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

    Invoke-RestMethod `
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

    Invoke-RestMethod `
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

    $authMethodLabel = if ($Config.authMethod -eq 'ClientSecret') { 'Client Secret' } else { $Config.authMethod }
    Write-Log $Label "Requesting access token ($authMethodLabel)..."

    try {
        $token = switch ($Config.authMethod) {
            'ClientSecret' {
                Get-TokenViaClientSecret $Config.tenantId $Config.clientId $Config.clientSecret
            }
            'Certificate' {
                Get-TokenViaCertificate $Config.tenantId $Config.clientId $Config.certThumbprint
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
        TenantId    = $Config.tenantId
        ClientId    = $Config.clientId
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

    if ($null -eq $Connection.ExpiresAt -or (Get-Date) -ge $Connection.ExpiresAt) {
        Write-Log $Connection.Label "Token expired. Refreshing..." "WARN"
        return New-GraphConnection -Config $Connection._Config -Label $Connection.Label
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
        [int]$MaxThrottleRetries = 5
    )

    [int]$retry = 0
    [int]$throttleCount = 0

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
            if ($status -in @(0, 500, 502, 504) -and $retry -lt ($MaxRetries - 1)) {
                $wait = [math]::Pow(2, $retry + 1)   # 2s, 4s …
                $retry++
                $_what = if ($status -eq 0) { "Network/transport error" } else { "Server error (HTTP $status)" }
                Write-Log $conn.Label "$_what. Retrying in $wait sec... [$retry/$($MaxRetries - 1)]" "WARN"
                Start-Sleep -Seconds $wait
                continue
            }

            # ─────────────────────────────────────────────
            # Unauthorized → refresh token once
            # ─────────────────────────────────────────────
            if ($status -eq 401 -and $retry -eq 0) {
                $conn = New-GraphConnection -Config $conn._Config -Label $conn.Label
                $params.Headers.Authorization = "Bearer $($conn.AccessToken)"
                $retry++
                continue
            }

            throw
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Paging
# ─────────────────────────────────────────────────────────────────────────────


function Get-GraphPagedResults {
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Uri,
        [string]$ApiVersion = "v1.0",
        # Heavy endpoints (configurationSettings) need more retries than the
        # default. This was never passed through, so every paged call was
        # capped at the default regardless of how expensive the endpoint is.
        [int]$MaxRetries = 3
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    $conn = $Connection

    while ($next) {
        $conn = Update-Connection $conn 
        $response = Invoke-IntuneGraphRequest -Connection $conn -Uri $next -ApiVersion $ApiVersion -MaxRetries $MaxRetries

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
    'Get-GraphPagedResults'
)