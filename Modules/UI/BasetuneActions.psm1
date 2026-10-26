# =============================================================================
# BasetuneActions.psm1
# The main window actions: Load, Compare, Export and Download (each runs in a
# runspace via BasetuneJobs.psm1), the definition preload at startup and the
# download tenant picker.
#
# Shares the controls ($UI) and the app state ($AppState) with the other UI
# modules through BasetuneState.psm1.
# =============================================================================

$script:UI       = (Get-BasetuneContext).UI
$script:AppState = (Get-BasetuneContext).State

# ── BasetunePolicyItem class (checkbox binding) ───────────────────────────────────────
# Add-Type C#, not a PowerShell `class`: PS class properties have no setter
# hook to raise INotifyPropertyChanged, so WPF would never see IsChecked
# changes made in code.
#
# Skipped when the type is already in the AppDomain (UI started again in the
# same host): recompiling adds startup time and a "type already exists"
# warning in some hosts.
#
# Policy holds the loaded policy object: Compare and Export take the ticked
# items' Policy directly, not matched on name (two policies can share a
# name). The distinct name keeps an older PolicyItem type without this
# property, still loaded in the same host, from being picked up.
if (-not ("BasetunePolicyItem" -as [type])) {
    Add-Type @"
using System.ComponentModel;
public class BasetunePolicyItem : INotifyPropertyChanged {
    private string _name;
    private bool   _isChecked = true;
    public object Policy { get; set; }
    public string PlatformLabel { get; set; }   // "Windows", "macOS", ...; empty without platform info
    public string TypeLabel { get; set; }       // "Settings Catalog", "Endpoint Security", ...
    public string Name {
        get { return _name; }
        set { _name = value; OnPropertyChanged("Name"); }
    }
    public bool IsChecked {
        get { return _isChecked; }
        set { _isChecked = value; OnPropertyChanged("IsChecked"); }
    }
    public event PropertyChangedEventHandler PropertyChanged;
    protected void OnPropertyChanged(string n) {
        if (PropertyChanged != null) PropertyChanged(this, new PropertyChangedEventArgs(n));
    }
}
"@
}

# Download button (Set-DownloadButtonStyle): orange when there are no
# definition or category files at all (downloaded or .default), otherwise the
# normal icon-bar look. Called at startup, after each download and compare,
# and after a cancel.
function Update-DownloadButton {
    $missing = -not (Get-DefinitionFile -DefinitionsPath $AppState.definitionsPath -Kind Definitions).Exists -or
               -not (Get-DefinitionFile -DefinitionsPath $AppState.definitionsPath -Kind Categories).Exists
    Set-DownloadButtonStyle $missing
}

# ═════════════════════════════════════════════════════════════════════════════
# UI HELPERS — shared by Load / Compare / Export / Download paths
# ═════════════════════════════════════════════════════════════════════════════

# Tenant entry (.Key/.Label/.Node) from $AppState.tenantList by Key, or $null.
function Get-TenantEntry {
    param($Id)
    if (-not $Id) { return $null }
    $AppState.tenantList | Where-Object { $_.Key -eq $Id } | Select-Object -First 1
}

# Display label for a tenant id (log messages, report headers). Falls back to
# the id, then to 'Basetune' when nothing is selected.
function Get-UITenantLabel {
    param($Id)
    $e = Get-TenantEntry $Id
    if ($e -and $e.Label) { return $e.Label }
    if ($Id) { return $Id }
    return 'Basetune'
}

