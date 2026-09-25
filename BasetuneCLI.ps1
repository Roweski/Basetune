[CmdletBinding(DefaultParameterSetName='Compare')]
param (
    # ── COMPARE ───────────────────────────────────────────────────────────────
    [Parameter(ParameterSetName='Compare', Mandatory)]
    [string]$SourceId,

    [Parameter(ParameterSetName='Compare', Mandatory)]
    [string]$TargetId,

    [Parameter(ParameterSetName='Compare')]
    [string]$SourceFilter = "",

    [Parameter(ParameterSetName='Compare')]
    [string]$TargetFilter = "",

    [Parameter(ParameterSetName='Compare')]
    [string]$ReportPath = "",

    [Parameter(ParameterSetName='Compare')]
    [Parameter(ParameterSetName='Export')]
    [int]$MaxThreads = 0,

    # ── EXPORT ────────────────────────────────────────────────────────────────
    [Parameter(ParameterSetName='Export', Mandatory)]
    [string]$ExportId = "",

    [Parameter(ParameterSetName='Export')]
    [string]$ExportPath = "",

    [Parameter(ParameterSetName='Export')]
    [string]$ExportFilter = "",

    # ── DOWNLOAD ──────────────────────────────────────────────────────────────
    [Parameter(ParameterSetName='Download', Mandatory)]
    [switch]$Download,

    [Parameter(ParameterSetName='Download')]
    [string]$Id = "",

    # ── INFO ──────────────────────────────────────────────────────────────────
    [Parameter(ParameterSetName='Tenants', Mandatory)]
    [switch]$Tenants,

    [Parameter(ParameterSetName='Help', Mandatory)]
    [Alias('?')]
    [switch]$Help
)

if ($Help) {
    Write-Host ""
    Write-Host "USAGE" -ForegroundColor Yellow
    Write-Host "  .\BasetuneCLI.ps1 -SourceId <id> -TargetId <id> [parameters]"
    Write-Host ""
    Write-Host "COMPARE" -ForegroundColor Yellow
    Write-Host "  -SourceId     <id>     Tenant id from Config.json to use as source (required)"
    Write-Host "  -TargetId     <id>     Tenant id from Config.json to use as target (required)"
    Write-Host "  -SourceFilter <text>   Only include source policies matching this filter"
    Write-Host "  -TargetFilter <text>   Only include target policies matching this filter"
    Write-Host "  -ReportPath   <path>   Override report output folder for this run"
    Write-Host "  -MaxThreads   <n>      Parallel threads for settings expand (default: from config or 8)"
    Write-Host ""
    Write-Host "EXPORT" -ForegroundColor Yellow
    Write-Host "  -ExportId     <id>     Export policies for tenant id to JSON files"
    Write-Host "  -ExportPath   <path>   Output folder (required)"
    Write-Host "  -ExportFilter <text>   Only include policies matching this filter"
    Write-Host ""
    Write-Host "DOWNLOAD" -ForegroundColor Yellow
    Write-Host "  -Download              Download setting definitions and categories"
    Write-Host "  -Id           <id>     Tenant to use (required: must be an online tenant)"
    Write-Host ""
    Write-Host "INFO" -ForegroundColor Yellow
    Write-Host "  -Tenants               List all configured tenants with id and auth method"
    Write-Host "  -? / -Help             Show this help"
    Write-Host ""
    Write-Host "EXAMPLES" -ForegroundColor Yellow
    Write-Host "  .\BasetuneCLI.ps1 -SourceId <id> -TargetId <id>"
    Write-Host "  .\BasetuneCLI.ps1 -SourceId <id> -SourceFilter Win-L1 -TargetId <id> -TargetFilter Win-L1"
    Write-Host "  .\BasetuneCLI.ps1 -ExportId <id> -ExportPath C:\MyExport"
    Write-Host "  .\BasetuneCLI.ps1 -ExportId <id> -ExportPath C:\MyExport -ExportFilter Win-L2"
    Write-Host "  .\BasetuneCLI.ps1 -Download -Id <id>"
    Write-Host "  .\BasetuneCLI.ps1 -Tenants"
    Write-Host ""
    exit
}

