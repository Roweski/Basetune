# =============================================================================
# BasetuneUI.psm1
# Small UI-state helpers used across event handlers in BasetuneUI.ps1.
# =============================================================================

# ── Busy state — turns the active Load button into Cancel; restores on done ──

function script:New-ButtonContent {
    param([string]$IconPath, [string]$Label)
    # Mirror the XAML PrimaryBtn pattern (Compare / Run Report) exactly:
    # icon Path Fill binds via RelativeSource AncestorType=Button. Make-BtnStyle
    # now uses the same ControlTemplate.Trigger structure as the XAML
    # PrimaryBtn so this binding gets the same disabled-state propagation.
    $xaml = @"
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
            Orientation="Horizontal" Margin="-2,0,0,0">
  <Viewbox Width="16" Height="16" Stretch="Uniform" Margin="0,1,6,0" VerticalAlignment="Center">
    <Canvas Width="24" Height="24">
      <Path Fill="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"
            Data="$IconPath"/>
    </Canvas>
  </Viewbox>
  <TextBlock Text="$Label" VerticalAlignment="Center"/>
</StackPanel>
"@
    return [System.Windows.Markup.XamlReader]::Parse($xaml)
}

$script:iconSync  = "M17.65,6.35C16.2,4.9 14.21,4 12,4A8,8 0 0,0 4,12A8,8 0 0,0 12,20C15.73,20 18.84,17.45 19.73,14H17.65C16.83,16.33 14.61,18 12,18A6,6 0 0,1 6,12A6,6 0 0,1 12,6C13.66,6 15.14,6.69 16.22,7.78L13,11H20V4L17.65,6.35Z"
$script:iconStop  = "M19,6.41L17.59,5L12,10.59L6.41,5L5,6.41L10.59,12L5,17.59L6.41,19L12,13.41L17.59,19L19,17.59L13.41,12L19,6.41Z"
$script:clrBlue   = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0x1A, 0x6E, 0xF5))
$script:clrBluHov = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0x16, 0x62, 0xD9))
$script:clrRed    = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0xCC, 0x33, 0x33))
$script:clrRedHov = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0xAA, 0x22, 0x22))

function script:Make-BtnStyle {
    param([string]$Bg, [string]$BgHover, [string]$BgDisabled = '#E5E7EB', [string]$FgDisabled = '#9AA3B0')
    $xaml = @"
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
       xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
       TargetType="Button">
  <Setter Property="Background" Value="$Bg"/>
  <Setter Property="Foreground" Value="White"/>
  <Setter Property="FontSize"   Value="13"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
  <Setter Property="Height"     Value="30"/>
  <Setter Property="BorderThickness" Value="0"/>
  <Setter Property="Cursor"     Value="Hand"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="7"
                Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True">
            <Setter Property="Background" Value="$BgHover"/>
          </Trigger>
          <Trigger Property="IsEnabled" Value="False">
            <Setter TargetName="bd" Property="Background" Value="$BgDisabled"/>
            <Setter Property="Foreground" Value="$FgDisabled"/>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
"@
    return [System.Windows.Markup.XamlReader]::Parse($xaml)
}

$script:styleLoad   = $null
$script:styleCancel = $null

# ─────────────────────────────────────────────────────────────────────────────
# Icon-only button mode toggle (Download + Export)
#
# Swaps a square icon button's icon between its action glyph (download arrow,
# export arrow) and a dark X to signal cancel mode during an active runspace.
# The SecBtn style (white background, grey border, blue border on hover) is
# kept in both modes — only the icon changes, with a ToolTip update to
# "Cancel" so hover gives the user a clear hint.
# ─────────────────────────────────────────────────────────────────────────────

# Material Design "close" outline (X). Rendered in #555 (same as the idle
# action icons) so the cancel state visually matches the rest of the icon-bar.
$script:iconCancelX = "M19,6.41L17.59,5L12,10.59L6.41,5L5,6.41L10.59,12L5,17.59L6.41,19L12,13.41L17.59,19L19,17.59L13.41,12L19,6.41Z"

