# Requires PowerShell 7

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

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
Import-Module "$ScriptRoot\Modules\IntuneGraphModules.psd1"  -Force -DisableNameChecking
Import-Module "$ScriptRoot\Modules\BasetuneConfig.psm1"      -Force -DisableNameChecking
Import-Module "$ScriptRoot\Modules\BasetuneUI.psm1"   -Force -DisableNameChecking

# ── Global paths ─────────────────────────────────────────────────────────────
$global:ScriptRoot         = $ScriptRoot
$global:GraphBeta          = 'https://graph.microsoft.com/beta'
$global:ModulesPath        = "$ScriptRoot\Modules"
$global:definitionsPath    = "$ScriptRoot\Definitions"
$global:reportBasePath     = "$ScriptRoot\Reports"
# Fixed default (Basetune\Reports). $global:reportBasePath is overwritten by
# the path from Config.json, so an emptied Report path in Options must not
# fall back to that.
$global:defaultReportPath  = $global:reportBasePath
function Get-DefaultPathReport { return $global:defaultReportPath }
$global:reportPath         = $null

# Show "Download Definitions" label on the button when either setting file
# is missing on disk; collapse to icon-only when both are present. Called at
# startup, after each download, and after a cancel.
function Update-DownloadButton {
    $defsFile = "$($global:definitionsPath)\settingDefinitions.json"
    $catsFile = "$($global:definitionsPath)\settingCategories.json"
    $missing  = -not (Test-Path $defsFile) -or -not (Test-Path $catsFile)
    Set-DownloadButtonLabel $missing
}

foreach ($d in @($global:definitionsPath, $global:reportBasePath)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}

# ── Initialise log file ─────────────────────────────────────────────────────
# Set-LogFile runs HERE (early, right after the global path setup) so that any
# Write-Log call from this point on goes to disk. Stored as $global:logFile
# because runspaces have their own module-scope $script:LogFile = $null on
# import and need the path injected via $Shared to call Set-LogFile themselves.
$global:logFile = "$ScriptRoot\Logs\BasetuneUI.log"
New-Item -ItemType Directory -Path (Split-Path $global:logFile -Parent) -Force | Out-Null
try { Set-LogFile -Path $global:logFile } catch {}

# ── Pre-UI globals ───────────────────────────────────────────────────────────
# $global:cfg is set later by Load-ConfigUI (BasetuneConfig.psm1) after the
# window is built and the Write-Log callback is wired. We don't bootstrap it
# here — calling Get-GraphConfig pre-UI used to trigger the plaintext->DPAPI
# migration log against Write-Host (no callback yet), so the warning ended up
# in the parent CMD window instead of the in-app log.
$global:cfg = $null
$global:tenantList       = @()
$global:sourceExpanded   = $null
$global:targetExpanded   = $null
$global:sourceConnection = $null
$global:targetConnection = $null

# ── Definition cache (single concept, grouped) ───────────────────────────────
# Holds the in-memory lookup of Settings Catalog definitions + categories.
# Replaces the previous flat globals (cachedDefLookup, cachedCatById,
# cachedHasDefs, cachedHasCats) — four variables for one concept.
# Populated by Update-DefinitionCache (BasetuneUI.psm1) on first compare/
# download; consumed by the Compare runspace via $Shared.
$global:Cache = @{
    Definitions = @{
        Lookup       = $null   # was $global:cachedDefLookup
        CategoryById = $null   # was $global:cachedCatById
        HasDefs      = $false  # was $global:cachedHasDefs
        HasCats      = $false  # was $global:cachedHasCats
    }
}

# ── Single job context ───────────────────────────────────────────────────────
# Basetune only ever runs ONE background operation at a time (Load, Compare,
# Export, or Download) — that's the architectural rule, enforced by the UI
# disabling competing buttons via Set-Busy.
#
# $global:CurrentJob makes that rule explicit:
#   $null  → idle (nothing running)
#   object → busy (a job is in flight)
#
# Lifecycle:
#   Set-Busy $true   → creates a stub { Side; IsBusy=$true }
#   Start-Runspace   → upgrades stub with runspace plumbing + caller Context
#   Tick (on done)   → fills .Output, runs OnDone, then nulls CurrentJob
#   Set-Busy $false  → nulls CurrentJob (called from OnDone or early-fail paths)
#   Stop-ActiveRunspace → disposes runspace, then Set-Busy $false nulls it
#
# Cross-module: BasetuneUI.psm1's Update-Counts and Update-ExportButtons read
# `if ($global:CurrentJob)` to gate UI re-enable while a job is in flight.
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
$global:CurrentJob = $null

# Run Report enabled-state snapshot, written by Set-Busy on busy-enter and
# read by Set-Busy on busy-exit so the button restores to its pre-busy state.
# Compare's OnDone overrides afterwards when a fresh report is produced.
$global:btnOpenReportPriorState = $null

# ── Build window from XAML file ───────────────────────────────────────────────
$global:window = Load-Xaml -Path "$ScriptRoot\UI\BasetuneUI.xaml" -Width 1400 -Height 1000 -ExitOnError

# ── Find controls ─────────────────────────────────────────────────────────────
function Find { param([string]$n) Find-InTree -Root $global:window -Name $n }

$global:cmbSourceTenant      = Find 'cmbSourceTenant'
$global:cmbTargetTenant      = Find 'cmbTargetTenant'
$global:txtSourceFilter      = Find 'txtSourceFilter'
$global:txtTargetFilter      = Find 'txtTargetFilter'
$global:txtSourceFilterHint  = Find 'txtSourceFilterHint'
$global:txtTargetFilterHint  = Find 'txtTargetFilterHint'
$global:btnClearSourceFilter = Find 'btnClearSourceFilter'
$global:btnClearTargetFilter = Find 'btnClearTargetFilter'
$global:btnClearSourceSearch = Find 'btnClearSourceSearch'
$global:btnClearTargetSearch = Find 'btnClearTargetSearch' 
$global:btnSourceLoad        = Find 'btnSourceLoad'
$global:btnTargetLoad        = Find 'btnTargetLoad'
$global:lstSource            = Find 'lstSource'
$global:lstTarget            = Find 'lstTarget'
$global:lblSourceCount       = Find 'lblSourceCount'
$global:lblTargetCount       = Find 'lblTargetCount'
$global:btnSourceAll         = Find 'btnSourceAll'
$global:btnSourceNone        = Find 'btnSourceNone'
$global:btnTargetAll         = Find 'btnTargetAll'
$global:btnTargetNone        = Find 'btnTargetNone'
$global:btnCompare           = Find 'btnCompare'
$global:btnSourceExport      = Find 'btnSourceExport'
$global:btnTargetExport      = Find 'btnTargetExport'
$global:btnOpenDownload      = Find 'btnOpenDownload'
$global:btnOpenReport        = Find 'btnOpenReport'
$global:btnOpenConfig        = Find 'btnOpenConfig'
$global:btnOpenOptions       = Find 'btnOpenOptions'
$global:progressBar          = Find 'progressBar'
$global:txtLog               = Find 'txtLog'

# Disable undo on the log TextBox. WPF TextBox keeps an undo stack of every
# AppendText() — for a log that streams thousands of lines per compare, this
# silently eats 50-200 MB of UI process memory that the trim-to-10k-lines logic
# can't touch. Logs are append-only output, not editable text, so undo has no
# value here. Must be set BEFORE any text is appended.
$global:txtLog.IsUndoEnabled = $false

# Tell .NET to compact the Large Object Heap when GC.Collect() runs. JSON
# parsing of settingDefinitions.json produces strings >85KB which land on the
# LOH — and the LOH is never compacted by default, only swept. After several
# compares the LOH fragments and the working set climbs even though the live
# object graph is small. One-time setting; honoured by every subsequent
# [GC]::Collect() call in Start-Runspace.
try {
    [System.Runtime.GCSettings]::LargeObjectHeapCompactionMode = `
        [System.Runtime.GCLargeObjectHeapCompactionMode]::CompactOnce
} catch {}

# Limit scroll speed on the log box — default WPF pixel-scroll is too fast
Set-SlowScroll -Element $global:txtLog

# Route Write-Log calls made on the UI thread (i.e. NOT inside a runspace) into
# the UI log. Each runspace sets its own callback that pushes into the runspace's
# LogQueue (drained by the DispatcherTimer Tick); on the UI thread there is no
# queue, so we write straight into txtLog. Without this, Get-GraphConfig's
# plaintext-secret migration warnings would silently fall through to Write-Host
# and appear in the parent CMD window instead of the in-app log.
Set-LogCallback {
    param($msg)
    # Defensive newline: the XAML placeholder ("Load source and target policies
    # to get started.") has no trailing newline, so the first AppendText would
    # glue our message onto it on the same line. If txtLog doesn't end on a
    # newline yet, insert one before appending.
    if ($global:txtLog.Text.Length -gt 0 -and
        -not $global:txtLog.Text.EndsWith("`n")) {
        $global:txtLog.AppendText("`n")
    }
    $global:txtLog.AppendText($msg + "`n")
    $global:txtLog.ScrollToEnd()
}

$global:txtSourceSearch      = Find 'txtSourceSearch'
$global:txtTargetSearch      = Find 'txtTargetSearch'
$global:txtSourceSearchHint  = Find 'txtSourceSearchHint'
$global:txtTargetSearchHint  = Find 'txtTargetSearchHint'