# ==============================================
# CONFIG
# ==============================================

Import-Module "$PSScriptRoot\Modules\IntuneGraphModules.psd1" -Force

# Initialise log file — CLI session writes to .\Logs\BasetuneCLI.log
# (separate from BasetuneUI.log so the two contexts don't interleave)
$_logDir = "$PSScriptRoot\Logs"
New-Item -ItemType Directory -Path $_logDir -Force | Out-Null
$_logFile = "$_logDir\BasetuneCLI.log"
try { Set-LogFile -Path $_logFile } catch {}

$GraphBeta   = "https://graph.microsoft.com/beta"

$ModulesPath      = "$PSScriptRoot\Modules"
$definitionsPath  = "$PSScriptRoot\Definitions"
$reportBasePath   = "$PSScriptRoot\Reports"

# Load config once — derive all settings from it
$rawCfg = $null
try { $rawCfg = Get-GraphConfig "$PSScriptRoot\Config\Config.json" } catch {}
# Invalid JSON / missing file used to surface only as "tenant not found".
if ($rawCfg -and $rawCfg.PSObject.Properties['__configError'] -and $rawCfg.__configError) {
    Write-Log "Config" "$($rawCfg.__configError)" "ERROR"
    exit 1
}
if (-not $rawCfg) { $rawCfg = [PSCustomObject]@{ tenant = $null } }

# MaxThreads: -MaxThreads param > config setting > default 8.
# Always validated (1..32): 0 or a bad config value used to reach
# ForEach-Object -ThrottleLimit and abort the load.
# $MaxThreads is [int]: a non-numeric config value must go through the
# validator first, not be assigned to it directly (that throws).
$_mtRequested = $MaxThreads
if ($MaxThreads -eq 0) {
    $_mtRequested = if ($rawCfg.PSObject.Properties['settings'] -and $rawCfg.settings -and
                        $rawCfg.settings.PSObject.Properties['maxthreads'] -and $rawCfg.settings.maxthreads) {
        $rawCfg.settings.maxthreads
    } else { 8 }
}
$MaxThreads = Get-ValidMaxThreads $_mtRequested

# Report path: config > default
$_cfgPaths = if ($rawCfg.PSObject.Properties['settings'] -and $rawCfg.settings -and
                  $rawCfg.settings.PSObject.Properties['path'] -and $rawCfg.settings.path) {
    $rawCfg.settings.path } else { $null }
if ($_cfgPaths -and $_cfgPaths.PSObject.Properties['report'] -and $_cfgPaths.report -and $_cfgPaths.report.Trim()) {
    # Relative config paths are relative to the Basetune folder. An invalid
    # path is already repaired in Config.json by Get-GraphConfig (set to the
    # default Reports folder); this is only a fallback if that write failed.
    $_rp = Resolve-FolderPath -Path $_cfgPaths.report -BasePath $PSScriptRoot
    if ($_rp.Error) {
        if ($PSCmdlet.ParameterSetName -eq 'Compare' -and -not $ReportPath) {
            Write-Log "Config" "Report path in Config.json is not valid: $($_rp.Error) Using default: $reportBasePath" "WARN"
        }
    } else {
        $reportBasePath = $_rp.Path
    }
}

# -ReportPath overrides the config report path for this run. Validated here,
# before any tenant connection, so a typo fails fast. Relative paths are
# relative to the current folder.
if ($PSCmdlet.ParameterSetName -eq 'Compare' -and $ReportPath) {
    $_cwd = (Get-Location -PSProvider FileSystem).ProviderPath
    $_rp  = Resolve-FolderPath -Path $ReportPath -BasePath $_cwd
    if ($_rp.Error) {
        Write-Log "Compare" "Parameter -ReportPath is not valid: $($_rp.Error)" "ERROR"
        exit 1
    }
    $reportBasePath = $_rp.Path
}