# Idle icons used by Set-IconButtonMode when restoring buttons after a cancel.
# Kept here (not in XAML) so the toggle helper has a single source of truth.
# These two paths must stay in sync with the inline Path Data in BasetuneUI.xaml:
#   iconDownload -> btnOpenDownload (tray + down arrow)
#   iconExport   -> btnSourceExport / btnTargetExport (square with arrow leaving top-right)
$script:iconDownload = "M5,20H19V18H5M19,9H15V3H9V9H5L12,16L19,9Z"
$script:iconExport   = "M14,3V5H17.59L12.67,9.91L14.08,11.32L19,6.41V10H21V3M19,19H5V5H12V3H5C3.89,3 3,3.89 3,5V19A2,2 0 0,0 5,21H19A2,2 0 0,0 21,19V12H19V19Z"

$script:idleStyleCache = @{}

# Build an icon-only Viewbox content for a square button. Used to swap the
# button's content between its idle icon and the X for cancel.
# Build an icon-only Viewbox content for a square button. Used to swap the
# button's content between its idle icon and the X for cancel.
#
# The Path's Fill is bound to the parent Button's Foreground via
# RelativeSource — same pattern as the inline-XAML icon buttons. This is
# essential because the SecBtn style has an IsEnabled=False trigger that
# greys the Foreground; the trigger only reaches the Path if Fill is bound
# (a hard-coded SolidColorBrush would ignore it, which is exactly why the
# disabled-state icon used to stay dark instead of going grey).
#
# $Fill is retained for call-site backward compatibility but is now a no-op:
# the Path inherits its colour from the parent button's Foreground.
function script:New-IconOnlyContent {
    param([string]$IconPath, [string]$Fill = 'White', [int]$Size = 15)
    $xaml = @"
<Viewbox xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
         Width="$Size" Height="$Size" Stretch="Uniform">
  <Canvas Width="24" Height="24">
    <Path Fill="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"
          Data="$IconPath"/>
  </Canvas>
</Viewbox>
"@
    return [System.Windows.Markup.XamlReader]::Parse($xaml)
}

# Flip a square icon button between idle (its XAML SecBtn style with the
# given action icon) and cancel (same SecBtn style, but with a dark X icon).
# The style is intentionally identical in both modes — the icon swap alone
# signals state. Tooltip updates to "Cancel" in cancel mode so hover gives
# the user a clear hint.
#
#   Mode      — 'idle' or 'cancel'
#   IdleIcon  — geometry path to show in idle state (e.g. download arrow or
#               export arrow)
#   IconSize  — Viewbox size for the icon (15 for 29-px buttons,
#               18 for 34-px buttons looks balanced)
function Set-IconButtonMode {
    param(
        [Parameter(Mandatory)]$Btn,
        [Parameter(Mandatory)][ValidateSet('idle','cancel')][string]$Mode,
        [Parameter(Mandatory)][string]$IdleIcon,
        [int]$IconSize = 15
    )

    # Cache the idle style on first touch so we can restore exactly the
    # XAML-declared SecBtn (Style=$null would lose border + hover).
    if (-not $script:idleStyleCache.ContainsKey($Btn.Name)) {
        $script:idleStyleCache[$Btn.Name] = $Btn.Style
    }
    # Ensure the button uses its idle SecBtn style — defensive in case a
    # previous run set something else.
    $Btn.Style = $script:idleStyleCache[$Btn.Name]

    if ($Mode -eq 'cancel') {
        # Dark X (same #555 as the idle action icons) — matches the visual
        # weight of the export/download icons it replaces.
        $Btn.Content = New-IconOnlyContent $script:iconCancelX '#555' $IconSize
        $Btn.Tag     = 'cancel'
        $Btn.ToolTip = 'Cancel'
        $Btn.IsEnabled = $true   # cancel must be clickable
    } else {
        $Btn.Content = New-IconOnlyContent $IdleIcon '#555' $IconSize
        $Btn.Tag     = $null
        # ToolTip will be re-set by the caller via the button's XAML default.
    }
}

function Set-LoadButtonHover {
    param($btn, [string]$Mode)
    if (-not $script:styleLoad) {
        $script:styleLoad   = Make-BtnStyle '#1A6EF5' '#1662D9'
        $script:styleCancel = Make-BtnStyle '#CC3333' '#AA2222' '#E08080'
    }
    $btn.Style = if ($Mode -eq 'cancel') { $script:styleCancel } else { $script:styleLoad }
}