# ── BasetunePolicyItem class (checkbox binding) ───────────────────────────────────────
# Stays as Add-Type C# rather than a PowerShell-native `class`. PS classes
# expose properties as plain fields with no setter hook, so you can't fire
# INotifyPropertyChanged.PropertyChanged from a property write — WPF then
# never sees IsChecked changes pushed back from the checkbox.
#
# Type-check guard: Add-Type re-compilation on an already-loaded type adds
# startup latency and emits a "type already exists" warning in some PS hosts.
# Skip if the type is already in the AppDomain (e.g. UI re-launched without
# exiting the host process).
#
# Policy holds the loaded policy object itself. Compare and Export take the
# ticked items' Policy directly instead of matching on Name — name matching
# also pulled in unticked policies that happened to share the name. (Named
# BasetunePolicyItem so an older PolicyItem type without this property, still
# loaded in the same host, can never be picked up by mistake.)
if (-not ("BasetunePolicyItem" -as [type])) {
    Add-Type @"
using System.ComponentModel;
public class BasetunePolicyItem : INotifyPropertyChanged {
    private string _name;
    private bool   _isChecked = true;
    public object Policy { get; set; }
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

# ── Win32 trim-working-set helper ─────────────────────────────────────────────
# After a forced GC the managed heap is clean, but Windows holds onto the
# previously-used pages as part of the process working set. They count toward
# what Task Manager shows as "Memory" even though .NET no longer needs them.
# SetProcessWorkingSetSize(-1, -1) tells the OS to trim the working set down
# to what's actually live. Real address space stays mapped (so subsequent
# allocations don't pay a page-fault price for genuinely-needed memory), but
# the visible footprint drops immediately instead of waiting minutes for the
# OS to notice on its own.
if (-not ("MemTrim" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class MemTrim {
    [DllImport("kernel32.dll")]
    public static extern bool SetProcessWorkingSetSize(IntPtr proc, IntPtr min, IntPtr max);
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetCurrentProcess();
    public static void Trim() {
        SetProcessWorkingSetSize(GetCurrentProcess(), (IntPtr)(-1), (IntPtr)(-1));
    }
}
"@
}

# ── Deferred memory cleanup ──────────────────────────────────────────────────
# Compare produces large transient allocations (flat setting arrays, resolved
# diffs, HTML payload). A forced, compacting gen2 collect gives that memory
# back, but it blocks every thread while it runs. Queue it at ApplicationIdle
# priority so it only runs after WPF has rendered the result, and skip it if
# another job has started in the meantime.
function Request-DeferredMemoryCleanup {
    $global:window.Dispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::ApplicationIdle,
        [System.Action]{
            if ($global:CurrentJob) { return }
            try {
                [System.Runtime.GCSettings]::LargeObjectHeapCompactionMode = `
                    [System.Runtime.GCLargeObjectHeapCompactionMode]::CompactOnce
            } catch {}
            [GC]::Collect(2, [System.GCCollectionMode]::Forced, $true, $true)
            [GC]::WaitForPendingFinalizers()
            [GC]::Collect(2, [System.GCCollectionMode]::Forced, $true, $true)
            try { [MemTrim]::Trim() } catch {}
        }
    ) | Out-Null
}

# ── Network watcher ──────────────────────────────────────────────────────────
# A request that was in flight when the network dropped only fails after its
# timeout (30 s without data). Until then the log was silent. This watcher
# checks the local network state every 2 s while a Load or Download is
# running and says so immediately when the connection disappears (and when it
# comes back). It only informs; the requests themselves still time out and
# are retried/reported as before.
#
# "Up" = at least one active, non-loopback, non-tunnel adapter with a default
# gateway. Virtual adapters without a gateway (Hyper-V internal switches etc.)
# therefore don't count, so switching Wi-Fi off is noticed.
function Test-NetworkUp {
    try {
        foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($ni.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
            if ($ni.NetworkInterfaceType -in @(
                    [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback,
                    [System.Net.NetworkInformation.NetworkInterfaceType]::Tunnel)) { continue }
            foreach ($g in $ni.GetIPProperties().GatewayAddresses) {
                $a = "$($g.Address)"
                if ($a -and $a -ne '0.0.0.0' -and $a -ne '::') { return $true }
            }
        }
        return $false
    } catch {
        return $true   # can't tell: don't raise a false alarm
    }
}

$global:NetWatchWasUp = $true
$global:NetWatchTimer = [System.Windows.Threading.DispatcherTimer]::new()
$global:NetWatchTimer.Interval = [TimeSpan]::FromSeconds(2)
$global:NetWatchTimer.Add_Tick({
    $job = $global:CurrentJob
    $watching = $job -and $job.Type -in @('Load', 'Download')
    if (-not $watching) { $global:NetWatchWasUp = $true; return }

    $up = Test-NetworkUp
    if (-not $up -and $global:NetWatchWasUp) {
        $maxWait = if ($job.Type -eq 'Download') { 60 } else { 30 }
        Write-UILog "[WARN][Network] Network connection lost. Waiting for requests in progress to time out (max $maxWait seconds)..."
    } elseif ($up -and -not $global:NetWatchWasUp) {
        Write-UILog "[INFO][Network] Network connection restored."
    }
    $global:NetWatchWasUp = $up
})
$global:NetWatchTimer.Start()

# ── Observable collections ────────────────────────────────────────────────────
$global:sourceItems = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
$global:targetItems = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
$global:lstSource.ItemsSource = $global:sourceItems
$global:lstTarget.ItemsSource = $global:targetItems

# ── Tenant store + editing state ─────────────────────────────────────────────
$global:tenantStore      = [System.Collections.Specialized.OrderedDictionary]::new()
$global:editingTenantKey = $null
$global:suppressEvents   = $false
$global:lastSourceTenantKey = $null
$global:lastTargetTenantKey = $null

# ── SelectedValue helper (Tag-based) ─────────────────────────────────────────
foreach ($cmb in @($global:cmbSourceTenant, $global:cmbTargetTenant)) {
    Add-Member -InputObject $cmb -MemberType ScriptProperty -Name 'SelectedValue' -Value {
        if ($this.SelectedItem) { $this.SelectedItem.Tag } else { $null }
    } -Force
}

# ═════════════════════════════════════════════════════════════════════════════
# RUNSPACE ENGINE
#
# Spins up a background PowerShell runspace, passes a $Shared hashtable into
# it as $Shared, plus a thread-safe ConcurrentQueue as $LogQueue, then polls
# both with a DispatcherTimer so log lines stream into the UI and $OnDone
# fires on completion.
#
# $Shared always carries a common base — ScriptRoot, GraphBeta, ModulesPath,
# defsPath. Callers add the mode-specific fields they need (e.g. Load adds
# TenantNode + Filter, Compare adds reportDir/reportFile + the def caches).
# This replaces the old monolithic 17-field bundle that pushed Compare-only
# data into every runspace.
# ═════════════════════════════════════════════════════════════════════════════
function Start-Runspace {
    param(
        [Parameter(Mandatory)][scriptblock]$Work,
        [Parameter(Mandatory)][scriptblock]$OnDone,
        [hashtable]$Shared  = @{},
        [hashtable]$Context = @{}    # Job-specific fields merged into $global:CurrentJob
                                     # (e.g. Type/Side/LoadItems/LoadOrigin). Merged BEFORE
                                     # the timer starts so OnDone always sees a complete job.
    )

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()

    # Common base merged into every runspace. Caller's $Shared wins on collisions.
    $base = @{
        ScriptRoot  = $ScriptRoot
        GraphBeta   = $global:GraphBeta
        ModulesPath = $global:ModulesPath
        defsPath    = $global:definitionsPath
        LogFile     = $global:logFile   # runspaces have their own $script:LogFile=$null
                                        # on import; $work needs to call Set-LogFile itself
    }
    foreach ($k in $base.Keys) {
        if (-not $Shared.ContainsKey($k)) { $Shared[$k] = $base[$k] }
    }

    $rs.SessionStateProxy.SetVariable('Shared', $Shared)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs

    $queue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $rs.SessionStateProxy.SetVariable('LogQueue', $queue)

    $ps.AddScript($Work) | Out-Null
    $handle = $ps.BeginInvoke()

    # Build the job context. Runspace plumbing fields (Runspace/PS/Handle/Queue/
    # OnDone/Done/Timer/Output) are owned by this function; caller-supplied
    # $Context fills in job-specific extras (Type, Side, LoadItems, LoadOrigin,
    # etc.).
    #
    # Set-Busy $true already created a CurrentJob stub (with IsBusy + Side)
    # before this call — merge into it instead of replacing, so the stub's
    # IsBusy survives. If for any reason no stub exists (shouldn't happen,
    # but defensive), start from scratch with IsBusy=$true.
    $job = if ($global:CurrentJob) { $global:CurrentJob } else { @{ IsBusy = $true } }
    $job.Runspace = $rs
    $job.PS       = $ps
    $job.Handle   = $handle
    $job.Queue    = $queue
    $job.OnDone   = $OnDone
    $job.Done     = $false
    $job.Timer    = $null
    $job.Output   = @()
    foreach ($k in $Context.Keys) { $job[$k] = $Context[$k] }
    $global:CurrentJob = $job

    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        # Guard: if Stop-ActiveRunspace ran, CurrentJob is $null. Bail.
        $job = $global:CurrentJob
        if (-not $job) { return }

        # Drain up to $maxPerTick log lines into a single StringBuilder, then
        # flush as ONE AppendText + ScrollToEnd. Per-line AppendText/ScrollToEnd
        # used to do a TextBox layout pass per call — fine for tens of lines per
        # tick, painful at hundreds. A noisy export can enqueue thousands of
        # lines while the user resizes the window.
        #
        # Capping per tick keeps the UI thread responsive: if the queue is
        # deeper than $maxPerTick, the rest waits 200ms for the next tick
        # (no loss — ConcurrentQueue is durable). On job completion the cap
        # is lifted so OnDone never sees a truncated log.
        $maxPerTick = 500
        $sb         = [System.Text.StringBuilder]::new()
        $drained    = 0
        $item       = $null
        while ($drained -lt $maxPerTick -and $job.Queue.TryDequeue([ref]$item)) {
            [void]$sb.Append($item).Append("`n")
            $drained++
        }
        if ($sb.Length -gt 0) {
            $global:txtLog.AppendText($sb.ToString())
            # Trim the visible buffer if it grows past ~10k lines. WPF TextBox
            # gets sluggish past a few MB of text; we keep a rolling window so
            # long-running sessions stay snappy. Cheap because LineCount is O(1)
            # and Remove is a single block delete.
            $maxLines = 10000
            if ($global:txtLog.LineCount -gt $maxLines) {
                $cutLines = $global:txtLog.LineCount - $maxLines
                $cutChars = $global:txtLog.GetCharacterIndexFromLineIndex($cutLines)
                if ($cutChars -gt 0) { $global:txtLog.Text = $global:txtLog.Text.Substring($cutChars) }
            }
            $global:txtLog.ScrollToEnd()
        }

        if (-not $job.Done -and $job.Handle.IsCompleted) {
            $job.Done = $true
            $job.Timer.Stop()
            # Final drain — uncapped, single batch. OnDone callbacks expect
            # to log against a complete txtLog.
            $sb   = [System.Text.StringBuilder]::new()
            $item = $null
            while ($job.Queue.TryDequeue([ref]$item)) {
                [void]$sb.Append($item).Append("`n")
            }
            if ($sb.Length -gt 0) {
                $global:txtLog.AppendText($sb.ToString())
                $global:txtLog.ScrollToEnd()
            }
            # EndInvoke() returns the pipeline output — capture before Dispose().
            # OnDone reads it via $global:CurrentJob.Output (no more $script:activeOutput).
            #
            # Errors: a terminating error in the work block makes EndInvoke
            # throw, and non-terminating errors land in PS.Streams.Error. Both
            # used to be discarded, so a failed Load showed "loaded 0 policies"
            # and a failed Compare just "Done.". Collect them on $job.Errors,
            # write them to the UI log + log file, and let OnDone react.
            $job.Errors = [System.Collections.Generic.List[string]]::new()
            $job.Fatal  = $false   # $true when the work block died (EndInvoke threw)
            $job.Output = try {
                @($job.PS.EndInvoke($job.Handle))
            } catch {
                $ex = $_.Exception
                while ($ex -is [System.Management.Automation.MethodInvocationException] -and $ex.InnerException) {
                    $ex = $ex.InnerException
                }
                $job.Errors.Add($ex.Message)
                $job.Fatal = $true
                @()
            }
            try {
                foreach ($er in $job.PS.Streams.Error) {
                    $m = "$er"
                    if ($m -and -not $job.Errors.Contains($m)) { $job.Errors.Add($m) }
                }
            } catch {}
            if ($job.Errors.Count -gt 0) {
                $jobLabel = if ($job.Type) { $job.Type } else { 'Job' }
                $maxShown = 10
                foreach ($m in ($job.Errors | Select-Object -First $maxShown)) {
                    Write-UILog "[ERROR][$jobLabel] $m"
                }
                if ($job.Errors.Count -gt $maxShown) {
                    Write-UILog "[ERROR][$jobLabel] ... and $($job.Errors.Count - $maxShown) more error(s)."
                }
            }
            $job.PS.Dispose()
            $job.Runspace.Dispose()
            # OnDone snapshots $global:CurrentJob locally, THEN calls
            # Set-Busy $false (which nulls $global:CurrentJob). The finally
            # is a safety net for the case where OnDone throws before
            # reaching its Set-Busy call — without it the UI would stay
            # locked in busy state forever.
            #
            # After OnDone: actively NULL all heavy references on $job so
            # the timer-closure (which captured $job via $global:CurrentJob)
            # no longer keeps PS pipeline output / queue / runspace alive
            # until the next GC. Then force a collect — the runspace just
            # produced potentially MB of compare data, and WPF won't trigger
            # gen2 GC on its own between user clicks.
            $jobType = $job.Type
            try { & $job.OnDone } finally {
                $job.PS       = $null
                $job.Runspace = $null
                $job.Handle   = $null
                $job.Queue    = $null
                $job.Output   = $null
                $job.Timer    = $null
                $job.OnDone   = $null
                $job          = $null
                $global:CurrentJob = $null

                # Compare/Load produce the largest transient allocations
                # (flat setting arrays, resolved diffs, HTML strings).
                # Force a full collect only for those — Export/Download
                # are cheap and don't warrant the ~50-200ms pause.
                if ($jobType -in @('Compare','Load')) {
                    $Error.Clear()
                    $sb = $null
                }
                # The forced full GC used to run right here, inside the tick
                # handler — i.e. BEFORE WPF could draw the loaded policies or
                # the "Report ready" line. A blocking, compacting gen2 collect
                # with the definition cache in memory takes a noticeable
                # moment, which is the pause users saw just before the policy
                # list appeared. Load no longer triggers it at all (its
                # allocations are modest); Compare schedules it for when the
                # UI is idle, after the result is on screen.
                if ($jobType -eq 'Compare') { Request-DeferredMemoryCleanup }
            }
        }
    })
    $global:CurrentJob.Timer = $timer
    $timer.Start()
}

# ── Cancel an in-progress runspace load ──────────────────────────────────────
# PS.Stop() is synchronous: it waits until the pipeline has actually stopped,
# which with ForEach-Object -Parallel means waiting for in-flight Graph calls.
# That froze the window after clicking Cancel. Now the stop is started with
# BeginStop() and the runspace is disposed later, by a small cleanup timer,
# once the stop has completed. The UI is released immediately.
$global:StoppingJobs = [System.Collections.Generic.List[object]]::new()
$global:StopCleanupTimer = [System.Windows.Threading.DispatcherTimer]::new()
$global:StopCleanupTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$global:StopCleanupTimer.Add_Tick({
    foreach ($s in @($global:StoppingJobs)) {
        if (-not $s.Handle -or $s.Handle.IsCompleted) {
            try { if ($s.Handle) { $s.PS.EndStop($s.Handle) } } catch {}
            try { $s.PS.Dispose() }       catch {}
            try { $s.Runspace.Dispose() } catch {}
            [void]$global:StoppingJobs.Remove($s)
        }
    }
    if ($global:StoppingJobs.Count -eq 0) { $global:StopCleanupTimer.Stop() }
})

function Stop-ActiveRunspace {
    param([string]$Side = '')

    $job = $global:CurrentJob
    if ($job) {
        if ($job.Timer) { $job.Timer.Stop() }
        if ($job.PS) {
            $stopHandle = $null
            try { $stopHandle = $job.PS.BeginStop($null, $null) } catch {}
            $global:StoppingJobs.Add(@{ PS = $job.PS; Runspace = $job.Runspace; Handle = $stopHandle })
            $global:StopCleanupTimer.Start()
        } elseif ($job.Runspace) {
            try { $job.Runspace.Dispose() } catch {}
        }
        # Match the Tick-handler cleanup: actively release heavy refs so
        # the cancelled job doesn't linger via the timer closure.
        $job.PS       = $null
        $job.Runspace = $null
        $job.Handle   = $null
        $job.Queue    = $null
        $job.Output   = $null
        $job.Timer    = $null
        $job.OnDone   = $null
    }

    # Set-Busy $false nulls $global:CurrentJob (the busy/idle source of truth)
    # AND restores btnOpenReport to its pre-busy state from the snapshot taken
    # when the runspace started — covers the cancel case without an explicit
    # Test-Path here.
    Set-Busy $false

    # Cancel also skips Update-Counts, so btnCompare would stay disabled
    # even when Source + Target are still loaded with selections from an
    # earlier load. Re-evaluate here.
    Update-Counts

    # Re-apply the Download button label if definitions are still missing —
    # cancel returned the button to icon-only via Set-IconButtonMode.
    Update-DownloadButton

    # Generic cancel message — Side can be 'Source', 'Target', 'Download',
    # 'Source Export', 'Target Export', etc.
    $what = if ($Side) { "$Side cancelled" } else { "Operation cancelled" }
    Write-UILog "`n$what."
}

# ═════════════════════════════════════════════════════════════════════════════
# UI HELPERS — shared by Load / Compare / Export / Download paths
# ═════════════════════════════════════════════════════════════════════════════

# Resolve a tenant from $tenantList by its Key. Returns the entry (with
# .Key/.Label/.Node) or $null.
function Get-TenantEntry {
    param($Id)
    if (-not $Id) { return $null }
    $global:tenantList | Where-Object { $_.Key -eq $Id } | Select-Object -First 1
}

# Friendly display label for a tenant id — used in log messages and report
# headers. Falls back to the id, then to 'Basetune' if nothing is selected.
function Get-UITenantLabel {
    param($Id)
    $e = Get-TenantEntry $Id
    if ($e -and $e.Label) { return $e.Label }
    if ($Id) { return $Id }
    return 'Basetune'
}

# Resolve MaxThreads from the saved setting, validated (1..32, default 8).
# 0 or garbage used to reach ForEach-Object -ThrottleLimit and abort the load.
function Get-MaxThreads {
    return Get-ValidMaxThreads $global:savedMaxThreads
}

# ═════════════════════════════════════════════════════════════════════════════
# LOAD POLICIES
# ═════════════════════════════════════════════════════════════════════════════
function Load-Side {
    param([string]$Side, [object]$Items)

    $cmb         = if ($Side -eq 'Source') { $global:cmbSourceTenant } else { $global:cmbTargetTenant }
    $selectedKey = $cmb.SelectedValue

    if (-not $selectedKey) {
        Clear-UILog "[INFO][$Side] No tenant selected. Add a tenant via Tenant Configuration first."
        Set-Busy $false
        return
    }

    $entry      = Get-TenantEntry $selectedKey
    $tenantNode = if ($entry) { $entry.Node } else { $null }
    $origin     = Get-TenantMode $tenantNode

    $filter = if ($Side -eq 'Source') { $global:txtSourceFilter.Text.Trim() } else { $global:txtTargetFilter.Text.Trim() }
    $maxT   = Get-MaxThreads

    $tenantJsonPath = if ($tenantNode -and $tenantNode.path -and $tenantNode.path.Trim()) {
        $tenantNode.path.Trim()
    } else { $null }

    $resolvedPath = if ($origin -eq 'Offline' -and -not $tenantJsonPath) {
        $label = Get-UITenantLabel $selectedKey
        Clear-UILog "[ERROR][$Side] No path configured for '$label'. Open Tenant Configuration and set a JSON path."
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
            Clear-UILog "`nCannot create path: $resolvedPath — $_"
            Set-Busy $false
            return
        }
    }

    # Reset search + clear list
    if ($Side -eq 'Source') {
        $global:txtSourceSearch.Text = ''
        if ($global:txtSourceSearchHint) { $global:txtSourceSearchHint.Visibility = 'Visible' }
    } else {
        $global:txtTargetSearch.Text = ''
        if ($global:txtTargetSearchHint) { $global:txtTargetSearchHint.Visibility = 'Visible' }
    }
    $Items.Clear()
    Set-Busy $true -Side $Side
    $global:btnCompare.IsEnabled = $false

    $tenantLabel = Get-UITenantLabel $selectedKey
    $originDesc  = if ($origin -eq 'Offline') { '(JSON)' } else { '(API)' }
    Clear-UILog "[INFO][$Side] Loading policies from $tenantLabel $originDesc..."

    # Per-mode $Shared — only the fields Load actually needs. TenantNode comes
    # through SetVariable as a real PSCustomObject; no JSON round-trip needed.
    $shared = @{
        Side        = $Side
        Origin      = $origin
        Filter      = $filter
        JsonPath    = $resolvedPath
        TenantNode  = $tenantNode
        TenantLabel = $tenantLabel
        MaxThreads  = $maxT
    }

    $work = {
        $S = $Shared
        Import-Module "$($S.ModulesPath)\IntuneGraphModules.psd1" -Force
        Set-LogCallback { param($msg) $LogQueue.Enqueue($msg) }
        if ($S.LogFile) { try { Set-LogFile -Path $S.LogFile } catch {} }

        # Every outcome ends with a status marker. OnDone trusts only that
        # marker: no marker (runspace died) or Success = $false means the load
        # failed, whatever else is in the output.
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
                -LogQueue    $LogQueue `
                -LogFile     $S.LogFile)

            # Emit connection first so the UI can stash it without scanning the
            # whole result; policies follow as the rest of the pipeline output.
            [PSCustomObject]@{ __type = 'connection'; conn = $conn }
            $policies
            [PSCustomObject]@{ __type = 'status'; Success = $true; Reason = '' }
        } catch {
            # Errors that were already reported in detail (expand failures)
            # are not repeated as "Load failed: ...".
            if (-not $_.Exception.Data['BasetuneLogged']) {
                Write-Log $S.Side "Load failed: $($_.Exception.Message)" 'ERROR'
            }
            [PSCustomObject]@{ __type = 'status'; Success = $false; Reason = 'error' }
        }
    }

    Start-Runspace -Work $work -Shared $shared -OnDone {
        # Snapshot the job BEFORE Set-Busy $false clears $global:CurrentJob.
        # Output / LoadSide / LoadItems / LoadOrigin still live on $job
        # (it's a hashtable reference — clearing the global only nulls the
        # variable, not the object it pointed to).
        $job      = $global:CurrentJob
        Set-Busy $false

        $result   = @($job.Output)
        $connObj  = $result | Where-Object { $_.PSObject.Properties['__type'] -and $_.__type -eq 'connection' } | Select-Object -First 1
        $status   = $result | Where-Object { $_.PSObject.Properties['__type'] -and $_.__type -eq 'status' } | Select-Object -Last 1
        $policies = @($result | Where-Object { -not $_.PSObject.Properties['__type'] })
        $loadOk   = ($status -and $status.Success -and -not $job.Fatal)

        # A failed load leaves the side empty: never show a partial list that
        # the user could then compare as if it were complete.
        if (-not $loadOk) { $policies = @() }

        if ($loadOk -and $connObj -and $connObj.conn) {
            if ($job.LoadSide -eq 'Source') { $global:sourceConnection = $connObj.conn }
            else                            { $global:targetConnection = $connObj.conn }
        }

        foreach ($p in ($policies | Sort-Object { $_.name })) {
            if (-not $p.name) { continue }
            $item           = [BasetunePolicyItem]::new()
            $item.Name      = $p.name
            $item.IsChecked = $true
            $item.Policy    = $p
            $job.LoadItems.Add($item)
        }

        if ($job.LoadSide -eq 'Source') {
            $global:sourceExpanded        = $policies
            $global:lstSource.ItemsSource = $global:sourceItems
        } else {
            $global:targetExpanded        = $policies
            $global:lstTarget.ItemsSource = $global:targetItems
        }

        $global:progressBar.IsIndeterminate = $false
        Update-Counts

        # Distinguish "loaded zero" from "failed". The status marker from the
        # work block says which: Reason 'connection' = no token (credentials,
        # network), anything else = an error that is already in the log above.
        $sideLabel = $job.LoadSide
        $count     = $job.LoadItems.Count
        if ($loadOk -and $count -eq 0) {
            # Not an error (the tenant or folder was read fine), but
            # "Successfully loaded 0" read like success. Say what happened.
            $filterNote = if ($job.LoadFilter) { " matching the filter '$($job.LoadFilter)'" } else { '' }
            Write-UILog "`nNo $sideLabel policies found$filterNote. Check the filter, the tenant or the JSON folder."
        } elseif ($loadOk) {
            Write-UILog "`nSuccessfully loaded $count $sideLabel policies."
        } elseif ($status -and $status.Reason -eq 'connection') {
            Write-UILog "`nFailed to load policies from $sideLabel. Check credentials in the configuration."
        } else {
            Write-UILog "`nFailed to load policies from $sideLabel. See the errors above."
        }
    } -Context @{
        Type       = 'Load'
        Side       = $Side
        LoadSide   = $Side
        LoadItems  = $Items
        LoadOrigin = $origin   # 'Online' / 'Offline' — for OnDone failure detection
        LoadFilter = $filter   # shown in the "no policies found" message
    }
}