# ═════════════════════════════════════════════════════════════════════════════
# LOAD POLICIES
# ═════════════════════════════════════════════════════════════════════════════
function Start-Load {
    param([string]$Side, [object]$Items)

    $cmb         = if ($Side -eq 'Source') { $UI.cmbSourceTenant } else { $UI.cmbTargetTenant }
    $selectedKey = $cmb.SelectedValue

    if (-not $selectedKey) {
        Clear-UILog "[INFO][$Side] No $($Side.ToLowerInvariant()) tenant selected. Add a tenant via Tenant Configuration first"
        Set-Busy $false
        return
    }
    $AppState.lastPickedTenantSide = $Side   # Tenant Configuration opens on the tenant loaded last

    $entry      = Get-TenantEntry $selectedKey
    $tenantNode = if ($entry) { $entry.Node } else { $null }
    $origin     = Get-TenantMode $tenantNode

    $filter = if ($Side -eq 'Source') { $UI.txtSourceFilter.Text.Trim() } else { $UI.txtTargetFilter.Text.Trim() }
    # Max threads from the saved setting, validated (1..32, default 8): 0 or
    # garbage would reach ForEach-Object -ThrottleLimit and abort the load.
    $maxT   = Get-ValidMaxThreads $AppState.savedMaxThreads

    $tenantJsonPath = if ($tenantNode -and $tenantNode.path -and $tenantNode.path.Trim()) {
        $tenantNode.path.Trim()
    } else { $null }

    $resolvedPath = if ($origin -eq 'Offline' -and -not $tenantJsonPath) {
        $label = Get-UITenantLabel $selectedKey
        Clear-UILog "[ERROR][$Side] No path configured for '$label'. Open Tenant Configuration and set a policy folder"
        Set-Busy $false
        return
    } else {
        $tenantJsonPath
    }

    if ($origin -eq 'Offline' -and -not (Test-Path $resolvedPath)) {
        try {
            New-Item -ItemType Directory -Path $resolvedPath -Force | Out-Null
            Write-UILog "[INFO][${Side}] Created folder: $resolvedPath"
        } catch {
            $err = $_
            Clear-UILog "[ERROR][$Side] Could not create folder: $resolvedPath. See the log file for details"
            Write-Log $Side "Details: $($err.Exception.Message)" 'ERROR' -FileOnly
            Set-Busy $false
            return
        }
    }

    # Clear the list right away (the name filter stays: it is the load
    # filter), so the select-all row and "x / y" of the previous load go.
    $Items.Clear()
    if ($Side -eq 'Source') { $UI.lstSource.ItemsSource = $Items } else { $UI.lstTarget.ItemsSource = $Items }
    # The card shows "Loading policies ..." until the load is done.
    $noMatch = if ($Side -eq 'Source') { $UI.lblSourceNoMatch } else { $UI.lblTargetNoMatch }
    if ($noMatch) { $noMatch.Text = Get-LoadingCardText $filter }
    Update-Counts
    Set-Busy $true -Side $Side
    $UI.btnCompare.IsEnabled = $false

    $tenantLabel = Get-UITenantLabel $selectedKey
    $originDesc  = if ($origin -eq 'Offline') { '(JSON)' } else { '(API)' }
    Clear-UILog "[INFO][$Side] Loading $($Side.ToLowerInvariant()) policies from $tenantLabel $originDesc..."
    Write-UILog "[INFO][$Side] Policy name filter: $(if ($filter) { "'$filter'" } else { 'None' })"
    Write-UILog "[INFO][$Side] Platform filter: $(Get-PlatformsText ([string[]]$AppState.savedPlatforms))"

    # Only the fields Load needs. TenantNode passes through SetVariable as a
    # real PSCustomObject (no JSON round-trip).
    $shared = @{
        Side        = $Side
        Origin      = $origin
        Filter      = $filter
        JsonPath    = $resolvedPath
        TenantNode  = $tenantNode
        TenantLabel = $tenantLabel
        MaxThreads  = $maxT
        Platforms   = [string[]]$AppState.savedPlatforms   # Options > Platforms
    }

    $work = {
        $S = $Shared
        Import-Module "$($S.ModulesPath)\BasetuneCore.psd1" -Force
        Set-RunspaceLogging -Queue $LogQueue -LogFile $S.LogFile

        # Every outcome ends with a status marker. OnDone trusts only that:
        # no marker (runspace died) or Success = $false means the load failed.
        try {
            $conn = $null
            if ($S.Origin -eq 'Online' -and $S.TenantNode) {
                $conn = New-GraphConnection -Config $S.TenantNode -Label $S.Side
                if (-not $conn) {
                    [PSCustomObject]@{ __type = 'status'; Success = $false; Reason = 'connection' }
                    return
                }
            }

            $policies = @(Resolve-PolicySource `
                -Origin      $S.Origin `
                -Connection  $conn `
                -Filter      $S.Filter `
                -Label       $S.Side `
                -GraphBeta   $S.GraphBeta `
                -ModulesPath $S.ModulesPath `
                -JsonPath    $S.JsonPath `
                -TenantLabel $S.TenantLabel `
                -MaxThreads  $S.MaxThreads `
                -Platforms   $S.Platforms `
                -LogQueue    $LogQueue `
                -LogFile     $S.LogFile)

            # Connection first, then the policies.
            [PSCustomObject]@{ __type = 'connection'; conn = $conn }
            $policies
            # PlatformSkipped: policies were found, but none for the selected
            # platforms (card text "No policies match the selected platforms").
            [PSCustomObject]@{ __type = 'status'; Success = $true; Reason = ''; PlatformSkipped = [bool](Test-LoadPlatformSkipped) }
        } catch {
            # Errors already reported in detail (expand failures) are not
            # repeated as "Load failed".
            if (-not $_.Exception.Data['BasetuneLogged']) {
                Write-Log $S.Side 'Load failed. See the log file for details' 'ERROR'
                Write-Log $S.Side "Details: $($_.Exception.Message)" 'ERROR' -FileOnly
            }
            [PSCustomObject]@{ __type = 'status'; Success = $false; Reason = 'error' }
        }
    }

    Start-Runspace -Work $work -Shared $shared -OnDone {
        # Take the job BEFORE Set-Busy $false clears $AppState.CurrentJob (that
        # only nulls the entry; the hashtable stays usable through $job).
        $job      = $AppState.CurrentJob
        Set-Busy $false

        # Remove "Loading policies ..." from the card: the list or one of the
        # messages below takes its place.
        $loadNm = if ($job.LoadSide -eq 'Source') { $UI.lblSourceNoMatch } else { $UI.lblTargetNoMatch }
        if ($loadNm -and $loadNm.Text -like 'Loading policies*') { $loadNm.Text = '' }

        $result   = @($job.Output)
        $connObj  = $result | Where-Object { $_.PSObject.Properties['__type'] -and $_.__type -eq 'connection' } | Select-Object -First 1
        $status   = $result | Where-Object { $_.PSObject.Properties['__type'] -and $_.__type -eq 'status' } | Select-Object -Last 1
        $policies = @($result | Where-Object { -not $_.PSObject.Properties['__type'] })
        $loadOk   = ($status -and $status.Success -and -not $job.Fatal)

        # A failed load leaves the side empty: never a partial list that could
        # be compared as if complete.
        if (-not $loadOk) { $policies = @() }

        if ($loadOk -and $connObj -and $connObj.conn) {
            if ($job.LoadSide -eq 'Source') { $AppState.sourceConnection = $connObj.conn }
            else                            { $AppState.targetConnection = $connObj.conn }
        }

        # Platform key -> label, looked up once per key: Get-PlatformLabel runs
        # a pipeline, too slow per policy with 1000+ policies.
        $platformLabels = @{}
        $multiPlatform  = @($AppState.savedPlatforms).Count -gt 1
        foreach ($p in ($policies | Sort-Object { $_.name })) {
            if (-not $p.name) { continue }
            $item           = [BasetunePolicyItem]::new()
            $item.Name      = $p.name
            $item.IsChecked = $true
            $item.Policy    = $p
            # Platform column (Windows, macOS, iOS, ...): only with more than one
            # platform selected in Options. Empty without platform info.
            # Guard: an older BasetunePolicyItem type without this property can
            # still be loaded when the UI is started twice in the same console.
            if ($item.PSObject.Properties['PlatformLabel']) {
                $pfKey  = Get-PlatformKey $p.Platforms
                $pfText = ''
                if ($pfKey -and $multiPlatform) {
                    $pfText = $platformLabels[$pfKey]
                    if ($null -eq $pfText) { $pfText = Get-PlatformLabel $pfKey; $platformLabels[$pfKey] = $pfText }
                }
                $item.PlatformLabel = $pfText
            }
            # Type column (always shown): Settings Catalog, Endpoint Security, ...
            if ($item.PSObject.Properties['TypeLabel']) {
                $tr = if ($p.PSObject.Properties['TemplateReference']) { $p.TemplateReference }
                      elseif ($p.PSObject.Properties['templateReference']) { $p.templateReference } else { $null }
                # JSON tenants: no type in the file = empty column (no Settings Catalog guess).
                $item.TypeLabel = if ($job.LoadOrigin -eq 'Offline') { Get-PolicyTypeLabel $tr -EmptyWhenMissing }
                                  else                               { Get-PolicyTypeLabel $tr }
            }
            $job.LoadItems.Add($item)
        }

        if ($job.LoadSide -eq 'Source') {
            $AppState.sourceExpanded        = $policies
            $UI.lstSource.ItemsSource = $AppState.sourceItems
        } else {
            $AppState.targetExpanded        = $policies
            $UI.lstTarget.ItemsSource = $AppState.targetItems
        }
        # Loaded sorted on name: headers Policy A-Z, Platform column if needed.
        Set-ListSort -Side $job.LoadSide -Reset

        # Load filter used: cleared after a load that found policies, so the
        # field now filters the loaded list. A failed or empty load keeps it
        # (retry or adjust).
        if ($loadOk -and $job.LoadItems.Count -gt 0) {
            if ($job.LoadSide -eq 'Source') { $UI.txtSourceFilter.Text = '' }
            else                            { $UI.txtTargetFilter.Text = '' }
        }
        Set-FilterMode -Side $job.LoadSide -Mode $(if ($loadOk -and $job.LoadItems.Count -gt 0) { 'Search' } else { 'Filter' })

        $UI.progressBar.IsIndeterminate = $false
        Update-Counts

        # "Loaded zero" vs "failed", from the status marker: Reason
        # 'connection' = no token (credentials, network), anything else = an
        # error already in the log.
        $sideLabel = $job.LoadSide
        $count     = $job.LoadItems.Count
        if ($loadOk -and $count -eq 0) {
            # Not an error. The load module already logs why ("No policies
            # match the filter 'x'" / "... in '<folder>'"); here only the
            # message in the empty card.
            $pfSkipped = ($status -and $status.PSObject.Properties['PlatformSkipped'] -and $status.PlatformSkipped)
            if ($pfSkipped) {
                # Policies found, but none for the platforms in Options: same text as the log.
                $noMatch = if ($sideLabel -eq 'Source') { $UI.lblSourceNoMatch } else { $UI.lblTargetNoMatch }
                if ($noMatch) { $noMatch.Text = Get-PlatformNoMatchText -Filter $job.LoadFilter }
                if ($job.LoadFilter) { $AppState.noMatchLoadFilter[$sideLabel] = $job.LoadFilter }
            } elseif ($job.LoadFilter) {
                $noMatch = if ($sideLabel -eq 'Source') { $UI.lblSourceNoMatch } else { $UI.lblTargetNoMatch }
                if ($noMatch) { $noMatch.Text = "No policies match the filter '$($job.LoadFilter)'" }
                # Remembered: Reset-Side clears it on a tenant switch if unchanged.
                $AppState.noMatchLoadFilter[$sideLabel] = $job.LoadFilter
            } else {
                # No filter: empty tenant/folder, or only other platforms than
                # selected in Options (the log line says which).
                $noMatch = if ($sideLabel -eq 'Source') { $UI.lblSourceNoMatch } else { $UI.lblTargetNoMatch }
                if ($noMatch) { $noMatch.Text = 'No policies found' }
            }
        } elseif ($loadOk) {
            # Success is already logged by the load module ("Loaded 24 policies with filter 'x'").
        } elseif ($status -and $status.Reason -eq 'connection') {
            Write-UILog "[ERROR][$sideLabel] Could not load policies. See the log file for details"
            $noMatch = if ($sideLabel -eq 'Source') { $UI.lblSourceNoMatch } else { $UI.lblTargetNoMatch }
            if ($noMatch) { $noMatch.Text = 'Could not load policies' }
        } else {
            # API and JSON tenants; the cause is in the log (e.g. unreadable files).
            Write-UILog "[ERROR][$sideLabel] Could not load policies. See the errors above"
            $noMatch = if ($sideLabel -eq 'Source') { $UI.lblSourceNoMatch } else { $UI.lblTargetNoMatch }
            if ($noMatch) { $noMatch.Text = 'Could not load policies' }
        }
    } -Context @{
        Type       = 'Load'
        Side       = $Side
        LoadSide   = $Side
        LoadItems  = $Items
        LoadOrigin = $origin   # 'Online' / 'Offline' — for OnDone failure detection
        LoadFilter = $filter   # shown in the "no policies found" message
    }
    # Search / sort stay usable on the other side, if loaded (Test-ListToolsAllowed).
    Enable-ListToolsDuringJob
}