# Build an inline WPF Button style that mimics the XAML SecBtn shape (29x29
# square, rounded corners) but with a blue fill, blue border, and white
# foreground. Used by the Download button when no setting definitions exist
# on disk — same size as Config/Options so the icon-bar stays aligned, but
# visually highlighted so the user sees the call-to-action.
function script:Make-BlueIconBtnStyle {
    $xaml = @"
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
       xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
       TargetType="Button">
  <Setter Property="Background"      Value="#1A6EF5"/>
  <Setter Property="Foreground"      Value="White"/>
  <Setter Property="BorderBrush"     Value="#1A6EF5"/>
  <Setter Property="BorderThickness" Value="1"/>
  <Setter Property="Cursor"          Value="Hand"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border Background="{TemplateBinding Background}"
                BorderBrush="{TemplateBinding BorderBrush}"
                BorderThickness="{TemplateBinding BorderThickness}"
                CornerRadius="6" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True">
            <Setter Property="Background"  Value="#1662D9"/>
            <Setter Property="BorderBrush" Value="#1662D9"/>
          </Trigger>
          <Trigger Property="IsEnabled" Value="False">
            <Setter Property="Background"  Value="#E5E7EB"/>
            <Setter Property="BorderBrush" Value="#E5E7EB"/>
            <Setter Property="Foreground"  Value="#9AA3B0"/>
            <Setter Property="Cursor"      Value="Arrow"/>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
"@
    return [System.Windows.Markup.XamlReader]::Parse($xaml)
}

$script:styleBlueIcon = $null

# ─────────────────────────────────────────────────────────────────────────────
# Download button appearance — icon-only square (29x29) in two flavours:
#
#   $WithLabel = $false  (definitions present on disk):
#       Default SecBtn style from XAML — white background, grey border,
#       black icon. Same look as the Config and Options buttons next to it.
#
#   $WithLabel = $true   (one or both definition files missing):
#       Blue fill, white border, white icon — same 29x29 size, but visually
#       highlighted so the missing-definitions state is obvious without
#       expanding the button or showing a text label.
#
# The parameter name "$WithLabel" is kept for backwards-compat with callers
# (Update-DownloadButton in BasetuneUI.ps1) — historically it meant
# "show 'Download' text"; today it just means "missing definitions, draw
# attention". Cancel mode (Set-IconButtonMode) is independent — when the
# runspace finishes, the OnDone calls this helper again to restore the right
# idle-state appearance.
# ─────────────────────────────────────────────────────────────────────────────
function Set-DownloadButtonLabel {
    param([bool]$WithLabel)

    $btn = $global:btnOpenDownload
    if (-not $btn) { return }

    # Cache the XAML-declared icon style on first touch — same cache key as
    # Set-IconButtonMode so both helpers see the same idle style.
    if (-not $script:idleStyleCache.ContainsKey($btn.Name)) {
        $script:idleStyleCache[$btn.Name] = $btn.Style
    }

    # Size and content are identical in both modes — only the style
    # (background + border + foreground) changes. Foreground is bound
    # to the icon Path Fill via RelativeSource in New-DownloadButtonContent,
    # so swapping the style automatically recolours the icon.
    $btn.Width   = 29
    $btn.Height  = 29
    $btn.Padding = [System.Windows.Thickness]::new(0)
    $btn.Content = New-DownloadButtonContent

    if ($WithLabel) {
        # Missing definitions — promote to blue with blue border + white icon
        if (-not $script:styleBlueIcon) {
            $script:styleBlueIcon = Make-BlueIconBtnStyle
        }
        $btn.Style = $script:styleBlueIcon
    } else {
        # Definitions present — neutral icon-bar look
        $btn.Style = $script:idleStyleCache[$btn.Name]
    }
}

# Build the Download button's idle content via inline XAML so the icon's
# Fill binding on the parent button's Foreground works out of the box —
# avoids the unreliable PS-side RelativeSource lookup. Size matches the
# Config / Options buttons (15x15 viewbox in a 24x24 canvas).
function script:New-DownloadButtonContent {
    $xaml = @"
<Viewbox xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
         Width="15" Height="15" Stretch="Uniform">
  <Canvas Width="24" Height="24">
    <Path Fill="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"
          Data="$script:iconDownload"/>
  </Canvas>
</Viewbox>
"@
    return [System.Windows.Markup.XamlReader]::Parse($xaml)
}