# The report folder is created only when a compare actually writes a report
# (see COMPARE + EXPORT), not for -Tenants / -Download / export runs.
New-Item -ItemType Directory -Path $definitionsPath -Force | Out-Null

$definitionsFile = "$definitionsPath\settingDefinitions.json"
$categoriesFile  = "$definitionsPath\settingCategories.json"


# ==============================================
# CONNECTIONS (only when needed)
# ==============================================

# Resolve source/target nodes from the single rawCfg load above
$cfg = $null
try { $cfg = Resolve-TenantConfig -Cfg $rawCfg -SourceId $SourceId -TargetId $TargetId } catch {}
if (-not $cfg) {
    $cfg = [PSCustomObject]@{ source = $null; target = $null; tenant = $null }
}

# ── Early tenant validation + connections (Compare mode only) ────────────────
# Both source AND target are fully validated and connected before any policy
# loading starts. All errors are collected so the user sees every problem at
# once instead of one per run.
if ($PSCmdlet.ParameterSetName -eq 'Compare') {
    $configErrors = [System.Collections.Generic.List[string]]::new()

    # ── id existence ──────────────────────────────────────────────────────────
    # Both -SourceId and -TargetId must resolve to a tenant entry in
    # Config.json. Errors are collected so the user sees both problems at once
    # if both ids are wrong, rather than having to re-run and fix them one by
    # one. Each side may be either Online (authMethod set) or Offline (no
    # authMethod / 'None') — the later credential check and offline-path
    # check handle the rest per side.
    # Resolve-TenantConfig returns $null both for an unknown id and for an
    # entry marked invalid by Get-GraphConfig (an empty tenantId, clientId,
    # clientSecret or certThumbprint). Tell the two apart.
    $rawTenantExists = {
        param($id)
        [bool]($id -and $rawCfg.PSObject.Properties['tenant'] -and $rawCfg.tenant -and $rawCfg.tenant.PSObject.Properties[$id])
    }
    if (-not $cfg.source) {
        if (& $rawTenantExists $SourceId) { $configErrors.Add("Source tenant '$SourceId' is incomplete in Config.json (tenantId, clientId, clientSecret or certThumbprint is empty).") }
        else                              { $configErrors.Add("Source tenant '$SourceId' not found in Config.json.") }
    }
    if (-not $cfg.target) {
        if (& $rawTenantExists $TargetId) { $configErrors.Add("Target tenant '$TargetId' is incomplete in Config.json (tenantId, clientId, clientSecret or certThumbprint is empty).") }
        else                              { $configErrors.Add("Target tenant '$TargetId' not found in Config.json.") }
    }

    if ($configErrors.Count -gt 0) {
        foreach ($e in $configErrors) { Write-Log "Config" $e "ERROR" }
        Write-Log "Config" "Use -Tenants to list all configured tenant ids." "INFO"
        exit 1
    }

    # ── Online credential sanity check (before attempting any network call) ───
    $srcAuth = if ($cfg.source.PSObject.Properties['authMethod'] -and $cfg.source.authMethod) { $cfg.source.authMethod } else { 'None' }
    $tgtAuth = if ($cfg.target.PSObject.Properties['authMethod'] -and $cfg.target.authMethod) { $cfg.target.authMethod } else { 'None' }

    if ($srcAuth -ne 'None') {
        if (-not $cfg.source.tenantId -or -not $cfg.source.clientId) {
            $configErrors.Add("Source '$SourceId': missing tenantId or clientId in Config.json.")
        } elseif ($srcAuth -eq 'ClientSecret' -and -not $cfg.source.clientSecret) {
            $configErrors.Add("Source '$SourceId': authMethod is ClientSecret but clientSecret is missing.")
        } elseif ($srcAuth -eq 'Certificate' -and -not $cfg.source.certThumbprint) {
            $configErrors.Add("Source '$SourceId': authMethod is Certificate but certThumbprint is missing.")
        }
    }
    if ($tgtAuth -ne 'None') {
        if (-not $cfg.target.tenantId -or -not $cfg.target.clientId) {
            $configErrors.Add("Target '$TargetId': missing tenantId or clientId in Config.json.")
        } elseif ($tgtAuth -eq 'ClientSecret' -and -not $cfg.target.clientSecret) {
            $configErrors.Add("Target '$TargetId': authMethod is ClientSecret but clientSecret is missing.")
        } elseif ($tgtAuth -eq 'Certificate' -and -not $cfg.target.certThumbprint) {
            $configErrors.Add("Target '$TargetId': authMethod is Certificate but certThumbprint is missing.")
        }
    }

    if ($configErrors.Count -gt 0) {
        foreach ($e in $configErrors) { Write-Log "Config" $e "ERROR" }
        exit 1
    }
}

