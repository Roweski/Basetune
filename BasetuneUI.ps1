#Requires -Version 7.0

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# ── Startup errors ───────────────────────────────────────────────────────────
# The console is hidden (Start-BasetuneUI.cmd): an error before the window
# shows would end the app silently. Show a message box, log it if logging is
# set up, and stop.
function Show-StartupError {
    param([string]$Message, [string]$Detail)
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        try {
            Write-Log 'Startup' $Message 'ERROR'
            if ($Detail) { Write-Log 'Startup' "Details: $Detail" 'ERROR' -FileOnly }
        } catch {}
    }
    $text = "Basetune could not start.`n`n$Message" + $(if ($Detail) { "`n`n$Detail" } else { '' })
    try { [System.Windows.MessageBox]::Show($text, 'Basetune', 'OK', 'Error') | Out-Null } catch { Write-Host $text -ForegroundColor Red }
    exit 1
}

# ── Resolve script root ───────────────────────────────────────────────────────
$ScriptRoot = if ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} elseif ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName -notlike '*pwsh*' -and
          [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName -notlike '*powershell*') {
    Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
} else {
    $PSScriptRoot
}

# ── Load modules ──────────────────────────────────────────────────────────────
# The engine (BasetuneCore.psd1, also used by the CLI and runspaces), then the
# UI modules, BasetuneState first: each UI module grabs the context on import.
#   BasetuneState          shared context: controls ($UI) and app state ($AppState)
#   BasetuneWpf            XAML loading, theme, dialog chrome, folder picker, scrolling
#   BasetuneLogView        the log view (Write-UILog, Add-UILogLines)
#   BasetuneButtons        busy state (Set-Busy) and the main window buttons
#   BasetuneSettings       Config.json / Options.json, tenant dropdowns
#   BasetuneWindow         title bar, window size / position, log collapse
#   BasetuneJobs           runspace engine (Start-Runspace / Stop-ActiveRunspace)
#   BasetuneActions        Load, Compare, Export, Download, definition preload
#   BasetunePolicyLists    policy lists, counts, filter / sort, tenant dropdown events
#   BasetuneConfigWindow   Tenant Configuration window and tenant form
#   BasetuneOptionsWindow  Options window
#   BasetuneDownloadWindow Download definitions window (tenant picker)
$uiModules = @(
    'Core\BasetuneCore.psd1',
    'UI\BasetuneState.psm1', 'UI\BasetuneWpf.psm1', 'UI\BasetuneLogView.psm1', 'UI\BasetuneButtons.psm1',
    'UI\BasetuneSettings.psm1', 'UI\BasetuneWindow.psm1', 'UI\BasetuneJobs.psm1', 'UI\BasetuneActions.psm1',
    'UI\BasetunePolicyLists.psm1', 'UI\BasetuneConfigWindow.psm1', 'UI\BasetuneOptionsWindow.psm1',
    'UI\BasetuneDownloadWindow.psm1'
)
foreach ($m in $uiModules) {
    try {
        Import-Module "$ScriptRoot\Modules\$m" -Force -DisableNameChecking -ErrorAction Stop
    } catch {
        Show-StartupError "Could not load module '$m'. Check that the Modules folder is complete" "$($_.Exception.Message)"
    }
}

# ── UI registry ──────────────────────────────────────────────────────────────
# Every control by its x:Name, plus the main window as $UI.Window. Same
# hashtable as $script:UI in the UI modules (see BasetuneState.psm1).
$UI = (Get-BasetuneContext).UI

# ── App state ────────────────────────────────────────────────────────────────
# Paths, config, tenants, the current job, selection and form state. Shared
# with the modules the same way as $UI.
$AppState = (Get-BasetuneContext).State

# ── Global paths ─────────────────────────────────────────────────────────────
$AppState.ScriptRoot         = $ScriptRoot
$AppState.GraphBeta          = 'https://graph.microsoft.com/beta'
$AppState.ModulesPath        = "$ScriptRoot\Modules\Core"   # engine modules, for the runspaces
$AppState.XamlPath           = "$ScriptRoot\Modules\UI\Xaml" # windows and the shared theme
$AppState.definitionsPath    = "$ScriptRoot\Definitions"
$AppState.reportBasePath     = "$ScriptRoot\Reports"
# Fixed default (Basetune\Reports) for an emptied Report path in Options;
# reportBasePath itself is overwritten from the config.
$AppState.defaultReportPath  = $AppState.reportBasePath
$AppState.reportPath         = $null