function Set-Busy {
    param([bool]$v, [string]$Side = '')

    # Single busy state: $global:CurrentJob is the source of truth.
    # - $null  → idle
    # - object → busy (either a stub set up here before Start-Runspace, or
    #            the full job context built by Start-Runspace itself).
    # Update-Counts and Update-ExportButtons check `if ($global:CurrentJob)`
    # to gate UI re-enable. Set-Busy is the only writer for the busy/idle
    # transitions; Start-Runspace replaces the stub with the full job.
    if ($v) {
        if (-not $global:CurrentJob) {
            $global:CurrentJob = @{ Side = $Side; IsBusy = $true }
        } else {
            $global:CurrentJob.IsBusy = $true
            if ($Side) { $global:CurrentJob.Side = $Side }
        }
    } else {
        $global:CurrentJob = $null
    }

    # Stash / restore the Run Report button's enabled state across the busy
    # cycle. Without this, Download / Export / Load runspaces would either
    # leave Run Report clickable while a runspace is in flight (Export, Load
    # currently don't touch it) or, if a previous Compare had disabled it,
    # the OnDone in the download handler used to flip it back on as soon as
    # a report file existed on disk — promoting an inactive button to active.
    # Single source of truth: snapshot here on entry, restore here on exit.
    if ($v) {
        $global:btnOpenReportPriorState = [bool]$global:btnOpenReport.IsEnabled
        $global:btnOpenReport.IsEnabled = $false
    }

    $global:progressBar.IsIndeterminate = $v
    if ($v) {
        $global:progressBar.Value      = 0
        $global:progressBar.Visibility = 'Visible'
    } else {
        $global:progressBar.Value      = 0
        $global:progressBar.Visibility = 'Hidden'
    }

    if ($v) {
        # Default: disable tenant pickers; per-Side handlers below decide
        # which buttons stay enabled (as cancel) vs disabled.
        $global:cmbSourceTenant.IsEnabled = $false
        $global:cmbTargetTenant.IsEnabled = $false

        if ($Side -eq 'Source') {
            $global:btnOpenDownload.IsEnabled = $false
            $global:btnSourceExport.IsEnabled = $false
            $global:btnTargetExport.IsEnabled = $false
            $global:btnTargetLoad.IsEnabled  = $false
            $global:btnSourceLoad.Content    = New-ButtonContent $script:iconStop 'Cancel'
            Set-LoadButtonHover $global:btnSourceLoad 'cancel'
            $global:btnSourceLoad.Tag       = 'cancel'
        } elseif ($Side -eq 'Target') {
            $global:btnOpenDownload.IsEnabled = $false
            $global:btnSourceExport.IsEnabled = $false
            $global:btnTargetExport.IsEnabled = $false
            $global:btnSourceLoad.IsEnabled  = $false
            $global:btnTargetLoad.Content    = New-ButtonContent $script:iconStop 'Cancel'
            Set-LoadButtonHover $global:btnTargetLoad 'cancel'
            $global:btnTargetLoad.Tag       = 'cancel'
        } elseif ($Side -eq 'Download') {
            # Download stays clickable as a red Cancel; everything else off.
            $global:btnSourceExport.IsEnabled = $false
            $global:btnTargetExport.IsEnabled = $false
            $global:btnSourceLoad.IsEnabled  = $false
            $global:btnTargetLoad.IsEnabled  = $false
            Set-IconButtonMode -Btn $global:btnOpenDownload -Mode 'cancel' `
                -IdleIcon $script:iconDownload -IconSize 15
        } elseif ($Side -eq 'SourceExport' -or $Side -eq 'TargetExport') {
            # Active Export side stays clickable as a red Cancel.
            $global:btnOpenDownload.IsEnabled = $false
            $global:btnSourceLoad.IsEnabled  = $false
            $global:btnTargetLoad.IsEnabled  = $false
            if ($Side -eq 'SourceExport') {
                $global:btnTargetExport.IsEnabled = $false
                Set-IconButtonMode -Btn $global:btnSourceExport -Mode 'cancel' `
                    -IdleIcon $script:iconExport -IconSize 15
            } else {
                $global:btnSourceExport.IsEnabled = $false
                Set-IconButtonMode -Btn $global:btnTargetExport -Mode 'cancel' `
                    -IdleIcon $script:iconExport -IconSize 15
            }
        } else {
            # Compare or other — disable everything load-related, including Download.
            $global:btnOpenDownload.IsEnabled = $false
            $global:btnSourceExport.IsEnabled = $false
            $global:btnTargetExport.IsEnabled = $false
            $global:btnSourceLoad.IsEnabled  = $false
            $global:btnTargetLoad.IsEnabled  = $false
        }
    } else {
        # Restore both Load buttons to normal state
        $global:btnSourceLoad.Content    = New-ButtonContent $script:iconSync 'Load'
        Set-LoadButtonHover $global:btnSourceLoad 'load'
        $global:btnSourceLoad.Tag       = $null
        $global:btnSourceLoad.IsEnabled = $true
        $global:btnTargetLoad.Content    = New-ButtonContent $script:iconSync 'Load'
        Set-LoadButtonHover $global:btnTargetLoad 'load'
        $global:btnTargetLoad.Tag       = $null
        $global:btnTargetLoad.IsEnabled = $true
        $global:cmbSourceTenant.IsEnabled = $true
        $global:cmbTargetTenant.IsEnabled = $true

        # Restore Download / Export icon buttons to idle look (no-ops if they
        # were never flipped). Tag-based check avoids unnecessary work and
        # avoids losing the ToolTip on first call.
        if ($global:btnOpenDownload.Tag -eq 'cancel') {
            Set-IconButtonMode -Btn $global:btnOpenDownload -Mode 'idle' `
                -IdleIcon $script:iconDownload -IconSize 15
            $global:btnOpenDownload.ToolTip = 'Download Definitions'
        }
        if ($global:btnSourceExport.Tag -eq 'cancel') {
            Set-IconButtonMode -Btn $global:btnSourceExport -Mode 'idle' `
                -IdleIcon $script:iconExport -IconSize 15
            $global:btnSourceExport.ToolTip = 'Export Policies'
        }
        if ($global:btnTargetExport.Tag -eq 'cancel') {
            Set-IconButtonMode -Btn $global:btnTargetExport -Mode 'idle' `
                -IdleIcon $script:iconExport -IconSize 15
            $global:btnTargetExport.ToolTip = 'Export Policies'
        }

        Update-ExportButtons   # sets Download + Export buttons based on current tenant selection

        # Restore Run Report to its pre-busy state. Compare's OnDone overrides
        # this when it produces a fresh report (sets IsEnabled=$true after
        # Set-Busy returns), so this restore is only the baseline.
        if ($null -ne $global:btnOpenReportPriorState) {
            $global:btnOpenReport.IsEnabled = $global:btnOpenReportPriorState
            $global:btnOpenReportPriorState = $null
        }
    }
}

