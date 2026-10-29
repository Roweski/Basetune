# =============================================================================
# BasetunePolicyLists.psm1
# The source / target policy lists of the main window: selection row and
# counts (Update-Counts), empty-card text, name filter and column sort,
# keyboard and whole-line scrolling, plus the event wiring for the
# checkboxes, filter fields and tenant dropdowns.
#
# Shares the controls ($UI) and the app state ($AppState) with the other UI
# modules through BasetuneState.psm1.
# =============================================================================

$script:UI       = (Get-BasetuneContext).UI
$script:AppState = (Get-BasetuneContext).State

# Select / deselect all visible (filtered) policies. The items raise
# PropertyChanged (BasetunePolicyItem), so the row checkboxes follow without
# rebuilding the list. Each changed row raises Checked / Unchecked, which
# normally runs Update-Counts; during this loop that is skipped
# ($AppState.bulkSelecting) and the counts are updated once at the end.
function Set-VisibleSelection {
    param($List, [bool]$Value)
    $visibleItems = $List.ItemsSource
    if ($visibleItems) {
        $AppState.bulkSelecting = $true
        try {
            foreach ($i in $visibleItems) { if ($i.IsChecked -ne $Value) { $i.IsChecked = $Value } }
            # Let the row checkboxes take the new values (their Checked /
            # Unchecked events) while the flag is still set.
            $List.UpdateLayout()
        } finally { $AppState.bulkSelecting = $false }
    }
    Update-Counts
}

# Empties a filter field (TextChanged shows the whole list again, ticks stay)
# and takes the focus out of it, so its grey hint text shows again.
function Clear-SearchField {
    param($Box, $Hint)
    $Box.Text = ''
    $scope = [System.Windows.Input.FocusManager]::GetFocusScope($Box)
    [System.Windows.Input.FocusManager]::SetFocusedElement($scope, $null)
    [System.Windows.Input.Keyboard]::ClearFocus()
    if ($Hint) { $Hint.Visibility = 'Visible' }
}

# ── Update "X / Y" labels and toggle Compare button ──────────────────────────
# Selection row above each list: select-all checkbox (checked = all visible
# (filtered) policies selected, a dot = some, empty = none) and the counter.
function Update-SelectionRow {
    param($Panel, $Box, $List, [int]$Total, $NoMatch, [string]$Search)
    if (-not $Panel -or -not $List) { return }
    # Hidden only when nothing is loaded. A search without matches keeps the
    # row: empty, disabled select-all box + "No policies match 'x'".
    # Nothing loaded: the no-match text is left alone, because Update-Counts
    # runs for BOTH sides and a "load found nothing" message must not vanish
    # because of the other side. It is cleared per side by Reset-Side,
    # Update-ListFilter and the start of a new load.
    if ($Total -eq 0) { $Panel.Visibility = 'Collapsed'; return }
    $Panel.Visibility = 'Visible'
    # Plain loops, not Where-Object: runs on every checkbox tick, over every
    # policy in the list (1000+ in a large tenant).
    $vis = @(foreach ($it in $List.ItemsSource) { if ($null -ne $it) { $it } })
    if ($Box) { $Box.IsEnabled = ($vis.Count -gt 0) }
    if ($NoMatch) {
        $NoMatch.Text = if ($vis.Count -eq 0 -and $Search) { "No policies match '$Search'" } else { '' }
    }
    $on = 0
    foreach ($it in $vis) { if ($it.IsChecked) { $on++ } }
    # All selected: checked; some: $null (the dot, see the CheckBox style in
    # BasetuneTheme.xaml); none: empty. A click (Add_Click in
    # Initialize-PolicyListEvents) selects all unless all are selected already.
    $state = if ($vis.Count -gt 0 -and $on -eq $vis.Count) { $true } elseif ($on -gt 0) { $null } else { $false }
    if ($Box -and $Box.IsChecked -ne $state) { $Box.IsChecked = $state }
}

# Snapshot of the selection on both sides: the checked items by reference,
# not their positions (sorting does not change the selection). Stored when a
# compare produces a report; View Report / View Details go off as soon as the
# selection no longer matches it (Test-SelectionSnapshot).
# Per side a Dictionary item -> $true, read by index: no .NET method call
# with an argument (HashSet.Contains) or Where-Object per policy, which is
# slow on every checkbox tick with 1000+ policies.
function Get-SelectionSnapshot {
    $key = @{}
    foreach ($side in 'Source', 'Target') {
        $items = if ($side -eq 'Source') { $AppState.sourceItems } else { $AppState.targetItems }
        $set   = [System.Collections.Generic.Dictionary[object, bool]]::new()
        foreach ($it in $items) { if ($it.IsChecked) { $set[$it] = $true } }
        $key[$side] = $set
    }
    return $key
}