# ═════════════════════════════════════════════════════════════════════════════
# COMPARE
# Works on $AppState.sourceExpanded / targetExpanded in memory: no new Graph
# calls, which is why it stays in the UI process.
# ═════════════════════════════════════════════════════════════════════════════

function Start-Compare {
    # After a few seconds a running compare turns this button into Cancel.
    if ($UI.btnCompare.Tag -eq 'cancel') {
        # No report: Run Report keeps the previous one; the run folder is
        # removed once the runspace stopped.
        $AppState.reportPath = $AppState.comparePrevReportPath
        Stop-ActiveRunspace -Side 'Compare' -RemoveDir $AppState.compareRunDir -RemoveDirIfEmpty $AppState.comparePairDir
        return
    }

    # The ticked items' own policy objects, not matched on name: two policies
    # can share a name.
    $srcFiltered = @($AppState.sourceItems | Where-Object { $_.IsChecked -and $_.Policy } | ForEach-Object { $_.Policy })
    $tgtFiltered = @($AppState.targetItems | Where-Object { $_.IsChecked -and $_.Policy } | ForEach-Object { $_.Policy })

    if ($srcFiltered.Count -eq 0 -or $tgtFiltered.Count -eq 0) {
        Clear-UILog "[WARN][Compare] Select at least one source and one target policy"
        return
    }
    # Selection of this compare: View Report / View Details only come on
    # afterwards when it is unchanged (it can change while the compare runs).
    $AppState.compareSelectionKey = Get-SelectionSnapshot
    $AppState.compareSelectionChangedLogged = $false
    $AppState.compareSelectionNotePending = $false

    Clear-UILog ''
    # Compare is disabled while it runs, so WPF drops the keyboard focus (the
    # next Tab would start at the top). Remembered, and put back on Run Report
    # (or Compare) when done.
    $AppState.compareHadFocus = [bool]$UI.btnCompare.IsKeyboardFocused
    Set-Busy $true
    $UI.btnCompare.IsEnabled    = $false
    # btnOpenReport disable / restore is handled centrally by Set-Busy

    # Report subfolder: Reports\SOURCE_TARGET\yyyyMMdd_HHmmss
    $runSrcLabel = Get-UITenantLabel $UI.cmbSourceTenant.SelectedValue
    $runTgtLabel = Get-UITenantLabel $UI.cmbTargetTenant.SelectedValue
    $safeRunSrc    = $runSrcLabel -replace '[\\/:*?"<>|\s]','_'
    $safeRunTgt    = $runTgtLabel -replace '[\\/:*?"<>|\s]','_'
    $runStamp      = Get-Date -Format 'yyyyMMdd_HHmmss'
    $runPairFolder = "${safeRunSrc}_${safeRunTgt}"
    # Join-Path: no double backslash when the report path is a drive root (C:\).
    $runReportDir  = Join-Path (Join-Path $AppState.reportBasePath $runPairFolder) $runStamp

    # Create the report folder up front, so a write failure shows before the
    # runspace starts, not as an Export-Csv error after a half-finished compare.
    try {
        New-Item -ItemType Directory -Path $runReportDir -Force -ErrorAction Stop | Out-Null
    } catch {
        $err = $_
        Clear-UILog "[ERROR][Compare] Could not create the report folder. See the log file for details"
        Write-Log 'Compare' "Details: '$runReportDir': $($err.Exception.Message)" 'ERROR' -FileOnly
        Set-Busy $false
        Update-Counts
        return
    }

    $runReportFile = Join-Path $runReportDir 'Report.html'
    # Previous report: Run Report goes back to it when this compare is cancelled or fails.
    $AppState.comparePrevReportPath = $AppState.reportPath
    $AppState.compareRunDir         = $runReportDir
    $AppState.comparePairDir        = Join-Path $AppState.reportBasePath $runPairFolder
    $AppState.reportPath = $runReportFile

    # In memory on the cached policies. The runspace gets the UI definition
    # cache (settings.json is parsed at most once per session), the report
    # paths and labels, and the Graph connections (to fetch unknown categories).
    $defCache = $AppState.Cache.Definitions
    $shared = @{
        reportDir         = $runReportDir
        reportFile        = $runReportFile
        reportSourceLabel = $runSrcLabel
        reportTargetLabel = $runTgtLabel
        reportTheme       = (Get-BasetuneTheme)
        cachedDefLookup   = $defCache.Lookup
        cachedCatById     = $defCache.CategoryById
        cachedHasDefs     = $defCache.HasDefs
        cachedHasCats     = $defCache.HasCats
        srcFiltered       = $srcFiltered
        tgtFiltered       = $tgtFiltered
        sourceConnection  = $AppState.sourceConnection
        targetConnection  = $AppState.targetConnection
    }

    $work = {
        $S = $Shared
        Import-Module "$($S.ModulesPath)\BasetuneCore.psd1" -Force
        Set-RunspaceLogging -Queue $LogQueue -LogFile $S.LogFile

        try {
            # Definitions + categories: the UI cache first (startup or a previous
            # compare), otherwise the files; same loader and log lines as the
            # CLI. Fetched categories are saved to categories.json.
            $_catsSave = Join-Path $S.defsPath 'categories.json'
            $_defs = Get-CompareDefinitions -DefinitionsPath $S.defsPath `
                         -CachedLookup       $(if ($S.cachedHasDefs) { $S.cachedDefLookup }) `
                         -CachedCategoryById $(if ($S.cachedHasCats) { $S.cachedCatById })
            $defLookup = $_defs.DefinitionLookup
            $catMap    = $_defs.CategoryById

            $conn = if ($S.sourceConnection) { $S.sourceConnection } elseif ($S.targetConnection) { $S.targetConnection } else { $null }

            # ── Same pipeline as the CLI ──
            $result = Invoke-BaselineCompare `
                -SourcePolicies     $S.srcFiltered `
                -TargetPolicies     $S.tgtFiltered `
                -ExportPath         $S.reportDir `
                -ReportFile         $S.reportFile `
                -DefinitionLookup   $defLookup `
                -CategoryById       $catMap `
                -CategoriesFilePath $_catsSave `
                -Connection         $conn `
                -SourceLabel        $S.reportSourceLabel `
                -TargetLabel        $S.reportTargetLabel `
                -ReportTheme        $S.reportTheme `
                -SuggestDownload    (-not (Test-DefinitionsRecent -DefinitionsPath $S.defsPath))
            # (compare.log is written by Invoke-BaselineCompare, next to the report.)

            # Cache back to the UI: the next compare does not re-parse settings.json.
            [PSCustomObject]@{
                __type    = 'cache'
                defLookup = $defLookup
                catMap    = $catMap
                hasDefs   = ($null -ne $defLookup -and $defLookup.Count -gt 0)
                hasCats   = ($null -ne $catMap -and $catMap.Count -gt 0)
            }
            # Logged: the compare module already wrote the error line (e.g.
            # "Could not write the comparison data"), OnDone adds nothing.
            # DownloadSuggested: settings without a definition and no recent
            # download -> tooltip hint on the Download button (OnDone).
            [PSCustomObject]@{ __type = 'status'; Success = [bool]$result.Success
                               Logged  = [bool]($result -and $result.PSObject.Properties['Logged'] -and $result.Logged)
                               DownloadSuggested = [bool]($result -and $result.PSObject.Properties['DownloadSuggested'] -and $result.DownloadSuggested) }
        } catch {
            Write-Log 'Compare' 'Compare failed. See the log file for details' 'ERROR'
            Write-Log 'Compare' "Details: $($_.Exception.Message)" 'ERROR' -FileOnly
            # Logged: OnDone does not add a second "Compare failed" line.
            [PSCustomObject]@{ __type = 'status'; Success = $false; Logged = $true }
        }
    }

    Start-Runspace -Work $work -Shared $shared -OnDone {
        # Take the job before Set-Busy nulls $AppState.CurrentJob.
        $job = $AppState.CurrentJob
        Set-Busy $false
        Update-Counts

        $out      = @($job.Output)
        $cacheOut = $out | Where-Object { $_.PSObject.Properties['__type'] -and $_.__type -eq 'cache' }  | Select-Object -First 1
        $status   = $out | Where-Object { $_.PSObject.Properties['__type'] -and $_.__type -eq 'status' } | Select-Object -Last 1

        # Take over the runspace's cache by reference: no disk reads on the UI thread.
        if ($cacheOut) {
            $defCache = $AppState.Cache.Definitions
            if ($cacheOut.hasDefs -and -not $defCache.HasDefs) {
                $defCache.Lookup  = $cacheOut.defLookup
                $defCache.HasDefs = $true
                # Not logged: the "Loaded N setting definitions from ..." line already says it.
            }
            if ($cacheOut.hasCats -and -not $defCache.HasCats) {
                $defCache.CategoryById = $cacheOut.catMap
                $defCache.HasCats      = $true
            }
        }

        # A selection change that is still waiting for its log line (no line came after it).
        if ($AppState.compareSelectionNotePending) {
            $AppState.compareSelectionNotePending = $false
            Write-UILog '[INFO][Compare] Policy selection changed. Disabling report and details buttons'
        }
        $ok = ($status -and $status.Success -and -not $job.Fatal)
        if ($ok) { Update-DownloadButton }
        $diffCsvPath = if ($AppState.reportPath) { Join-Path (Split-Path $AppState.reportPath -Parent) 'Diff.csv' } else { $null }
        if ($ok -and (Test-Path -LiteralPath $AppState.reportPath) -and $diffCsvPath -and (Test-Path -LiteralPath $diffCsvPath)) {
            # View Report / View Details only with both files on disk and the
            # selection of this compare unchanged.
            if (Test-SelectionSnapshot $AppState.compareSelectionKey) {
                $UI.btnOpenReport.IsEnabled = $true
                $AppState.reportSelectionKey      = $AppState.compareSelectionKey   # off again when the selection changes
            } else {
                $UI.btnOpenReport.IsEnabled = $false
                $AppState.reportSelectionKey      = $null
            }
            # Success is already logged by the report module ("[OK][Report] Created ...\Report.html ...").
        } elseif (-not $job.Fatal -and -not ($status -and $status.PSObject.Properties['Logged'] -and $status.Logged)) {
            # Not logged yet (a fatal error already says "Unexpected error").
            Write-UILog "[ERROR][Compare] Compare failed. See the errors above"
        }
        # No new report: Run Report (restored by Set-Busy) opens the previous one again.
        if (-not ($ok -and (Test-Path $AppState.reportPath))) { $AppState.reportPath = $AppState.comparePrevReportPath }
        # Keyboard focus back: Run Report after a successful compare, else Compare.
        if ($AppState.compareHadFocus) {
            $AppState.compareHadFocus = $false
            if ($UI.btnOpenReport.IsEnabled) { [void]$UI.btnOpenReport.Focus() }
            elseif ($UI.btnCompare.IsEnabled) { [void]$UI.btnCompare.Focus() }
        }
    } -Context @{ Type = 'Compare'; Side = '' }
    # Search / sort stay usable during the compare (Test-ListToolsAllowed).
    Enable-ListToolsDuringJob
    # Red Cancel after 5 seconds (see $AppState.compareCancelTimer).
    $AppState.compareCancelTimer.Stop()
    $AppState.compareCancelTimer.Start()
}