$sourceLabel = if ($cfg.source -and $cfg.source.PSObject.Properties['displayName'] -and $cfg.source.displayName) { $cfg.source.displayName } `
               elseif ($SourceId -and $rawCfg.PSObject.Properties['tenant'] -and $rawCfg.tenant.PSObject.Properties[$SourceId]) {
                   $n = $rawCfg.tenant.PSObject.Properties[$SourceId].Value
                   if ($n.PSObject.Properties['displayName'] -and $n.displayName) { $n.displayName } else { $SourceId }
               } `
               elseif ($SourceId) { $SourceId } else { "Basetune" }

$targetLabel = if ($cfg.target -and $cfg.target.PSObject.Properties['displayName'] -and $cfg.target.displayName) { $cfg.target.displayName } `
               elseif ($TargetId -and $rawCfg.PSObject.Properties['tenant'] -and $rawCfg.tenant.PSObject.Properties[$TargetId]) {
                   $n = $rawCfg.tenant.PSObject.Properties[$TargetId].Value
                   if ($n.PSObject.Properties['displayName'] -and $n.displayName) { $n.displayName } else { $TargetId }
               } `
               elseif ($TargetId) { $TargetId } else { "Basetune" }

$sourceConnection = $null
$targetConnection = $null

# Determine which sides actually need a connection
# Mode is derived from the tenant config (authMethod), not a CLI parameter.
# Download skips the normal source/target setup entirely.
# Get-TenantMode lives in BasetuneConfig.psm1 — single source of truth, used
# by both this CLI and BasetuneUI.ps1.

$sourceOrigin = if ($cfg.source) { Get-TenantMode $cfg.source } else { 'Offline' }
$targetOrigin = if ($cfg.target) { Get-TenantMode $cfg.target } else { 'Offline' }

$needSource = -not $Download -and $sourceOrigin -eq 'Online' -and $cfg.source -and $ExportId -eq ""
$needTarget = -not $Download -and $targetOrigin -eq 'Online' -and $cfg.target -and $ExportId -eq ""

# Connections are established after offline checks — see LOAD POLICIES section

# ==============================================
# DOWNLOAD MODE (Definitions / Categories)
# ==============================================