$global:btnSourceLoad.Add_Click({
    if ($global:btnSourceLoad.Tag -eq 'cancel') {
        Stop-ActiveRunspace -Side 'Source'
    } else {
        Load-Side -Side 'Source' -Items $global:sourceItems
    }
})
$global:btnTargetLoad.Add_Click({
    if ($global:btnTargetLoad.Tag -eq 'cancel') {
        Stop-ActiveRunspace -Side 'Target'
    } else {
        Load-Side -Side 'Target' -Items $global:targetItems
    }
})

# ═════════════════════════════════════════════════════════════════════════════
# COMPARE
# Uses $global:sourceExpanded / $global:targetExpanded cached in memory —
# no new Graph calls needed, which is why this must stay in the UI process.
# ═════════════════════════════════════════════════════════════════════════════
$global:btnCompare.Add_Click({
    # Take the ticked items' own policy objects. Matching on name used to
    # include every policy with that name, ticked or not.
    $srcFiltered = @($global:sourceItems | Where-Object { $_.IsChecked -and $_.Policy } | ForEach-Object { $_.Policy })
    $tgtFiltered = @($global:targetItems | Where-Object { $_.IsChecked -and $_.Policy } | ForEach-Object { $_.Policy })

    if ($srcFiltered.Count -eq 0 -or $tgtFiltered.Count -eq 0) {
        Clear-UILog "Select at least one source and one target policy."
        return
    }

    Clear-UILog ''
    Set-Busy $true
    $global:btnCompare.IsEnabled    = $false
    # btnOpenReport disable / restore is handled centrally by Set-Busy

    # Build timestamped report subfolder: Report\SOURCE_TARGET\YYYYMMDD_HHMMSS
    $runSrcLabel = Get-UITenantLabel $global:cmbSourceTenant.SelectedValue
    $runTgtLabel = Get-UITenantLabel $global:cmbTargetTenant.SelectedValue
    $safeRunSrc    = $runSrcLabel -replace '[\\/:*?"<>|\s]','_'
    $safeRunTgt    = $runTgtLabel -replace '[\\/:*?"<>|\s]','_'
    $runStamp      = Get-Date -Format 'yyyyMMdd_HHmmss'
    $runPairFolder = "${safeRunSrc}_${safeRunTgt}"
    # Join-Path: no double backslash when the report path is a drive root (C:\).
    $runReportDir  = Join-Path (Join-Path $global:reportBasePath $runPairFolder) $runStamp

    # Create the report folder up front so write-failures surface before the
    # runspace launches — otherwise the user sees a half-finished compare
    # with a cryptic Export-Csv error deep in the log.
    try {
        New-Item -ItemType Directory -Path $runReportDir -Force -ErrorAction Stop | Out-Null
    } catch {
        Clear-UILog "[ERROR][Compare] Cannot create report folder '$runReportDir'. $($_.Exception.Message)"
        Set-Busy $false
        Update-Counts
        return
    }

    $runReportFile = Join-Path $runReportDir 'Report.html'
    $global:reportPath = $runReportFile

    # Compare runs purely in-memory on the cached policies. The runspace gets
    # the UI definition cache (so settingDefinitions.json is parsed at most
    # once per session), the report paths and labels, and the Graph
    # connections (used to fetch unknown categories on demand).
    $defCache = $global:Cache.Definitions
    $shared = @{
        reportDir         = $runReportDir
        reportFile        = $runReportFile
        reportSourceLabel = $runSrcLabel
        reportTargetLabel = $runTgtLabel
        cachedDefLookup   = $defCache.Lookup
        cachedCatById     = $defCache.CategoryById
        cachedHasDefs     = $defCache.HasDefs
        cachedHasCats     = $defCache.HasCats
        srcFiltered       = $srcFiltered
        tgtFiltered       = $tgtFiltered
        sourceConnection  = $global:sourceConnection
        targetConnection  = $global:targetConnection
    }

    $work = {
        $S = $Shared
        Import-Module "$($S.ModulesPath)\IntuneGraphModules.psd1" -Force
        Set-LogCallback { param($msg) $LogQueue.Enqueue($msg) }
        if ($S.LogFile) { try { Set-LogFile -Path $S.LogFile } catch {} }

        try {
            $_defsFile = "$($S.defsPath)\settingDefinitions.json"
            $_catsFile = "$($S.defsPath)\settingCategories.json"

            # ── Definitions: UI cache first, otherwise parse the file once ──
            $defLookup = $null
            if ($S.cachedHasDefs -and $S.cachedDefLookup) {
                $defLookup = $S.cachedDefLookup
                Write-Log 'Definitions' "$($defLookup.Count) definitions loaded from cache" 'OK'
            } elseif (Test-Path $_defsFile) {
                try {
                    Write-Log 'Definitions' 'Loading setting definitions...' 'INFO'
                    $defLookup = Import-SettingDefinitions -Path $_defsFile
                    Write-Log 'Definitions' "$($defLookup.Count) definitions loaded" 'OK'
                } catch {
                    $defLookup = $null
                    Write-Log 'Definitions' "Cannot read settingDefinitions.json: $($_.Exception.Message)" 'WARN'
                }
            }
            if (-not $defLookup) { Write-Log 'Definitions' 'Definition file not found. Using settingDefinitionId' 'WARN' }

            # ── Categories ──
            $catMap = $null
            if ($S.cachedHasCats -and $S.cachedCatById) {
                $catMap = $S.cachedCatById
                Write-Log 'Categories' "$($catMap.Count) categories loaded from cache" 'OK'
            } elseif (Test-Path $_catsFile) {
                try {
                    $catMap = Import-SettingCategories -Path $_catsFile
                    Write-Log 'Categories' "$($catMap.Count) categories loaded" 'OK'
                } catch {
                    $catMap = $null
                    Write-Log 'Categories' "Cannot read settingCategories.json: $($_.Exception.Message)" 'WARN'
                }
            }
            if (-not $catMap) { Write-Log 'Categories' 'No categories — paths will be skipped' 'WARN' }

            $conn = if ($S.sourceConnection) { $S.sourceConnection } elseif ($S.targetConnection) { $S.targetConnection } else { $null }

            # ── Same pipeline as the CLI ──
            $result = Invoke-BaselineCompare `
                -SourcePolicies     $S.srcFiltered `
                -TargetPolicies     $S.tgtFiltered `
                -ExportPath         $S.reportDir `
                -ReportFile         $S.reportFile `
                -DefinitionLookup   $defLookup `
                -CategoryById       $catMap `
                -CategoriesFilePath $_catsFile `
                -Connection         $conn `
                -SourceLabel        $S.reportSourceLabel `
                -TargetLabel        $S.reportTargetLabel

            # Emit cache contents back to the UI so the next compare doesn't
            # need to re-parse settingDefinitions.json.
            [PSCustomObject]@{
                __type    = 'cache'
                defLookup = $defLookup
                catMap    = $catMap
                hasDefs   = ($null -ne $defLookup -and $defLookup.Count -gt 0)
                hasCats   = ($null -ne $catMap -and $catMap.Count -gt 0)
            }
            [PSCustomObject]@{ __type = 'status'; Success = [bool]$result.Success }
        } catch {
            Write-Log 'Compare' "Compare failed: $($_.Exception.Message)" 'ERROR'
            [PSCustomObject]@{ __type = 'status'; Success = $false }
        }
    }

    Start-Runspace -Work $work -Shared $shared -OnDone {
        # Snapshot the job locally before Set-Busy nulls $global:CurrentJob.
        $job = $global:CurrentJob
        Set-Busy $false
        Update-Counts

        $out      = @($job.Output)
        $cacheOut = $out | Where-Object { $_.PSObject.Properties['__type'] -and $_.__type -eq 'cache' }  | Select-Object -First 1
        $status   = $out | Where-Object { $_.PSObject.Properties['__type'] -and $_.__type -eq 'status' } | Select-Object -Last 1

        # Pick up the cache emitted by the runspace: rehome the references,
        # no disk reads on the UI thread.
        if ($cacheOut) {
            $defCache = $global:Cache.Definitions
            if ($cacheOut.hasDefs -and -not $defCache.HasDefs) {
                $defCache.Lookup  = $cacheOut.defLookup
                $defCache.HasDefs = $true
                Write-UILog "[OK][Definitions] $($cacheOut.defLookup.Count) definitions cached"
            }
            if ($cacheOut.hasCats -and -not $defCache.HasCats) {
                $defCache.CategoryById = $cacheOut.catMap
                $defCache.HasCats      = $true
                Write-UILog "[OK][Categories] $($cacheOut.catMap.Count) categories cached"
            }
        }

        $ok = ($status -and $status.Success -and -not $job.Fatal)
        if ($ok -and (Test-Path $global:reportPath)) {
            $global:btnOpenReport.IsEnabled = $true
            Write-UILog "`nReport ready."
        } else {
            Write-UILog "`nCompare failed. See the errors above."
        }
    } -Context @{ Type = 'Compare'; Side = '' }
})