# ═════════════════════════════════════════════════════════════════════════════
# EXPORT / DOWNLOAD — runspace launchers (same runspace engine as Load and
# Compare)
# ═════════════════════════════════════════════════════════════════════════════

# ── Export ────────────────────────────────────────────────────────────────────
# Both Export buttons: folder picker, checks, then Export-CachedPoliciesToJson
# in a runspace on the loaded policies (no Graph calls). Only the ticked
# policies are written.
function Start-Export {
    param([Parameter(Mandatory)][ValidateSet('Source','Target')][string]$Side)

    $expanded = if ($Side -eq 'Source') { $AppState.sourceExpanded } else { $AppState.targetExpanded }
    $items    = if ($Side -eq 'Source') { $AppState.sourceItems    } else { $AppState.targetItems    }

    # The ticked policies themselves, not matched on name: two policies can
    # share a name.
    $selectedPolicies = @($items | Where-Object { $_.IsChecked -and $_.Policy } | ForEach-Object { $_.Policy })
    if ($selectedPolicies.Count -eq 0) {
        Clear-UILog "[ERROR][Export] No $Side policies selected. Check at least one policy to export"
        return
    }

    $key = if ($Side -eq 'Source') { $UI.cmbSourceTenant.SelectedValue } `
           else                    { $UI.cmbTargetTenant.SelectedValue }
    $exportLabel = Get-UITenantLabel $key

    # Folder picker FIRST, Set-Busy only after it: the button does not flicker
    # into Cancel mode when the picker is cancelled.
    $exportFolder = Show-FolderBrowser
    if (-not $exportFolder) { return }
    if ($exportFolder -match '^[A-Za-z]:\\?$') {
        Clear-UILog "[ERROR][Export] Cannot export to a drive root ($exportFolder). Choose a subfolder (e.g. C:\Export)"
        return
    }
    # JSON tenant: never into its own folder (files overwritten or duplicated).
    $entry = Get-TenantEntry $key
    if ($entry -and (Get-TenantMode $entry.Node) -eq 'Offline' -and $entry.Node.path) {
        $src = $entry.Node.path.Trim().TrimEnd('\')
        if ($src -and $exportFolder.TrimEnd('\') -ieq $src) {
            Clear-UILog "[ERROR][Export] Cannot export to the policy folder of $exportLabel itself ($exportFolder). Choose another folder"
            return
        }
    }

    Set-Busy $true -Side "${Side}Export"
    $UI.btnCompare.IsEnabled = $false
    Clear-UILog "[INFO][Export] Exporting $($selectedPolicies.Count) of $(@($expanded).Count) $exportLabel policies..."

    $shared = @{
        Policies      = $selectedPolicies
        SideLabel     = $Side
        OutputPath    = $exportFolder
    }

    $work = {
        $S = $Shared
        Import-Module "$($S.ModulesPath)\BasetuneCore.psd1" -Force
        Set-RunspaceLogging -Queue $LogQueue -LogFile $S.LogFile

        try {
            $r = Export-CachedPoliciesToJson `
                -Policies      $S.Policies `
                -OutputPath    $S.OutputPath
            [PSCustomObject]@{ Success = ($null -ne $r -and $r.Failed -eq 0) }
        } catch {
            Write-Log 'Export' 'Export failed. See the log file for details' 'ERROR'
            Write-Log 'Export' "Details: $($_.Exception.Message)" 'ERROR' -FileOnly
            [PSCustomObject]@{ Success = $false; Logged = $true }
        }
    }

    Start-Runspace -Work $work -Shared $shared -OnDone {
        $job = $AppState.CurrentJob
        Set-Busy $false
        Update-Counts
        $result = @($job.Output) | Select-Object -Last 1
        if ($result -and $result.Success -and -not $job.Fatal) {
            # Success is already logged by the export module ("[OK][Export] Export completed. ...").
        } elseif (-not $job.Fatal -and -not ($result -and $result.PSObject.Properties['Logged'] -and $result.Logged)) {
            # Some policies failed (each one is in the log above).
            Write-UILog "[ERROR][Export] Export failed"
        }
    } -Context @{ Type = 'Export'; Side = "${Side}Export" }
}

# ── Load definitions + categories at startup (background) ───────────────────
# Fills $AppState.Cache.Definitions right after the window opens, so the first
# compare and the Download dialog need not read the files. Own runspace,
# outside $AppState.CurrentJob: no buttons blocked. A compare started before
# it finishes reads the files itself; a download that finishes first wins
# (the cache is only filled while empty).
function Start-DefinitionPreload {
    $defs = Get-DefinitionFile -DefinitionsPath $AppState.definitionsPath -Kind Definitions
    $cats = Get-DefinitionFile -DefinitionsPath $AppState.definitionsPath -Kind Categories
    if (-not $defs.Exists -and -not $cats.Exists) { return }   # startup already warns

    # First line right away (UI thread); the runspace adds the result lines.
    # Only existing files are loaded; a missing one already has the startup
    # warning ("No category definitions found. ...").
    $what = if ($defs.Exists -and $cats.Exists) { 'setting and category definitions' }
            elseif ($defs.Exists)               { 'setting definitions' }
            else                                { 'category definitions' }
    Write-UILog "[INFO][Definitions] Loading $what..."

    # The dots of that line cycle (. .. ...) every 0.6 s (timer below) and end
    # as plain "...". Best effort: without the run nothing animates.
    $loadingRun = $null
    try {
        $lb = $UI.txtLog.Document.Blocks.LastBlock
        if ($lb -is [System.Windows.Documents.Paragraph] -and $lb.Inlines.FirstInline -is [System.Windows.Documents.Run]) {
            $loadingRun = $lb.Inlines.FirstInline
        }
    } catch {}
    $AppState.DefinitionPreloadAnim = @{ Run = $loadingRun; Base = "Loading $what"; Tick = 0 }

    # Progress bar while loading (no job, so not via Set-Busy); hidden again
    # when done, unless a job runs.
    if (-not $AppState.CurrentJob -and $UI.progressBar) {
        $UI.progressBar.Value           = 0
        $UI.progressBar.IsIndeterminate = $true
        $UI.progressBar.Visibility      = 'Visible'
    }

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $queue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $rs.SessionStateProxy.SetVariable('LogQueue', $queue)
    $rs.SessionStateProxy.SetVariable('Shared', @{
        ModulesPath = $AppState.ModulesPath
        LogFile     = $AppState.logFile
        DefsPath    = $defs.Path; DefsName = $defs.Name; DefsExists = $defs.Exists
        CatsPath    = $cats.Path; CatsName = $cats.Name; CatsExists = $cats.Exists
    })
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    $ps.AddScript({
        $S = $Shared
        Import-Module "$($S.ModulesPath)\BasetuneCore.psd1" -Force
        Set-RunspaceLogging -Queue $LogQueue -LogFile $S.LogFile

        $defLookup = $null
        if ($S.DefsExists) {
            try {
                $defLookup = Import-SettingDefinitions -Path $S.DefsPath
                Write-Log 'Definitions' "Cached $($defLookup.Count) setting definitions from $($S.DefsName)" 'OK'
            } catch {
                $defLookup = $null
                Write-Log 'Definitions' "Could not read setting definitions. Display names will not be resolved" 'WARN'
                Write-Log 'Definitions' "Details: $($_.Exception.Message)" 'WARN' -FileOnly
            }
        }
        $catMap = $null
        if ($S.CatsExists) {
            try {
                $catMap = Import-SettingCategories -Path $S.CatsPath
                Write-Log 'Categories' "Cached $($catMap.Count) category definitions from $($S.CatsName)" 'OK'
            } catch {
                $catMap = $null
                Write-Log 'Categories' "Could not read category definitions. Categories will not be resolved" 'WARN'
                Write-Log 'Categories' "Details: $($_.Exception.Message)" 'WARN' -FileOnly
            }
        }
        [PSCustomObject]@{ defLookup = $defLookup; catMap = $catMap }
    }) | Out-Null

    $AppState.DefinitionPreload = @{
        Runspace = $rs; PS = $ps; Handle = $ps.BeginInvoke(); Queue = $queue; Timer = $null
    }
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        $p = $AppState.DefinitionPreload
        if (-not $p) { return }
        $done = $p.Handle.IsCompleted
        $a = $AppState.DefinitionPreloadAnim
        if ($a -and $a.Run) {
            $a.Tick++
            $dots = if ($done) { 3 } else { ([int][math]::Floor($a.Tick / 3) % 3) + 1 }
            try { $a.Run.Text = $a.Base + ('.' * $dots) } catch {}
            if ($done) { $AppState.DefinitionPreloadAnim = $null }
        }
        $sb = [System.Text.StringBuilder]::new(); $item = $null
        while ($p.Queue.TryDequeue([ref]$item)) { [void]$sb.Append($item).Append("`n") }
        if ($sb.Length -gt 0) { Add-UILogLines $sb.ToString() }
        if (-not $done) { return }

        $p.Timer.Stop()
        $out = $null
        try { $out = @($p.PS.EndInvoke($p.Handle)) | Select-Object -Last 1 }
        catch { Write-Log 'Definitions' "Could not load definitions: $($_.Exception.Message)" 'WARN' -FileOnly }
        $defCache = $AppState.Cache.Definitions
        if ($out -and $out.defLookup -and $out.defLookup.Count -gt 0 -and -not $defCache.HasDefs) {
            $defCache.Lookup = $out.defLookup; $defCache.HasDefs = $true
        }
        if ($out -and $out.catMap -and $out.catMap.Count -gt 0 -and -not $defCache.HasCats) {
            $defCache.CategoryById = $out.catMap; $defCache.HasCats = $true
        }
        try { $p.PS.Dispose(); $p.Runspace.Dispose() } catch {}
        $AppState.DefinitionPreload = $null
        if (-not $AppState.CurrentJob -and $UI.progressBar) {
            $UI.progressBar.IsIndeterminate = $false
            $UI.progressBar.Value           = 0
            $UI.progressBar.Visibility      = 'Hidden'
        }
    })
    $AppState.DefinitionPreload.Timer = $timer
    $timer.Start()
}

