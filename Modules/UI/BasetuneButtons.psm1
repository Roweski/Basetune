# =============================================================================
# BasetuneButtons.psm1
# Busy state (Set-Busy: the active button becomes Cancel, the rest is
# disabled while a job runs) and the look of the main window buttons: Load /
# Compare / icon button modes, the Download button colour, Export buttons
# enabled per tenant and selection.
# =============================================================================

# Controls of the main and config window, by x:Name (BasetuneState.psm1).
$script:UI = (Get-BasetuneContext).UI
# Current job, list items, selection state (initialised in BasetuneUI.ps1).
$script:AppState = (Get-BasetuneContext).State

# ── Busy state — turns the active Load button into Cancel; restores on done ──

function script:New-ButtonContent {
    param([string]$IconPath, [string]$Label, [int]$Size = 15, [string]$IconMargin = '0,1,0,0')
    # Same as the XAML Load / Compare content: the icon Fill binds to the
    # Button's Foreground, so the colour of every style (idle, the red Cancel,
    # the disabled colour) reaches the icon too.
    $xaml = @"
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
            Orientation="Horizontal">
  <Viewbox Width="$Size" Height="$Size" Stretch="Uniform" Margin="$IconMargin" VerticalAlignment="Center">
    <Canvas Width="24" Height="24">
      <Path Fill="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"
            Data="$IconPath"/>
    </Canvas>
  </Viewbox>
  <TextBlock Text="$Label" Margin="6,0,0,0" VerticalAlignment="Center" Visibility="{DynamicResource StripLabelVisibility}"/>
</StackPanel>
"@
    return [System.Windows.Markup.XamlReader]::Parse($xaml)
}

# The XAML content of the Load buttons (play icon + "Load"), kept the first
# time a load turns one into Cancel and put back when idle, so the XAML stays
# the one place that defines it (icon, its StripPlayIconMargin).
$script:loadIdleContent = @{}
# Cancel X: left margin -1.5: the 18px icon is wider than
# the 15px inside the 12.5 padding of a 40px button, so it would sit 1.5 right.
$script:iconStop  = "M19,6.41L17.59,5L12,10.59L6.41,5L5,6.41L10.59,12L5,17.59L6.41,19L12,13.41L17.59,19L19,17.59L13.41,12L19,6.41Z"

# The Cancel of every strip button (Load, Compare, Export, Download): the
# StripCancelBtn style of BasetuneTheme.xaml (a red line at the bottom), looked
# up on first use (the theme must be loaded). Idle, each button
# gets its own XAML style back (idleStyleCache).
$script:styleCancel = $null
function script:Initialize-ButtonStyles {
    if ($script:styleCancel) { return }
    $script:styleCancel = [System.Windows.Application]::Current.FindResource('StripCancelBtn')
}