# ═════════════════════════════════════════════════════════════════════════════
# EXPORT / DOWNLOAD — runspace launchers
# Both used to fork a CLI subprocess via ProcessRunner2; now they run in the
# same in-process runspace engine as Load and Compare.
# ═════════════════════════════════════════════════════════════════════════════

# ── Export ────────────────────────────────────────────────────────────────────
# One helper for both Source/Target export buttons. Shows a folder picker,
# validates, then runs Export-CachedPoliciesToJson in a runspace.
# Uses the already-loaded policy cache — no extra Graph API calls.
# Only the checked (selected) policies are written to disk.
function Start-ExportRunspace {
    param([Parameter(Mandatory)][ValidateSet('Source','Target')][string]$Side)

    $expanded = if ($Side -eq 'Source') { $global:sourceExpanded } else { $global:targetExpanded }
    $items    = if ($Side -eq 'Source') { $global:sourceItems    } else { $global:targetItems    }

    # Collect the checked policies themselves — the user's current selection
    # drives what gets exported. (Selecting by name also exported unticked
    # policies that shared a name with a ticked one.)
    $selectedPolicies = @($items | Where-Object { $_.IsChecked -and $_.Policy } | ForEach-Object { $_.Policy })
    if ($selectedPolicies.Count -eq 0) {
        Clear-UILog "[ERROR][Export] No $Side policies selected. Check at least one policy to export."
        return
    }

    $key = if ($Side -eq 'Source') { $global:cmbSourceTenant.SelectedValue } `
           else                    { $global:cmbTargetTenant.SelectedValue }
    $exportLabel = Get-UITenantLabel $key

    # Folder picker FIRST — Set-Busy stays untouched until the export is
    # confirmed so the button never flickers into Cancel mode on a cancel click.
    $exportFolder = Show-FolderBrowser
    if (-not $exportFolder) { return }
    if ($exportFolder -match '^[A-Za-z]:\\?$') {
        Clear-UILog "[ERROR][Export] Cannot export to a drive root ($exportFolder). Choose a subfolder (e.g. C:\Export)."
        return
    }

    Set-Busy $true -Side "${Side}Export"
    $global:btnCompare.IsEnabled = $false
    Clear-UILog "[INFO][Export] Exporting $($selectedPolicies.Count) of $(@($expanded).Count) $exportLabel policies..."

    $shared = @{
        Policies      = $selectedPolicies
        SideLabel     = $Side
        OutputPath    = $exportFolder
    }

    $work = {
        $S = $Shared
        Import-Module "$($S.ModulesPath)\IntuneGraphModules.psd1" -Force
        Set-LogCallback { param($msg) $LogQueue.Enqueue($msg) }
        if ($S.LogFile) { try { Set-LogFile -Path $S.LogFile } catch {} }

        try {
            $r = Export-CachedPoliciesToJson `
                -Policies      $S.Policies `
                -OutputPath    $S.OutputPath
            [PSCustomObject]@{ Success = ($null -ne $r -and $r.Failed -eq 0) }
        } catch {
            Write-Log 'Export' "Export failed: $($_.Exception.Message)" 'ERROR'
            [PSCustomObject]@{ Success = $false }
        }
    }

    Start-Runspace -Work $work -Shared $shared -OnDone {
        $job = $global:CurrentJob
        Set-Busy $false
        Update-Counts
        $result = @($job.Output) | Select-Object -Last 1
        if ($result -and $result.Success -and -not $job.Fatal) {
            Write-UILog "`nExport complete."
        } else {
            Write-UILog "`nExport failed."
        }
    } -Context @{ Type = 'Export'; Side = "${Side}Export" }
}