# Required folders: the Basetune folder must be writable, else stop with a
# clear message.
foreach ($d in @($AppState.definitionsPath, $AppState.reportBasePath, "$ScriptRoot\Logs")) {
    try {
        New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null
    } catch {
        Show-StartupError "Could not create the folder '$d'. Check that the Basetune folder is writable" "$($_.Exception.Message)"
    }
}

# ── Initialise log file ─────────────────────────────────────────────────────
# Set early, so every Write-Log from here on goes to disk. Kept in
# $AppState.logFile: runspaces start with $script:LogFile = $null and get the
# path via $Shared (Set-RunspaceLogging). One log for UI and CLI; the CMTrace
# Source field shows which one wrote a line.
$AppState.logFile = "$ScriptRoot\Logs\Basetune.log"
try { Set-LogFile -Path $AppState.logFile -Rotate -Source 'UI' } catch {}   # -Rotate: > 5 MB becomes Basetune_<date>_<time>.log (5 kept)
# First line of every start in the log file: which version wrote what follows.
Write-Log 'Startup' "Basetune $(Get-BasetuneVersion) started (UI)" 'INFO' -FileOnly

# ── Pre-UI state ─────────────────────────────────────────────────────────────
# $AppState.cfg is set by Import-Config (BasetuneSettings.psm1) once the
# window and the Write-Log callback exist: Get-BasetuneConfig before that would
# send its plaintext->DPAPI migration warning to the console, not the log view.
$AppState.cfg = $null
$AppState.tenantList       = @()
$AppState.sourceExpanded   = $null
$AppState.targetExpanded   = $null
$AppState.sourceConnection = $null
$AppState.targetConnection = $null

# ── Definition cache ─────────────────────────────────────────────────────────
# In-memory lookup of Settings Catalog definitions + categories. Filled by the
# Download and Compare runspaces, read by the Compare runspace via $Shared.
$AppState.Cache = @{
    Definitions = @{
        Lookup       = $null
        CategoryById = $null
        HasDefs      = $false
        HasCats      = $false
    }
}

# ── Single job context ───────────────────────────────────────────────────────
# ONE background operation at a time (Load, Compare, Export or Download);
# Set-Busy disables the competing buttons. $AppState.CurrentJob: $null = idle,
# object = a job in flight.
#
# Lifecycle:
#   Set-Busy $true   → creates a stub { Side; IsBusy=$true }
#   Start-Runspace   → upgrades stub with runspace plumbing + caller Context
#   Tick (on done)   → fills .Output, runs OnDone, then nulls CurrentJob
#   Set-Busy $false  → nulls CurrentJob (called from OnDone or early-fail paths)
#   Stop-ActiveRunspace → disposes runspace, then Set-Busy $false nulls it
#
# Update-Counts (BasetunePolicyLists) and Update-ExportButtons (BasetuneButtons)
# check it to keep buttons disabled while a job runs.
#
# Shape when active:
#   @{
#     Type       = 'Load' | 'Compare' | 'Export' | 'Download'
#     Side       = 'Source' | 'Target' | 'Download' | 'SourceExport' | ...
#     IsBusy     = $true
#     Runspace   = <Runspace>
#     PS         = <PowerShell>
#     Handle     = <IAsyncResult>
#     Queue      = <ConcurrentQueue[string]>
#     OnDone     = <scriptblock>
#     Done       = $false
#     Timer      = <DispatcherTimer>
#     Output     = @()             # filled by Tick handler when Handle completes
#     LoadItems  = $items          # Load only — items collection to populate
#     LoadOrigin = 'Online'/'Offline'  # Load only — for online-failure detection
#   }
$AppState.CurrentJob = $null

# Run Report enabled state before busy, restored by Set-Busy on busy-exit.
# Compare's OnDone overrides it when a fresh report is produced.
$AppState.btnOpenReportPriorState = $null

