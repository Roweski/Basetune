# =============================================================================
# BasetuneGraph.psm1
# Stateless multi-tenant Microsoft Graph module (ClientSecret or Certificate).
# Tokens (New-GraphConnection) and Graph requests (Invoke-IntuneGraphRequest,
# paging, network checks). Config.json / Options.json: BasetuneConfig.psm1.
# Write-Log comes from BasetuneHelpers.psm1 (first nested module).
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
# Request timeouts
# Invoke-RestMethod waits forever by default (-TimeoutSec 0). When the network
# drops mid-request (e.g. Wi-Fi off) the connection is not closed, so a Load
# would hang on "Expanded settings: ..." until the network is back. With a
# timeout the request fails as a transport error, is retried, then reported.
# 30 s for normal requests (policy list/expand, export); the heavy definition
# download passes 60 s itself.
# ─────────────────────────────────────────────────────────────────────────────
$script:RequestTimeoutSec = 30
$script:TokenTimeoutSec   = 30

# PowerShell 7.4+: -TimeoutSec is an alias of -ConnectionTimeoutSeconds and
# only covers connecting / receiving headers. A body that stalls halfway
# (network dropped mid-download) needs -OperationTimeoutSeconds (per read),
# or the request hangs forever. Used when available.
$script:HasOperationTimeout = (Get-Command Invoke-RestMethod).Parameters.ContainsKey('OperationTimeoutSeconds')

function script:Get-TimeoutParams {
    param([int]$Seconds)
    $p = @{ TimeoutSec = $Seconds }
    if ($script:HasOperationTimeout) { $p['OperationTimeoutSeconds'] = $Seconds }
    return $p
}

function script:Get-TokenExpiry {
    param([int]$ExpiresIn = 3600)
    # 60 s safety buffer: refresh before it expires mid-request.
    return (Get-Date).AddSeconds($ExpiresIn - 60)
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
        [Parameter(Mandatory)][string]$Label,
        # Level of the "Cannot connect" / "Could not authenticate" lines: ERROR
        # when the action stops (load, export, download, token refresh), WARN
        # for the test on Save in Tenant Configuration (the save goes on).
        [ValidateSet('WARN', 'ERROR')][string]$FailLevel = 'ERROR'
    )

    $authMethod = Get-NodeValue $Config 'authMethod'
    $tenantId   = Get-NodeValue $Config 'tenantId'
    $clientId   = Get-NodeValue $Config 'clientId'

    # Offline baselines and unknown auth methods: say so explicitly
    # instead of the generic "no response" below.
    if ($authMethod -notin @('ClientSecret', 'Certificate')) {
        $shown = if ($authMethod) { $authMethod } else { 'None' }
        Write-Log $Label "Cannot connect: authMethod '$shown' is not valid for an online tenant (ClientSecret or Certificate)" $FailLevel
        return $null
    }
    if (-not $tenantId -or -not $clientId) {
        Write-Log $Label "Cannot connect: tenantId or clientId is missing in the configuration" $FailLevel
        return $null
    }

    # Just-in-time decryption: the secret stays DPAPI-encrypted in the config
    # and is decrypted only here, for this token request, into locals only
    # (never written back). Plaintext from an older Config.json is accepted.
    $secret = $null
    if ($authMethod -eq 'ClientSecret') {
        $storedSecret = [string](Get-NodeValue $Config 'clientSecret')
        if (-not $storedSecret) {
            Write-Log $Label "Cannot connect: clientSecret is empty. Enter it in Tenant Configuration" $FailLevel
            return $null
        }
        $secret = Unprotect-Secret $storedSecret
        if (-not $secret) {
            Write-Log $Label "Could not decrypt the Client Secret (encrypted by another Windows user or on another PC). Re-enter the secret in Tenant Configuration" "ERROR"
            return $null
        }
    }

    $authMethodText = if ($authMethod -eq 'ClientSecret') { 'client secret' } else { 'certificate' }
    Write-Log $Label "Authenticating with Microsoft Graph using $authMethodText..."

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
        Write-Log $Label "Could not authenticate with Microsoft Graph. See Basetune.log for details" $FailLevel
        Write-Log $Label "Details: $($_.Exception.Message)" $FailLevel -FileOnly
        return $null
    }

    # Guard: token may be null or an OAuth error object (no exception thrown by Invoke-RestMethod)
    if (-not $token) {
        Write-Log $Label "Could not authenticate with Microsoft Graph: no response. Check the tenant credentials" $FailLevel
        return $null
    }
    if ($token.PSObject.Properties['error'] -and $token.error) {
        $errDesc = if ($token.PSObject.Properties['error_description'] -and $token.error_description) { $token.error_description } else { $token.error }
        Write-Log $Label "Could not authenticate with Microsoft Graph. See Basetune.log for details" $FailLevel
        Write-Log $Label "Details: $errDesc" $FailLevel -FileOnly
        return $null
    }
    if (-not ($token.PSObject.Properties['access_token']) -or -not $token.access_token) {
        Write-Log $Label "Could not authenticate with Microsoft Graph: no access token in the response" $FailLevel
        return $null
    }

    $expiresIn = if ($token.PSObject.Properties['expires_in'] -and $token.expires_in) { [int]$token.expires_in } else { 3600 }
    $expiresAt = Get-TokenExpiry $expiresIn
    Write-Log $Label "Signed in successfully. Access valid until $($expiresAt.ToString('HH:mm:ss'))"

    [PSCustomObject]@{
        Label       = $Label
        TenantId    = $tenantId
        ClientId    = $clientId
        AccessToken = $token.access_token
        ExpiresAt   = $expiresAt
        # The tenant settings this token was made with (Get-GraphConnection
        # reuses it only while they are unchanged).
        Fingerprint = Get-GraphConfigFingerprint $Config
        _Config     = $Config
    }
}