# ── Download (definitions + categories) ──────────────────────────────────────

function Start-DefinitionDownload {
    # A click while running = cancel.
    if ($UI.btnOpenDownload.Tag -eq 'cancel') {
        Stop-ActiveRunspace -Side 'Download'
        return
    }

    $pickedKey = Show-TenantPickerDialog
    if (-not $pickedKey) { return }

    $entry = Get-TenantEntry $pickedKey
    if (-not $entry -or (Get-TenantMode $entry.Node) -ne 'Online') {
        Clear-UILog "[ERROR][Download] Download needs an API tenant (ClientSecret or Certificate)"
        return
    }

    # Icon-only before Set-Busy makes it a Cancel button: keeps the X centred
    # in a square 34x34 button.
    Set-DownloadButtonStyle $false

    Set-Busy $true -Side 'Download'
    $UI.btnCompare.IsEnabled    = $false
    # btnOpenReport disable / restore is handled centrally by Set-Busy
    Clear-UILog   # the download itself logs "Downloading setting and category definitions using tenant: ..."

    $shared = @{
        TenantNode      = $entry.Node
        DownloadLabel   = $entry.Label
        DefinitionsPath = $AppState.definitionsPath
    }

    $work = {
        $S = $Shared
        Import-Module "$($S.ModulesPath)\BasetuneCore.psd1" -Force
        Set-RunspaceLogging -Queue $LogQueue -LogFile $S.LogFile

        Write-Log 'Download' "Downloading setting and category definitions using tenant: $($S.DownloadLabel)..." 'INFO'
        $conn = New-GraphConnection -Config $S.TenantNode -Label 'Download'
        if (-not $conn) {
            Write-Log 'Download' "Could not connect to tenant '$($S.DownloadLabel)'. Check the credentials in Tenant Configuration. See the log file for details" 'ERROR'
            return [PSCustomObject]@{ Success = $false; Logged = $true }
        }

        try {
            $dl = Invoke-DefinitionDownload `
                -Connection      $conn `
                -DefinitionsPath $S.DefinitionsPath `
                -GraphBeta       $S.GraphBeta `
                -LogQueue        $LogQueue
            # Hand the freshly built lookups to the UI (see OnDone).
            [PSCustomObject]@{
                __type    = 'cache'
                defLookup = $dl.DefinitionLookup
                catMap    = $dl.CategoryById
            }
            [PSCustomObject]@{ Success = $true }
        } catch {
            Write-Log 'Download' 'Download failed. See the log file for details' 'ERROR'
            Write-Log 'Download' "Details: $($_.Exception.Message)" 'ERROR' -FileOnly
            [PSCustomObject]@{ Success = $false; Logged = $true }
        }
    }

    Start-Runspace -Work $work -Shared $shared -OnDone {
        # Take the job before Set-Busy $false clears CurrentJob.
        $job = $AppState.CurrentJob
        Set-Busy $false
        Update-Counts
        # Set-Busy restores Run Report to its state before the download: a
        # download must NOT enable an inactive Run Report.
        # The cache is only refreshed after a completed download, so a failed
        # one never looks like fresh data was loaded.
        $result   = @($job.Output) | Select-Object -Last 1
        $cacheOut = @($job.Output) | Where-Object { $_.PSObject.Properties['__type'] -and $_.__type -eq 'cache' } | Select-Object -First 1
        if ($result -and $result.Success -and -not $job.Fatal) {
            # Lookups built by the runspace: the 60+ MB file is not re-parsed
            # on the UI thread.
            $defCache = $AppState.Cache.Definitions
            if ($cacheOut -and $cacheOut.defLookup -and $cacheOut.defLookup.Count -gt 0) {
                $defCache.Lookup  = $cacheOut.defLookup
                $defCache.HasDefs = $true
            }
            if ($cacheOut -and $cacheOut.catMap -and $cacheOut.catMap.Count -gt 0) {
                $defCache.CategoryById = $cacheOut.catMap
                $defCache.HasCats      = $true
            }
            # Success is already logged by the load module ("[OK][Download] Download complete.").
        } elseif (-not $job.Fatal -and -not ($result -and $result.PSObject.Properties['Logged'] -and $result.Logged)) {
            Write-UILog "[ERROR][Download] Download failed"
        }
        # Icon-only when both files are on disk now, the label after a failure.
        Update-DownloadButton
    } -Context @{ Type = 'Download'; Side = 'Download' }
    # Search / sort stay usable during the download (Test-ListToolsAllowed).
    Enable-ListToolsDuringJob
}