if ($Download) {

    # -Id is required for download — pick the specified tenant
    $downloadConfig = $null
    if ($Id) {
        if ($rawCfg.PSObject.Properties['tenant'] -and $rawCfg.tenant -and
            $rawCfg.tenant.PSObject.Properties[$Id]) {
            $downloadConfig = $rawCfg.tenant.PSObject.Properties[$Id].Value
        }
        if (-not $downloadConfig) {
            Write-Log "Download" "Tenant '$Id' not found in Config.json. Use -Tenants to list all configured tenant ids." "ERROR"
            exit 1
        }
        if ((Get-TenantMode $downloadConfig) -ne 'Online') {
            Write-Log "Download" "Tenant '$Id' is an offline (JSON) tenant. Download needs an online tenant (ClientSecret or Certificate)." "ERROR"
            exit 1
        }
    } else {
        # No -Id: fall back to first online tenant in config
        if ($rawCfg.PSObject.Properties['tenant'] -and $rawCfg.tenant) {
            foreach ($prop in $rawCfg.tenant.PSObject.Properties) {
                $n = $prop.Value
                if ($n -and $n.PSObject.Properties['authMethod'] -and $n.authMethod -and $n.authMethod -ne 'None') {
                    $downloadConfig = $n
                    break
                }
            }
        }
        if (-not $downloadConfig) {
            Write-Log "Download" "No online tenant found. Use -Id <id> or add an online tenant to Config.json." "ERROR"
            exit 1
        }
    }
    $downloadLabel = if ($downloadConfig.PSObject.Properties['displayName'] -and $downloadConfig.displayName) { $downloadConfig.displayName } else { 'tenant' }
    Write-Log "Download" "Downloading setting definitions using tenant: $downloadLabel..." "INFO"
    $downloadConnection = New-GraphConnection -Config $downloadConfig -Label "Download"
    if (-not $downloadConnection) {
        Write-Log "Download" "Could not connect to tenant '$downloadLabel'. Check credentials in the configuration." "ERROR"
        exit 1
    }

    try {
        $null = Invoke-DefinitionDownload `
            -Connection      $downloadConnection `
            -DefinitionsPath $definitionsPath `
            -GraphBeta       $GraphBeta
    } catch {
        Write-Log "Download" "Download failed: $_" "ERROR"
        exit 1
    }

    exit
    
}

# ==============================================
# TENANTS LIST MODE
# ==============================================

if ($Tenants) {
    if ($rawCfg.PSObject.Properties['tenant'] -and $rawCfg.tenant) {
        $first = $true
        foreach ($prop in $rawCfg.tenant.PSObject.Properties) {
            $k = $prop.Name
            $n = $prop.Value
            $auth  = if ($n.PSObject.Properties['authMethod'] -and $n.authMethod) { $n.authMethod } else { 'None' }
            $label = if ($n.PSObject.Properties['displayName'] -and $n.displayName) { $n.displayName } else { $k }
            if (-not $first) { Write-Host "" }
            Write-Host "Name: $label"
            Write-Host "Id:   $k"
            Write-Host "Auth: $auth"
            $first = $false
        }
    }
    exit
}

# ==============================================
# EXPORT MODE
# ==============================================

if ($ExportId -ne "") {

    # ── -ExportPath required first ────────────────────────────────────────────
    # Validate BEFORE doing anything that could acquire a Graph token, so the
    # user gets a clear "missing parameter" message instead of a token attempt
    # followed by a path error.
    if (-not $ExportPath -or -not $ExportPath.Trim()) {
        Write-Log "Export" "Parameter -ExportPath is required for export. Specify a target folder." "ERROR"
        exit 1
    }

    $_ep = Resolve-FolderPath -Path $ExportPath -BasePath (Get-Location -PSProvider FileSystem).ProviderPath
    if ($_ep.Error) {
        Write-Log "Export" "Parameter -ExportPath is not valid: $($_ep.Error)" "ERROR"
        exit 1
    }
    $outPath = $_ep.Path
    if ($outPath -match '^[A-Za-z]:\\?$') {
        Write-Log "Export" "Cannot export to a drive root ($outPath). Choose a folder." "ERROR"
        exit 1
    }

    # ── Resolve tenant node ───────────────────────────────────────────────────
    $exportNode = $null
    if ($rawCfg.PSObject.Properties['tenant'] -and $rawCfg.tenant -and
        $rawCfg.tenant.PSObject.Properties[$ExportId]) {
        $exportNode = $rawCfg.tenant.PSObject.Properties[$ExportId].Value
    }
    if (-not $exportNode) {
        Write-Log "Export" "Tenant '$ExportId' not found in Config.json. Use -Tenants to list all configured tenant ids." "ERROR"
        exit 1
    }

    $exportLabel  = if ($exportNode.PSObject.Properties['displayName'] -and $exportNode.displayName) { $exportNode.displayName } else { $ExportId }
    $exportOrigin = Get-TenantMode $exportNode

    # Offline tenants can't be exported — their data already lives on disk as
    # JSON files. The user can copy those directly instead of re-exporting.
    if ($exportOrigin -ne 'Online') {
        Write-Log "Export" "Tenant '$exportLabel' is offline (JSON-based). Export is only available for online tenants. Copy the existing JSON files directly if you need them elsewhere." "ERROR"
        exit 1
    }

    # Build connection
    $exportConnection = New-GraphConnection -Config $exportNode -Label "Export"
    if (-not $exportConnection) {
        Write-Log "Export" "Could not connect to tenant '$exportLabel'. Check credentials in the configuration." "ERROR"
        exit 1
    }

    if (-not (Test-Path $outPath)) { New-Item -ItemType Directory -Path $outPath -Force | Out-Null }

    Write-Log "Export" "Exporting $exportLabel to $outPath..." "INFO"
    try {
        $exportResult = Export-PoliciesToJson `
            -Connection $exportConnection `
            -Filter      $ExportFilter `
            -OutputPath  $outPath `
            -GraphBeta   $GraphBeta `
            -MaxThreads  $MaxThreads
    } catch {
        Write-Log "Export" "Export failed: $_" "ERROR"
        exit 1
    }

    if ($exportResult -and $exportResult.Failed -gt 0) {
        Write-Log "Done" "Export finished with $($exportResult.Failed) failed policies." "ERROR"
        exit 1
    }
    Write-Log "Done" "Export complete." "OK"
    exit
}