# The sign-in fields of a tenant entry as one string: authMethod, tenantId,
# clientId, clientSecret (as stored, encrypted) and certThumbprint. A Save in
# Tenant Configuration that changes any of them (also a re-entered secret:
# the encrypted value changes) gives another fingerprint.
function script:Get-GraphConfigFingerprint {
    param($Config)
    (@('authMethod', 'tenantId', 'clientId', 'clientSecret', 'certThumbprint') |
        ForEach-Object { [string](Get-NodeValue $Config $_) }) -join "`n"
}

# A Graph connection for a tenant: the one from an earlier sign-in (UI: the
# last Load or Download of that tenant) while its token is valid for at least
# 5 more minutes and the tenant's sign-in fields are unchanged; otherwise a
# new sign-in (New-GraphConnection, same parameters). One sign-in per token
# instead of one per action, also in the Entra sign-in logs. The reused
# connection is a copy with this action's Label (its log lines).
function Get-GraphConnection {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Label,
        $Cached = $null,
        [ValidateSet('WARN', 'ERROR')][string]$FailLevel = 'ERROR'
    )
    if ($Cached -and $Cached.PSObject.Properties['Fingerprint'] -and $Cached.ExpiresAt -and
        $Cached.Fingerprint -ceq (Get-GraphConfigFingerprint $Config) -and
        $Cached.ExpiresAt -gt (Get-Date).AddMinutes(5)) {
        $conn = $Cached.PSObject.Copy()
        $conn.Label = $Label
        Write-Log $Label "Using the current sign-in. Access valid until $($conn.ExpiresAt.ToString('HH:mm:ss'))"
        return $conn
    }
    return New-GraphConnection -Config $Config -Label $Label -FailLevel $FailLevel
}

# ─────────────────────────────────────────────────────────────────────────────
# Token check — returns a NEW connection object if the token has expired.
# Connections are immutable; this function never mutates the input object,
# so a caller that makes several requests keeps the returned one (e.g.
# Resolve-Category): otherwise every request signs in again.
# ─────────────────────────────────────────────────────────────────────────────