# ── Build window from XAML file ───────────────────────────────────────────────
try {
    $UI.Window = Import-Xaml -Path "$($AppState.XamlPath)\BasetuneUI.xaml" -Width 1400 -Height 1000
} catch {
    Show-StartupError "Could not load the main window (Modules\UI\Xaml folder)" "$($_.Exception.Message)"
}
# Window title with the version; the own title bar shows it (Binding Title).
$UI.Window.Title = "Basetune $(Get-BasetuneVersion)"

# ── Find controls ─────────────────────────────────────────────────────────────
Register-BasetuneControls -Root $UI.Window -Names @(
    # Own title bar (WindowChrome)
    'rootBorder', 'imgTitleIcon', 'btnCaptionMin', 'btnCaptionMax', 'btnCaptionClose',
    # Source / target panes
    'cmbSourceTenant', 'cmbTargetTenant',
    'txtSourceFilter', 'txtTargetFilter', 'txtSourceFilterHint', 'txtTargetFilterHint',
    'txtSourceTenantHint', 'txtTargetTenantHint',
    'btnClearSourceFilter', 'btnClearTargetFilter',
    'btnSourceLoad', 'btnTargetLoad', 'lstSource', 'lstTarget',
    'lblSourceCountOn', 'lblSourceCountSlash', 'lblSourceCountOf', 'lblTargetCountOn', 'lblTargetCountSlash', 'lblTargetCountOf',
    'icoSourceFilter', 'icoTargetFilter', 'lblSourceNoMatch', 'lblTargetNoMatch',
    'chkSourceAll', 'chkTargetAll', 'pnlSourceSelect', 'pnlTargetSelect',
    'btnSourceSortName', 'btnSourceSortPlatform', 'btnSourceSortType',
    'btnTargetSortName', 'btnTargetSortPlatform', 'btnTargetSortType',
    'btnSourceExport', 'btnTargetExport',
    # Toolbar, progress and log
    'btnCompare', 'btnOpenDownload', 'btnOpenReport', 'btnViewDetails',
    'btnOpenConfig', 'btnOpenOptions', 'progressBar', 'txtLog',
    'btnToggleLog', 'pathToggleLog'
)

# ── Window chrome and log view (BasetuneWindow.psm1) ────────────────────────
Initialize-BasetuneWindow

# Write-Log on the UI thread goes straight into txtLog (runspaces set their own
# callback into their LogQueue, drained by the timer Tick). Without it,
# Get-BasetuneConfig's migration warnings would go to the console via Write-Host.
Set-LogCallback {
    param($msg)
    Add-UILogLines $msg
}

# ── Job engine timers (BasetuneJobs.psm1) ───────────────────────────────────
Initialize-BasetuneJobs

# ── Observable collections ────────────────────────────────────────────────────
$AppState.sourceItems = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
# Load filter per side that last gave "No policies match the filter" (see Reset-Side).
$AppState.noMatchLoadFilter = @{ Source = $null; Target = $null }
$AppState.targetItems = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
# Sort per list (column headers Policy / Platform), see Set-ListSort.
$AppState.listSort = @{ Source = @{ Key = 'Name'; Desc = $false }; Target = @{ Key = 'Name'; Desc = $false } }
$UI.lstSource.ItemsSource = $AppState.sourceItems
$UI.lstTarget.ItemsSource = $AppState.targetItems
# True while Set-VisibleSelection (un)ticks a whole list: row Checked /
# Unchecked events skip Update-Counts, which runs once afterwards.
$AppState.bulkSelecting = $false
# True while an Update-Counts for row Checked / Unchecked events is queued
# (Initialize-PolicyListEvents): the events in between add nothing.
$AppState.countsQueued = $false

# ── Tenant store + editing state ─────────────────────────────────────────────
$AppState.tenantStore      = [System.Collections.Specialized.OrderedDictionary]::new()
$AppState.editingTenantKey = $null
$AppState.suppressEvents   = $false
$AppState.lastSourceTenantKey = $null
$AppState.lastTargetTenantKey = $null

# ── SelectedValue helper (Tag-based) ─────────────────────────────────────────
foreach ($cmb in @($UI.cmbSourceTenant, $UI.cmbTargetTenant)) {
    Add-Member -InputObject $cmb -MemberType ScriptProperty -Name 'SelectedValue' -Value {
        if ($this.SelectedItem) { $this.SelectedItem.Tag } else { $null }
    } -Force
}