# ==============================================
# LOAD POLICIES
# ==============================================

# Helper: build tenant info string for logging
function Get-TenantInfoLog {
    param([object]$Node, [string]$FallbackId, [string]$Origin)
    if ($Node -and $Node.PSObject.Properties['displayName'] -and $Node.displayName) {
        $auth = if ($Node.PSObject.Properties['authMethod'] -and $Node.authMethod) { $Node.authMethod } else { 'None' }
        return "$($Node.displayName) [$auth] ($Origin)"
    } elseif ($FallbackId) {
        return "$FallbackId ($Origin)"
    } else {
        return "Basetune (Default) ($Origin)"
    }
}

# Resolve paths — no fallback for offline tenants: path must be set in config
$resolvedSourcePath = if ($sourceOrigin -eq 'Online') {
    $null
} elseif ($cfg.source -and $cfg.source.PSObject.Properties['path'] -and $cfg.source.path -and $cfg.source.path.Trim()) {
    $cfg.source.path.Trim()
} else { $null }

$resolvedTargetPath = if ($targetOrigin -eq 'Online') {
    $null
} elseif ($cfg.target -and $cfg.target.PSObject.Properties['path'] -and $cfg.target.path -and $cfg.target.path.Trim()) {
    $cfg.target.path.Trim()
} else { $null }

