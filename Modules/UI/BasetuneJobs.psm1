# =============================================================================
# BasetuneJobs.psm1
# Background job engine: Start-Runspace / Stop-ActiveRunspace (one job at a
# time, see $AppState.CurrentJob), cancel cleanup, deferred memory cleanup and
# the network watcher. $UI / $AppState come from BasetuneState.psm1.
# =============================================================================

$script:UI       = (Get-BasetuneContext).UI
$script:AppState = (Get-BasetuneContext).State

# ── Win32 trim-working-set helper ─────────────────────────────────────────────
# After a forced GC Windows still keeps the freed pages in the working set
# (Task Manager "Memory"), although .NET no longer needs them.
# SetProcessWorkingSetSize(-1, -1) trims it to what is live right away instead
# of minutes later; the address space stays mapped.
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
# Compare allocates a lot (flat setting arrays, resolved diffs, HTML). A forced,
# compacting gen2 collect gives it back but blocks every thread, so it is
# queued at ApplicationIdle (after WPF has drawn the result) and skipped when
# another job has started meanwhile.
function Request-DeferredMemoryCleanup {
    $UI.Window.Dispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::ApplicationIdle,
        [System.Action]{
            if ($AppState.CurrentJob) { return }
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
# A request in flight when the network drops only fails after its timeout
# (30 s without data). While a Load or Download runs, this checks the network
# every 2 s and logs at once when it goes away (and comes back). It only
# informs; the requests still time out and are retried/reported as usual.
#
# "Up" = an active, non-loopback, non-tunnel adapter with a default gateway.
# Virtual adapters without a gateway (Hyper-V switches etc.) don't count, so
# switching Wi-Fi off is noticed.
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

# ═════════════════════════════════════════════════════════════════════════════
# RUNSPACE ENGINE
#
# Runs $Work in a background runspace with $Shared and a ConcurrentQueue
# $LogQueue; a DispatcherTimer streams the queued log entries into the UI and
# calls $OnDone when the job ends.
#
# $Shared always gets a common base (ScriptRoot, GraphBeta, ModulesPath,
# defsPath, LogFile); callers add only their own fields (Load: TenantNode +
# Filter, Compare: reportDir/reportFile + the def caches).
# ═════════════════════════════════════════════════════════════════════════════
function Start-Runspace {
    param(
        [Parameter(Mandatory)][scriptblock]$Work,
        [Parameter(Mandatory)][scriptblock]$OnDone,
        [hashtable]$Shared  = @{},
        [hashtable]$Context = @{}    # Job-specific fields merged into $AppState.CurrentJob
                                     # (e.g. Type/Side/LoadItems/LoadOrigin). Merged BEFORE
                                     # the timer starts so OnDone always sees a complete job.
    )

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()

    # Common base merged into every runspace. Caller's $Shared wins on collisions.
    $base = @{
        ScriptRoot  = $AppState.ScriptRoot
        GraphBeta   = $AppState.GraphBeta
        ModulesPath = $AppState.ModulesPath
        defsPath    = $AppState.definitionsPath
        LogFile     = $AppState.logFile   # runspaces have their own $script:LogFile=$null
                                        # on import; $work passes it to Set-RunspaceLogging
    }
    foreach ($k in $base.Keys) {
        if (-not $Shared.ContainsKey($k)) { $Shared[$k] = $base[$k] }
    }

    $rs.SessionStateProxy.SetVariable('Shared', $Shared)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs

    $queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $rs.SessionStateProxy.SetVariable('LogQueue', $queue)

    $ps.AddScript($Work) | Out-Null
    $handle = $ps.BeginInvoke()

    # Job context: the plumbing fields are set here, $Context adds the
    # job-specific ones (Type, Side, LoadItems, LoadOrigin, ...).
    # Set-Busy $true already created a CurrentJob stub (IsBusy + Side): merge
    # into it so IsBusy survives; without a stub (defensive) start a new one.
    $job = if ($AppState.CurrentJob) { $AppState.CurrentJob } else { @{ IsBusy = $true } }
    $job.Runspace = $rs
    $job.PS       = $ps
    $job.Handle   = $handle
    $job.Queue    = $queue
    $job.OnDone   = $OnDone
    $job.Done     = $false
    $job.Timer    = $null
    $job.Output   = @()
    foreach ($k in $Context.Keys) { $job[$k] = $Context[$k] }
    $AppState.CurrentJob = $job

    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    # 100 ms: the end of a job is picked up on average 50 ms after it; a tick
    # with an empty queue costs next to nothing.
    $timer.Interval = [TimeSpan]::FromMilliseconds(100)
    $timer.Add_Tick({
        # Guard: if Stop-ActiveRunspace ran, CurrentJob is $null. Bail.
        $job = $AppState.CurrentJob
        if (-not $job) { return }

        # Drain up to $maxPerTick log entries into one batch and add them in
        # one call: each call is a layout pass, and a noisy export can queue
        # thousands of lines. The cap keeps the UI thread responsive; the rest
        # waits for the next tick (nothing is lost). At job end the drain is
        # uncapped so OnDone sees the full log.
        $maxPerTick = 500
        $batch      = [System.Collections.Generic.List[object]]::new()
        $item       = $null
        while ($batch.Count -lt $maxPerTick -and $job.Queue.TryDequeue([ref]$item)) {
            $batch.Add($item)
        }
        if ($batch.Count -gt 0) {
            # Add-UILogLines also trims the view to a rolling window of lines.
            Add-UILogLines $batch.ToArray()
        }

        if (-not $job.Done -and $job.Handle.IsCompleted) {
            $job.Done = $true
            $job.Timer.Stop()
            # Final drain: uncapped, one batch, so OnDone logs after a complete log.
            $batch = [System.Collections.Generic.List[object]]::new()
            $item  = $null
            while ($job.Queue.TryDequeue([ref]$item)) {
                $batch.Add($item)
            }
            if ($batch.Count -gt 0) {
                Add-UILogLines $batch.ToArray()
            }
            # EndInvoke() returns the pipeline output (capture before Dispose);
            # OnDone reads it from $AppState.CurrentJob.Output.
            # A terminating error makes EndInvoke throw; non-terminating ones are
            # in PS.Streams.Error. Both are collected on $job.Errors and logged,
            # so OnDone can report a failed job as failed.
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
                # One line in the log view; the errors themselves only in the log file.
                Write-UILog $jobLabel "Unexpected error. See Basetune.log for details" 'ERROR'
                foreach ($m in $job.Errors) {
                    Write-Log $jobLabel "Details: $m" 'ERROR' -FileOnly
                }
            }
            # Dispose the pipeline + runspace after OnDone, when the UI is idle:
            # closing a runspace takes a moment and would delay OnDone (Run
            # Report still disabled after "Saved ...Report.html" is logged).
            $doneJobPS = $job.PS
            $doneJobRs = $job.Runspace
            # OnDone snapshots $AppState.CurrentJob, then calls Set-Busy $false
            # (which nulls it). The finally also clears the job when OnDone
            # throws first, so the UI never stays busy.
            # The heavy references on $job are nulled so the timer closure does
            # not keep output / queue / runspace alive; WPF triggers no gen2 GC
            # on its own between clicks.
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
                $AppState.CurrentJob = $null

                $toDispose = @($doneJobPS, $doneJobRs)
                [void]$UI.Window.Dispatcher.BeginInvoke(
                    [System.Windows.Threading.DispatcherPriority]::ApplicationIdle,
                    [System.Action]{ foreach ($d in $toDispose) { if ($d) { try { $d.Dispose() } catch {} } } }.GetNewClosure())

                # Compare/Load make the largest allocations: drop the
                # references that still hold them ($Error, the log batch).
                if ($jobType -in @('Compare','Load')) {
                    $Error.Clear()
                    $batch = $null
                }
                # Full GC only after Compare (Load allocates little), and only
                # when the UI is idle (Request-DeferredMemoryCleanup): run here,
                # it would delay drawing the result.
                if ($jobType -eq 'Compare') { Request-DeferredMemoryCleanup }
            }
        }
    })
    $AppState.CurrentJob.Timer = $timer
    $timer.Start()
}