# ── Event wiring (BasetuneActions / PolicyLists / ConfigWindow / OptionsWindow)
Initialize-BasetuneActions
Initialize-PolicyListEvents
Initialize-ConfigWindowEvents
Initialize-OptionsWindowEvents

# ═════════════════════════════════════════════════════════════════════════════
# STARTUP
# ═════════════════════════════════════════════════════════════════════════════
$AppState.savedMaxThreads = '8'
$AppState.savedPlatforms  = Get-DefaultPlatforms   # defaults; Import-Options reads Options.json
$AppState.savedTheme      = 'dark'
$AppState.savedPathReport = $AppState.reportBasePath

# Config first: an upgrade from v2 logs "Settings moved from Config.json to
# Options.json ..." before Options.json is created. Neither reads the other's
# file; old settings in Config.json are removed, not carried over.
Import-Config    # Config.json: tenants
Import-Options   # Options.json: report path, platforms, theme, max threads
Set-BasetuneTheme $AppState.savedTheme
Set-LoadButtonMode $UI.btnSourceLoad 'load'
Set-LoadButtonMode $UI.btnTargetLoad 'load'
$AppState.suppressEvents = $true
Sync-MainTenantDropdowns
$AppState.suppressEvents = $false
$AppState.lastSourceTenantKey = if ($UI.cmbSourceTenant.SelectedItem) { $UI.cmbSourceTenant.SelectedItem.Tag } else { $null }
$AppState.lastTargetTenantKey = if ($UI.cmbTargetTenant.SelectedItem) { $UI.cmbTargetTenant.SelectedItem.Tag } else { $null }
Update-ExportButtons
# Empty cards: "Ready to load policies" when a tenant is selected.
Update-EmptyState 'Source'; Update-EmptyState 'Target'

$UI.Window.Add_Loaded({
    # No tenants (first start, or emptied): one line, before the definitions
    # lines. Not when Config.json is invalid or unreadable (the error line says
    # why). Creating Config.json / Options.json is in the log file only.
    if (@($AppState.tenantStore.Keys).Count -eq 0 -and -not $AppState.configReadFailed) {
        Write-UILog '[INFO][Config] Click the gear icon to configure a tenant and get started'
    }

    # Downloaded or shipped (.default) files both count.
    $missingDefs = -not (Get-DefinitionFile -DefinitionsPath $AppState.definitionsPath -Kind Definitions).Exists
    $missingCats = -not (Get-DefinitionFile -DefinitionsPath $AppState.definitionsPath -Kind Categories).Exists

    $msg = if ($missingDefs -and $missingCats) {
        '[WARN][Definitions] No setting and category definitions found. Download definitions to resolve display names'
    } elseif ($missingDefs) {
        '[WARN][Definitions] No setting definitions found. Download definitions to resolve display names'
    } elseif ($missingCats) {
        '[WARN][Definitions] No category definitions found. Download definitions to resolve categories'
    } else { $null }

    if ($msg) {
        # Appended, not Clear-UILog: startup lines (e.g. Get-BasetuneConfig's
        # WARN/ERROR for a plaintext or undecryptable secret) must stay.
        # Write-UILog also writes it to Basetune.log.
        Write-UILog $msg
    }

    # Show "Download Definitions" label if either file is missing.
    Update-DownloadButton

    # Definitions + categories into the cache, in the background.
    try { Start-DefinitionPreload } catch {
        Write-Log 'Definitions' "Could not start loading definitions: $($_.Exception.Message)" 'WARN' -FileOnly
    }
})

# ── Bring window to the foreground on startup ────────────────────────────────
# Started from a console (e.g. Start-BasetuneUI), the window can open BEHIND
# it. Topmost before ShowDialog raises it; dropped after 500 ms so it then
# behaves like a normal window.
$UI.Window.Topmost = $true
$AppState.topmostTimer = New-Object System.Windows.Threading.DispatcherTimer
$AppState.topmostTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$AppState.topmostTimer.Add_Tick({
    $UI.Window.Topmost = $false
    $AppState.topmostTimer.Stop()
})
$AppState.topmostTimer.Start()

$UI.Window.ShowDialog() | Out-Null