# Offline path checks — both sides validated before aborting on failure
$pathErrors = $false
if ($sourceOrigin -eq 'Offline') {
    if (-not $resolvedSourcePath) {
        $srcLabel = if ($cfg.source -and $cfg.source.PSObject.Properties['displayName'] -and $cfg.source.displayName) { $cfg.source.displayName } else { $SourceId }
        Write-Log "Source" "No path configured for '$srcLabel'. Set a JSON path in Config.json." "ERROR"
        $pathErrors = $true
    } else {
        if (-not (Test-Path $resolvedSourcePath)) {
            try {
                New-Item -ItemType Directory -Path $resolvedSourcePath -Force | Out-Null
                Write-Log "Source" "Created folder: $resolvedSourcePath" "INFO"
            } catch {
                Write-Log "Source" "Cannot create path: $resolvedSourcePath. $_" "ERROR"
                $pathErrors = $true
            }
        }
        if (-not $pathErrors) {
            $srcJsonCount = @(Get-ChildItem -Path $resolvedSourcePath -Filter '*.json' -ErrorAction SilentlyContinue).Count
            if ($srcJsonCount -eq 0) {
                Write-Log "Source" (Get-TenantInfoLog -Node $cfg.source -FallbackId $SourceId -Origin $sourceOrigin) "INFO"
                Write-Log "Source" "No JSON files found in $resolvedSourcePath." "ERROR"
                $pathErrors = $true
            }
        }
    }
}
if ($targetOrigin -eq 'Offline') {
    if (-not $resolvedTargetPath) {
        $tgtLabel = if ($cfg.target -and $cfg.target.PSObject.Properties['displayName'] -and $cfg.target.displayName) { $cfg.target.displayName } else { $TargetId }
        Write-Log "Target" "No path configured for '$tgtLabel'. Set a JSON path in Config.json." "ERROR"
        $pathErrors = $true
    } else {
        if (-not (Test-Path $resolvedTargetPath)) {
            try {
                New-Item -ItemType Directory -Path $resolvedTargetPath -Force | Out-Null
                Write-Log "Target" "Created folder: $resolvedTargetPath" "INFO"
            } catch {
                Write-Log "Target" "Cannot create path: $resolvedTargetPath. $_" "ERROR"
                $pathErrors = $true
            }
        }
        if (Test-Path $resolvedTargetPath) {
            $tgtJsonCount = @(Get-ChildItem -Path $resolvedTargetPath -Filter '*.json' -ErrorAction SilentlyContinue).Count
            if ($tgtJsonCount -eq 0) {
                Write-Log "Target" (Get-TenantInfoLog -Node $cfg.target -FallbackId $TargetId -Origin $targetOrigin) "INFO"
                Write-Log "Target" "No JSON files found in $resolvedTargetPath." "ERROR"
                $pathErrors = $true
            }
        }
    }
}
if ($pathErrors) { exit 1 }

# Now establish online connections — both attempted before aborting on failure
if ($needSource) {
    $sourceConnection = New-GraphConnection -Config $cfg.source -Label "Source"
}
if ($needTarget) {
    $targetConnection = New-GraphConnection -Config $cfg.target -Label "Target"
}

# Report all connection failures at once
$connErrors = $false
if ($needSource -and -not $sourceConnection) {
    Write-Log "Source" "Could not connect to tenant '$SourceId'. Check credentials in the configuration." "ERROR"
    $connErrors = $true
}
if ($needTarget -and -not $targetConnection) {
    Write-Log "Target" "Could not connect to tenant '$TargetId'. Check credentials in the configuration." "ERROR"
    $connErrors = $true
}
if ($connErrors) { exit 1 }
$global:GraphConnection = if ($sourceConnection) { $sourceConnection } elseif ($targetConnection) { $targetConnection } else { $null }

# A load that throws (e.g. policies that could not be fetched after all
# retries) stops the run: comparing with an incomplete set would report the
# missing policies' settings as Missing.
Write-Log "Source" (Get-TenantInfoLog -Node $cfg.source -FallbackId $SourceId -Origin $sourceOrigin) "INFO"
try {
    $sourceExpanded = @(Resolve-PolicySource `
        -Origin $sourceOrigin -Connection $sourceConnection -Filter $SourceFilter `
        -Label "Source" -GraphBeta $GraphBeta -ModulesPath $ModulesPath `
        -JsonPath $resolvedSourcePath -TenantLabel $sourceLabel -MaxThreads $MaxThreads `
        -LogFile $_logFile)
} catch {
    if (-not $_.Exception.Data['BasetuneLogged']) { Write-Log "Source" "Load failed: $($_.Exception.Message)" "ERROR" }
    exit 1
}

# Online or offline: without source policies there is nothing to compare.
if ($sourceExpanded.Count -eq 0) {
    Write-Log "Source" "No policies loaded. Check the source filter ('$SourceFilter')." "ERROR"
    exit 1
}