$global:btnSourceExport.Add_Click({
    if ($global:btnSourceExport.Tag -eq 'cancel') {
        Stop-ActiveRunspace -Side 'Source Export'
    } else {
        Start-ExportRunspace -Side 'Source'
    }
})
$global:btnTargetExport.Add_Click({
    if ($global:btnTargetExport.Tag -eq 'cancel') {
        Stop-ActiveRunspace -Side 'Target Export'
    } else {
        Start-ExportRunspace -Side 'Target'
    }
})

# ── Tenant picker dialog for download ────────────────────────────────────────
function Show-TenantPickerDialog {
    $onlineTenants = @($global:tenantList | Where-Object {
        (Get-TenantMode $_.Node) -eq 'Online'
    } | Sort-Object { $_.Label })

    $dlg = Load-Xaml -Path "$ScriptRoot\UI\BasetuneDownload.xaml"
    $dlg.Owner = $global:window

    $cmb       = $dlg.FindName('cmbDownloadTenant')
    $btnOk     = $dlg.FindName('btnDownloadOk')
    $btnCancel = $dlg.FindName('btnDownloadCancel')
    $btnClose  = $dlg.FindName('btnTitleClose')
    $titleBar  = $dlg.FindName('titleBar')

    if ($titleBar) { $titleBar.Add_MouseLeftButtonDown({ $dlg.DragMove() }) }
    if ($btnClose) { $btnClose.Add_Click({ $dlg.Close() }) }

    if ($onlineTenants.Count -eq 0) {
        $cmb.IsEnabled   = $false
        $btnOk.IsEnabled = $false
        $lblNoTenants    = $dlg.FindName('lblNoTenants')
        if ($lblNoTenants) { $lblNoTenants.Visibility = 'Visible' }
    } else {
        foreach ($t in $onlineTenants) {
            $item         = [System.Windows.Controls.ComboBoxItem]::new()
            $item.Content = $t.Label
            $item.Tag     = $t.Key
            $cmb.Items.Add($item) | Out-Null
        }
        $cmb.SelectedIndex = 0
    }

    $script:dlgPickedKey = $null
    $btnOk.Add_Click({     $script:dlgPickedKey = $cmb.SelectedItem.Tag; $dlg.DialogResult = $true  })
    $btnCancel.Add_Click({ $dlg.DialogResult = $false })
    $dlg.Add_KeyDown({ param($s,$e); if ($e.Key -eq 'Escape') { $dlg.DialogResult = $false } })
    $dlg.ShowDialog() | Out-Null
    return $script:dlgPickedKey
}

# ── Download (definitions + categories) ──────────────────────────────────────
$global:btnOpenDownload.Add_Click({
    # When already running, this click is the user asking to cancel.
    if ($global:btnOpenDownload.Tag -eq 'cancel') {
        Stop-ActiveRunspace -Side 'Download'
        return
    }

    $pickedKey = Show-TenantPickerDialog
    if (-not $pickedKey) { return }

    $entry = Get-TenantEntry $pickedKey
    if (-not $entry -or (Get-TenantMode $entry.Node) -ne 'Online') {
        Clear-UILog "[ERROR][Download] Selected tenant is not online."
        return
    }

    # Collapse the button to icon-only before Set-Busy flips it into cancel
    # mode — keeps the cancel X centred in a square 34x34 footprint.
    Set-DownloadButtonLabel $false

    Set-Busy $true -Side 'Download'
    $global:btnCompare.IsEnabled    = $false
    # btnOpenReport disable / restore is handled centrally by Set-Busy
    Clear-UILog "[INFO][Download] Download Definitions"

    $shared = @{
        TenantNode      = $entry.Node
        DownloadLabel   = $entry.Label
        DefinitionsPath = $global:definitionsPath
    }

    $work = {
        $S = $Shared
        Import-Module "$($S.ModulesPath)\IntuneGraphModules.psd1" -Force
        Set-LogCallback { param($msg) $LogQueue.Enqueue($msg) }
        if ($S.LogFile) { try { Set-LogFile -Path $S.LogFile } catch {} }

        Write-Log 'Download' "Downloading setting definitions using tenant: $($S.DownloadLabel)..." 'INFO'
        $conn = New-GraphConnection -Config $S.TenantNode -Label 'Download'
        if (-not $conn) {
            Write-Log 'Download' "Could not connect to tenant '$($S.DownloadLabel)'. Check credentials in the configuration." 'ERROR'
            return [PSCustomObject]@{ Success = $false }
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
            Write-Log 'Download' "Download failed: $($_.Exception.Message)" 'ERROR'
            [PSCustomObject]@{ Success = $false }
        }
    }

    Start-Runspace -Work $work -Shared $shared -OnDone {
        # Snapshot before Set-Busy $false clears CurrentJob.
        $job = $global:CurrentJob
        Set-Busy $false
        Update-Counts
        # Run Report state is restored by Set-Busy to whatever it was before
        # the download started — a fresh download must NOT promote an
        # inactive Run Report button to active.
        # Only refresh the in-memory cache (and log success) when the download
        # actually completed. Without this guard, a failed download silently
        # reloads the OLD cached files and logs "definitions cached", which
        # makes it look like fresh data was loaded.
        $result   = @($job.Output) | Select-Object -Last 1
        $cacheOut = @($job.Output) | Where-Object { $_.PSObject.Properties['__type'] -and $_.__type -eq 'cache' } | Select-Object -First 1
        if ($result -and $result.Success -and -not $job.Fatal) {
            # Refresh the in-memory cache with the lookups the runspace built
            # from the downloaded data. Previously Update-DefinitionCache
            # re-read and parsed the 60+ MB file HERE, on the UI thread, which
            # froze the window for several seconds after every download.
            $defCache = $global:Cache.Definitions
            if ($cacheOut -and $cacheOut.defLookup -and $cacheOut.defLookup.Count -gt 0) {
                $defCache.Lookup  = $cacheOut.defLookup
                $defCache.HasDefs = $true
                Write-UILog "[OK][Definitions] $($cacheOut.defLookup.Count) definitions cached"
            }
            if ($cacheOut -and $cacheOut.catMap -and $cacheOut.catMap.Count -gt 0) {
                $defCache.CategoryById = $cacheOut.catMap
                $defCache.HasCats      = $true
                Write-UILog "[OK][Categories] $($cacheOut.catMap.Count) categories cached"
            }
            Write-UILog "`nDownload complete."
        } else {
            Write-UILog "`nDownload failed."
        }
        # Re-evaluate the Download button label: collapses to icon-only when
        # both files are now on disk, re-applies the label after a failure.
        Update-DownloadButton
    } -Context @{ Type = 'Download'; Side = 'Download' }
})

$global:btnOpenReport.Add_Click({ if (Test-Path $global:reportPath) { Start-Process $global:reportPath } })

# ═════════════════════════════════════════════════════════════════════════════
# POLICY LIST EVENT WIRING
# ═════════════════════════════════════════════════════════════════════════════

# Checkbox routed events → Update-Counts
$global:window.AddHandler(
    [System.Windows.Controls.Primitives.ToggleButton]::CheckedEvent,
    [System.Windows.RoutedEventHandler]{ Update-Counts }
)
$global:window.AddHandler(
    [System.Windows.Controls.Primitives.ToggleButton]::UncheckedEvent,
    [System.Windows.RoutedEventHandler]{ Update-Counts }
)

$global:btnSourceAll.Add_Click({
    $visibleItems = $global:lstSource.ItemsSource
    if ($visibleItems) {
        foreach ($i in $visibleItems) { $i.IsChecked = $true }
        $global:lstSource.ItemsSource = $null
        $global:lstSource.ItemsSource = $visibleItems
    }
    Update-Counts
})
$global:btnSourceNone.Add_Click({
    $visibleItems = $global:lstSource.ItemsSource
    if ($visibleItems) {
        foreach ($i in $visibleItems) { $i.IsChecked = $false }
        $global:lstSource.ItemsSource = $null
        $global:lstSource.ItemsSource = $visibleItems
    }
    Update-Counts
})
$global:btnTargetAll.Add_Click({
    $visibleItems = $global:lstTarget.ItemsSource
    if ($visibleItems) {
        foreach ($i in $visibleItems) { $i.IsChecked = $true }
        $global:lstTarget.ItemsSource = $null
        $global:lstTarget.ItemsSource = $visibleItems
    }
    Update-Counts
})
$global:btnTargetNone.Add_Click({
    $visibleItems = $global:lstTarget.ItemsSource
    if ($visibleItems) {
        foreach ($i in $visibleItems) { $i.IsChecked = $false }
        $global:lstTarget.ItemsSource = $null
        $global:lstTarget.ItemsSource = $visibleItems
    }
    Update-Counts
})

$global:txtSourceSearch.Add_TextChanged({
    $has = [bool]$global:txtSourceSearch.Text
    if ($global:txtSourceSearchHint)  { $global:txtSourceSearchHint.Visibility  = if ($has -or $global:txtSourceSearch.IsFocused) { 'Collapsed' } else { 'Visible' } }
    if ($global:btnClearSourceSearch) { $global:btnClearSourceSearch.Visibility = if ($has) { 'Visible' } else { 'Collapsed' } }
    Apply-ListFilter -Side 'Source'
})
$global:txtTargetSearch.Add_TextChanged({
    $has = [bool]$global:txtTargetSearch.Text
    if ($global:txtTargetSearchHint)  { $global:txtTargetSearchHint.Visibility  = if ($has -or $global:txtTargetSearch.IsFocused) { 'Collapsed' } else { 'Visible' } }
    if ($global:btnClearTargetSearch) { $global:btnClearTargetSearch.Visibility = if ($has) { 'Visible' } else { 'Collapsed' } }
    Apply-ListFilter -Side 'Target'
})
$global:txtSourceFilter.Add_TextChanged({
    $has = [bool]$global:txtSourceFilter.Text
    if ($global:txtSourceFilterHint)  { $global:txtSourceFilterHint.Visibility  = if ($has) { 'Collapsed' } else { 'Visible' } }
    if ($global:btnClearSourceFilter) { $global:btnClearSourceFilter.Visibility = if ($has) { 'Visible' } else { 'Collapsed' } }
})
$global:txtTargetFilter.Add_TextChanged({
    $has = [bool]$global:txtTargetFilter.Text
    if ($global:txtTargetFilterHint)  { $global:txtTargetFilterHint.Visibility  = if ($has) { 'Collapsed' } else { 'Visible' } }
    if ($global:btnClearTargetFilter) { $global:btnClearTargetFilter.Visibility = if ($has) { 'Visible' } else { 'Collapsed' } }
})

