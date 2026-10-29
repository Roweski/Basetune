#Requires -Version 7.0
# Basetune CLI. Run .\BasetuneCLI.ps1 -Help for the parameters.
#
# Structure: the help first, then the CLI itself in a script block with the
# parameters ($cli, called at the end with the arguments of this script).
# Why: PowerShell answers -? itself for a script with [CmdletBinding()] /
# [Parameter()] attributes (its own syntax list) before the script runs.
# This script has no parameter block, so -? arrives in $args and shows the
# Basetune help, the same as -Help.

# Full help (-Help, -?, /?, -h, --help).
function Show-BasetuneCliHelp {
    # The modules are not loaded yet: the version straight from the manifest.
    $_version = try { (Import-PowerShellDataFile -LiteralPath "$PSScriptRoot\Modules\Core\BasetuneCore.psd1").ModuleVersion } catch { 'unknown' }
    Write-Host ""
    Write-Host "Basetune $_version" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "USAGE" -ForegroundColor Yellow
    Write-Host "  .\BasetuneCLI.ps1 -Source <id> -Target <id> [parameters]"
    Write-Host ""
    Write-Host "COMPARE" -ForegroundColor Yellow
    Write-Host "  -Source       <id>     Source tenant ID from Config.json (required)"
    Write-Host "  -Target       <id>     Target tenant ID from Config.json (required)"
    Write-Host "  -SourceFilter <text>   Filter source policies by name before loading"
    Write-Host "  -TargetFilter <text>   Filter target policies by name before loading"
    Write-Host "  -ReportPath   <path>   Override report output folder for this run"
    Write-Host "  -MaxThreads   <n>      Parallel threads for loading policy settings, 1-32 (default: from Options.json)"
    Write-Host "  -Platforms    <list>   Comma-separated: windows,macos,ios,android,linux (default: windows)"
    Write-Host ""
    Write-Host "EXPORT" -ForegroundColor Yellow
    Write-Host "  -Export       <id>     Export policies from this tenant ID to JSON files"
    Write-Host "  -ExportPath   <path>   Output folder (required)"
    Write-Host "  -ExportFilter <text>   Filter policies by name before exporting"
    Write-Host "  -Platforms    <list>   Comma-separated: windows,macos,ios,android,linux (default: windows)"
    Write-Host ""
    Write-Host "DOWNLOAD" -ForegroundColor Yellow
    Write-Host "  -Download     <id>     Download setting definitions and categories using this online tenant ID"
    Write-Host ""
    Write-Host "INFO" -ForegroundColor Yellow
    Write-Host "  -TenantList            List all configured tenants with IDs and authentication methods"
    Write-Host "  -? / -Help             Show this help"
    Write-Host ""
    Write-Host "EXAMPLES" -ForegroundColor Yellow
    Write-Host "  .\BasetuneCLI.ps1 -Source <id> -Target <id>"
    Write-Host "  .\BasetuneCLI.ps1 -Source <id> -SourceFilter Win-L1 -Target <id> -TargetFilter Win-L1"
    Write-Host "  .\BasetuneCLI.ps1 -Export <id> -ExportPath C:\MyExport"
    Write-Host "  .\BasetuneCLI.ps1 -Export <id> -ExportPath C:\MyExport -ExportFilter Win-L2"
    Write-Host "  .\BasetuneCLI.ps1 -Download <id>"
    Write-Host "  .\BasetuneCLI.ps1 -TenantList"
    Write-Host ""
}

if (@($args | Where-Object { "$_" -in '-?', '/?', '-Help', '-h', '--help' }).Count -gt 0) {
    Show-BasetuneCliHelp
    exit
}