# ═════════════════════════════════════════════════════════════════════════════
# INITIALISATION
# Wires the Load / Compare / Export / Download / View Report buttons.
# Called once from BasetuneUI.ps1.
# ═════════════════════════════════════════════════════════════════════════════
function Initialize-BasetuneActions {
    $UI.btnSourceLoad.Add_Click({
        if ($UI.btnSourceLoad.Tag -eq 'cancel') {
            Stop-ActiveRunspace -Side 'Source'
        } else {
            Start-Load -Side 'Source' -Items $AppState.sourceItems
        }
    })
    $UI.btnTargetLoad.Add_Click({
        if ($UI.btnTargetLoad.Tag -eq 'cancel') {
            Stop-ActiveRunspace -Side 'Target'
        } else {
            Start-Load -Side 'Target' -Items $AppState.targetItems
        }
    })

    $UI.btnCompare.Add_Click({ Start-Compare })

    $UI.btnSourceExport.Add_Click({
        if ($UI.btnSourceExport.Tag -eq 'cancel') {
            Stop-ActiveRunspace -Side 'Source Export'
        } else {
            Start-Export -Side 'Source'
        }
    })
    $UI.btnTargetExport.Add_Click({
        if ($UI.btnTargetExport.Tag -eq 'cancel') {
            Stop-ActiveRunspace -Side 'Target Export'
        } else {
            Start-Export -Side 'Target'
        }
    })

    $AppState.DefinitionPreload = $null

    $UI.btnOpenDownload.Add_Click({ Start-DefinitionDownload })

    $UI.btnOpenReport.Add_Click({ if (Test-Path $AppState.reportPath) { Start-Process $AppState.reportPath } })
    # View Details: Diff.csv next to Report.html, in the default .csv app.
    if ($UI.btnViewDetails) {
        $UI.btnViewDetails.Add_Click({
            $diffCsv = if ($AppState.reportPath) { Join-Path (Split-Path $AppState.reportPath -Parent) 'Diff.csv' } else { $null }
            if ($diffCsv -and (Test-Path -LiteralPath $diffCsv)) {
                try { Start-Process $diffCsv -ErrorAction Stop } catch {
                    Write-Log 'Report' 'Could not open Diff.csv. See the log file for details' 'ERROR'
                    Write-Log 'Report' "Details: $($_.Exception.Message)" 'ERROR' -FileOnly
                }
            } else {
                Write-Log 'Report' 'Diff.csv not found. Run the compare again' 'WARN'
            }
        })
    }
}

Export-ModuleMember -Function @(
    'Update-DownloadButton',
    'Get-TenantEntry',
    'Get-UITenantLabel',
    'Start-Load',
    'Start-Compare',
    'Start-Export',
    'Start-DefinitionPreload',
    'Start-DefinitionDownload',
    'Initialize-BasetuneActions'
)