# ── Clear buttons ────────────────────────────────────────────────────────────
if ($global:btnClearSourceFilter) { $global:btnClearSourceFilter.Add_Click({ $global:txtSourceFilter.Text = '' }) }
if ($global:btnClearTargetFilter) { $global:btnClearTargetFilter.Add_Click({ $global:txtTargetFilter.Text = '' }) }
if ($global:btnClearSourceSearch) { $global:btnClearSourceSearch.Add_Click({ $global:txtSourceSearch.Text = ''; Apply-ListFilter -Side 'Source' }) }
if ($global:btnClearTargetSearch) { $global:btnClearTargetSearch.Add_Click({ $global:txtTargetSearch.Text = ''; Apply-ListFilter -Side 'Target' }) }

# ── GotFocus/LostFocus for all filter hints ───────────────────────────────────
if ($global:txtSourceFilter) {
    $global:txtSourceFilter.Add_GotFocus({ if ($global:txtSourceFilterHint) { $global:txtSourceFilterHint.Visibility = 'Collapsed' } })
    $global:txtSourceFilter.Add_LostFocus({ if ($global:txtSourceFilterHint) { $global:txtSourceFilterHint.Visibility = if ($global:txtSourceFilter.Text) { 'Collapsed' } else { 'Visible' } } })
}
if ($global:txtTargetFilter) {
    $global:txtTargetFilter.Add_GotFocus({ if ($global:txtTargetFilterHint) { $global:txtTargetFilterHint.Visibility = 'Collapsed' } })
    $global:txtTargetFilter.Add_LostFocus({ if ($global:txtTargetFilterHint) { $global:txtTargetFilterHint.Visibility = if ($global:txtTargetFilter.Text) { 'Collapsed' } else { 'Visible' } } })
}
if ($global:txtSourceSearch) {
    $global:txtSourceSearch.Add_GotFocus({ if ($global:txtSourceSearchHint) { $global:txtSourceSearchHint.Visibility = 'Collapsed' } })
    $global:txtSourceSearch.Add_LostFocus({ if ($global:txtSourceSearchHint) { $global:txtSourceSearchHint.Visibility = if ($global:txtSourceSearch.Text) { 'Collapsed' } else { 'Visible' } } })
}
if ($global:txtTargetSearch) {
    $global:txtTargetSearch.Add_GotFocus({ if ($global:txtTargetSearchHint) { $global:txtTargetSearchHint.Visibility = 'Collapsed' } })
    $global:txtTargetSearch.Add_LostFocus({ if ($global:txtTargetSearchHint) { $global:txtTargetSearchHint.Visibility = if ($global:txtTargetSearch.Text) { 'Collapsed' } else { 'Visible' } } })
}

# ── Tenant dropdown changes ───────────────────────────────────────────────────
$global:cmbSourceTenant.Add_SelectionChanged({
    $newKey = if ($global:cmbSourceTenant.SelectedItem) { $global:cmbSourceTenant.SelectedItem.Tag } else { $null }
    if (-not $global:suppressEvents -and $newKey -ne $global:lastSourceTenantKey) { Reset-Side 'Source' }
    $global:lastSourceTenantKey = $newKey
    Update-ExportButtons
})
$global:cmbTargetTenant.Add_SelectionChanged({
    $newKey = if ($global:cmbTargetTenant.SelectedItem) { $global:cmbTargetTenant.SelectedItem.Tag } else { $null }
    if (-not $global:suppressEvents -and $newKey -ne $global:lastTargetTenantKey) { Reset-Side 'Target' }
    $global:lastTargetTenantKey = $newKey
    Update-ExportButtons
})