# $true when the current selection is the same as in the snapshot.
function Test-SelectionSnapshot {
    param([hashtable]$Key)
    if (-not $Key) { return $false }
    foreach ($side in 'Source', 'Target') {
        $items   = if ($side -eq 'Source') { $AppState.sourceItems } else { $AppState.targetItems }
        $checked = @(foreach ($it in $items) { if ($it.IsChecked) { $it } })
        if ($checked.Count -ne $Key[$side].Count) { return $false }
        foreach ($it in $checked) { if (-not $Key[$side][$it]) { return $false } }
    }
    return $true
}

# The counter is three text blocks (BasetuneUI.xaml): selected, "/" and total,
# so the "/" stays in place. -Text is "43 / 45", or '' for no counter.
function script:Set-CountLabel {
    param([string]$Side, [string]$Text)
    $parts = $Text -split ' / ', 2
    $on    = if ($Text) { $parts[0] } else { '' }
    $of    = if ($Text -and $parts.Count -gt 1) { $parts[1] } else { '' }
    $UI["lbl${Side}CountOn"].Text    = $on
    $UI["lbl${Side}CountSlash"].Text = if ($Text) { '/' } else { '' }
    $UI["lbl${Side}CountOf"].Text    = $of
}
function Update-Counts {
    # Plain loops, not Where-Object (runs on every checkbox tick, over every
    # policy of both lists).
    $srcChecked = 0
    foreach ($it in $AppState.sourceItems) { if ($it.IsChecked) { $srcChecked++ } }
    $tgtChecked = 0
    foreach ($it in $AppState.targetItems) { if ($it.IsChecked) { $tgtChecked++ } }

    # The report belongs to the last compare: a selection change switches it
    # off until the next compare (also its saved state while a busy action
    # has it off, so it is not restored).
    if ($null -ne $AppState.reportSelectionKey -and -not (Test-SelectionSnapshot $AppState.reportSelectionKey)) {
        $UI.btnOpenReport.IsEnabled = $false
        if ($null -ne $AppState.btnOpenReportPriorState) { $AppState.btnOpenReportPriorState = $false }
        $AppState.reportSelectionKey = $null
    }
    # Selection changed during a compare: its report will not match, so View
    # Report / View Details stay off afterwards. Logged once, not right now
    # but after the "All reports created successfully" line (see Add-UILogLines)
    # or at the end of the compare.
    if ($AppState.CurrentJob -and $AppState.CurrentJob.Type -eq 'Compare' -and $AppState.compareSelectionKey -and
        -not $AppState.compareSelectionChangedLogged -and -not (Test-SelectionSnapshot $AppState.compareSelectionKey)) {
        $AppState.compareSelectionChangedLogged = $true
        $AppState.compareSelectionNotePending = $true
    }
    # "43 / 45" = selected / total; while searching only the search results
    # ("23 / 24"). Empty list: no counter instead of "0 / 0".
    $fmt = { param($list, $items, [int]$checked)
        if ($items.Count -eq 0) { return '' }
        $on = $checked; $of = $items.Count
        if ($null -ne $list.ItemsSource -and -not [object]::ReferenceEquals($list.ItemsSource, $items)) {
            $vis = @(foreach ($it in $list.ItemsSource) { if ($null -ne $it) { $it } })
            $on  = 0
            foreach ($it in $vis) { if ($it.IsChecked) { $on++ } }
            $of  = $vis.Count
        }
        "$on / $of"
    }
    Set-CountLabel -Side 'Source' -Text (& $fmt $UI.lstSource $AppState.sourceItems $srcChecked)
    Set-CountLabel -Side 'Target' -Text (& $fmt $UI.lstTarget $AppState.targetItems $tgtChecked)
    # While searching, a filter icon left of the counter says it counts only
    # the search results.
    foreach ($c in @(@($UI.icoSourceFilter, $UI.lstSource, $AppState.sourceItems), @($UI.icoTargetFilter, $UI.lstTarget, $AppState.targetItems))) {
        if (-not $c[0]) { continue }
        $searching = $c[2].Count -gt 0 -and $null -ne $c[1].ItemsSource -and -not [object]::ReferenceEquals($c[1].ItemsSource, $c[2])
        $c[0].Visibility = if ($searching) { 'Visible' } else { 'Collapsed' }
    }

    # Selection row (select-all checkbox, counter) above each list.
    Update-SelectionRow -Panel $UI.pnlSourceSelect -Box $UI.chkSourceAll -List $UI.lstSource -Total $AppState.sourceItems.Count -NoMatch $UI.lblSourceNoMatch -Search $UI.txtSourceFilter.Text.Trim()
    Update-SelectionRow -Panel $UI.pnlTargetSelect -Box $UI.chkTargetAll -List $UI.lstTarget -Total $AppState.targetItems.Count -NoMatch $UI.lblTargetNoMatch -Search $UI.txtTargetFilter.Text.Trim()

    # Don't re-enable Compare while a job runs: re-ticking policies during an
    # export would otherwise allow a Compare that clears the export's UI
    # status. Same guard as in Update-ExportButtons.
    if ($AppState.CurrentJob) { return }

    $UI.btnCompare.IsEnabled = (
        $srcChecked -gt 0 -and $tgtChecked -gt 0 -and
        $null -ne $AppState.sourceExpanded -and $null -ne $AppState.targetExpanded
    )

    # Export buttons also depend on selection — keep them in sync.
    Update-ExportButtons
}