$cli = {
    [CmdletBinding(DefaultParameterSetName='Compare')]
    param (
        # ── COMPARE ───────────────────────────────────────────────────────────────
        [Parameter(ParameterSetName='Compare', Mandatory)]
        [string]$Source,

        [Parameter(ParameterSetName='Compare', Mandatory)]
        [string]$Target,

        [Parameter(ParameterSetName='Compare')]
        [string]$SourceFilter = "",

        [Parameter(ParameterSetName='Compare')]
        [string]$TargetFilter = "",

        [Parameter(ParameterSetName='Compare')]
        [string]$ReportPath = "",

        [Parameter(ParameterSetName='Compare')]
        [Parameter(ParameterSetName='Export')]
        [int]$MaxThreads = 0,

        # Comma separated: windows,macos,ios,android,linux. Default: windows.
        [Parameter(ParameterSetName='Compare')]
        [Parameter(ParameterSetName='Export')]
        [string[]]$Platforms = @(),

        # ── EXPORT ────────────────────────────────────────────────────────────────
        [Parameter(ParameterSetName='Export', Mandatory)]
        [string]$Export,

        [Parameter(ParameterSetName='Export')]
        [string]$ExportPath = "",

        [Parameter(ParameterSetName='Export')]
        [string]$ExportFilter = "",

        # ── DOWNLOAD ──────────────────────────────────────────────────────────────
        # The id of the online tenant to download with (no default tenant).
        [Parameter(ParameterSetName='Download', Mandatory)]
        [string]$Download,

        # ── INFO ──────────────────────────────────────────────────────────────────
        [Parameter(ParameterSetName='TenantList', Mandatory)]
        [switch]$TenantList
    )

    # ==============================================
    # CONFIG
    # ==============================================

    Import-Module "$PSScriptRoot\Modules\Core\BasetuneCore.psd1" -Force
    # CLI-only functions (Resolve-TenantConfig); the UI does not use them.
    Import-Module "$PSScriptRoot\Modules\CLI\BasetuneCLI.psm1" -Force

    # Log file shared with the UI (Logs\Basetune.log; CMTrace Source = UI or
    # CLI). Writes go through a named mutex (Add-LogFileLine), so a CLI run next
    # to an open UI loses no lines.
    $_logDir = "$PSScriptRoot\Logs"
    New-Item -ItemType Directory -Path $_logDir -Force | Out-Null
    $_logFile = "$_logDir\Basetune.log"
    try { Set-LogFile -Path $_logFile -Rotate -Source 'CLI' } catch {}   # -Rotate: > 5 MB becomes Basetune_<date>_<time>.log, 5 kept (every run, also scheduled)
    # First line of every run in the log file: which version wrote what follows.
    Write-Log 'Startup' "Basetune $(Get-BasetuneVersion) started (CLI)" 'INFO' -FileOnly

    $GraphBeta   = "https://graph.microsoft.com/beta"

    $ModulesPath      = "$PSScriptRoot\Modules\Core"   # engine modules (parallel workers import from here)
    $definitionsPath  = "$PSScriptRoot\Definitions"
    $reportBasePath   = "$PSScriptRoot\Reports"

    # Load config once — derive all settings from it
    $rawCfg = $null
    try { $rawCfg = Get-BasetuneConfig "$PSScriptRoot\Config\Config.json" }
    catch { Write-Log "Config" "Details: $($_.Exception.Message)" "ERROR" -FileOnly }
    # Invalid JSON / missing file: report it (otherwise only "tenant not found").
    if ($rawCfg -and $rawCfg.PSObject.Properties['__configError'] -and $rawCfg.__configError) {
        Write-Log "Config" "$($rawCfg.__configError)" "ERROR"
        if ($rawCfg.PSObject.Properties['__configErrorDetail'] -and $rawCfg.__configErrorDetail) {
            Write-Log "Config" "Details: $($rawCfg.__configErrorDetail)" "ERROR" -FileOnly
        }
        exit 1
    }
    if (-not $rawCfg) { $rawCfg = [PSCustomObject]@{ tenant = $null } }

    # Options (report path, theme, max threads) from Options.json — the same file
    # as the Options window. Created / repaired by Get-BasetuneOptions. The
    # platforms in it are for the UI only (CLI: -Platforms, default Windows).
    $options = Get-BasetuneOptions -Path "$PSScriptRoot\Config\Options.json"

    # MaxThreads: -MaxThreads > Options.json > 8. Always validated (1..32): 0 or
    # a bad value would make ForEach-Object -ThrottleLimit abort the load.
    # $MaxThreads is [int]: a non-numeric config value goes through the
    # validator first (assigning it directly throws).
    $_mtRequested = $MaxThreads
    if ($MaxThreads -eq 0) {
        $_mtRequested = if ($options.MaxThreads) { $options.MaxThreads } else { 8 }
    }
    $MaxThreads = Get-ValidMaxThreads $_mtRequested

    # Platforms for compare and export: -Platforms windows,macos (comma separated;
    # also works as one string from cmd). Without -Platforms: Windows only, the
    # same default as the UI. An unknown platform stops the run.
    $_pfAllowed = @(Get-PlatformOptions | ForEach-Object { $_.Key })
    $_pfAsked   = @($Platforms | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    $_pfBad     = @($_pfAsked | Where-Object { $_ -notin $_pfAllowed })
    if ($_pfBad.Count -gt 0) {
        Write-Log "Config" "Invalid platform '$($_pfBad -join ', ')'. Allowed: $($_pfAllowed -join ', ')" "ERROR"
        exit 1
    }
    $loadPlatforms = if ($_pfAsked.Count -gt 0) { [string[]](Get-ValidPlatforms $_pfAsked) } else { [string[]](Get-DefaultPlatforms) }

    # Report path: Options.json > default. Relative paths are relative to the
    # Basetune folder. An invalid path is already repaired in Options.json by
    # Get-BasetuneOptions; this is only a fallback if that write failed.
    if ($options.ReportPath -and "$($options.ReportPath)".Trim()) {
        $_rp = Resolve-FolderPath -Path $options.ReportPath -BasePath $PSScriptRoot
        if (-not $_rp.Error) { $reportBasePath = $_rp.Path }
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
    # (see COMPARE + EXPORT), not for -TenantList / -Download / export runs.
    New-Item -ItemType Directory -Path $definitionsPath -Force | Out-Null

    # Fetched categories are always saved to categories.json (the definitions
    # themselves are read by Get-CompareDefinitions: downloaded file first,
    # otherwise the .default file shipped with the release).
    $categoriesFile  = Join-Path $definitionsPath 'categories.json'


    # ==============================================
    # CONNECTIONS (only when needed)
    # ==============================================

    # Resolve source/target nodes from the single rawCfg load above
    $cfg = $null
    try { $cfg = Resolve-TenantConfig -Cfg $rawCfg -SourceId $Source -TargetId $Target } catch {}
    if (-not $cfg) {
        $cfg = [PSCustomObject]@{ source = $null; target = $null; tenant = $null }
    }

    # ── Early tenant validation + connections (Compare mode only) ────────────────
    # Source AND target are validated before any policy loading starts. Errors
    # are collected, so the user sees every problem at once, not one per run.
    if ($PSCmdlet.ParameterSetName -eq 'Compare') {
        $configErrors = [System.Collections.Generic.List[string]]::new()

        # ── id existence ──────────────────────────────────────────────────────────
        # Both ids must resolve to a tenant in Config.json (API or JSON; the
        # credential and path checks below handle the rest per side).
        # Resolve-TenantConfig returns $null both for an unknown id and for an
        # entry marked invalid by Get-BasetuneConfig (an empty tenantId, clientId,
        # clientSecret or certThumbprint). Tell the two apart. One line per id:
        # the same unknown id as source and target is reported once.
        $rawTenantExists = {
            param($id)
            [bool]($id -and $rawCfg.PSObject.Properties['tenant'] -and $rawCfg.tenant -and $rawCfg.tenant.PSObject.Properties[$id])
        }
        foreach ($tenantRef in @(@{ Id = $Source; Node = $cfg.source }, @{ Id = $Target; Node = $cfg.target })) {
            if ($tenantRef.Node) { continue }
            $msg = if (& $rawTenantExists $tenantRef.Id) { "Tenant with id '$($tenantRef.Id)' is incomplete in Config.json (tenantId, clientId, clientSecret or certThumbprint is empty)" }
                   else                             { "Tenant with id '$($tenantRef.Id)' not found in Config.json" }
            if (-not $configErrors.Contains($msg)) { $configErrors.Add($msg) }
        }

        if ($configErrors.Count -gt 0) {
            foreach ($e in $configErrors) { Write-Log "Config" $e "ERROR" }
            Write-Log "Config" "Use -TenantList to list all configured tenant IDs" "INFO"
            exit 1
        }

        # ── Online credential sanity check (before attempting any network call) ───
        $srcAuth = if ($cfg.source.PSObject.Properties['authMethod'] -and $cfg.source.authMethod) { $cfg.source.authMethod } else { 'None' }
        $tgtAuth = if ($cfg.target.PSObject.Properties['authMethod'] -and $cfg.target.authMethod) { $cfg.target.authMethod } else { 'None' }

        if ($srcAuth -ne 'None') {
            if (-not $cfg.source.tenantId -or -not $cfg.source.clientId) {
                $configErrors.Add("Source '$Source': missing tenantId or clientId in Config.json")
            } elseif ($srcAuth -eq 'ClientSecret' -and -not $cfg.source.clientSecret) {
                $configErrors.Add("Source '$Source': authMethod is ClientSecret but clientSecret is missing")
            } elseif ($srcAuth -eq 'Certificate' -and -not $cfg.source.certThumbprint) {
                $configErrors.Add("Source '$Source': authMethod is Certificate but certThumbprint is missing")
            }
        }
        if ($tgtAuth -ne 'None') {
            if (-not $cfg.target.tenantId -or -not $cfg.target.clientId) {
                $configErrors.Add("Target '$Target': missing tenantId or clientId in Config.json")
            } elseif ($tgtAuth -eq 'ClientSecret' -and -not $cfg.target.clientSecret) {
                $configErrors.Add("Target '$Target': authMethod is ClientSecret but clientSecret is missing")
            } elseif ($tgtAuth -eq 'Certificate' -and -not $cfg.target.certThumbprint) {
                $configErrors.Add("Target '$Target': authMethod is Certificate but certThumbprint is missing")
            }
        }

        if ($configErrors.Count -gt 0) {
            foreach ($e in $configErrors) { Write-Log "Config" $e "ERROR" }
            exit 1
        }
    }

    $sourceLabel = if ($cfg.source -and $cfg.source.PSObject.Properties['displayName'] -and $cfg.source.displayName) { $cfg.source.displayName } `
                   elseif ($Source -and $rawCfg.PSObject.Properties['tenant'] -and $rawCfg.tenant.PSObject.Properties[$Source]) {
                       $n = $rawCfg.tenant.PSObject.Properties[$Source].Value
                       if ($n.PSObject.Properties['displayName'] -and $n.displayName) { $n.displayName } else { $Source }
                   } `
                   elseif ($Source) { $Source } else { "Basetune" }

    $targetLabel = if ($cfg.target -and $cfg.target.PSObject.Properties['displayName'] -and $cfg.target.displayName) { $cfg.target.displayName } `
                   elseif ($Target -and $rawCfg.PSObject.Properties['tenant'] -and $rawCfg.tenant.PSObject.Properties[$Target]) {
                       $n = $rawCfg.tenant.PSObject.Properties[$Target].Value
                       if ($n.PSObject.Properties['displayName'] -and $n.displayName) { $n.displayName } else { $Target }
                   } `
                   elseif ($Target) { $Target } else { "Basetune" }

    $sourceConnection = $null
    $targetConnection = $null

    # Which sides need a connection. The mode comes from the tenant's authMethod
    # (Get-TenantMode, BasetuneHelpers, shared with the UI). Download skips this.

    $sourceOrigin = if ($cfg.source) { Get-TenantMode $cfg.source } else { 'Offline' }
    $targetOrigin = if ($cfg.target) { Get-TenantMode $cfg.target } else { 'Offline' }

    $needSource = -not $Download -and $sourceOrigin -eq 'Online' -and $cfg.source -and $Export -eq ""
    $needTarget = -not $Download -and $targetOrigin -eq 'Online' -and $cfg.target -and $Export -eq ""

    # Connections are established after offline checks — see LOAD POLICIES section

    # Execution-speed throttling off for the whole run, also when the terminal
    # is not in the foreground (Windows can otherwise apply it, see
    # Set-ProcessPowerThrottling). Not for -TenantList: nothing to speed up.
    # The process ends with the run, so there is nothing to switch back.
    if (-not $TenantList) { Set-ProcessPowerThrottling -Enabled $false }

    # ==============================================
    # DOWNLOAD MODE (Definitions / Categories)
    # ==============================================

    if ($Download) {

        # The tenant given with -Download; it must be an online tenant.
        $downloadConfig = $null
        if ($rawCfg.PSObject.Properties['tenant'] -and $rawCfg.tenant -and
            $rawCfg.tenant.PSObject.Properties[$Download]) {
            $downloadConfig = $rawCfg.tenant.PSObject.Properties[$Download].Value
        }
        if (-not $downloadConfig) {
            Write-Log "Download" "Tenant '$Download' not found in Config.json. Use -TenantList to list all configured tenant IDs" "ERROR"
            exit 1
        }
        if ((Get-TenantMode $downloadConfig) -ne 'Online') {
            Write-Log "Download" "Tenant '$Download' is an offline baseline. Download needs an online tenant (ClientSecret or Certificate)" "ERROR"
            exit 1
        }
        $downloadLabel = if ($downloadConfig.PSObject.Properties['displayName'] -and $downloadConfig.displayName) { $downloadConfig.displayName } else { 'tenant' }
        Write-Log "Download" "Downloading setting and category definitions using tenant '$downloadLabel'..." "INFO"
        $downloadConnection = New-GraphConnection -Config $downloadConfig -Label "Download"
        if (-not $downloadConnection) {
            Write-Log "Download" "Could not connect to tenant '$downloadLabel'. Check the credentials in Config.json. See Basetune.log for details" "ERROR"
            exit 1
        }

        try {
            $null = Invoke-DefinitionDownload `
                -Connection      $downloadConnection `
                -DefinitionsPath $definitionsPath `
                -GraphBeta       $GraphBeta
        } catch {
            Write-Log "Download" "Download failed. See Basetune.log for details" "ERROR"
            Write-Log "Download" "Details: $($_.Exception.Message)" "ERROR" -FileOnly
            exit 1
        }

        exit

    }

    # ==============================================
    # TENANTS LIST MODE
    # ==============================================

    if ($TenantList) {
        # One table, sorted by Id: numeric ids in numeric order (1, 2, 10),
        # other ids after them, alphabetically.
        $rows = @()
        if ($rawCfg.PSObject.Properties['tenant'] -and $rawCfg.tenant) {
            $rows = @(foreach ($prop in $rawCfg.tenant.PSObject.Properties) {
                $n = $prop.Value
                [PSCustomObject]@{
                    Id   = $prop.Name
                    Name = if ($n.PSObject.Properties['displayName'] -and $n.displayName) { "$($n.displayName)" } else { $prop.Name }
                    Auth = if ($n.PSObject.Properties['authMethod'] -and $n.authMethod) { "$($n.authMethod)" } else { 'None' }
                    Type = if ((Get-TenantMode $n) -eq 'Online') { 'Microsoft Graph' } else { 'JSON' }
                }
            })
        }
        if ($rows.Count -eq 0) {
            Write-Host "No tenants configured. Add a tenant via Tenant Configuration in the UI."
            exit
        }
        $num  = 0
        $rows = @($rows | Sort-Object @{ Expression = { if ([int]::TryParse($_.Id, [ref]$num)) { 0 } else { 1 } } },
                                      @{ Expression = { if ([int]::TryParse($_.Id, [ref]$num)) { $num } else { 0 } } },
                                      @{ Expression = { $_.Id } })
        $cols = 'Id', 'Name', 'Auth', 'Type'
        $w = @{}
        foreach ($c in $cols) { $w[$c] = [math]::Max($c.Length, ($rows | ForEach-Object { "$($_.$c)".Length } | Measure-Object -Maximum).Maximum) }
        $fmt = { param($vals) (@(for ($c = 0; $c -lt $cols.Count; $c++) { "$($vals[$c])".PadRight($w[$cols[$c]]) }) -join '  ').TrimEnd() }
        Write-Host ""
        Write-Host (& $fmt $cols)
        Write-Host (& $fmt ($cols | ForEach-Object { '-' * $_.Length }))
        foreach ($r in $rows) { Write-Host (& $fmt @($r.Id, $r.Name, $r.Auth, $r.Type)) }
        Write-Host ""
        $noun = if ($rows.Count -eq 1) { 'tenant' } else { 'tenants' }
        Write-Host "$($rows.Count) $noun. Use the Id with -Source / -Target, -Export or -Download."
        exit
    }

    # ==============================================
    # EXPORT MODE
    # ==============================================

    if ($Export -ne "") {

        # ── -ExportPath required first ────────────────────────────────────────────
        # Checked BEFORE any Graph token request: a clear "missing parameter"
        # message instead of a token attempt and then a path error.
        if (-not $ExportPath -or -not $ExportPath.Trim()) {
            Write-Log "Export" "Parameter -ExportPath is required for export. Specify a target folder" "ERROR"
            exit 1
        }

        # Export may go to a network share (\\server\share): a one-off write,
        # unlike the report path, which must be local (policy folders may be on a share too).
        $_ep = Resolve-FolderPath -Path $ExportPath -BasePath (Get-Location -PSProvider FileSystem).ProviderPath
        if ($_ep.Error) {
            Write-Log "Export" "Parameter -ExportPath is not valid: $($_ep.Error)" "ERROR"
            exit 1
        }
        $outPath = $_ep.Path
        if ($outPath -match '^[A-Za-z]:\\?$') {
            Write-Log "Export" "Cannot export to a drive root ($outPath). Choose a subfolder (e.g. C:\Export)" "ERROR"
            exit 1
        }

        # ── Resolve tenant node ───────────────────────────────────────────────────
        $exportNode = $null
        if ($rawCfg.PSObject.Properties['tenant'] -and $rawCfg.tenant -and
            $rawCfg.tenant.PSObject.Properties[$Export]) {
            $exportNode = $rawCfg.tenant.PSObject.Properties[$Export].Value
        }
        if (-not $exportNode) {
            Write-Log "Export" "Tenant '$Export' not found in Config.json. Use -TenantList to list all configured tenant IDs" "ERROR"
            exit 1
        }

        $exportLabel  = if ($exportNode.PSObject.Properties['displayName'] -and $exportNode.displayName) { $exportNode.displayName } else { $Export }
        $exportOrigin = Get-TenantMode $exportNode

        # Offline baselines can't be exported — their data already lives on disk as
        # JSON files. The user can copy those directly instead of re-exporting.
        if ($exportOrigin -ne 'Online') {
            Write-Log "Export" "Tenant '$exportLabel' is an offline baseline. Export is only available for online tenants. Copy the existing JSON files directly if you need them elsewhere" "ERROR"
            exit 1
        }

        # Export folder first, then the start line (as in the UI), then the
        # sign-in (as in a load: after the start line).
        Write-Log "Export" "Export folder: $outPath" "INFO"
        Write-Log "Export" "Exporting policies from '$exportLabel'..." "INFO"

        $exportConnection = New-GraphConnection -Config $exportNode -Label "Export"
        if (-not $exportConnection) {
            Write-Log "Export" "Could not connect to tenant '$exportLabel'. Check the credentials in Config.json. See Basetune.log for details" "ERROR"
            exit 1
        }

        if (-not (Test-Path $outPath)) { New-Item -ItemType Directory -Path $outPath -Force | Out-Null }

        try {
            $exportResult = Export-PoliciesToJson `
                -Connection $exportConnection `
                -Filter      $ExportFilter `
                -OutputPath  $outPath `
                -GraphBeta   $GraphBeta `
                -MaxThreads  $MaxThreads `
                -Platforms   $loadPlatforms
        } catch {
            Write-Log "Export" "Export failed. See Basetune.log for details" "ERROR"
            Write-Log "Export" "Details: $($_.Exception.Message)" "ERROR" -FileOnly
            exit 1
        }

        # Same as the UI: success is in the module's "Export completed (...)" line; failures
        # are listed per policy, followed by "Export failed.".
        if ($exportResult -and $exportResult.Failed -gt 0) {
            Write-Log "Export" "Export failed" "ERROR"
            exit 1
        }
        exit
    }

    # ==============================================
    # LOAD POLICIES
    # ==============================================

    # Same start lines as the UI:
    #   Loading policies from source 'Contoso' (id: 1)...
    #   Policy name filter: 'x'   /   Policy name filter: None
    #   Platform filter: Windows, macOS
    function Write-LoadStartLog {
        param([string]$Side, [string]$TenantLabel, [string]$TenantId, [string]$Origin, [string]$Filter)
        Write-Log $Side "Loading policies from $($Side.ToLowerInvariant()) '$TenantLabel' (id: $TenantId)..." "INFO"
        Write-Log $Side "Policy name filter: $(if ($Filter) { "'$Filter'" } else { 'None' })" "INFO"
        Write-Log $Side "Platform filter: $(Get-PlatformsText $loadPlatforms)" "INFO"
    }

    # Resolve paths — no fallback for offline baselines: path must be set in config
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
            $srcLabel = if ($cfg.source -and $cfg.source.PSObject.Properties['displayName'] -and $cfg.source.displayName) { $cfg.source.displayName } else { $Source }
            Write-Log "Source" "No path configured for '$srcLabel'. Set a policy folder in Config.json" "ERROR"
            $pathErrors = $true
        } else {
            # A missing folder is reported, not created (as in the UI).
            if (-not (Test-Path -LiteralPath $resolvedSourcePath -PathType Container)) {
                Write-Log "Source" "Policy folder '$resolvedSourcePath' not found" "ERROR"
                $pathErrors = $true
            } else {
                $srcJsonCount = @(Get-ChildItem -Path $resolvedSourcePath -Filter '*.json' -ErrorAction SilentlyContinue).Count
                if ($srcJsonCount -eq 0) {
                    Write-Log "Source" "No policies found in folder '$resolvedSourcePath'" "ERROR"
                    $pathErrors = $true
                }
            }
        }
    }
    if ($targetOrigin -eq 'Offline') {
        if (-not $resolvedTargetPath) {
            $tgtLabel = if ($cfg.target -and $cfg.target.PSObject.Properties['displayName'] -and $cfg.target.displayName) { $cfg.target.displayName } else { $Target }
            Write-Log "Target" "No path configured for '$tgtLabel'. Set a policy folder in Config.json" "ERROR"
            $pathErrors = $true
        } else {
            if (-not (Test-Path -LiteralPath $resolvedTargetPath -PathType Container)) {
                Write-Log "Target" "Policy folder '$resolvedTargetPath' not found" "ERROR"
                $pathErrors = $true
            } else {
                $tgtJsonCount = @(Get-ChildItem -Path $resolvedTargetPath -Filter '*.json' -ErrorAction SilentlyContinue).Count
                if ($tgtJsonCount -eq 0) {
                    Write-Log "Target" "No policies found in folder '$resolvedTargetPath'" "ERROR"
                    $pathErrors = $true
                }
            }
        }
    }
    if ($pathErrors) { exit 1 }

    # Each side signs in right after its start lines, as in the UI: "Loading
    # policies from source ...", the filters, then "Authenticating ...". A
    # failed sign-in stops the run; New-GraphConnection already logged why
    # ("Could not authenticate with Microsoft Graph ..."), so no extra line.
    # A load that throws (e.g. policies that could not be fetched after all
    # retries) stops the run too: comparing with an incomplete set would
    # report the missing policies' settings as Missing.
    Write-LoadStartLog -Side "Source" -TenantLabel $sourceLabel -TenantId $Source -Origin $sourceOrigin -Filter $SourceFilter
    if ($needSource) {
        $sourceConnection = New-GraphConnection -Config $cfg.source -Label "Source"
        if (-not $sourceConnection) { exit 1 }
    }
    try {
        $sourceExpanded = @(Resolve-PolicySource `
            -Origin $sourceOrigin -Connection $sourceConnection -Filter $SourceFilter `
            -Label "Source" -GraphBeta $GraphBeta -ModulesPath $ModulesPath `
            -JsonPath $resolvedSourcePath -TenantLabel $sourceLabel -MaxThreads $MaxThreads `
            -Platforms $loadPlatforms -LogFile $_logFile)
    } catch {
        if (-not $_.Exception.Data['BasetuneLogged']) {
            Write-Log "Source" "Load failed. See Basetune.log for details" "ERROR"
            Write-Log "Source" "Details: $($_.Exception.Message)" "ERROR" -FileOnly
        }
        exit 1
    }

    # Online or offline: without source policies there is nothing to compare.
    # The load module already said why ("No policies match the selected filters").
    if ($sourceExpanded.Count -eq 0) { exit 1 }

    Write-LoadStartLog -Side "Target" -TenantLabel $targetLabel -TenantId $Target -Origin $targetOrigin -Filter $TargetFilter
    if ($needTarget) {
        $targetConnection = New-GraphConnection -Config $cfg.target -Label "Target"
        if (-not $targetConnection) { exit 1 }
    }
    $categoryConnection = if ($sourceConnection) { $sourceConnection } elseif ($targetConnection) { $targetConnection } else { $null }
    try {
        $targetExpanded = @(Resolve-PolicySource `
            -Origin $targetOrigin -Connection $targetConnection -Filter $TargetFilter `
            -Label "Target" -GraphBeta $GraphBeta -ModulesPath $ModulesPath `
            -JsonPath $resolvedTargetPath -TenantLabel $targetLabel -MaxThreads $MaxThreads `
            -Platforms $loadPlatforms -LogFile $_logFile)
    } catch {
        if (-not $_.Exception.Data['BasetuneLogged']) {
            Write-Log "Target" "Load failed. See Basetune.log for details" "ERROR"
            Write-Log "Target" "Details: $($_.Exception.Message)" "ERROR" -FileOnly
        }
        exit 1
    }

    # An empty target is allowed (e.g. a fresh tenant, or a filter that matches
    # nothing): every baseline setting is then reported as Missing. The compare
    # module logs that ("No target policies loaded. ..."). Offline folders
    # without JSON files were already rejected by the path checks above.

    # ==============================================
    # DEFINITIONS LOOKUP
    # ==============================================
    # Same loader as the UI compare (Get-CompareDefinitions, BasetuneDefinitions).
    # A missing file means "not downloaded yet" (raw ids in the output); a
    # corrupt file is reported.
    $compareDefs      = Get-CompareDefinitions -DefinitionsPath $definitionsPath
    $definitionLookup = $compareDefs.DefinitionLookup
    $categoryById     = $compareDefs.CategoryById

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
        Write-Log "Compare" "Could not create the report folder. See Basetune.log for details" "ERROR"
        Write-Log "Compare" "Details: '$runReportDir': $($_.Exception.Message)" "ERROR" -FileOnly
        exit 1
    }
    $runReportFile = Join-Path $runReportDir 'Report.html'

    # The HTML report opens in the same theme as the Basetune UI (Options.json theme,
    # default dark).
    $reportTheme = if ($options.Theme -eq 'light') { 'light' } else { 'dark' }

    try {
        $compareResult = Invoke-BaselineCompare `
            -SourcePolicies     $sourceExpanded `
            -TargetPolicies     $targetExpanded `
            -ExportPath         $runReportDir `
            -ReportFile         $runReportFile `
            -DefinitionLookup   $definitionLookup `
            -CategoryById       $categoryById `
            -CategoriesFilePath $categoriesFile `
            -Connection         $categoryConnection `
            -SourceLabel        $sourceLabel `
            -TargetLabel        $targetLabel `
            -ReportTheme        $reportTheme `
            -SuggestDownload    (-not (Test-DefinitionsRecent -DefinitionsPath $definitionsPath))
    } catch {
        Write-Log "Compare" "Compare failed. See Basetune.log for details" "ERROR"
        Write-Log "Compare" "Details: $($_.Exception.Message)" "ERROR" -FileOnly
        exit 1
    }
    if (-not $compareResult -or -not $compareResult.Success) { exit 1 }
}

# Run the CLI. A wrong or missing parameter gives a short message (not the
# internal "& $cli @args" line) and points to -Help.
try {
    & $cli @args
} catch [System.Management.Automation.ParameterBindingException] {
    # Only the binding of the CLI parameters themselves; anything else is rethrown.
    if ($_.InvocationInfo.Line -notmatch '& \$cli @args') { throw }
    Write-Host "BasetuneCLI.ps1: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Run .\BasetuneCLI.ps1 -Help to see the parameters"
    exit 1
}