# ═════════════════════════════════════════════════════════════════════════════
# CONFIGURATION WINDOW
# ═════════════════════════════════════════════════════════════════════════════
function Open-ConfigWindow {
    $cfgWindow = Load-Xaml -Path "$ScriptRoot\UI\BasetuneConfig.xaml" -Width 820 -Height 600
    $cfgWindow.Owner = $global:window

    function CFind { param([string]$n) Find-InTree -Root $cfgWindow -Name $n }

    # Wire config controls from the new window
    $global:lstTenants              = CFind 'lstTenants'
    $global:btnAddTenant            = CFind 'btnAddTenant'
    $global:btnRemoveTenant         = CFind 'btnRemoveTenant'
    $global:btnSaveConfig           = CFind 'btnSaveConfig'
    $global:lblConnectionStatus     = CFind 'lblConnectionStatus'
    $global:pnlTenantForm           = CFind 'pnlTenantForm'
    $global:pnlDefaultPaths         = CFind 'pnlDefaultPaths'
    $global:cfgTenantDisplayName    = CFind 'cfgTenantDisplayName'
    $global:cfgTenantAuthMethod     = CFind 'cfgTenantAuthMethod'
    $global:cfgTenantTenantId       = CFind 'cfgTenantTenantId'
    $global:cfgTenantClientId       = CFind 'cfgTenantClientId'
    $global:cfgTenantClientSecret   = CFind 'cfgTenantClientSecret'        # PasswordBox (masked)
    $global:cfgTenantClientSecretShown = CFind 'cfgTenantClientSecretShown'  # TextBox (revealed)
    $global:btnRevealSecret         = CFind 'btnRevealSecret'
    $global:iconEyeOpen             = CFind 'iconEyeOpen'                  # SVG path, eye open
    $global:iconEyeOff              = CFind 'iconEyeOff'                   # SVG path, eye crossed-out
    $global:cfgTenantCertThumbprint = CFind 'cfgTenantCertThumbprint'
    $global:cfgTenantPath           = CFind 'cfgTenantPath'
    $global:pnlTenantPath           = CFind 'pnlTenantPath'
    $global:pnlCredential           = CFind 'pnlCredential'
    $global:btnBrowseTenantPath     = CFind 'btnBrowseTenantPath'
    $global:lblTenantSecret         = CFind 'lblTenantSecret'
    $global:lblTenantThumb          = CFind 'lblTenantThumb'
    $global:pnlTenantId             = CFind 'pnlTenantId'
    $global:pnlClientId             = CFind 'pnlClientId'
    $global:btnTitleClose           = CFind 'btnTitleClose'
    $titleBar                       = CFind 'titleBar'

    # Required label controls — used by Commit-TenantForm to show inline errors
    $global:requiredLabels = @{
        DisplayName  = CFind 'reqDisplayName'
        TenantId     = CFind 'reqTenantId'
        ClientId     = CFind 'reqClientId'
        ClientSecret = CFind 'reqClientSecret'
        CertThumb    = CFind 'reqCertThumb'
        JsonPath     = CFind 'reqJsonPath'
    }

    # Restore saved default path into the greyed-out field

    # ── Unsaved changes tracking ────────────────────────────────────────────────────────
    $script:hasUnsavedChanges = $false
    function Set-UnsavedChanges {
        $script:hasUnsavedChanges = $true
        if ($global:btnSaveConfig) { $global:btnSaveConfig.IsEnabled = $true }
    }
    function Clear-UnsavedChanges {
        $script:hasUnsavedChanges = $false
        if ($global:btnSaveConfig) { $global:btnSaveConfig.IsEnabled = $false }
    }

    # Always start in greyed-out state; user selects a tenant from the dropdown
    Update-ConfigDropdowns
    Clear-TenantSelection

    # Title bar drag + close
    if ($titleBar)             { $titleBar.Add_MouseLeftButtonDown({ $cfgWindow.DragMove() }) }
    if ($global:btnTitleClose) { $global:btnTitleClose.Add_Click({ $cfgWindow.Close() }) }

    # ── Event wiring ──────────────────────────────────────────────────────────
    $global:cfgTenantAuthMethod.Add_SelectionChanged({
        Update-TenantAuthFields
        if (-not $global:suppressEvents) { Set-UnsavedChanges }
    })

    $global:btnBrowseTenantPath.Add_Click({
        $p = Show-FolderBrowser -InitialPath $global:cfgTenantPath.Text.Trim() -Owner $cfgWindow
        if ($p) { $global:cfgTenantPath.Text = $p; Set-UnsavedChanges }
    })

    foreach ($ctrl in @(
        $global:cfgTenantDisplayName, $global:cfgTenantTenantId,
        $global:cfgTenantClientId, $global:cfgTenantPath,
        $global:cfgTenantCertThumbprint
    )) { if ($ctrl) { $ctrl.Add_TextChanged({ if (-not $global:suppressEvents) { Set-UnsavedChanges } }) } }

    # PasswordBox uses PasswordChanged (no TextChanged); the paired reveal-
    # TextBox uses TextChanged. Mark unsaved on either path. Also mirror
    # the live edit to the OTHER control so revealing/hiding doesn't lose
    # whatever the user just typed.
    if ($global:cfgTenantClientSecret) {
        $global:cfgTenantClientSecret.Add_PasswordChanged({
            if ($global:suppressEvents) { return }
            # Mirror to the revealed TextBox so a later reveal-toggle shows
            # the same value the user is currently typing in the masked box.
            if ($global:cfgTenantClientSecretShown) {
                $global:suppressEvents = $true
                try { $global:cfgTenantClientSecretShown.Text = $global:cfgTenantClientSecret.Password }
                finally { $global:suppressEvents = $false }
            }
            Set-UnsavedChanges
        })
    }
    if ($global:cfgTenantClientSecretShown) {
        $global:cfgTenantClientSecretShown.Add_TextChanged({
            if ($global:suppressEvents) { return }
            # Mirror back to the PasswordBox so hiding doesn't lose the edit.
            if ($global:cfgTenantClientSecret) {
                $global:suppressEvents = $true
                try { $global:cfgTenantClientSecret.Password = $global:cfgTenantClientSecretShown.Text }
                finally { $global:suppressEvents = $false }
            }
            Set-UnsavedChanges
        })
    }

    # Reveal-toggle: swap visibility between the masked PasswordBox and the
    # plain TextBox. Inline SVG paths are toggled instead of a font glyph —
    # see iconEyeOpen / iconEyeOff in BasetuneConfig.xaml.
    if ($global:btnRevealSecret) {
        $global:btnRevealSecret.Add_Click({
            if (-not $global:cfgTenantClientSecret -or -not $global:cfgTenantClientSecretShown) { return }
            $isShown = $global:cfgTenantClientSecretShown.Visibility -eq 'Visible'
            if ($isShown) {
                # Hide: copy back to PasswordBox, show masked
                $global:suppressEvents = $true
                try {
                    $global:cfgTenantClientSecret.Password = $global:cfgTenantClientSecretShown.Text
                } finally { $global:suppressEvents = $false }
                $global:cfgTenantClientSecretShown.Visibility = 'Collapsed'
                $global:cfgTenantClientSecret.Visibility      = 'Visible'
                if ($global:iconEyeOpen) { $global:iconEyeOpen.Visibility = 'Visible' }
                if ($global:iconEyeOff)  { $global:iconEyeOff.Visibility  = 'Collapsed' }
            } else {
                # Show: copy from PasswordBox, show plain TextBox
                $global:suppressEvents = $true
                try {
                    $global:cfgTenantClientSecretShown.Text = $global:cfgTenantClientSecret.Password
                } finally { $global:suppressEvents = $false }
                $global:cfgTenantClientSecret.Visibility      = 'Collapsed'
                $global:cfgTenantClientSecretShown.Visibility = 'Visible'
                if ($global:iconEyeOpen) { $global:iconEyeOpen.Visibility = 'Collapsed' }
                if ($global:iconEyeOff)  { $global:iconEyeOff.Visibility  = 'Visible' }
            }
        })
    }

    $global:cfgTenantDisplayName.Add_TextChanged({
        if (-not $global:suppressEvents) { Set-UnsavedChanges }
        $txt = $global:cfgTenantDisplayName.Text
        if ($txt -match '[\\/:*?"<>|]') {
            $global:cfgTenantDisplayName.BorderBrush = [System.Windows.Media.Brushes]::Red
            $global:cfgTenantDisplayName.ToolTip     = 'Invalid characters: \ / : * ? " < > |'
        } else {
            $global:cfgTenantDisplayName.BorderBrush =
                [System.Windows.Media.SolidColorBrush]::new(
                    [System.Windows.Media.Color]::FromRgb(0xDD, 0xE2, 0xEA))
            $global:cfgTenantDisplayName.ToolTip = $null
        }
    })

    $global:lstTenants.Add_SelectionChanged({
        if ($global:suppressEvents) { return }
        $sel = $global:lstTenants.SelectedItem
        if (-not $sel) { return }
        $key = $sel.Tag
        $node = $global:tenantStore[$key]
        if (-not $node) { return }
        $global:suppressEvents = $true
        $global:editingTenantKey       = $key
        $global:cfgTenantDisplayName.Text    = if ($node.displayName)    { $node.displayName    } else { '' }
        $global:cfgTenantTenantId.Text = if ($node.tenantId) { $node.tenantId } else { '' }
        $global:cfgTenantClientId.Text = if ($node.clientId) { $node.clientId } else { '' }
        # Handle both Hashtable (ordered) and PSCustomObject nodes for the path property
        $nodePath = if ($node -is [System.Collections.IDictionary]) {
            if ($node.Contains('path') -and $node['path']) { $node['path'] } else { '' }
        } else {
            if ($node.PSObject.Properties['path'] -and $node.path) { $node.path } else { '' }
        }
        $global:cfgTenantPath.Text = $nodePath
        $global:cfgTenantAuthMethod.SelectedIndex = switch ($node.authMethod) {
            'Certificate' { 1 }; 'None' { 2 }; default { 0 }
        }
        Update-TenantAuthFields
        if ($node.authMethod -eq 'Certificate') {
            $global:cfgTenantCertThumbprint.Text   = if ($node -is [System.Collections.IDictionary]) {
                if ($node.Contains('certThumbprint') -and $node['certThumbprint']) { $node['certThumbprint'] } else { '' }
            } else {
                if ($node.certThumbprint) { $node.certThumbprint } else { '' }
            }
        } else {
            # Pre-fill the secret into BOTH dual-control sides. The
            # PasswordBox is what the user sees by default; the TextBox is
            # the revealed alternate.
            #
            # The store holds the secret ENCRYPTED; it is decrypted here, only
            # for the tenant that was just selected, and only into the form
            # controls. If it cannot be decrypted (other Windows user or PC)
            # the field stays empty so a new secret can be entered.
            $storedSecret = if ($node -is [System.Collections.IDictionary]) {
                if ($node.Contains('clientSecret') -and $node['clientSecret']) { $node['clientSecret'] } else { '' }
            } else {
                if ($node.PSObject.Properties['clientSecret'] -and $node.clientSecret) { $node.clientSecret } else { '' }
            }
            $secretValue = ''
            if ($storedSecret) {
                $secretValue = Unprotect-Secret ([string]$storedSecret)
                if ($null -eq $secretValue) {
                    $secretValue = ''
                    $lblName = if ($node.displayName) { $node.displayName } else { $key }
                    Write-Log 'Config' "Cannot decrypt the clientSecret for '$lblName' (encrypted by another Windows user or on another PC). Enter the secret again." 'ERROR'
                }
            }
            if ($global:cfgTenantClientSecret)      { $global:cfgTenantClientSecret.Password = $secretValue }
            if ($global:cfgTenantClientSecretShown) { $global:cfgTenantClientSecretShown.Text = $secretValue }
            # Reset reveal-state to masked whenever we load a different tenant.
            if ($global:cfgTenantClientSecret)      { $global:cfgTenantClientSecret.Visibility      = 'Visible' }
            if ($global:cfgTenantClientSecretShown) { $global:cfgTenantClientSecretShown.Visibility = 'Collapsed' }
            if ($global:iconEyeOpen)                { $global:iconEyeOpen.Visibility = 'Visible' }
            if ($global:iconEyeOff)                 { $global:iconEyeOff.Visibility  = 'Collapsed' }
        }
        $global:suppressEvents = $false
        Show-TenantForm
    })

    $global:btnAddTenant.Add_Click({ Start-AddTenant })

    $global:btnRemoveTenant.Add_Click({
        $sel = $global:lstTenants.SelectedItem
        if (-not $sel) { return }
        $key = $sel.Tag
        $global:tenantStore.Remove($key)
        if ($global:editingTenantKey -eq $key) { $global:editingTenantKey = $null }
        Update-ConfigDropdowns
        Clear-TenantSelection
        Set-UnsavedChanges
    })


    $global:btnSaveConfig.Add_Click({
        if (-not (Commit-TenantForm)) { return }

        # ── Connection test (sync) ──────────────────────────────────────────
        # Runs BEFORE Save-Config writes to disk. The just-committed tenant
        # lives in $global:tenantStore[$editingTenantKey] with its secret
        # encrypted; New-GraphConnection decrypts it just-in-time.
        #
        # Sync (not runspace) because Tenant Configuration is a modal dialog:
        # blocking the dialog during the 2-5 second token request is the
        # desired behaviour (user can't poke other controls mid-test).
        #
        # On failure we still proceed with Save-Config — the user might be
        # offline, or have just mis-typed and want to come back later. The
        # log + label make it clear the credentials didn't verify.
        $testKey  = $global:editingTenantKey
        $testNode = if ($testKey) { $global:tenantStore[$testKey] } else { $null }
        $shouldTest = ($testNode -and $testNode.authMethod -ne 'None' -and $testNode.authMethod)
        $testPassed = $true   # Default true so offline-only tenants don't trigger a failure UI

        if ($shouldTest) {
            $tenantLabel = if ($testNode.displayName) { $testNode.displayName } else { $testKey }
            if ($global:lblConnectionStatus) {
                $global:lblConnectionStatus.Foreground = [System.Windows.Media.Brushes]::Gray
                $global:lblConnectionStatus.Text       = "Testing connection..."
                # Force WPF to paint the label change before the token call
                # blocks the UI thread. Without this, the user sees the old
                # label until the test completes — defeating the "I see it's
                # working" purpose.
                $global:lblConnectionStatus.Dispatcher.Invoke(
                    [System.Windows.Threading.DispatcherPriority]::Render,
                    [System.Action]{}
                )
            }
            # No button-disable needed: the sync token call blocks the UI
            # thread, so click events on Save/Close/AddTenant queue up but
            # don't fire until this handler returns. The dialog feels "busy"
            # because it actually IS busy.
            $conn = $null
            try { $conn = New-GraphConnection -Config $testNode -Label 'Config' } catch {}

            $testPassed = ($null -ne $conn)

            if ($global:lblConnectionStatus) {
                if ($testPassed) {
                    $global:lblConnectionStatus.Foreground = [System.Windows.Media.Brushes]::Green
                    $global:lblConnectionStatus.Text       = "Connection successful"
                } else {
                    $global:lblConnectionStatus.Foreground = [System.Windows.Media.Brushes]::Red
                    $global:lblConnectionStatus.Text       = "Connection failed"
                }
            }
            if ($testPassed) {
                Write-Log 'Config' "Connection verified for '$tenantLabel'." 'OK'
            } else {
                Write-Log 'Config' "Connection failed for '$tenantLabel'. Saving anyway — re-check the credentials." 'WARN'
            }
        } else {
            # Offline-only tenant (or no tenant selected) — clear any stale
            # status from a previous save attempt.
            if ($global:lblConnectionStatus) { $global:lblConnectionStatus.Text = '' }
        }

        try {
            Save-Config

            $savedKey   = $global:editingTenantKey
            $prevSrcTag = if ($global:cmbSourceTenant.SelectedItem) { $global:cmbSourceTenant.SelectedItem.Tag } else { '' }
            $prevTgtTag = if ($global:cmbTargetTenant.SelectedItem) { $global:cmbTargetTenant.SelectedItem.Tag } else { '' }
            $global:suppressEvents = $true
            Load-ConfigUI
            Sync-MainTenantDropdowns -PreferSrcTag $prevSrcTag -PreferTgtTag $prevTgtTag
            $global:suppressEvents = $false
            $global:lastSourceTenantKey = if ($global:cmbSourceTenant.SelectedItem) { $global:cmbSourceTenant.SelectedItem.Tag } else { $null }
            $global:lastTargetTenantKey = if ($global:cmbTargetTenant.SelectedItem) { $global:cmbTargetTenant.SelectedItem.Tag } else { $null }
            Update-ExportButtons
            Clear-UnsavedChanges
            if ($savedKey) {
                $global:suppressEvents = $true
                foreach ($item in $global:lstTenants.Items) {
                    if ($item.Tag -eq $savedKey) { $global:lstTenants.SelectedItem = $item; break }
                }
                $global:suppressEvents = $false
                $node = $global:tenantStore[$savedKey]
                $lbl  = if ($node -and $node.displayName) { $node.displayName } else { $savedKey }
                Show-TenantForm   # no -IsNew: shows Remove button for the saved tenant
            } else {
                Clear-TenantSelection
            }
        } catch {
            # Used to be swallowed silently: the user believed the config was
            # saved while Config.json was never written (e.g. file locked by sync).
            $global:suppressEvents = $false
            $global:btnSaveConfig.IsEnabled = $true
            Write-Log 'Config' "Saving Config.json failed: $($_.Exception.Message)" 'ERROR'
            [System.Windows.MessageBox]::Show("Saving the configuration failed:`n$($_.Exception.Message)", "Basetune", 'OK', 'Error') | Out-Null
        }
    })

    $btnClose = CFind 'btnCloseConfig'
    if ($btnClose) { $btnClose.Add_Click({ $cfgWindow.Close() }) }

    $cfgWindow.Add_Closed({
        $prevSrcTag = if ($global:cmbSourceTenant.SelectedItem) { $global:cmbSourceTenant.SelectedItem.Tag } else { '' }
        $prevTgtTag = if ($global:cmbTargetTenant.SelectedItem) { $global:cmbTargetTenant.SelectedItem.Tag } else { '' }
        Load-ConfigUI
        $global:suppressEvents = $true
        Sync-MainTenantDropdowns -PreferSrcTag $prevSrcTag -PreferTgtTag $prevTgtTag
        $global:suppressEvents = $false
        $global:lastSourceTenantKey = if ($global:cmbSourceTenant.SelectedItem) { $global:cmbSourceTenant.SelectedItem.Tag } else { $null }
        $global:lastTargetTenantKey = if ($global:cmbTargetTenant.SelectedItem) { $global:cmbTargetTenant.SelectedItem.Tag } else { $null }
        Update-ExportButtons
    })

    $cfgWindow.Add_KeyDown({ param($s,$e); if ($e.Key -eq 'Escape') { $cfgWindow.Close() } })
    $cfgWindow.ShowDialog() | Out-Null
}