# Remove the output folder of a cancelled job (the compare run folder
# Reports\SRC_TGT\yyyyMMdd_HHmmss) and its parent when that is empty now.
function Remove-CancelledOutput {
    param([string]$Dir, [string]$DirIfEmpty)
    if ($Dir -and (Test-Path -LiteralPath $Dir)) {
        try { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction Stop }
        catch { Write-Log 'Compare' "Could not remove the cancelled report folder '$Dir': $($_.Exception.Message)" 'WARN' -FileOnly }
    }
    if ($DirIfEmpty -and (Test-Path -LiteralPath $DirIfEmpty) -and
        -not (Get-ChildItem -LiteralPath $DirIfEmpty -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        try { Remove-Item -LiteralPath $DirIfEmpty -Force -ErrorAction Stop } catch {}
    }
}

function Stop-ActiveRunspace {
    param(
        [string]$Side = '',
        [string]$RemoveDir = '',          # output folder to remove once the job has stopped
        [string]$RemoveDirIfEmpty = ''    # its parent, removed when empty
    )

    $job = $AppState.CurrentJob
    if ($job) {
        if ($job.Timer) { $job.Timer.Stop() }
        if ($job.PS) {
            $stopHandle = $null
            try { $stopHandle = $job.PS.BeginStop($null, $null) } catch {}
            $AppState.StoppingJobs.Add(@{ PS = $job.PS; Runspace = $job.Runspace; Handle = $stopHandle
                                        RemoveDir = $RemoveDir; RemoveDirIfEmpty = $RemoveDirIfEmpty
                                        JobType = $job.Type })
            $AppState.StopCleanupTimer.Start()
        } else {
            if ($job.Runspace) { try { $job.Runspace.Dispose() } catch {} }
            Remove-CancelledOutput -Dir $RemoveDir -DirIfEmpty $RemoveDirIfEmpty
        }
        # As in the Tick handler: release heavy refs so the cancelled job
        # does not linger via the timer closure.
        $job.PS       = $null
        $job.Runspace = $null
        $job.Handle   = $null
        $job.Queue    = $null
        $job.Output   = $null
        $job.Timer    = $null
        $job.OnDone   = $null
    }

    # Set-Busy $false nulls $AppState.CurrentJob and restores btnOpenReport
    # to its state before the job.
    Set-Busy $false

    # A cancel skips OnDone and its Update-Counts: re-evaluate btnCompare,
    # Source + Target may still be loaded from an earlier load.
    Update-Counts

    # Re-apply the Download button look (orange when definitions are missing).
    Update-DownloadButton

    # Side: 'Source', 'Target', 'Download', 'Compare', 'Source Export', ...
    $what = switch ($Side) {
        { $_ -in 'Source', 'Target' } { 'Loading cancelled by user'; break }
        'Download'                    { 'Download cancelled by user'; break }
        'Compare'                     { 'Compare cancelled by user'; break }
        ''                            { 'Operation cancelled'; break }
        default                       { "$Side cancelled" }
    }
    $sideLabel = if ($Side) { $Side } else { 'Basetune' }
    Write-UILog $sideLabel $what 'WARN'
    # A cancelled load also says so in the middle of the (empty) card.
    if ($Side -in 'Source', 'Target') {
        $noMatch = if ($Side -eq 'Source') { $UI.lblSourceNoMatch } else { $UI.lblTargetNoMatch }
        if ($noMatch) { $noMatch.Text = 'Loading cancelled by user' }
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# INITIALISATION
# Creates the job timers (network watcher, stop cleanup, compare Cancel).
# Called once from BasetuneUI.ps1.
# ═════════════════════════════════════════════════════════════════════════════
function Initialize-BasetuneJobs {
    # Compact the Large Object Heap on the next GC.Collect(). Parsing
    # settings.json makes strings >85 KB, which land on the LOH; it is only
    # swept by default, so after several compares it fragments and the working
    # set climbs. CompactOnce resets after one collect, so
    # Request-DeferredMemoryCleanup sets it again each time.
    try {
        [System.Runtime.GCSettings]::LargeObjectHeapCompactionMode = `
            [System.Runtime.GCLargeObjectHeapCompactionMode]::CompactOnce
    } catch {}

    $AppState.NetWatchWasUp = $true
    $AppState.NetWatchTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $AppState.NetWatchTimer.Interval = [TimeSpan]::FromSeconds(2)
    $AppState.NetWatchTimer.Add_Tick({
        $job = $AppState.CurrentJob
        $watching = $job -and $job.Type -in @('Load', 'Download')
        if (-not $watching) { $AppState.NetWatchWasUp = $true; return }

        $up = Test-NetworkUp
        if (-not $up -and $AppState.NetWatchWasUp) {
            $maxWait = if ($job.Type -eq 'Download') { 60 } else { 30 }
            Write-UILog 'Network' "Network connection lost. Waiting for requests in progress to time out (max $maxWait seconds)..." 'WARN'
        } elseif ($up -and -not $AppState.NetWatchWasUp) {
            Write-UILog 'Network' "Network connection restored"
        }
        $AppState.NetWatchWasUp = $up
    })
    $AppState.NetWatchTimer.Start()

    # ── Cancel an in-progress runspace load ──────────────────────────────────────
    # PS.Stop() waits for the pipeline to stop (with ForEach-Object -Parallel:
    # for in-flight Graph calls), which would freeze the window. Cancel uses
    # BeginStop() and releases the UI at once; this timer disposes the
    # runspace once the stop has completed.
    $AppState.StoppingJobs = [System.Collections.Generic.List[object]]::new()
    $AppState.StopCleanupTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $AppState.StopCleanupTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $AppState.StopCleanupTimer.Add_Tick({
        foreach ($s in @($AppState.StoppingJobs)) {
            if (-not $s.Handle -or $s.Handle.IsCompleted) {
                try { if ($s.Handle) { $s.PS.EndStop($s.Handle) } } catch {}
                try { $s.PS.Dispose() }       catch {}
                try { $s.Runspace.Dispose() } catch {}
                # A cancelled compare leaves its half-written report folder behind;
                # it is removed only now, when the runspace no longer writes to it.
                Remove-CancelledOutput -Dir $s.RemoveDir -DirIfEmpty $s.RemoveDirIfEmpty
                # Cancelled compare: same memory cleanup as a finished one, now
                # the runspace is disposed. $Error holds the stopped pipeline's
                # errors, which still reference the compare data.
                if ($s.JobType -eq 'Compare') {
                    $global:Error.Clear()
                    Request-DeferredMemoryCleanup
                }
                [void]$AppState.StoppingJobs.Remove($s)
            }
        }
        if ($AppState.StoppingJobs.Count -eq 0) { $AppState.StopCleanupTimer.Stop() }
    })

    # ── Compare: show Cancel only after a few seconds ────────────────────────────
    # The red Cancel only appears when a compare still runs after 5 s, so a
    # short compare doesn't flash red. Set-Busy $false stops the timer and
    # turns the button back into Compare Policies.
    $AppState.compareCancelTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $AppState.compareCancelTimer.Interval = [TimeSpan]::FromSeconds(5)
    $AppState.compareCancelTimer.Add_Tick({
        $AppState.compareCancelTimer.Stop()
        if ($AppState.CurrentJob -and $AppState.CurrentJob.Type -eq 'Compare' -and $AppState.CurrentJob.PS) {
            Set-CompareButtonMode 'cancel'
        }
    })
}

Export-ModuleMember -Function @(
    'Request-DeferredMemoryCleanup',
    'Test-NetworkUp',
    'Start-Runspace',
    'Remove-CancelledOutput',
    'Stop-ActiveRunspace',
    'Initialize-BasetuneJobs'
)