# ── Update "X / Y selected" labels and toggle Compare button ─────────────────
function Update-Counts {
    $srcChecked = @($global:sourceItems | Where-Object { $_.IsChecked }).Count
    $tgtChecked = @($global:targetItems | Where-Object { $_.IsChecked }).Count
    $global:lblSourceCount.Text = "$srcChecked / $($global:sourceItems.Count) selected"
    $global:lblTargetCount.Text = "$tgtChecked / $($global:targetItems.Count) selected"

    # Don't re-enable Compare while a runspace (load/export/download/compare)
    # is in flight. Without this, deselecting + reselecting policies during an
    # export would flip btnCompare back to enabled, letting the user start a
    # Compare that clears the UI status of the still-running export.
    # Mirrors the same guard used in Update-ExportButtons below.
    if ($global:CurrentJob) { return }

    $global:btnCompare.IsEnabled = (
        $srcChecked -gt 0 -and $tgtChecked -gt 0 -and
        $null -ne $global:sourceExpanded -and $null -ne $global:targetExpanded
    )

    # Export buttons also depend on selection — keep them in sync.
    Update-ExportButtons
}

# ── Enable/disable Export buttons based on online tenant + selection ─────────
function Update-ExportButtons {
    # Don't re-enable buttons while a runspace (load/export/download/compare)
    # is in flight. $global:CurrentJob is the cross-module busy signal —
    # Set-Busy sets it on entry, clears it on exit. Module-scope $script:*
    # vars from BasetuneUI.ps1 aren't visible here, which is why the old
    # $script:subRunner check silently never fired.
    if ($global:CurrentJob) { return }

    foreach ($side in @('Source', 'Target')) {
        $btn = if ($side -eq 'Source') { $global:btnSourceExport } else { $global:btnTargetExport }
        if (-not $btn) { continue }
        $key   = if ($side -eq 'Source') { $global:cmbSourceTenant.SelectedValue } `
                 else                    { $global:cmbTargetTenant.SelectedValue  }
        $items = if ($side -eq 'Source') { $global:sourceItems } else { $global:targetItems }

        $canDo = $false
        if ($key) {
            $entry = $global:tenantList | Where-Object { $_.Key -eq $key } | Select-Object -First 1
            $onlineOk = $entry -and (Get-TenantMode $entry.Node) -eq 'Online'
            # At least one policy must be checked — exporting an empty selection
            # would just create an empty folder.
            $hasSelection = @($items | Where-Object { $_.IsChecked }).Count -gt 0
            $canDo = $onlineOk -and $hasSelection
        }
        $btn.IsEnabled = $canDo
    }

    # Download always enabled — no-online-tenant check happens at click time
    if ($global:btnOpenDownload) {
        $global:btnOpenDownload.IsEnabled = $true
    }
}

# ── Clear one side's policy list and cached data ──────────────────────────────
# Called on tenant-switch and before a new Load. Drops the policy items, the
# expanded-policy cache, AND the side's Graph connection — a connection bound
# to a tenant that's no longer selected should never be reused.
function Reset-Side {
    param([string]$Side)
    if ($Side -eq 'Source') {
        $global:sourceItems.Clear()
        $global:sourceExpanded       = $null
        $global:sourceConnection     = $null
        $global:lblSourceCount.Text  = ''
        $global:txtSourceSearch.Text = ''
        if ($global:txtSourceSearchHint) { $global:txtSourceSearchHint.Visibility = 'Visible' }
        $global:lstSource.ItemsSource = $global:sourceItems
    } else {
        $global:targetItems.Clear()
        $global:targetExpanded       = $null
        $global:targetConnection     = $null
        $global:lblTargetCount.Text  = ''
        $global:txtTargetSearch.Text = ''
        if ($global:txtTargetSearchHint) { $global:txtTargetSearchHint.Visibility = 'Visible' }
        $global:lstTarget.ItemsSource = $global:targetItems
    }
    Update-Counts
    $global:btnOpenReport.IsEnabled = $false
}

# ── Filter visible policy list without changing checked state ─────────────────
function Apply-ListFilter {
    param([string]$Side)
    $search = if ($Side -eq 'Source') { $global:txtSourceSearch.Text.Trim().ToLower() } `
              else                    { $global:txtTargetSearch.Text.Trim().ToLower() }
    $lst    = if ($Side -eq 'Source') { $global:lstSource } else { $global:lstTarget }
    $items  = if ($Side -eq 'Source') { $global:sourceItems } else { $global:targetItems }
    $hint   = if ($Side -eq 'Source') { $global:txtSourceSearchHint } else { $global:txtTargetSearchHint }

    if ($search) {
        $filtered = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
        foreach ($it in $items) {
            if ($it.Name -and $it.Name.ToLower().Contains($search)) { $filtered.Add($it) }
        }
        $lst.ItemsSource = $filtered
    } else {
        $lst.ItemsSource = $items
    }
    Update-Counts
}

# ── Log helpers ───────────────────────────────────────────────────────────────
# UI status messages are mirrored to the log file so the on-disk log is a
# complete record of what the user saw. Best-effort: file write never throws.
function script:Append-LogFile {
    param([string]$msg)
    if (-not $global:logFile -or -not $msg) { return }
    # Skip pure whitespace/newline-only entries (Write-UILog "`n" etc.)
    if ($msg.Trim().Length -eq 0) { return }
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    foreach ($line in ($msg -split "`r?`n")) {
        if ($line.Trim().Length -eq 0) { continue }
        try { Add-Content -Path $global:logFile -Value "$stamp $line" -Encoding UTF8 } catch {}
    }
}

function Write-UILog {
    param([string]$msg)
    $global:txtLog.AppendText($msg + "`n")
    $global:txtLog.ScrollToEnd()
    Append-LogFile $msg
}

function Clear-UILog {
    param([string]$msg = '')
    $global:txtLog.Text = if ($msg) { $msg + "`n" } else { '' }
    $global:txtLog.ScrollToEnd()
    if ($msg) { Append-LogFile $msg }
}

# ── Folder browser dialog ─────────────────────────────────────────────────────
# Previously Shell.Application.BrowseForFolder with root "C:\": that dialog
# could not leave drive C: (no other drives, no network shares) and had no
# owner window, so it could open behind Basetune.
#
# Now:
#   1. Microsoft.Win32.OpenFolderDialog (WPF, .NET 8 = PowerShell 7.4+):
#      the modern Explorer-style picker, owned by the Basetune window.
#   2. Fallback for older PowerShell 7 versions: WinForms FolderBrowserDialog
#      (System.Windows.Forms is loaded by BasetuneUI.ps1).
#
#   InitialPath — optional folder to start in (ignored if it does not exist)
#   Owner       — window that opens the picker. Must be the dialog it is opened
#                 from (Tenant Configuration / Options): a modal picker owned by
#                 the main window would re-enable the main window behind the
#                 still-open dialog when it closes. Defaults to the main window.
function Show-FolderBrowser {
    param([string]$InitialPath = '', $Owner = $null)

    $owner = if ($Owner) { $Owner } else { $global:window }
    $start = if ($InitialPath -and (Test-Path -LiteralPath $InitialPath)) { $InitialPath } else { $null }

    $wpfDialogType = 'Microsoft.Win32.OpenFolderDialog' -as [type]
    if ($wpfDialogType) {
        $dlg = $wpfDialogType::new()
        $dlg.Title = 'Select folder'
        if ($start) { $dlg.InitialDirectory = $start }
        $ok = if ($owner) { $dlg.ShowDialog($owner) } else { $dlg.ShowDialog() }
        if ($ok) { return $dlg.FolderName }
        return $null
    }

    $fb = [System.Windows.Forms.FolderBrowserDialog]::new()
    try {
        $fb.ShowNewFolderButton = $true
        if ($start) { $fb.SelectedPath = $start }
        if ($fb.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK -and $fb.SelectedPath) {
            return $fb.SelectedPath
        }
        return $null
    } finally {
        $fb.Dispose()
    }
}

# ── Write loaded definitions back to main-thread cache ───────────────────────
# Called after a successful compare or download runspace completes.
# Default: only cache if not already cached (idempotent — Compare can be called
# repeatedly without re-reading the files from disk).
# -Force: always re-read from disk, overwriting any existing cache. Use after
# a Download that just wrote fresh files — the previously cached values are
# now stale.
function Update-DefinitionCache {
    param(
        [string]$JsonDefsPath,
        [switch]$Force
    )

    $defsFile = "$JsonDefsPath\settingDefinitions.json"
    $catsFile = "$JsonDefsPath\settingCategories.json"
    $defCache = $global:Cache.Definitions

    # Same loader as the CLI and the compare runspace (IntuneGraphPolicies).
    # A parse failure is logged instead of swallowed: a corrupt file used to
    # produce "Loading..." followed by nothing at all.
    if (($Force -or -not $defCache.HasDefs) -and (Test-Path $defsFile)) {
        try {
            Write-UILog "[INFO][Definitions] Loading setting definitions..."
            $lookup = Import-SettingDefinitions -Path $defsFile
            $defCache.Lookup  = $lookup
            $defCache.HasDefs = ($null -ne $lookup -and $lookup.Count -gt 0)
            Write-UILog "[OK][Definitions] $($lookup.Count) definitions cached"
        } catch {
            $defCache.Lookup  = $null
            $defCache.HasDefs = $false
            Write-UILog "[ERROR][Definitions] Cannot read settingDefinitions.json: $($_.Exception.Message). Download the definitions again."
        }
    }

    if (($Force -or -not $defCache.HasCats) -and (Test-Path $catsFile)) {
        try {
            Write-UILog "[INFO][Categories] Loading setting categories..."
            $catMap = Import-SettingCategories -Path $catsFile
            $defCache.CategoryById = $catMap
            $defCache.HasCats      = ($null -ne $catMap -and $catMap.Count -gt 0)
            Write-UILog "[OK][Categories] $($catMap.Count) categories cached"
        } catch {
            $defCache.CategoryById = $null
            $defCache.HasCats      = $false
            Write-UILog "[ERROR][Categories] Cannot read settingCategories.json: $($_.Exception.Message). Download the definitions again."
        }
    }
}

# ── Slow down mouse-wheel scroll on a TextBox or other scrollable element ────
# Default WPF pixel-scroll is too fast for log-style readouts. Walks up the
# visual tree to find the containing ScrollViewer, then translates each wheel
# tick into $Lines LineUp/LineDown calls.
function Set-SlowScroll {
    param(
        [Parameter(Mandatory)][System.Windows.UIElement]$Element,
        [int]$Lines = 3
    )
    $Element.Add_PreviewMouseWheel({
        param($sender, $e)
        $sv = $null
        $el = $sender
        while ($el -ne $null) {
            $el = [System.Windows.Media.VisualTreeHelper]::GetParent($el)
            if ($el -is [System.Windows.Controls.ScrollViewer]) { $sv = $el; break }
        }
        if ($sv) {
            if ($e.Delta -gt 0) { for ($i = 0; $i -lt $Lines; $i++) { $sv.LineUp() } }
            else                { for ($i = 0; $i -lt $Lines; $i++) { $sv.LineDown() } }
            $e.Handled = $true
        }
    }.GetNewClosure())
}

# ── Load a XAML file and return the root element ─────────────────────────────
# Centralises three previously copy-pasted load blocks (main window + Config
# dialog + Options dialog). Reads UTF8, parses, surfaces clear errors. If
# -Width/-Height are given, forces a layout pass so FindName / VisualTree
# walks work immediately on the returned element.
function Load-Xaml {
    param(
        [Parameter(Mandatory)][string]$Path,
        [double]$Width  = 0,
        [double]$Height = 0,
        [switch]$ExitOnError   # Main window can't recover from a broken XAML; dialogs throw instead.
    )

    if (-not (Test-Path $Path)) {
        $msg = "XAML FILE NOT FOUND: $Path"
        if ($ExitOnError) { Write-Host $msg -ForegroundColor Red; Read-Host "Press Enter to exit"; exit 1 }
        throw $msg
    }

    try {
        [xml]$xaml = Get-Content $Path -Raw -Encoding UTF8
    } catch {
        $msg = "XAML XML PARSE ERROR: $_"
        if ($ExitOnError) { Write-Host $msg -ForegroundColor Red; Read-Host "Press Enter to exit"; exit 1 }
        throw $msg
    }

    $reader = [System.Xml.XmlNodeReader]::new($xaml)
    try {
        $root = [Windows.Markup.XamlReader]::Load($reader)
    } catch {
        $inner = $_.Exception.InnerException
        $msg = "XAML LOAD ERROR: $($_.Exception.Message)" + $(if ($inner) { "`nINNER: $($inner.Message)" } else { '' })
        if ($ExitOnError) {
            Write-Host "XAML LOAD ERROR: $($_.Exception.Message)" -ForegroundColor Red
            if ($inner) { Write-Host "INNER: $($inner.Message)" -ForegroundColor Yellow }
            Read-Host "Press Enter to exit"; exit 1
        }
        throw $msg
    }
    if (-not $root) {
        $msg = "XAML loaded but root is null: $Path"
        if ($ExitOnError) { Write-Host $msg -ForegroundColor Red; Read-Host "Press Enter to exit"; exit 1 }
        throw $msg
    }

    # Force a layout pass — XamlReader::Load registers names in its own
    # nameScope, not the Window's; FindName won't find them until the visual
    # tree is built.
    if ($Width -gt 0 -and $Height -gt 0) {
        $root.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
        $root.Arrange([System.Windows.Rect]::new(0, 0, $Width, $Height))
        $root.UpdateLayout()
    }

    return $root
}

# ── Find a named element anywhere in a WPF tree ───────────────────────────────
# Replaces three copy-pasted local closures (Find / CFind / SFind). Tries
# FindName first (works when the name is registered in the tree's nameScope),
# falls back to a BFS over the visual tree for names XAMLReader buried in a
# different scope.
function Find-InTree {
    param(
        [Parameter(Mandatory)]$Root,
        [Parameter(Mandatory)][string]$Name
    )
    $r = $Root.FindName($Name)
    if ($r) { return $r }
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue($Root)
    while ($queue.Count -gt 0) {
        $el = $queue.Dequeue()
        if ($el -is [System.Windows.FrameworkElement] -and $el.Name -eq $Name) { return $el }
        try {
            $c = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($el)
            for ($i = 0; $i -lt $c; $i++) {
                $queue.Enqueue([System.Windows.Media.VisualTreeHelper]::GetChild($el, $i))
            }
        } catch {}
    }
    return $null
}

Export-ModuleMember -Function @(
    'Set-Busy',
    'Update-Counts',
    'Update-ExportButtons',
    'Reset-Side',
    'Apply-ListFilter',
    'Write-UILog',
    'Clear-UILog',
    'Show-FolderBrowser',
    'Update-DefinitionCache',
    'Set-LoadButtonHover',
    'Set-IconButtonMode',
    'Set-DownloadButtonLabel',
    'Set-SlowScroll',
    'Load-Xaml',
    'Find-InTree'
)