$global:btnOpenConfig.Add_Click({ Open-ConfigWindow })

# ═════════════════════════════════════════════════════════════════════════════
# SETTINGS WINDOW
# ═════════════════════════════════════════════════════════════════════════════
function Open-OptionsWindow {
    $sWindow = Load-Xaml -Path "$ScriptRoot\UI\BasetuneOptions.xaml" -Width 520 -Height 400
    $sWindow.Owner = $global:window

    function SFind { param([string]$n) Find-InTree -Root $sWindow -Name $n }

    $sTitleBar         = SFind 'titleBar'
    $sBtnClose         = SFind 'btnTitleClose'
    $sBtnCloseSettings = SFind 'btnCloseSettings'
    $sBtnSave          = SFind 'btnSaveSettings'
    $sTxtMaxThreads    = SFind 'txtMaxThreads'
    $sTxtPathReport    = SFind 'cfgPathReport'
    $sBtnBrowseReport  = SFind 'btnBrowsePathReport'

    # Populate with current saved values
    if (-not $global:savedMaxThreads)  { $global:savedMaxThreads  = '8' }
    if (-not $global:savedPathReport)  { $global:savedPathReport  = Get-DefaultPathReport }
    if ($sTxtMaxThreads)   { $sTxtMaxThreads.Text  = $global:savedMaxThreads }
    if ($sTxtPathReport)   { $sTxtPathReport.Text   = $global:savedPathReport }

    # Snapshot original values so we can enable Save Settings only when the
    # user actually changes something. Anything else (re-opening with the
    # same path, switching focus, etc.) keeps Save Settings disabled.
    $script:originalMaxThreads = if ($sTxtMaxThreads) { $sTxtMaxThreads.Text } else { '' }
    $script:originalPathReport = if ($sTxtPathReport) { $sTxtPathReport.Text } else { '' }

    # Save Settings is enabled only when something changed AND Max threads is
    # a whole number in the allowed range (1..32). An invalid value keeps the
    # button disabled and marks the field red with a tooltip — no popup.
    $mtRange       = Get-MaxThreadsRange
    $updateSaveState = {
        if (-not $sBtnSave) { return }
        $mtNow   = if ($sTxtMaxThreads) { $sTxtMaxThreads.Text } else { '' }
        $pathNow = if ($sTxtPathReport) { $sTxtPathReport.Text } else { '' }
        $mtValid = (-not $sTxtMaxThreads) -or (Test-MaxThreadsValue $mtNow)

        if ($sTxtMaxThreads) {
            if ($mtValid) {
                # ClearValue instead of re-assigning the old brush, so style
                # triggers (focus/hover border) keep working.
                $sTxtMaxThreads.ClearValue([System.Windows.Controls.Control]::BorderBrushProperty)
                $sTxtMaxThreads.ToolTip     = $null
            } else {
                $sTxtMaxThreads.BorderBrush = [System.Windows.Media.Brushes]::Red
                $sTxtMaxThreads.ToolTip     = "Enter a whole number from $($mtRange.Min) to $($mtRange.Max)."
            }
        }

        # Report path: empty = default Reports folder; otherwise it must be a
        # valid full path. The folder does not have to exist yet (Save offers
        # to create it). Same red-border + tooltip pattern as Max threads.
        $pathValid = $true
        if ($sTxtPathReport) {
            $pathErr = if ($pathNow.Trim()) { (Resolve-FolderPath -Path $pathNow -RequireAbsolute).Error } else { $null }
            $pathValid = -not $pathErr
            if ($pathValid) {
                $sTxtPathReport.ClearValue([System.Windows.Controls.Control]::BorderBrushProperty)
                $sTxtPathReport.ToolTip     = $null
            } else {
                $sTxtPathReport.BorderBrush = [System.Windows.Media.Brushes]::Red
                $sTxtPathReport.ToolTip     = $pathErr
            }
        }

        $changed = ($mtNow -ne $script:originalMaxThreads) -or ($pathNow -ne $script:originalPathReport)
        $sBtnSave.IsEnabled = $changed -and $mtValid -and $pathValid
    }

    if ($sTxtMaxThreads) { $sTxtMaxThreads.Add_TextChanged($updateSaveState) }
    if ($sTxtPathReport) { $sTxtPathReport.Add_TextChanged($updateSaveState) }

    if ($sTitleBar)  { $sTitleBar.Add_MouseLeftButtonDown({ $sWindow.DragMove() }) }
    if ($sBtnClose)  { $sBtnClose.Add_Click({ $sWindow.Close() }) }
    if ($sBtnCloseSettings) { $sBtnCloseSettings.Add_Click({ $sWindow.Close() }) }

    if ($sBtnBrowseReport) {
        $sBtnBrowseReport.Add_Click({
            $start = if ($sTxtPathReport) { $sTxtPathReport.Text.Trim() } else { '' }
            $p = Show-FolderBrowser -InitialPath $start -Owner $sWindow
            if ($p -and $sTxtPathReport) { $sTxtPathReport.Text = $p }
        })
    }

    if ($sBtnSave) {
        $sBtnSave.Add_Click({
            # Validate report path (safety net: Save is already disabled while
            # the path is invalid). Stored normalized: C:\Reports\ -> C:\Reports.
            $reportPathInput = $null
            if ($sTxtPathReport -and $sTxtPathReport.Text.Trim()) {
                $rp = Resolve-FolderPath -Path $sTxtPathReport.Text -RequireAbsolute
                if ($rp.Error) {
                    [System.Windows.MessageBox]::Show("Report path is not valid.`n`n$($rp.Error)", "Basetune", 'OK', 'Warning') | Out-Null
                    return
                }
                $reportPathInput = $rp.Path
            }
            # A valid folder that does not exist yet is allowed: ask, then create.
            if ($reportPathInput -and -not (Test-Path -LiteralPath $reportPathInput -PathType Container)) {
                if (Test-Path -LiteralPath $reportPathInput) {
                    [System.Windows.MessageBox]::Show("Report path '$reportPathInput' is a file, not a folder.", "Basetune", 'OK', 'Warning') | Out-Null
                    return
                }
                $ans = [System.Windows.MessageBox]::Show("Folder '$reportPathInput' does not exist.`n`nCreate it now?", "Basetune", 'YesNo', 'Question')
                if ($ans -ne 'Yes') { return }
                try { New-Item -ItemType Directory -Path $reportPathInput -Force -ErrorAction Stop | Out-Null } catch {
                    [System.Windows.MessageBox]::Show("Cannot create report folder '$reportPathInput'.`n`n$($_.Exception.Message)", "Basetune", 'OK', 'Warning') | Out-Null
                    return
                }
            }

            # Safety net only: Save is already disabled while Max threads is invalid.
            $mtRange = Get-MaxThreadsRange
            if ($sTxtMaxThreads -and -not (Test-MaxThreadsValue $sTxtMaxThreads.Text)) { return }

            # Persist values
            $global:savedMaxThreads = if ($sTxtMaxThreads) { "$([int]$sTxtMaxThreads.Text.Trim())" } else { "$($mtRange.Default)" }
            $global:savedPathReport = if ($reportPathInput) { $reportPathInput } else { Get-DefaultPathReport }

            # Write to Config.json
            try {
                Save-Config
                # Apply the new report path immediately so the next run uses it.
                $global:reportBasePath = if ($global:savedPathReport -and $global:savedPathReport.Trim()) {
                    $global:savedPathReport.Trim()
                } else {
                    Get-DefaultPathReport
                }
                # Show the normalized path (e.g. trailing '\' removed).
                if ($sTxtPathReport -and $reportPathInput) { $sTxtPathReport.Text = $reportPathInput }
                # Update the snapshot so Save Settings becomes disabled again
                # until the user makes another change. Window stays open.
                $script:originalMaxThreads = if ($sTxtMaxThreads) { $sTxtMaxThreads.Text } else { '' }
                $script:originalPathReport = if ($sTxtPathReport) { $sTxtPathReport.Text } else { '' }
                $sBtnSave.IsEnabled = $false
            } catch {
                [System.Windows.MessageBox]::Show("Error saving settings: $_", "Basetune", 'OK', 'Error') | Out-Null
            }
        })
    }

    $sWindow.Add_KeyDown({ param($s,$e); if ($e.Key -eq 'Escape') { $sWindow.Close() } })
    $sWindow.ShowDialog() | Out-Null
}

$global:btnOpenOptions.Add_Click({ Open-OptionsWindow })

# ═════════════════════════════════════════════════════════════════════════════
# STARTUP
# ═════════════════════════════════════════════════════════════════════════════
$global:savedMaxThreads = '8'
$global:savedPathReport = $global:reportBasePath   # default; Load-ConfigUI overschrijft als config een pad heeft

Load-ConfigUI
Set-LoadButtonHover $global:btnSourceLoad 'load'
Set-LoadButtonHover $global:btnTargetLoad 'load'
$global:suppressEvents = $true
Sync-MainTenantDropdowns
$global:suppressEvents = $false
$global:lastSourceTenantKey = if ($global:cmbSourceTenant.SelectedItem) { $global:cmbSourceTenant.SelectedItem.Tag } else { $null }
$global:lastTargetTenantKey = if ($global:cmbTargetTenant.SelectedItem) { $global:cmbTargetTenant.SelectedItem.Tag } else { $null }
Update-ExportButtons

$global:window.Add_Loaded({
    $defsFile    = "$($global:definitionsPath)\settingDefinitions.json"
    $catsFile    = "$($global:definitionsPath)\settingCategories.json"
    $missingDefs = -not (Test-Path $defsFile)
    $missingCats = -not (Test-Path $catsFile)

    $msg = if ($missingDefs -and $missingCats) {
        'Setting definitions and categories not found. Click Download.'
    } elseif ($missingDefs) {
        'Setting definitions not found. Click Download.'
    } elseif ($missingCats) {
        'Setting categories not found. Click Download.'
    } else { $null }

    if ($msg) {
        # Strip the XAML placeholder ("Load source and target policies to get
        # started.") if it's still there, but PRESERVE any real log lines that
        # were appended during startup — most importantly the WARN/ERROR
        # messages emitted by Get-GraphConfig during plaintext->DPAPI migration
        # or decrypt failures. Using Clear-UILog here would wipe those.
        $placeholder = 'Load source and target policies to get started.'
        $current     = $global:txtLog.Text
        if ($current.StartsWith($placeholder)) {
            # Drop the placeholder; keep anything appended after it.
            $current = $current.Substring($placeholder.Length).TrimStart("`r", "`n")
            $global:txtLog.Text = $current
        }
        # Append the definitions notice using the same path as runtime logs,
        # so it lands in BasetuneUI.log on disk as well.
        Write-UILog $msg
    }

    # Show "Download Definitions" label if either file is missing.
    Update-DownloadButton
})

# ── Bring window to the foreground on startup ────────────────────────────────
# When launched from a CMD/PowerShell window (especially via Start-BasetuneUI),
# the new WPF window can end up BEHIND the parent console — easy to miss.
# Trick: set Topmost=True just before ShowDialog so the OS raises it above
# everything, then drop Topmost after a short delay so it behaves like any
# normal window from that point on. The delay is long enough for the window
# to actually appear on top, short enough that it never gets in the user's
# way if they immediately switch to another app.
$global:window.Topmost = $true
$global:topmostTimer = New-Object System.Windows.Threading.DispatcherTimer
$global:topmostTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$global:topmostTimer.Add_Tick({
    $global:window.Topmost = $false
    $global:topmostTimer.Stop()
})
$global:topmostTimer.Start()

$global:window.ShowDialog() | Out-Null