Write-Log "Target" (Get-TenantInfoLog -Node $cfg.target -FallbackId $TargetId -Origin $targetOrigin) "INFO"
try {
    $targetExpanded = @(Resolve-PolicySource `
        -Origin $targetOrigin -Connection $targetConnection -Filter $TargetFilter `
        -Label "Target" -GraphBeta $GraphBeta -ModulesPath $ModulesPath `
        -JsonPath $resolvedTargetPath -TenantLabel $targetLabel -MaxThreads $MaxThreads `
        -LogFile $_logFile)
} catch {
    if (-not $_.Exception.Data['BasetuneLogged']) { Write-Log "Target" "Load failed: $($_.Exception.Message)" "ERROR" }
    exit 1
}

# An empty target is allowed (e.g. a fresh tenant, or a filter that matches
# nothing): every baseline setting is then reported as Missing. Offline
# folders without JSON files were already rejected by the path checks above.
if ($targetExpanded.Count -eq 0) {
    Write-Log "Target" "No target policies loaded (filter: '$TargetFilter'). All baseline settings will be reported as Missing." "WARN"
}

# ==============================================
# DEFINITIONS LOOKUP
# ==============================================
# Same loader as the UI (IntuneGraphPolicies.psm1). A missing file means "not
# downloaded yet" (raw ids in the output); a corrupt file is reported.

$definitionLookup = $null
$categoryById     = $null
try {
    if (Test-Path $definitionsFile) { Write-Log "Definitions" "Loading setting definitions..." "INFO" }
    $definitionLookup = Import-SettingDefinitions -Path $definitionsFile
} catch {
    Write-Log "Definitions" "Cannot read settingDefinitions.json: $($_.Exception.Message). Run -Download again." "ERROR"
}
if ($definitionLookup) {
    Write-Log "Definitions" "$($definitionLookup.Count) definitions loaded" "OK"
} else {
    Write-Log "Definitions" "No definitions file found. Output will use raw settingDefinitionId." "WARN"
}

if ($definitionLookup) {
    try {
        $categoryById = Import-SettingCategories -Path $categoriesFile
    } catch {
        Write-Log "Categories" "Cannot read settingCategories.json: $($_.Exception.Message). Run -Download again." "ERROR"
    }
}
if ($categoryById) {
    Write-Log "Categories" "$($categoryById.Count) categories loaded" "OK"
} else {
    Write-Log "Categories" "No categories file found. Category paths will be skipped." "WARN"
}

# ==============================================
# COMPARE + EXPORT
# ==============================================

# Build report subfolder: Report\SOURCE_TARGET\YYYYMMDD_HHMMSS
# $reportBasePath is already validated and normalized (config / -ReportPath),
# see CONFIG above. Join-Path avoids a double backslash on a drive root (C:\).
$safeSrcLabel  = ($sourceLabel -replace '[\\/:*?"<>|\s]','_')
$safeTgtLabel  = ($targetLabel -replace '[\\/:*?"<>|\s]','_')
$runStamp      = Get-Date -Format 'yyyyMMdd_HHmmss'
$runPairFolder = "${safeSrcLabel}_${safeTgtLabel}"
$runReportDir  = Join-Path (Join-Path $reportBasePath $runPairFolder) $runStamp
try {
    New-Item -ItemType Directory -Path $runReportDir -Force -ErrorAction Stop | Out-Null
} catch {
    Write-Log "Compare" "Cannot create report folder '$runReportDir'. $($_.Exception.Message)" "ERROR"
    exit 1
}
$runReportFile = Join-Path $runReportDir 'Report.html'

try {
    $compareResult = Invoke-BaselineCompare `
        -SourcePolicies     $sourceExpanded `
        -TargetPolicies     $targetExpanded `
        -ExportPath         $runReportDir `
        -ReportFile         $runReportFile `
        -DefinitionLookup   $definitionLookup `
        -CategoryById       $categoryById `
        -CategoriesFilePath $categoriesFile `
        -Connection         $global:GraphConnection `
        -SourceLabel        $sourceLabel `
        -TargetLabel        $targetLabel
} catch {
    Write-Log "Compare" "Compare failed: $($_.Exception.Message)" "ERROR"
    exit 1
}
if (-not $compareResult -or -not $compareResult.Success) { exit 1 }