function script:Update-GraphConnection {
    param($Connection)

    if ($null -eq $Connection) {
        throw "No Graph connection available"
    }

    if ($null -eq $Connection.ExpiresAt -or (Get-Date) -ge $Connection.ExpiresAt) {
        Write-Log $Connection.Label "Token expired. Refreshing..." "WARN"
        $fresh = New-GraphConnection -Config $Connection._Config -Label $Connection.Label
        # $null would surface later as "The property 'AccessToken' cannot be
        # found" (strict mode): fail here with the real reason.
        if (-not $fresh) {
            throw "Token refresh failed for '$($Connection.Label)'. Check the tenant credentials"
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
        # Network/transport errors (no DNS, no route, timeout): $NetworkRetries
        # attempts, $NetworkRetryDelaySec apart. Parallel workers pass 0 so the
        # parent handles an outage once.
        [int]$NetworkRetries = 3,
        [int]$NetworkRetryDelaySec = 10
    )

    [int]$retry = 0
    [int]$throttleCount = 0
    [int]$netRetry = 0

    $conn = Update-GraphConnection $Connection

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
            # Intune proxy transient error: HTTP 200 with an
            # error object in the body (e.g. "UnknownError").
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
                Write-Log $conn.Label "Graph API error '$errCode' after $MaxRetries attempts. Stopped retrying" "ERROR"
                throw "Graph API returned error: $errCode"
            }

            return $response
        }
        catch {
            # Timeouts and dropped connections (HttpRequestException /
            # TaskCanceledException) have no .Response, and under strict mode
            # reading it throws ("The property 'Response' cannot be found")
            # and would skip the retries: check first. Status 0 = transport
            # failure, retryable.
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
                    Write-Log $conn.Label "Graph API still busy after $MaxThrottleRetries retries (HTTP $status). Stopped retrying" "ERROR"
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
            # Network / transport error (status 0): fixed
            # delay, own counter
            # ─────────────────────────────────────────────
            if ($status -eq 0) {
                if ($netRetry -lt $NetworkRetries) {
                    $netRetry++
                    # One uniform message: the underlying reason adds nothing.
                    Write-Log $conn.Label "Network unavailable. Retrying in $NetworkRetryDelaySec sec... [$netRetry/$NetworkRetries]" "WARN"
                    Start-Sleep -Seconds $NetworkRetryDelaySec
                    continue
                }
                # Still an HttpRequestException (Test-GraphNetworkError must
                # recognise it), readable message, original kept as inner.
                throw [System.Net.Http.HttpRequestException]::new("Network connection lost", $_exc)
            }

            # HTTP 500 / 502 / 504: server faults, retried with back-off.
            if ($status -in @(500, 502, 504) -and $retry -lt ($MaxRetries - 1)) {
                $wait = [math]::Pow(2, $retry + 1)   # 2s, 4s …
                $retry++
                # 504 = Graph gateway timeout (the definition download returns
                # the whole catalog in one response).
                $what = if ($status -eq 504) { 'Microsoft Graph request timed out (HTTP 504)' } else { "Server error (HTTP $status)" }
                Write-Log $conn.Label "$what. Retrying in $wait sec... [$retry/$($MaxRetries - 1)]" "WARN"
                Start-Sleep -Seconds $wait
                continue
            }

            # ─────────────────────────────────────────────
            # Unauthorized → refresh token once
            # ─────────────────────────────────────────────
            if ($status -eq 401 -and $retry -eq 0) {
                $fresh = New-GraphConnection -Config $conn._Config -Label $conn.Label
                if (-not $fresh) {
                    throw "HTTP 401 and token refresh failed for '$($conn.Label)'. Check the tenant credentials"
                }
                $conn = $fresh
                $params.Headers.Authorization = "Bearer $($conn.AccessToken)"
                $retry++
                continue
            }

            throw
        }
    }

    # Reached only when retries ran out on a path that does not throw itself
    # (e.g. -MaxRetries 1 with a 401 refresh). The caller would read $null as
    # "no data".
    throw "Graph request failed after $MaxRetries attempts: $Uri"
}

# ─────────────────────────────────────────────────────────────────────────────
# Network helpers
#
# Test-GraphNetworkError : $true for a transport problem (no DNS, no route,
#                          dropped connection, timeout), not an HTTP error
#                          answered by Graph.
# Test-GraphReachable    : resolves the Graph host name (max 5 s); used to wait
#                          for the network before retrying a batch.
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

# ─────────────────────────────────────────────────────────────────────────────
# Paging
# ─────────────────────────────────────────────────────────────────────────────
function Get-GraphPagedResults {
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Uri,
        [string]$ApiVersion = "v1.0",
        # Passed on per page: heavy endpoints (configurationSettings) need
        # more retries than the default.
        [int]$MaxRetries = 3,
        [int]$TimeoutSec = $script:RequestTimeoutSec,
        # -Quiet: no "Fetching... (n <ItemName> so far)" / "Fetched <ItemName>
        # (n)" lines; the caller logs its own result (policy load: "Fetched 47
        # policies from Graph API"). The definition download and the export
        # keep them, with their own ItemName ("setting definitions", ...).
        [switch]$Quiet,
        [string]$ItemName = 'items'
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    $conn = $Connection

    while ($next) {
        $conn = Update-GraphConnection $conn
        $response = Invoke-IntuneGraphRequest -Connection $conn -Uri $next -ApiVersion $ApiVersion -MaxRetries $MaxRetries -TimeoutSec $TimeoutSec

        if ($response.value) {
            foreach ($i in $response.value) {
                $results.Add($i)
            }
        }

        $nextProp = $response.PSObject.Properties['@odata.nextLink']
        $next = if ($nextProp) { $nextProp.Value } else { $null }
        # Only while more pages follow (else the count shows twice).
        if (-not $Quiet -and $next) { Write-Log $conn.Label "Fetching... ($($results.Count) $ItemName so far)" }
    }

    if (-not $Quiet) { Write-Log $conn.Label "Fetched $ItemName ($($results.Count))" }
    return $results
}

# ─────────────────────────────────────────────────────────────────────────────
# Export
# ─────────────────────────────────────────────────────────────────────────────

Export-ModuleMember -Function @(
    'New-GraphConnection',
    'Get-GraphConnection',
    'Update-GraphConnection',
    'Invoke-IntuneGraphRequest',
    'Test-GraphNetworkError',
    'Test-GraphReachable',
    'Get-GraphPagedResults'
)
