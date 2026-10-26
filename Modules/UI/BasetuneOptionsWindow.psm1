# =============================================================================
# BasetuneOptionsWindow.psm1
# Options window (Open-OptionsWindow): max threads, platforms, theme and
# report folder. $UI / $AppState come from BasetuneState.psm1.
# =============================================================================

$script:UI       = (Get-BasetuneContext).UI
$script:AppState = (Get-BasetuneContext).State

# Fixed default report folder (Basetune\Reports), see BasetuneUI.ps1.
function Get-DefaultReportPath { return $AppState.defaultReportPath }

# ═════════════════════════════════════════════════════════════════════════════
# SETTINGS WINDOW
# ═════════════════════════════════════════════════════════════════════════════
function Open-OptionsWindow {
    $sWindow = Import-Xaml -Path "$($AppState.XamlPath)\BasetuneOptions.xaml" -Width 520 -Height 400
    $sWindow.Owner = $UI.Window

    function Find-OptionsControl { param([string]$n) Find-InTree -Root $sWindow -Name $n }

    $sBtnCloseSettings = Find-OptionsControl 'btnCloseSettings'
    $sBtnSave          = Find-OptionsControl 'btnSaveSettings'
    $sCmbMaxThreads    = Find-OptionsControl 'cmbMaxThreads'
    $sCmbPlatforms     = Find-OptionsControl 'cmbPlatforms'
    $sCmbTheme         = Find-OptionsControl 'cmbTheme'
    $sTxtPlatforms     = Find-OptionsControl 'txtPlatforms'
    $sTxtPathReport    = Find-OptionsControl 'cfgPathReport'
    $sBtnBrowseReport  = Find-OptionsControl 'btnBrowsePathReport'

    # Populate with current saved values
    if (-not $AppState.savedMaxThreads)  { $AppState.savedMaxThreads  = '8' }
    if (-not $AppState.savedPathReport)  { $AppState.savedPathReport  = Get-DefaultReportPath }
    # Max threads: only the allowed values (1..32), so none can be invalid.
    $mtRange = Get-MaxThreadsRange
    if ($sCmbMaxThreads) {
        $sCmbMaxThreads.ItemsSource  = @($mtRange.Min..$mtRange.Max | ForEach-Object { "$_" })
        $sCmbMaxThreads.SelectedItem = "$(Get-ValidMaxThreads $AppState.savedMaxThreads)"
    }
    if ($sTxtPathReport)   { $sTxtPathReport.Text   = $AppState.savedPathReport }
    # Theme: a new choice is shown right away (preview); Save Settings keeps
    # it, closing without saving goes back to the saved theme.
    if ($sCmbTheme) {
        $sCmbTheme.ItemsSource  = @('Dark', 'Light')
        $sCmbTheme.SelectedItem = if ((Get-BasetuneTheme) -eq 'light') { 'Light' } else { 'Dark' }
    }

    # Platforms: a checkbox per platform (multi-select). The ComboBox never
    # keeps a selected item; the text on top shows the ticked platforms. A
    # click anywhere on a row toggles it and keeps the list open.
    if (-not $AppState.savedPlatforms) { $AppState.savedPlatforms = Get-DefaultPlatforms }
    $script:optPlatformChecks = [System.Collections.Generic.List[object]]::new()
    if ($sCmbPlatforms) {
        foreach ($o in (Get-PlatformOptions)) {
            $cb = [System.Windows.Controls.CheckBox]::new()
            $cb.Content   = $o.Label
            $cb.Tag       = $o.Key
            $cb.IsChecked = ($o.Key -in $AppState.savedPlatforms)
            $cb.Padding   = [System.Windows.Thickness]::new(8, 0, 0, 0)
            $cb.FontSize  = 13
            $bd = [System.Windows.Controls.Border]::new()
            $bd.Background = [System.Windows.Media.Brushes]::Transparent
            $bd.Padding    = [System.Windows.Thickness]::new(8, 6, 8, 6)
            $bd.Child      = $cb
            # Click next to the checkbox (row padding): toggle too, and mark it
            # handled so the ComboBox does not select the row and close.
            $bd.Add_MouseLeftButtonUp({
                param($sender, $e)
                $sender.Child.IsChecked = -not [bool]$sender.Child.IsChecked
                $e.Handled = $true
            })
            $ci = [System.Windows.Controls.ComboBoxItem]::new()
            $ci.Padding = [System.Windows.Thickness]::new(0)
            $ci.Content = $bd
            [void]$sCmbPlatforms.Items.Add($ci)
            $script:optPlatformChecks.Add($cb)
        }
        # Keyboard (Enter on a row) selects it: toggle that row instead.
        $sCmbPlatforms.Add_SelectionChanged({
            param($sender, $e)
            $ci = $sender.SelectedItem
            if (-not $ci) { return }
            $sender.SelectedIndex = -1
            $cbx = $ci.Content.Child
            $cbx.IsChecked = -not [bool]$cbx.IsChecked
        })
    }
    # Ticked platform keys in the fixed order (windows, macos, ios, android, linux).
    $getPlatformsNow = {
        @($script:optPlatformChecks | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag })
    }
    $updatePlatformText = {
        if (-not $sTxtPlatforms) { return }
        $labels = @($script:optPlatformChecks | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Content })
        if ($labels.Count -eq 0) {
            $sTxtPlatforms.Text = 'Select at least one platform'
            $sTxtPlatforms.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'HintBrush')
        } else {
            $sTxtPlatforms.Text = if ($labels.Count -eq $script:optPlatformChecks.Count) { 'All platforms' } else { $labels -join ', ' }
            $sTxtPlatforms.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'TextBrush')
        }
        if ($sCmbPlatforms) { $sCmbPlatforms.ToolTip = if ($labels.Count) { $labels -join ', ' } else { 'Settings Catalog platforms to load' } }
    }
    & $updatePlatformText

    # Snapshot of the values: Save Settings is enabled only on a real change.
    $script:originalMaxThreads = if ($sCmbMaxThreads) { "$($sCmbMaxThreads.SelectedItem)" } else { '' }
    $script:originalPathReport = if ($sTxtPathReport) { $sTxtPathReport.Text } else { '' }
    $script:originalPlatforms  = (& $getPlatformsNow) -join ','
    $script:originalTheme      = if ($sCmbTheme) { "$($sCmbTheme.SelectedItem)" } else { '' }

    # Save Settings is enabled only when something changed and the report
    # path is valid. Max threads is always valid (picked from the list).
    $updateSaveState = {
        if (-not $sBtnSave) { return }
        $mtNow   = if ($sCmbMaxThreads) { "$($sCmbMaxThreads.SelectedItem)" } else { '' }
        $pathNow = if ($sTxtPathReport) { $sTxtPathReport.Text } else { '' }

        # Report path: empty = default Reports folder, else a valid full path
        # (need not exist yet). Invalid: red border + tooltip.
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

        # Platforms: at least one must be ticked.
        $pfNow   = (& $getPlatformsNow) -join ','
        $pfValid = [bool]$pfNow

        $themeNow = if ($sCmbTheme) { "$($sCmbTheme.SelectedItem)" } else { '' }

        $changed = ($mtNow -ne $script:originalMaxThreads) -or ($pathNow -ne $script:originalPathReport) -or
                   ($pfNow -ne $script:originalPlatforms) -or ($themeNow -ne $script:originalTheme)
        $sBtnSave.IsEnabled = $changed -and $pathValid -and $pfValid
    }

    if ($sCmbMaxThreads) { $sCmbMaxThreads.Add_SelectionChanged($updateSaveState) }
    if ($sCmbTheme) {
        $sCmbTheme.Add_SelectionChanged({
            $t = if ("$($sCmbTheme.SelectedItem)" -eq 'Light') { 'light' } else { 'dark' }
            if ($t -ne (Get-BasetuneTheme)) { Set-BasetuneTheme $t }
            & $updateSaveState
        })
    }
    foreach ($cb in $script:optPlatformChecks) {
        $cb.Add_Checked({ & $updatePlatformText; & $updateSaveState })
        $cb.Add_Unchecked({ & $updatePlatformText; & $updateSaveState })
    }
    if ($sTxtPathReport) { $sTxtPathReport.Add_TextChanged($updateSaveState) }

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
            # Safety net (Save is disabled while the path is invalid). Stored
            # normalized: C:\Reports\ -> C:\Reports.
            $reportPathInput = $null
            if ($sTxtPathReport -and $sTxtPathReport.Text.Trim()) {
                $rp = Resolve-FolderPath -Path $sTxtPathReport.Text -RequireAbsolute
                if ($rp.Error) {
                    [System.Windows.MessageBox]::Show("Report folder is not valid.`n`n$($rp.Error)", "Basetune", 'OK', 'Warning') | Out-Null
                    return
                }
                $reportPathInput = $rp.Path
            }
            # A folder that does not exist yet is fine: the compare creates it.
            if ($reportPathInput -and (Test-Path -LiteralPath $reportPathInput -PathType Leaf)) {
                [System.Windows.MessageBox]::Show("Report folder '$reportPathInput' is a file, not a folder.", "Basetune", 'OK', 'Warning') | Out-Null
                return
            }

            # Persist values
            $mtRange = Get-MaxThreadsRange
            $AppState.savedMaxThreads = if ($sCmbMaxThreads -and $sCmbMaxThreads.SelectedItem) { "$($sCmbMaxThreads.SelectedItem)" } else { "$($mtRange.Default)" }
            $AppState.savedPathReport = if ($reportPathInput) { $reportPathInput } else { Get-DefaultReportPath }
            $pfPicked = @(& $getPlatformsNow)
            if ($pfPicked.Count -gt 0) { $AppState.savedPlatforms = [string[]]$pfPicked }
            # Theme: kept, also when saving Options.json fails below (then for
            # this session only).
            if ($sCmbTheme -and $sCmbTheme.SelectedItem) {
                $AppState.savedTheme = if ("$($sCmbTheme.SelectedItem)" -eq 'Light') { 'light' } else { 'dark' }
            }

            # Write to Options.json (Config.json holds the tenants only)
            try {
                Save-Options
                # Apply the new report path immediately so the next run uses it.
                $AppState.reportBasePath = if ($AppState.savedPathReport -and $AppState.savedPathReport.Trim()) {
                    $AppState.savedPathReport.Trim()
                } else {
                    Get-DefaultReportPath
                }
                # Show the normalized path (e.g. trailing '\' removed).
                if ($sTxtPathReport -and $reportPathInput) { $sTxtPathReport.Text = $reportPathInput }
                # New snapshot: Save Settings disabled until the next change.
                # The window stays open.
                $script:originalMaxThreads = if ($sCmbMaxThreads) { "$($sCmbMaxThreads.SelectedItem)" } else { '' }
                $script:originalPathReport = if ($sTxtPathReport) { $sTxtPathReport.Text } else { '' }
                $script:originalPlatforms  = (& $getPlatformsNow) -join ','
                $script:originalTheme      = if ($sCmbTheme) { "$($sCmbTheme.SelectedItem)" } else { '' }
                $sBtnSave.IsEnabled = $false
            } catch {
                # Options.json is separate: an unreadable Config.json does not
                # block saving the options.
                Write-Log 'Config' 'Could not save the settings. See the log file for details' 'ERROR'
                Write-Log 'Config' "Details: $($_.Exception.Message)" 'ERROR' -FileOnly
                [System.Windows.MessageBox]::Show("Error saving settings: $_", "Basetune", 'OK', 'Error') | Out-Null
            }
        })
    }

    # Closed without saving the theme: back to the saved theme.
    $sWindow.Add_Closed({
        $keep = if ($AppState.savedTheme -eq 'light') { 'light' } else { 'dark' }
        if ((Get-BasetuneTheme) -ne $keep) { Set-BasetuneTheme $keep }
    })

    $sWindow.Add_KeyDown({ param($s,$e); if ($e.Key -eq 'Escape') { $sWindow.Close() } })
    $sWindow.ShowDialog() | Out-Null
}

# ═════════════════════════════════════════════════════════════════════════════
# INITIALISATION
# Opens Options from the main window. Called once from BasetuneUI.ps1.
# ═════════════════════════════════════════════════════════════════════════════
function Initialize-OptionsWindowEvents {
    $UI.btnOpenOptions.Add_Click({ Open-OptionsWindow })
}

Export-ModuleMember -Function @(
    'Get-DefaultReportPath',
    'Open-OptionsWindow',
    'Initialize-OptionsWindowEvents'
)