# ── Clear one side's policy list and cached data ──────────────────────────────
# On a tenant switch and before a new Load: drops the policy items, the
# expanded-policy cache AND the side's Graph connection (never reuse a
# connection to a tenant that is no longer selected).
function Reset-Side {
    param([string]$Side)
    if ($Side -eq 'Source') {
        $AppState.sourceItems.Clear()
        $AppState.sourceExpanded       = $null
        $AppState.sourceConnection     = $null
        Set-CountLabel -Side 'Source' -Text ''
        $UI.lstSource.ItemsSource = $AppState.sourceItems
    } else {
        $AppState.targetItems.Clear()
        $AppState.targetExpanded       = $null
        $AppState.targetConnection     = $null
        Set-CountLabel -Side 'Target' -Text ''
        $UI.lstTarget.ItemsSource = $AppState.targetItems
    }
    Update-EmptyState -Side $Side -Force     # "Ready to load policies" (or nothing without a tenant)
    Set-ListSort -Side $Side -Reset          # headers back to Policy A-Z, no Platform column
    # A load filter typed before loading is kept (it applies to the next Load).
    # A search term in the loaded list is cleared: that list is gone.
    $box  = if ($Side -eq 'Source') { $UI.txtSourceFilter }     else { $UI.txtTargetFilter }
    $hint = if ($Side -eq 'Source') { $UI.txtSourceFilterHint } else { $UI.txtTargetFilterHint }
    $wasSearch = ($hint -and $hint.Text -eq 'Filter policies')
    # So is an unchanged load filter that gave "No policies match the selected filters".
    $wasNoMatch = ($box -and $box.Text -and $AppState.noMatchLoadFilter -and
                   $AppState.noMatchLoadFilter[$Side] -and $box.Text -eq $AppState.noMatchLoadFilter[$Side])
    if ($AppState.noMatchLoadFilter) { $AppState.noMatchLoadFilter[$Side] = $null }
    if ($box -and ($wasSearch -or $wasNoMatch)) { $box.Text = '' }
    if ($hint -and $box -and -not $box.IsFocused -and -not $box.Text) { $hint.Visibility = 'Visible' }
    Set-FilterMode -Side $Side -Mode 'Filter'
    Update-Counts
    $UI.btnOpenReport.IsEnabled = $false
    $AppState.reportSelectionKey      = $null
}

# ── Name filter field: 'Filter' before a load, 'Search' once policies are loaded ──
# Before loading the text is the load filter ("Filter by name"); after a load
# it searches the loaded list ("Filter policies"). Load always uses the field
# as its filter.
function Set-FilterMode {
    param([string]$Side, [ValidateSet('Filter','Search')][string]$Mode)
    $box  = if ($Side -eq 'Source') { $UI.txtSourceFilter }     else { $UI.txtTargetFilter }
    $hint = if ($Side -eq 'Source') { $UI.txtSourceFilterHint } else { $UI.txtTargetFilterHint }
    if ($Mode -eq 'Search') {
        if ($hint) { $hint.Text = 'Filter policies' }
        if ($box)  { $box.ToolTip = 'Filter the loaded policies by name' }
    } else {
        if ($hint) { $hint.Text = 'Filter by name' }
        if ($box)  { $box.ToolTip = 'Filter policies by name before loading' }
    }
}

# ── Message in the middle of an empty policy card ────────────────────────────
# Empty list + a tenant: "Ready to load policies"; no tenant configured:
# "Configure a tenant to get started"; a load on that side: "Loading policies"
# / "Loading policies with name filter 'x'". A "No ... matching 'x'" message from
# a load that found nothing is kept, unless -Force (tenant switch, typing in
# that side's filter).
$script:ReadyText    = 'Ready to load policies'
$script:NoTenantText = 'Configure a tenant to get started'   # clickable (XAML trigger on this exact text + click handler in BasetuneUI.ps1)
function Get-LoadingCardText {
    param([string]$Filter)
    if ($Filter) { "Loading policies with name filter '$Filter'" } else { 'Loading policies' }
}
function Update-EmptyState {
    param([string]$Side, [switch]$Force)
    $nm    = if ($Side -eq 'Source') { $UI.lblSourceNoMatch } else { $UI.lblTargetNoMatch }
    $cmb   = if ($Side -eq 'Source') { $UI.cmbSourceTenant }  else { $UI.cmbTargetTenant }
    if ($Side -eq 'Source') { $items = $AppState.sourceItems } else { $items = $AppState.targetItems }
    if (-not $nm -or $items.Count -gt 0) { return }   # loaded list: Update-SelectionRow handles it
    if (-not $Force -and $nm.Text -and $nm.Text -ne $script:ReadyText -and $nm.Text -ne $script:NoTenantText) { return }
    $job = $AppState.CurrentJob
    $loadingHere = $job -and $job.Type -eq 'Load' -and $job.Side -eq $Side
    $nm.Text = if ($loadingHere)                         { Get-LoadingCardText $job.LoadFilter }
               elseif ($cmb -and $cmb.SelectedItem)      { $script:ReadyText }
               else                                      { $script:NoTenantText }
}