# Keep a button's XAML style the first time it is restyled, so idle can put
# it back (Style=$null would lose the strip look and hover).
function script:Save-IdleStyle {
    param($Btn)
    if (-not $script:idleStyleCache.ContainsKey($Btn.Name)) {
        $script:idleStyleCache[$Btn.Name] = $Btn.Style
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Icon-only button mode toggle (Download + Export)
#
# While a job runs, a square icon button (Download, Export) becomes a red
# Cancel with an X (CancelAction* palette colours) and the tooltip "Cancel";
# idle restores its XAML StripIconBtn style and icon.
# ─────────────────────────────────────────────────────────────────────────────

# Material Design "close" (X).
$script:iconCancelX = "M19,6.41L17.59,5L12,10.59L6.41,5L5,6.41L10.59,12L5,17.59L6.41,19L12,13.41L17.59,19L19,17.59L13.41,12L19,6.41Z"

# Idle icons for Set-IconButtonMode / New-DownloadButtonContent. Keep them in
# sync with the inline Path Data in BasetuneUI.xaml:
#   iconDownload -> btnOpenDownload (box with a list: dots and lines)
#   iconExport   -> btnSourceExport / btnTargetExport (square with arrow leaving top-right)
$script:iconDownload = "M5,3H19A2,2 0 0,1 21,5V19A2,2 0 0,1 19,21H5A2,2 0 0,1 3,19V5A2,2 0 0,1 5,3Z M5.5,7H7.5V9H5.5Z M9.5,7H18.5V9H9.5Z M5.5,11H7.5V13H5.5Z M9.5,11H18.5V13H9.5Z M5.5,15H7.5V17H5.5Z M9.5,15H18.5V17H9.5Z"   # the View Report box with a list (dots and lines) cut out, see New-DownloadButtonContent
$script:iconExport   = "M14,3V5H17.59L12.67,9.91L14.08,11.32L19,6.41V10H21V3M19,19H5V5H12V3H5C3.89,3 3,3.89 3,5V19A2,2 0 0,0 5,21H19A2,2 0 0,0 21,19V12H19V19Z"

$script:idleStyleCache = @{}
$script:idleContentCache = @{}   # XAML icon content per button (keeps its glyph margin)

# Icon-only Viewbox content for a square button (idle icon or cancel X).
# The Path Fill is bound to the Button's Foreground, as in the XAML icon
# buttons: the StripIconBtn IsEnabled=False trigger greys the Foreground, and only
# a bound Fill follows it (a fixed brush would stay dark when disabled).
function script:New-IconOnlyContent {
    param([string]$IconPath, [int]$Size = 15, [string]$Margin = '0')
    $xaml = @"
<Viewbox xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
         Width="$Size" Height="$Size" Stretch="Uniform" Margin="$Margin">
  <Canvas Width="24" Height="24">
    <Path Fill="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"
          Data="$IconPath"/>
  </Canvas>
</Viewbox>
"@
    return [System.Windows.Markup.XamlReader]::Parse($xaml)
}

# Flip a strip icon button between idle (XAML StripIconBtn style + action icon)
# and cancel (red like Load in Cancel mode, with an X, tooltip "Cancel").
#
#   Mode      — 'idle' or 'cancel'
#   IdleIcon  — icon path for idle, used when no XAML content was cached
#   IconSize  — Viewbox size (20, as all strip icons)
function Set-IconButtonMode {
    param(
        [Parameter(Mandatory)]$Btn,
        [Parameter(Mandatory)][ValidateSet('idle','cancel')][string]$Mode,
        [Parameter(Mandatory)][string]$IdleIcon,
        [int]$IconSize = 15
    )

    Save-IdleStyle $Btn
    # Same for the XAML icon content, so idle restores the exact glyph
    # (incl. its optical margin) instead of a rebuilt, centred one.
    if (-not $script:idleContentCache.ContainsKey($Btn.Name) -and $Btn.Tag -ne 'cancel') {
        $script:idleContentCache[$Btn.Name] = $Btn.Content
    }
    # Start from the idle style (defensive).
    $Btn.Style = $script:idleStyleCache[$Btn.Name]

    if ($Mode -eq 'cancel') {
        # Red (CancelAction* palette brushes) with the X: same look as Load while it runs (a square
        # strip segment: Export and Download sit in a strip).
        Initialize-ButtonStyles
        $Btn.Style   = $script:styleCancel
        # Size 18, as all strip icons; in a 40px segment the even leftover (22)
        # centres it. The X path is symmetric (5..19 of 24).
        # Margin top 2 moves it exactly 1px down, which looks centred.
        $Btn.Content = New-IconOnlyContent $script:iconCancelX 18 '0,2,0,0'
        $Btn.Tag     = 'cancel'
        $Btn.ToolTip = 'Cancel'
        $Btn.IsEnabled = $true   # cancel must be clickable
    } else {
        # No cached content: Download gets its own (New-DownloadButtonContent),
        # the others the idle icon.
        $Btn.Content = if ($script:idleContentCache[$Btn.Name]) { $script:idleContentCache[$Btn.Name] }
                       elseif ($Btn -eq $UI.btnOpenDownload) { New-DownloadButtonContent }
                       else { New-IconOnlyContent $IdleIcon $IconSize }
        $Btn.Tag     = $null
        # The caller sets the idle ToolTip again.
    }
    # Download as Cancel hides the attention tooltip, idle may show it again.
    if ($Btn -eq $UI.btnOpenDownload) { Update-AttentionTip }
}

function Set-LoadButtonMode {
    # Load / Cancel in its tenant strip: red Cancel with the X, or its XAML
    # style (StripAccentBtn) and content (play icon + "Load") back.
    param($btn, [string]$Mode)
    Save-IdleStyle $btn
    Initialize-ButtonStyles
    if ($Mode -eq 'cancel') {
        if ($btn.Tag -ne 'cancel' -and -not $script:loadIdleContent.ContainsKey($btn.Name)) {
            $script:loadIdleContent[$btn.Name] = $btn.Content
        }
        $btn.Content = New-ButtonContent $script:iconStop 'Cancel' 18 '-1.5,1,0,0'
        $btn.Style   = $script:styleCancel
        $btn.Tag     = 'cancel'
        $btn.ToolTip = 'Cancel'
    } else {
        if ($script:loadIdleContent.ContainsKey($btn.Name)) { $btn.Content = $script:loadIdleContent[$btn.Name] }
        $btn.Style = $script:idleStyleCache[$btn.Name]
        $btn.Tag   = $null
        $btn.ToolTip = 'Load policies'   # the idle tooltip of the XAML
    }
}



# ─────────────────────────────────────────────────────────────────────────────
# Download button look (icon-only square):
#   $Missing = $false  definitions on disk: the XAML StripIconBtn style, like the
#                      Config and Options buttons next to it.
#   $Missing = $true   one or both definition files missing: the action look
#                      (StripAccentBtn: the blue line at the bottom).
#
# Called by Update-DownloadButton (BasetuneActions.psm1). Cancel mode
# (Set-IconButtonMode) is separate; after a job this sets the idle look again.
# ─────────────────────────────────────────────────────────────────────────────
function Set-DownloadButtonStyle {
    # The action look only when there are no definition files at all; otherwise the
    # normal look. The tooltip is always "Download Definitions" (settings
    # without a definition are reported in the log at the end of a compare).
    param([bool]$Missing)

    $btn = $UI.btnOpenDownload
    if (-not $btn) { return }

    # Cache the XAML style on first touch (shared with Set-IconButtonMode).
    if (-not $script:idleStyleCache.ContainsKey($btn.Name)) {
        $script:idleStyleCache[$btn.Name] = $btn.Style
    }

    # Size and content are the same in every mode; only the style changes
    # (the width is that of its strip segment). The icon Fill is bound to the
    # Foreground (New-DownloadButtonContent), so a new style recolours the
    # icon too.
    $btn.Height  = 34
    $btn.Padding = [System.Windows.Thickness]::new(0)
    $btn.Content = New-DownloadButtonContent

    if ($Missing) {
        # No definition files at all - the action look, so it is clear where to start.
        $btn.Style = $btn.FindResource('StripAccentBtn')
    } else {
        # Definitions present - neutral strip look
        $btn.Style = $script:idleStyleCache[$btn.Name]
    }
    $btn.ToolTip = 'Download Definitions'
    $script:definitionsMissing = $Missing
    Update-AttentionTip
}

# Baseline Configuration button: the attention look (StripAttentionIconBtn: the
# tint and a blue icon) while no tenant is configured, the first step the log
# names ("Click the layers icon ..."); otherwise the normal strip look. Called by
# Sync-MainTenantDropdowns (startup, after Baseline Configuration). The disabled
# look during a job comes from the style itself.
function Update-ConfigButtonStyle {
    $btn = $UI.btnOpenConfig
    if (-not $btn) { return }
    if (-not $script:idleStyleCache.ContainsKey($btn.Name)) {
        $script:idleStyleCache[$btn.Name] = $btn.Style
    }
    $btn.Style = if (@($AppState.tenantStore.Keys).Count -eq 0) { $btn.FindResource('StripAttentionIconBtn') }
                 else { $script:idleStyleCache[$btn.Name] }
    $btn.ToolTip = 'Baseline Configuration'
    Update-AttentionTip
}

# ── Attention tooltip — the first step, shown without hovering ──────────────
# No tenant configured: the tooltip of Baseline Configuration (bottom left) stays
# open; tenants but no definition files: the one of Download Definitions. Tenants
# first: without a tenant there is nothing to download with. A ToolTip of its own
# (not the button's, which closes when the mouse leaves), placed as the button
# tooltips (Top, -4); the button's own tooltip is off while it shows, so hovering
# never shows the text twice.
# Shown only while the main window is active and not minimised (a popup stays on
# top of other windows) and the button can be used (not disabled by a job, not
# the red Cancel of a running download). A click anywhere in the window closes
# it for good for that button ($script:attentionDismissed); when the next step
# changes (a tenant added, definitions still missing) the other one shows.
# Initialize-AttentionTip wires the window events; Update-ConfigButtonStyle /
# Set-DownloadButtonStyle call it when the state changes.
$script:definitionsMissing = $false
$script:attentionTip       = $null
$script:attentionDismissed = @{}
function script:Get-AttentionTarget {
    if (@($AppState.tenantStore.Keys).Count -eq 0) { return $UI.btnOpenConfig }
    if ($script:definitionsMissing) { return $UI.btnOpenDownload }
    return $null
}
function script:Update-AttentionTip {
    $win = $UI.Window
    if (-not $win) { return }
    $target = Get-AttentionTarget
    $show = $target -and -not $script:attentionDismissed[$target.Name] -and
            $win.IsLoaded -and $win.IsActive -and $win.WindowState -ne 'Minimized' -and
            $target.IsEnabled -and $target.IsVisible -and $target.Tag -ne 'cancel'
    if (-not $script:attentionTip) {
        $tip = [System.Windows.Controls.ToolTip]::new()
        $style = $win.TryFindResource([System.Windows.Controls.ToolTip])
        if ($style) { $tip.Style = $style }
        $tip.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Top
        $tip.VerticalOffset = -4
        $script:attentionTip = $tip
    }
    $tip = $script:attentionTip
    # The button tooltips back on, except the one the attention tip stands in for.
    foreach ($b in @($UI.btnOpenConfig, $UI.btnOpenDownload)) {
        if ($b) { [System.Windows.Controls.ToolTipService]::SetIsEnabled($b, -not ($show -and $b -eq $target)) }
    }
    if (-not $show) { $tip.IsOpen = $false; return }
    if ($tip.PlacementTarget -ne $target) { $tip.IsOpen = $false; $tip.PlacementTarget = $target }
    $tip.Content = [string]$target.ToolTip
    if ($tip.IsOpen) {
        # Moved or resized window: the popup does not follow by itself; a change
        # of offset makes it place itself again.
        $tip.HorizontalOffset = if ($tip.HorizontalOffset -eq 0) { 0.01 } else { 0 }
    } else {
        $tip.IsOpen = $true
    }
}

# Window and button events that can open, move or close the attention tooltip.
# Called once from BasetuneUI.ps1, after the window is created.
function Initialize-AttentionTip {
    $win = $UI.Window
    $win.Add_ContentRendered({ Update-AttentionTip })
    $win.Add_Activated({ Update-AttentionTip })
    $win.Add_Deactivated({ Update-AttentionTip })
    $win.Add_StateChanged({ Update-AttentionTip })
    $win.Add_LocationChanged({ Update-AttentionTip })
    $win.Add_SizeChanged({ Update-AttentionTip })
    $win.Add_Closing({ if ($script:attentionTip) { $script:attentionTip.IsOpen = $false } })
    # Any click in the window (Preview: before a button handles it) dismisses
    # the tooltip that shows now.
    $win.Add_PreviewMouseDown({
        $t = Get-AttentionTarget
        if ($t -and $script:attentionTip -and $script:attentionTip.IsOpen) {
            $script:attentionDismissed[$t.Name] = $true
            Update-AttentionTip
        }
    })
    foreach ($b in @($UI.btnOpenConfig, $UI.btnOpenDownload)) {
        if ($b) { $b.Add_IsEnabledChanged({ Update-AttentionTip }) }
    }
}

# Download button content as inline XAML, so the icon Fill binds to the
# Button's Foreground (a RelativeSource binding built from PowerShell is
# unreliable). The icon of the XAML (IconDownload in BasetuneTheme.xaml: the
# box with a list cut out), size 20 as View Report.
function script:New-DownloadButtonContent {
    $xaml = @"
<Viewbox xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
         Width="20" Height="20" Stretch="Uniform"
         HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,1,0,0">
  <Canvas Width="24" Height="24">
    <Path Fill="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"
          Data="$script:iconDownload"/>
  </Canvas>
</Viewbox>
"@
    return [System.Windows.Markup.XamlReader]::Parse($xaml)
}

# Compare button: Cancel (StripCancelBtn: red, the X, "Cancel", tooltip
# "Cancel") as soon as a compare runs (Start-Compare), Compare again when it is
# done (Set-Busy). The XAML style and content are kept on first use and put
# back for 'idle'.
function Set-CompareButtonMode {
    param([ValidateSet('idle','cancel')][string]$Mode)
    $btn = $UI.btnCompare
    if (-not $btn) { return }
    if (-not $script:compareIdle) {
        $script:compareIdle = @{ Style = $btn.Style; Content = $btn.Content }
    }
    # The height (34, the inside of its strip) is set in the XAML, a local
    # value: it stays when the style changes.
    if ($Mode -eq 'cancel') {
        if ($btn.Tag -eq 'cancel') { return }
        Initialize-ButtonStyles
        $btn.Content   = New-ButtonContent $script:iconStop 'Cancel' 20 '-1.5,1,0,0'
        $btn.Style     = $script:styleCancel
        $btn.Tag       = 'cancel'
        $btn.ToolTip   = 'Cancel'
        $btn.IsEnabled = $true
    } else {
        if ($btn.Tag -ne 'cancel') { return }
        $btn.Style   = $script:compareIdle.Style
        $btn.Content = $script:compareIdle.Content
        $btn.Tag     = $null
        $btn.ToolTip = 'Compare Policies'   # the idle tooltip of the XAML
    }
}

function Set-Busy {
    param([bool]$v, [string]$Side = '')

    # The button with keyboard focus (Load -> Cancel, Export, Download) gets a
    # new style/content below; give the focus back to it at the end, so a
    # keyboard user stays on Cancel and lands on Load again afterwards.
    $focusedBefore = [System.Windows.Input.Keyboard]::FocusedElement

    # $AppState.CurrentJob is the busy state: $null = idle, otherwise busy
    # (a stub made here, filled in by Start-Runspace). Update-Counts and
    # Update-ExportButtons re-enable nothing while it is set. Only Set-Busy
    # switches between busy and idle.
    if ($v) {
        if (-not $AppState.CurrentJob) {
            $AppState.CurrentJob = @{ Side = $Side; IsBusy = $true }
        } else {
            $AppState.CurrentJob.IsBusy = $true
            if ($Side) { $AppState.CurrentJob.Side = $Side }
        }
    } else {
        $AppState.CurrentJob = $null
    }

    # While a job runs: execution-speed throttling off, also with another
    # window in front (Windows can apply it to a process that is not in the
    # foreground; a large compare measured 55 s there against 33 s in front).
    # When idle, Windows manages it again. See Set-ProcessPowerThrottling in
    # BasetuneHelpers (Core).
    Set-ProcessPowerThrottling -Enabled (-not $v)

    # Run Report is off while any job runs; its enabled state is saved here
    # on entry and restored on exit, so a job never turns on a button that
    # was off before it.
    if ($v) {
        $AppState.btnOpenReportPriorState = [bool]$UI.btnOpenReport.IsEnabled
        $UI.btnOpenReport.IsEnabled = $false
    }

    $UI.progressBar.IsIndeterminate = $v
    if ($v) {
        $UI.progressBar.Value      = 0
        $UI.progressBar.Visibility = 'Visible'
    } else {
        $UI.progressBar.Value      = 0
        $UI.progressBar.Visibility = 'Hidden'
    }

    if ($v) {
        # Tenant pickers and filter fields off (Update-ExportButtons turns the
        # filters on again; during a load Enable-ListToolsDuringJob turns the
        # other side's back on); per Side below, which button becomes Cancel.
        $UI.cmbSourceTenant.IsEnabled = $false
        $UI.cmbTargetTenant.IsEnabled = $false
        if ($UI.txtSourceFilter) { $UI.txtSourceFilter.IsEnabled = $false }
        if ($UI.txtTargetFilter) { $UI.txtTargetFilter.IsEnabled = $false }
        # Baseline Configuration (all three layers buttons) is off while a job
        # runs: editing or removing a tenant (and rebuilding the tenant
        # dropdowns when it closes) must not happen during a load / compare /
        # export / download.
        foreach ($cfgBtn in $UI.btnOpenConfig, $UI.btnSourceConfig, $UI.btnTargetConfig) { if ($cfgBtn) { $cfgBtn.IsEnabled = $false } }

        if ($Side -eq 'Source') {
            $UI.btnOpenDownload.IsEnabled = $false
            $UI.btnSourceExport.IsEnabled = $false
            $UI.btnTargetExport.IsEnabled = $false
            $UI.btnTargetLoad.IsEnabled  = $false
            Set-LoadButtonMode $UI.btnSourceLoad 'cancel'
        } elseif ($Side -eq 'Target') {
            $UI.btnOpenDownload.IsEnabled = $false
            $UI.btnSourceExport.IsEnabled = $false
            $UI.btnTargetExport.IsEnabled = $false
            $UI.btnSourceLoad.IsEnabled  = $false
            Set-LoadButtonMode $UI.btnTargetLoad 'cancel'
        } elseif ($Side -eq 'Download') {
            # Download stays clickable as a red Cancel; everything else off.
            $UI.btnSourceExport.IsEnabled = $false
            $UI.btnTargetExport.IsEnabled = $false
            $UI.btnSourceLoad.IsEnabled  = $false
            $UI.btnTargetLoad.IsEnabled  = $false
            Set-IconButtonMode -Btn $UI.btnOpenDownload -Mode 'cancel' `
                -IdleIcon $script:iconDownload -IconSize 20
        } elseif ($Side -eq 'SourceExport' -or $Side -eq 'TargetExport') {
            # Active Export side stays clickable as a red Cancel.
            $UI.btnOpenDownload.IsEnabled = $false
            $UI.btnSourceLoad.IsEnabled  = $false
            $UI.btnTargetLoad.IsEnabled  = $false
            if ($Side -eq 'SourceExport') {
                $UI.btnTargetExport.IsEnabled = $false
                Set-IconButtonMode -Btn $UI.btnSourceExport -Mode 'cancel' `
                    -IdleIcon $script:iconExport -IconSize 16
            } else {
                $UI.btnSourceExport.IsEnabled = $false
                Set-IconButtonMode -Btn $UI.btnTargetExport -Mode 'cancel' `
                    -IdleIcon $script:iconExport -IconSize 16
            }
        } else {
            # Compare (the one job without a side): everything load-related off;
            # Compare itself becomes its Cancel (Set-CompareButtonMode, Start-Compare).
            $UI.btnOpenDownload.IsEnabled = $false
            $UI.btnSourceExport.IsEnabled = $false
            $UI.btnTargetExport.IsEnabled = $false
            $UI.btnSourceLoad.IsEnabled  = $false
            $UI.btnTargetLoad.IsEnabled  = $false
        }
    } else {
        # Compare: a Cancel back into Compare (Update-Counts decides whether it is enabled).
        Set-CompareButtonMode 'idle'

        # Restore both Load buttons to normal state
        Set-LoadButtonMode $UI.btnSourceLoad 'load'
        $UI.btnSourceLoad.IsEnabled = $true
        Set-LoadButtonMode $UI.btnTargetLoad 'load'
        $UI.btnTargetLoad.IsEnabled = $true
        $UI.cmbSourceTenant.IsEnabled = $true
        $UI.cmbTargetTenant.IsEnabled = $true
        foreach ($cfgBtn in $UI.btnOpenConfig, $UI.btnSourceConfig, $UI.btnTargetConfig) { if ($cfgBtn) { $cfgBtn.IsEnabled = $true } }

        # Download / Export icon buttons back to idle, only those in cancel
        # mode (Tag), so an untouched button keeps its ToolTip.
        if ($UI.btnOpenDownload.Tag -eq 'cancel') {
            Set-IconButtonMode -Btn $UI.btnOpenDownload -Mode 'idle' `
                -IdleIcon $script:iconDownload -IconSize 20
            $UI.btnOpenDownload.ToolTip = 'Download Definitions'
        }
        if ($UI.btnSourceExport.Tag -eq 'cancel') {
            Set-IconButtonMode -Btn $UI.btnSourceExport -Mode 'idle' `
                -IdleIcon $script:iconExport -IconSize 16
            $UI.btnSourceExport.ToolTip = 'Export Policies'
        }
        if ($UI.btnTargetExport.Tag -eq 'cancel') {
            Set-IconButtonMode -Btn $UI.btnTargetExport -Mode 'idle' `
                -IdleIcon $script:iconExport -IconSize 16
            $UI.btnTargetExport.ToolTip = 'Export Policies'
        }

        Update-ExportButtons   # sets Download + Export buttons based on current tenant selection

        # Run Report back to its state before the job; Compare's OnDone
        # enables it afterwards when it made a new report.
        if ($null -ne $AppState.btnOpenReportPriorState) {
            $UI.btnOpenReport.IsEnabled = $AppState.btnOpenReportPriorState
            $AppState.btnOpenReportPriorState = $null
        }
    }

    if ($focusedBefore -is [System.Windows.UIElement] -and
        $focusedBefore.IsEnabled -and $focusedBefore.IsVisible -and
        -not $focusedBefore.IsKeyboardFocused) {
        [void]$focusedBefore.Focus()
    }
}

# ── Enable/disable Export buttons based on online tenant + selection ─────────
function Update-ExportButtons {
    # Nothing is re-enabled while a job runs. $AppState.CurrentJob is the
    # busy signal shared by all modules (set and cleared by Set-Busy).
    if ($AppState.CurrentJob) { return }

    foreach ($side in @('Source', 'Target')) {
        $btn = if ($side -eq 'Source') { $UI.btnSourceExport } else { $UI.btnTargetExport }
        if (-not $btn) { continue }
        $key   = if ($side -eq 'Source') { $UI.cmbSourceTenant.SelectedValue } `
                 else                    { $UI.cmbTargetTenant.SelectedValue  }
        $items = if ($side -eq 'Source') { $AppState.sourceItems } else { $AppState.targetItems }

        $canDo = $false
        if ($key) {
            $entry = $AppState.tenantList | Where-Object { $_.Key -eq $key } | Select-Object -First 1
            # Online tenants and offline baselines alike (the export writes the loaded
            # policies); at least one must be checked, or it makes an empty folder.
            $hasSelection = @($items | Where-Object { $_.IsChecked }).Count -gt 0
            $canDo = [bool]$entry -and $hasSelection
        }
        $btn.IsEnabled = $canDo

        # No tenant selected (none configured yet): the tenant dropdown, Load
        # and the filter field are off too — there is nothing to load from.
        $load = if ($side -eq 'Source') { $UI.btnSourceLoad }   else { $UI.btnTargetLoad }
        $flt  = if ($side -eq 'Source') { $UI.txtSourceFilter } else { $UI.txtTargetFilter }
        $cmb  = if ($side -eq 'Source') { $UI.cmbSourceTenant } else { $UI.cmbTargetTenant }
        if ($load -and $load.Tag -ne 'cancel') { $load.IsEnabled = [bool]$key }
        if ($flt) { $flt.IsEnabled = [bool]$key }
        if ($cmb) { $cmb.IsEnabled = [bool]$key }
    }

    # Download always enabled — no-online-tenant check happens at click time
    if ($UI.btnOpenDownload) {
        $UI.btnOpenDownload.IsEnabled = $true
    }
}

Export-ModuleMember -Function @(
    'Set-IconButtonMode',
    'Set-LoadButtonMode',
    'Set-CompareButtonMode',

    'Set-DownloadButtonStyle',
    'Update-ConfigButtonStyle',
    'Initialize-AttentionTip',
    'Set-Busy',
    'Update-ExportButtons'
)