# ── Filter visible policy list without changing checked state ─────────────────
function Update-ListFilter {
    param([string]$Side)
    # The policy name filter in the tenant card doubles as the list filter.
    $search = if ($Side -eq 'Source') { $UI.txtSourceFilter.Text.Trim().ToLower() } `
              else                    { $UI.txtTargetFilter.Text.Trim().ToLower() }
    $lst    = if ($Side -eq 'Source') { $UI.lstSource } else { $UI.lstTarget }
    # Plain assignment, not "$items = if (...) { ... }": an if-expression unrolls
    # an EMPTY collection to $null, which would make ItemsSource $null and show
    # the select-all checkbox before anything is loaded.
    if ($Side -eq 'Source') { $items = $AppState.sourceItems } else { $items = $AppState.targetItems }

    # Nothing loaded: typing replaces an earlier "No ... matching" message
    # with "Ready to load policies".
    if ($items.Count -eq 0) { Update-EmptyState -Side $Side -Force }

    if ($search) {
        # No .NET call with an argument (Contains, Add) per policy: costly
        # here. -clike with the escaped search text is the same substring test
        # on the lowercased name; the matches go in with one call, in order.
        $pattern  = '*' + [System.Management.Automation.WildcardPattern]::Escape($search) + '*'
        $matched  = @(foreach ($it in $items) {
            if ($it.Name -and $it.Name.ToLower() -clike $pattern) { $it }
        })
        $filtered = [System.Collections.ObjectModel.ObservableCollection[object]]::new([object[]]$matched)
        $lst.ItemsSource = $filtered
    } else {
        $lst.ItemsSource = $items
    }
    Update-Counts
}

# ── Sorting the policy lists (column headers Policy / Type / Platform) ──────
# Click a header: sort on it (A-Z); again: reverse. Type and Platform sort on
# the label, then on name. Only the order of the side's item collection
# changes: ticks, search and compare are not affected. A new load starts on
# Policy A-Z.
# $AppState.listSort = @{ Source = @{ Key; Desc }; Target = @{ Key; Desc } }
function Update-ListSortHeaders {
    param([string]$Side)
    if (-not $AppState.listSort) { return }
    $st = $AppState.listSort[$Side]
    if ($Side -eq 'Source') { $bn = $UI.btnSourceSortName; $bp = $UI.btnSourceSortPlatform; $bt = $UI.btnSourceSortType; $items = $AppState.sourceItems }
    else                    { $bn = $UI.btnTargetSortName; $bp = $UI.btnTargetSortPlatform; $bt = $UI.btnTargetSortType; $items = $AppState.targetItems }
    $arrow = if ($st.Desc) { ' ' + [char]0x25BC } else { ' ' + [char]0x25B2 }
    if ($bn) { $bn.Content = 'POLICY'   + $(if ($st.Key -eq 'Name')     { $arrow } else { '' }) }
    if ($bp) {
        $bp.Content = 'PLATFORM' + $(if ($st.Key -eq 'Platform') { $arrow } else { '' })
        # Only when policies in the list have a platform label.
        $hasPf = $false
        foreach ($it in $items) { if ($it.PSObject.Properties['PlatformLabel'] -and $it.PlatformLabel) { $hasPf = $true; break } }
        $bp.Visibility = if ($hasPf) { 'Visible' } else { 'Collapsed' }
    }
    if ($bt) {
        $bt.Content = 'TYPE' + $(if ($st.Key -eq 'Type') { $arrow } else { '' })
        # Without the Platform column the rows end 19 px further right than the
        # header (scrollbar space); with it, the Platform header covers that.
        $pfShown = ($bp -and $bp.Visibility -eq 'Visible')
        $bt.Margin = if ($pfShown) { [System.Windows.Thickness]::new(0) } else { [System.Windows.Thickness]::new(0, 0, 7, 0) }
    }
}

# Search and sort on a policy list while a job runs: allowed when the job does
# not touch that list and the list is loaded.
#   Compare  : both sides (the compare works on its own copy of the selection)
#   Download : both sides (does not use the lists)
#   Load     : only the other side
#   Export   : no
function Test-ListToolsAllowed {
    param([string]$Side)
    $job = $AppState.CurrentJob
    if (-not $job) { return $true }
    $items = if ($Side -eq 'Source') { $AppState.sourceItems } else { $AppState.targetItems }
    if (-not $items -or $items.Count -eq 0) { return $false }
    switch ($job['Type']) {
        'Compare'  { return $true }
        'Download' { return $true }
        'Load'     { return ($job['LoadSide'] -ne $Side) }
        default    { return $false }
    }
}

# Re-enables the search fields where Test-ListToolsAllowed allows it (Set-Busy
# switches both off). Called right after Start-Runspace (job type known).
function Enable-ListToolsDuringJob {
    foreach ($side in 'Source', 'Target') {
        $box = if ($side -eq 'Source') { $UI.txtSourceFilter } else { $UI.txtTargetFilter }
        if ($box -and (Test-ListToolsAllowed -Side $side)) { $box.IsEnabled = $true }
    }
}

function Set-ListSort {
    param([string]$Side, [ValidateSet('Name', 'Type', 'Platform')][string]$Key = 'Name', [switch]$Reset)
    if (-not $AppState.listSort) { return }
    if ($Reset) {
        $AppState.listSort[$Side] = @{ Key = 'Name'; Desc = $false }
        Update-ListSortHeaders -Side $Side
        return
    }
    # During a job: only where the job does not touch the list (Test-ListToolsAllowed).
    if ($AppState.CurrentJob -and -not (Test-ListToolsAllowed -Side $Side)) { return }
    $st = $AppState.listSort[$Side]
    if ($st.Key -eq $Key) { $st.Desc = -not $st.Desc } else { $st.Key = $Key; $st.Desc = $false }

    if ($Side -eq 'Source') { $items = $AppState.sourceItems } else { $items = $AppState.targetItems }
    $sorted = if ($st.Key -eq 'Type') {
        @($items | Sort-Object @{ Expression = { "$($_.TypeLabel)" }; Descending = $st.Desc },
                               @{ Expression = { "$($_.Name)" };      Descending = $false })
    } elseif ($st.Key -eq 'Platform') {
        @($items | Sort-Object @{ Expression = { "$($_.PlatformLabel)" }; Descending = $st.Desc },
                               @{ Expression = { "$($_.Name)" };          Descending = $false })
    } else {
        @($items | Sort-Object @{ Expression = { "$($_.Name)" }; Descending = $st.Desc })
    }
    $items.Clear()
    foreach ($it in $sorted) { $items.Add($it) }
    Update-ListFilter -Side $Side     # rebuilds the visible list (search) + counts
    Update-ListSortHeaders -Side $Side
}

# ── Keyboard navigation in the policy lists ──────────────────────────────────
# Up/Down move to the previous/next policy (focus on its checkbox, scrolled
# into view); Space toggles the checkbox of the current policy. The row with
# keyboard focus is highlighted by the ListBoxItem style in BasetuneTheme.xaml.
function script:Find-VisualChildCheckBox {
    param($Parent)
    if (-not $Parent) { return $null }
    $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Parent)
    for ($i = 0; $i -lt $n; $i++) {
        $c = [System.Windows.Media.VisualTreeHelper]::GetChild($Parent, $i)
        if ($c -is [System.Windows.Controls.CheckBox]) { return $c }
        $r = Find-VisualChildCheckBox $c
        if ($r) { return $r }
    }
    return $null
}

# ── Policy lists: only whole lines visible ────────────────────────────────────
# The list fills the card, so its height follows the window and the last line
# would be cut in half. The leftover pixels (visible height modulo one row) go
# to the list's bottom margin, so it always shows a whole number of rows. The
# lists scroll per item, so the top line is whole as well.
function Enable-WholeLineList {
    param([System.Windows.Controls.ListBox]$List)
    if (-not $List) { return }
    # Scp: the ScrollContentPresenter, found once (the template does not
    # change). LastH / LastPitch: the heights of the last check, so a layout
    # pass that changed nothing returns at once. LayoutUpdated fires after
    # every layout pass in the window (hundreds for one maximise).
    $state = @{ Base = $List.Margin; Extra = 0.0; Logged = $false; Scp = $null; LastH = -1.0; LastPitch = -1.0 }

    $fit = {
        if ($List.Items.Count -eq 0) { return }
        # Visible item area = ScrollContentPresenter inside the ListBox template.
        $scp = $state.Scp
        if (-not $scp -or -not $scp.IsVisible) {
            $scp = $null
            $queue = [System.Collections.Generic.Queue[System.Windows.DependencyObject]]::new()
            $queue.Enqueue($List)
            while ($queue.Count -gt 0 -and -not $scp) {
                $el = $queue.Dequeue()
                $n  = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($el)
                for ($i = 0; $i -lt $n; $i++) {
                    $c = [System.Windows.Media.VisualTreeHelper]::GetChild($el, $i)
                    if ($c -is [System.Windows.Controls.ScrollContentPresenter]) { $scp = $c; break }
                    $queue.Enqueue($c)
                }
            }
            if (-not $scp) { return }
            $state.Scp = $scp
        }
        $first = $List.ItemContainerGenerator.ContainerFromIndex(0)
        if (-not $first -or $first.ActualHeight -le 0) { return }
        $pitch = $first.ActualHeight + $first.Margin.Top + $first.Margin.Bottom
        if ($pitch -le 0) { return }
        # Nothing changed since the last check: done.
        $h = $scp.ActualHeight
        if ($h -eq $state.LastH -and $pitch -eq $state.LastPitch) { return }
        $state.LastH = $h; $state.LastPitch = $pitch

        $total = $scp.ActualHeight + $state.Extra          # visible height without our extra margin
        $extra = $total - ([math]::Floor($total / $pitch) * $pitch)
        if ([math]::Abs($extra - $state.Extra) -gt 0.5) {
            $state.Extra = $extra
            $b = $state.Base
            $List.Margin = [System.Windows.Thickness]::new($b.Left, $b.Top, $b.Right, $b.Bottom + $extra)
        }
    }.GetNewClosure()

    # After every layout pass (resize, list (re)loaded, filtered). Only changes
    # the margin when the leftover changed, so it settles after one extra pass.
    $List.Add_LayoutUpdated({
        try { & $fit }
        catch {
            if (-not $state.Logged) {
                $state.Logged = $true
                Write-UILog 'Basetune' 'Could not adjust the policy list layout. See Basetune.log for details' 'WARN'
                Write-Log 'Basetune' "Details: $($_.Exception.Message)" 'WARN' -FileOnly
            }
        }
    }.GetNewClosure())
}

function Enable-PolicyListKeys {
    param([System.Windows.Controls.ListBox]$List)
    if (-not $List) { return }
    $List.Add_PreviewKeyDown({
        param($sender, $e)
        $key = $e.Key
        if ($key -ne [System.Windows.Input.Key]::Up -and
            $key -ne [System.Windows.Input.Key]::Down -and
            $key -ne [System.Windows.Input.Key]::Space) { return }
        $lst   = $sender
        $count = $lst.Items.Count
        if ($count -eq 0) { return }

        $focused = [System.Windows.Input.Keyboard]::FocusedElement
        $cont = $null
        if ($focused -is [System.Windows.DependencyObject]) {
            $cont = [System.Windows.Controls.ItemsControl]::ContainerFromElement($lst, $focused)
        }
        $idx = if ($cont) { $lst.ItemContainerGenerator.IndexFromContainer($cont) } else { -1 }

        if ($key -eq [System.Windows.Input.Key]::Space) {
            # Focus on the checkbox itself: its own Space handling toggles it.
            if ($focused -is [System.Windows.Controls.CheckBox]) { return }
            if ($cont) {
                $cb = Find-VisualChildCheckBox $cont
                if ($cb) {
                    $cb.IsChecked = -not [bool]$cb.IsChecked
                    [void]$cb.Focus()
                    $e.Handled = $true
                }
            }
            return
        }

        $new = if ($idx -lt 0) { 0 }
               elseif ($key -eq [System.Windows.Input.Key]::Up) { [Math]::Max(0, $idx - 1) }
               else { [Math]::Min($count - 1, $idx + 1) }
        $lst.ScrollIntoView($lst.Items[$new])
        $lst.UpdateLayout()
        $c2 = $lst.ItemContainerGenerator.ContainerFromIndex($new)
        if ($c2) {
            $cb = Find-VisualChildCheckBox $c2
            if ($cb) { [void]$cb.Focus() } else { [void]$c2.Focus() }
        }
        $e.Handled = $true
    })
}

# ═════════════════════════════════════════════════════════════════════════════
# INITIALISATION
# Wires the policy list, filter and tenant dropdown handlers. Called once
# from BasetuneUI.ps1.
# ═════════════════════════════════════════════════════════════════════════════
function Initialize-PolicyListEvents {
    # Checkbox routed events → Update-Counts. Not during Set-VisibleSelection
    # (it updates once afterwards), not for the select-all boxes (set by
    # Update-SelectionRow, clicks go through Set-VisibleSelection). Queued,
    # not right away: a redraw (sort, search) re-binds every row checkbox and
    # each raises Checked. One Update-Counts runs at Background priority after
    # layout and render; the events in between add nothing.
    $onToggle = [System.Windows.RoutedEventHandler]{
        param($s, $e)
        if ($AppState.bulkSelecting) { return }
        if ([object]::ReferenceEquals($e.OriginalSource, $UI.chkSourceAll) -or [object]::ReferenceEquals($e.OriginalSource, $UI.chkTargetAll)) { return }
        if ($AppState.countsQueued) { return }
        $AppState.countsQueued = $true
        [void]$UI.Window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{
            $AppState.countsQueued = $false
            Update-Counts
        })
    }
    $UI.Window.AddHandler([System.Windows.Controls.Primitives.ToggleButton]::CheckedEvent, $onToggle)
    $UI.Window.AddHandler([System.Windows.Controls.Primitives.ToggleButton]::UncheckedEvent, $onToggle)
    $UI.Window.AddHandler([System.Windows.Controls.Primitives.ToggleButton]::IndeterminateEvent, $onToggle)

    # Select-all checkbox: selects all visible policies, or deselects them when
    # all were selected. Decided from the items (the box's own IsChecked is
    # re-synced by Update-Counts during the click).
    $UI.chkSourceAll.Add_Click({
        $vis   = @($UI.lstSource.ItemsSource)
        $allOn = $vis.Count -gt 0 -and @($vis | Where-Object { -not $_.IsChecked }).Count -eq 0
        Set-VisibleSelection -List $UI.lstSource -Value (-not $allOn)
    })
    # Column headers: sort the list (again = reverse).
    if ($UI.btnSourceSortName)     { $UI.btnSourceSortName.Add_Click({     Set-ListSort -Side 'Source' -Key 'Name' }) }
    if ($UI.btnSourceSortPlatform) { $UI.btnSourceSortPlatform.Add_Click({ Set-ListSort -Side 'Source' -Key 'Platform' }) }
    if ($UI.btnTargetSortName)     { $UI.btnTargetSortName.Add_Click({     Set-ListSort -Side 'Target' -Key 'Name' }) }
    if ($UI.btnTargetSortPlatform) { $UI.btnTargetSortPlatform.Add_Click({ Set-ListSort -Side 'Target' -Key 'Platform' }) }
    if ($UI.btnSourceSortType)     { $UI.btnSourceSortType.Add_Click({     Set-ListSort -Side 'Source' -Key 'Type' }) }
    if ($UI.btnTargetSortType)     { $UI.btnTargetSortType.Add_Click({     Set-ListSort -Side 'Target' -Key 'Type' }) }
    $UI.chkTargetAll.Add_Click({
        $vis   = @($UI.lstTarget.ItemsSource)
        $allOn = $vis.Count -gt 0 -and @($vis | Where-Object { -not $_.IsChecked }).Count -eq 0
        Set-VisibleSelection -List $UI.lstTarget -Value (-not $allOn)
    })

    # The name filter is the load filter on Load and filters the loaded list
    # live while typing.
    $UI.txtSourceFilter.Add_TextChanged({
        $has = [bool]$UI.txtSourceFilter.Text
        if ($UI.txtSourceFilterHint)  { $UI.txtSourceFilterHint.Visibility  = if ($has -or $UI.txtSourceFilter.IsFocused) { 'Collapsed' } else { 'Visible' } }
        if ($UI.btnClearSourceFilter) { $UI.btnClearSourceFilter.Visibility = if ($has) { 'Visible' } else { 'Collapsed' } }
        Update-ListFilter -Side 'Source'
    })
    $UI.txtTargetFilter.Add_TextChanged({
        $has = [bool]$UI.txtTargetFilter.Text
        if ($UI.txtTargetFilterHint)  { $UI.txtTargetFilterHint.Visibility  = if ($has -or $UI.txtTargetFilter.IsFocused) { 'Collapsed' } else { 'Visible' } }
        if ($UI.btnClearTargetFilter) { $UI.btnClearTargetFilter.Visibility = if ($has) { 'Visible' } else { 'Collapsed' } }
        Update-ListFilter -Side 'Target'
    })

    # ── Clear buttons ────────────────────────────────────────────────────────────
    if ($UI.btnClearSourceFilter) { $UI.btnClearSourceFilter.Add_Click({ $UI.txtSourceFilter.Text = '' }) }
    if ($UI.btnClearTargetFilter) { $UI.btnClearTargetFilter.Add_Click({ $UI.txtTargetFilter.Text = '' }) }

    # A click anywhere outside the focused text field takes the focus out of
    # it. WPF only moves focus on a click on something focusable; on the
    # background or a card the cursor would stay, and an emptied field would
    # not show its grey hint text again.
    $UI.Window.Add_PreviewMouseDown({
        param($sender, $e)
        $focused = [System.Windows.Input.Keyboard]::FocusedElement
        if ($focused -isnot [System.Windows.Controls.TextBox]) { return }
        # Click inside the focused field itself (text, its X button): leave it.
        $el = $e.OriginalSource
        while ($el) {
            if ([object]::ReferenceEquals($el, $focused)) { return }
            if ($el -is [System.Windows.Controls.Button] -and [object]::ReferenceEquals($el.Parent, $focused.Parent)) { return }
            $el = if ($el -is [System.Windows.Media.Visual] -or $el -is [System.Windows.Media.Media3D.Visual3D]) {
                      [System.Windows.Media.VisualTreeHelper]::GetParent($el)
                  } else {
                      [System.Windows.LogicalTreeHelper]::GetParent($el)
                  }
        }
        $scope = [System.Windows.Input.FocusManager]::GetFocusScope($focused)
        [System.Windows.Input.FocusManager]::SetFocusedElement($scope, $null)
        [System.Windows.Input.Keyboard]::ClearFocus()
    })

    # Escape in a filter field empties it and takes the focus out (hint text
    # shows again, TextChanged refreshes the list).
    # No GetNewClosure: the handler must see the module function Clear-SearchField.
    foreach ($ecBox in @($UI.txtSourceFilter, $UI.txtTargetFilter)) {
        if (-not $ecBox) { continue }
        $ecBox.Add_PreviewKeyDown({
            param($sender, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
                $hint = if ($sender -eq $UI.txtSourceFilter) { $UI.txtSourceFilterHint } else { $UI.txtTargetFilterHint }
                Clear-SearchField $sender $hint
                $e.Handled = $true
            }
        })
    }

    # ── GotFocus/LostFocus for all filter hints ───────────────────────────────────
    if ($UI.txtSourceFilter) {
        $UI.txtSourceFilter.Add_GotFocus({ if ($UI.txtSourceFilterHint) { $UI.txtSourceFilterHint.Visibility = 'Collapsed' } })
        $UI.txtSourceFilter.Add_LostFocus({ if ($UI.txtSourceFilterHint) { $UI.txtSourceFilterHint.Visibility = if ($UI.txtSourceFilter.Text) { 'Collapsed' } else { 'Visible' } } })
    }
    if ($UI.txtTargetFilter) {
        $UI.txtTargetFilter.Add_GotFocus({ if ($UI.txtTargetFilterHint) { $UI.txtTargetFilterHint.Visibility = 'Collapsed' } })
        $UI.txtTargetFilter.Add_LostFocus({ if ($UI.txtTargetFilterHint) { $UI.txtTargetFilterHint.Visibility = if ($UI.txtTargetFilter.Text) { 'Collapsed' } else { 'Visible' } } })
    }

    # ── Tenant dropdown changes ───────────────────────────────────────────────────
    # Tenant Configuration opens on the tenant of the side the user used last
    # (dropdown change or a load); Source at start. Selections made by
    # Basetune itself (start-up, after a save) do not count.
    $AppState.lastPickedTenantSide = 'Source'
    $UI.cmbSourceTenant.Add_SelectionChanged({
        $newKey = if ($UI.cmbSourceTenant.SelectedItem) { $UI.cmbSourceTenant.SelectedItem.Tag } else { $null }
        if (-not $AppState.suppressEvents -and $UI.Window.IsLoaded -and $newKey -and $newKey -ne $AppState.lastSourceTenantKey) {
            $AppState.lastPickedTenantSide = 'Source'
        }
        if (-not $AppState.suppressEvents -and $newKey -ne $AppState.lastSourceTenantKey) { Reset-Side 'Source' }
        $AppState.lastSourceTenantKey = $newKey
        Update-ExportButtons
    })
    $UI.cmbTargetTenant.Add_SelectionChanged({
        $newKey = if ($UI.cmbTargetTenant.SelectedItem) { $UI.cmbTargetTenant.SelectedItem.Tag } else { $null }
        if (-not $AppState.suppressEvents -and $UI.Window.IsLoaded -and $newKey -and $newKey -ne $AppState.lastTargetTenantKey) {
            $AppState.lastPickedTenantSide = 'Target'
        }
        if (-not $AppState.suppressEvents -and $newKey -ne $AppState.lastTargetTenantKey) { Reset-Side 'Target' }
        $AppState.lastTargetTenantKey = $newKey
        Update-ExportButtons
    })
}

Export-ModuleMember -Function @(
    'Set-VisibleSelection',
    'Clear-SearchField',
    'Update-SelectionRow',
    'Get-SelectionSnapshot',
    'Test-SelectionSnapshot',
    'Update-Counts',
    'Reset-Side',
    'Set-FilterMode',
    'Get-LoadingCardText',
    'Update-EmptyState',
    'Update-ListFilter',
    'Update-ListSortHeaders',
    'Test-ListToolsAllowed',
    'Enable-ListToolsDuringJob',
    'Set-ListSort',
    'Enable-WholeLineList',
    'Enable-PolicyListKeys',
    'Initialize-PolicyListEvents'
)
