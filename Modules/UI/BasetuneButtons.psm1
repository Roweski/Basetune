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
    param([string]$IconPath, [string]$Label)
    # Same as the XAML PrimaryBtn (Compare / Run Report): the icon Fill binds
    # to the Button's Foreground, and New-ButtonStyle uses the same triggers,
    # so the disabled colour reaches the icon too.
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

function script:New-ButtonStyle {
    # Disabled colours come from the theme palette (DynamicResource), so a
    # disabled Load button looks right in light and dark mode.
    param([string]$Bg, [string]$BgHover, [string]$BgDisabled = '{DynamicResource DisabledBgBrush}', [string]$FgDisabled = '{DynamicResource DisabledFgBrush}', [string]$BorderDisabled = '{DynamicResource DisabledBorderBrush}')
    $xaml = @"
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
       xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
       TargetType="Button">
  <Setter Property="Background" Value="$Bg"/>
  <Setter Property="Foreground" Value="White"/>
  <Setter Property="FocusVisualStyle" Value="{DynamicResource PrimaryFocusVisual}"/>
  <Setter Property="FontSize"   Value="13"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
  <Setter Property="Height"     Value="32"/>
  <Setter Property="BorderThickness" Value="0"/>
  <Setter Property="Cursor"     Value="Hand"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8"
                BorderThickness="1" BorderBrush="{TemplateBinding Background}"
                Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True">
            <Setter Property="Background" Value="$BgHover"/>
          </Trigger>
          <Trigger Property="IsEnabled" Value="False">
            <Setter TargetName="bd" Property="Background" Value="$BgDisabled"/>
            <Setter TargetName="bd" Property="BorderBrush" Value="$BorderDisabled"/>
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
# While a job runs, a square icon button (Download, Export) becomes a red
# Cancel with a white X and the tooltip "Cancel"; idle restores its XAML
# SecBtn style and icon.
# ─────────────────────────────────────────────────────────────────────────────

# Material Design "close" (X).
$script:iconCancelX = "M19,6.41L17.59,5L12,10.59L6.41,5L5,6.41L10.59,12L5,17.59L6.41,19L12,13.41L17.59,19L19,17.59L13.41,12L19,6.41Z"

# Idle icons for Set-IconButtonMode / New-DownloadButtonContent. Keep them in
# sync with the inline Path Data in BasetuneUI.xaml:
#   iconDownload -> btnOpenDownload (tray + down arrow)
#   iconExport   -> btnSourceExport / btnTargetExport (square with arrow leaving top-right)
$script:iconDownload = "M5,20H19V18H5M19,9H15V3H9V9H5L12,16L19,9Z"
$script:iconExport   = "M14,3V5H17.59L12.67,9.91L14.08,11.32L19,6.41V10H21V3M19,19H5V5H12V3H5C3.89,3 3,3.89 3,5V19A2,2 0 0,0 5,21H19A2,2 0 0,0 21,19V12H19V19Z"

$script:idleStyleCache = @{}
$script:idleContentCache = @{}   # XAML icon content per button (keeps its glyph margin)

# Icon-only Viewbox content for a square button (idle icon or cancel X).
# The Path Fill is bound to the Button's Foreground, as in the XAML icon
# buttons: the SecBtn IsEnabled=False trigger greys the Foreground, and only
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

# Flip a square icon button between idle (XAML SecBtn style + action icon)
# and cancel (red like Load in Cancel mode, white X, tooltip "Cancel").
#
#   Mode      — 'idle' or 'cancel'
#   IdleIcon  — icon path for idle, used when no XAML content was cached
#   IconSize  — Viewbox size (15 for 32-px buttons, 18 for 34-px buttons)
function Set-IconButtonMode {
    param(
        [Parameter(Mandatory)]$Btn,
        [Parameter(Mandatory)][ValidateSet('idle','cancel')][string]$Mode,
        [Parameter(Mandatory)][string]$IdleIcon,
        [int]$IconSize = 15
    )

    # Cache the XAML SecBtn style on first touch (Style=$null would lose
    # border + hover).
    if (-not $script:idleStyleCache.ContainsKey($Btn.Name)) {
        $script:idleStyleCache[$Btn.Name] = $Btn.Style
    }
    # Same for the XAML icon content, so idle restores the exact glyph
    # (incl. its optical margin) instead of a rebuilt, centred one.
    if (-not $script:idleContentCache.ContainsKey($Btn.Name) -and $Btn.Tag -ne 'cancel') {
        $script:idleContentCache[$Btn.Name] = $Btn.Content
    }
    # Start from the idle style (defensive).
    $Btn.Style = $script:idleStyleCache[$Btn.Name]

    if ($Mode -eq 'cancel') {
        # Red background, white X: same look as Load while it runs.
        if (-not $script:styleCancel) {
            $script:styleLoad   = New-ButtonStyle '#1A6EF5' '#1662D9'
            $script:styleCancel = New-ButtonStyle '#CC3333' '#AA2222' '#E08080' -BorderDisabled '#E08080'
        }
        $Btn.Style   = $script:styleCancel
        # Size 16 (not 15) in the 32px button: the even leftover centres the X
        # (15 leaves 17px, split 8/9). The X path is symmetric (5..19 of 24).
        # Margin top 2 moves it exactly 1px down, which looks centred.
        $Btn.Content = New-IconOnlyContent $script:iconCancelX 16 '0,2,0,0'
        $Btn.Tag     = 'cancel'
        $Btn.ToolTip = 'Cancel'
        $Btn.IsEnabled = $true   # cancel must be clickable
    } else {
        $Btn.Content = if ($script:idleContentCache[$Btn.Name]) { $script:idleContentCache[$Btn.Name] }
                       else { New-IconOnlyContent $IdleIcon $IconSize }
        $Btn.Tag     = $null
        # The caller sets the idle ToolTip again.
    }
}

function Set-LoadButtonMode {
    param($btn, [string]$Mode)
    if (-not $script:styleLoad) {
        $script:styleLoad   = New-ButtonStyle '#1A6EF5' '#1662D9'
        $script:styleCancel = New-ButtonStyle '#CC3333' '#AA2222' '#E08080' -BorderDisabled '#E08080'
    }
    $btn.Style = if ($Mode -eq 'cancel') { $script:styleCancel } else { $script:styleLoad }
}

# Compare button: a running compare can be cancelled, but the red Cancel only
# shows after a short delay (compareCancelTimer, Initialize-BasetuneJobs), so a quick
# compare doesn't flash red. The XAML style and content are kept on first use
# and put back for 'idle'.
function Set-CompareButtonMode {
    param([ValidateSet('idle','cancel')][string]$Mode)
    $btn = $UI.btnCompare
    if (-not $btn) { return }
    if (-not $script:compareIdle) {
        $script:compareIdle = @{ Style = $btn.Style; Content = $btn.Content }
    }
    if ($Mode -eq 'cancel') {
        if ($btn.Tag -eq 'cancel') { return }
        $btn.Content = New-ButtonContent $script:iconStop 'Cancel'
        Set-LoadButtonMode $btn 'cancel'
        $btn.Height    = 34          # PrimaryBtn height; the cancel style uses 32
        $btn.Tag       = 'cancel'
        $btn.IsEnabled = $true
    } else {
        if ($btn.Tag -ne 'cancel') { return }
        $btn.Style   = $script:compareIdle.Style
        $btn.Content = $script:compareIdle.Content
        $btn.ClearValue([System.Windows.FrameworkElement]::HeightProperty)
        $btn.Tag     = $null
    }
}

# Button style with the XAML SecBtn shape (square, rounded corners) but a
# coloured fill and border and a white foreground. Used for the Download
# button when no definition files exist (orange): same size as the other
# icon-bar buttons, but it stands out.
function script:New-BlueIconButtonStyle {
    param([string]$Bg = '#1A6EF5', [string]$BgHover = '#1662D9')
    $xaml = @"
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
       xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
       TargetType="Button">
  <Setter Property="Background"      Value="$Bg"/>
  <Setter Property="Foreground"      Value="White"/>
  <Setter Property="FocusVisualStyle" Value="{DynamicResource PrimaryFocusVisual}"/>
  <Setter Property="BorderBrush"     Value="$Bg"/>
  <Setter Property="BorderThickness" Value="1"/>
  <Setter Property="Cursor"          Value="Hand"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border Background="{TemplateBinding Background}"
                BorderBrush="{TemplateBinding BorderBrush}"
                BorderThickness="{TemplateBinding BorderThickness}"
                CornerRadius="8" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True">
            <Setter Property="Background"  Value="$BgHover"/>
            <Setter Property="BorderBrush" Value="$BgHover"/>
          </Trigger>
          <Trigger Property="IsEnabled" Value="False">
            <Setter Property="Background"  Value="{DynamicResource DisabledBgBrush}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource DisabledBorderBrush}"/>
            <Setter Property="Foreground"  Value="{DynamicResource DisabledFgBrush}"/>
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

$script:styleBlueIcon   = $null
$script:styleOrangeIcon = $null   # same shape, orange (#f0a340, as on basetune.dev)

# ─────────────────────────────────────────────────────────────────────────────
# Download button look (icon-only square):
#   $Missing = $false  definitions on disk: the XAML SecBtn style, like the
#                      Config and Options buttons next to it.
#   $Missing = $true   one or both definition files missing: orange fill,
#                      white icon.
#
# Called by Update-DownloadButton (BasetuneActions.psm1). Cancel mode
# (Set-IconButtonMode) is separate; after a job this sets the idle look again.
# ─────────────────────────────────────────────────────────────────────────────
function Set-DownloadButtonStyle {
    # Orange only when there are no definition files at all; otherwise the
    # normal look. The tooltip is always "Download Definitions" (settings
    # without a definition are reported in the log at the end of a compare).
    param([bool]$Missing)

    $btn = $UI.btnOpenDownload
    if (-not $btn) { return }

    # Cache the XAML style on first touch (shared with Set-IconButtonMode).
    if (-not $script:idleStyleCache.ContainsKey($btn.Name)) {
        $script:idleStyleCache[$btn.Name] = $btn.Style
    }

    # Size and content are the same in every mode; only the style changes.
    # The icon Fill is bound to the Foreground (New-DownloadButtonContent),
    # so a new style recolours the icon too.
    $btn.Width   = 34
    $btn.Height  = 34
    $btn.Padding = [System.Windows.Thickness]::new(0)
    $btn.Content = New-DownloadButtonContent

    if ($Missing) {
        # No definition files at all - orange, so it is clear where to start.
        if (-not $script:styleOrangeIcon) {
            $script:styleOrangeIcon = New-BlueIconButtonStyle -Bg '#F0A340' -BgHover '#D98E2B'
        }
        $btn.Style = $script:styleOrangeIcon
        $btn.ToolTip = 'Download Definitions'
    } else {
        # Definitions present - neutral icon-bar look
        $btn.Style = $script:idleStyleCache[$btn.Name]
        $btn.ToolTip = 'Download Definitions'
    }
}

# Tenant Configuration button: always the normal icon-bar look and tooltip.
# Called by Sync-MainTenantDropdowns (startup, after Tenant Configuration).
# The disabled look during a job comes from the style itself.
function Reset-ConfigButtonStyle {
    $btn = $UI.btnOpenConfig
    if (-not $btn) { return }
    if (-not $script:idleStyleCache.ContainsKey($btn.Name)) {
        $script:idleStyleCache[$btn.Name] = $btn.Style
    }
    $btn.Style = $script:idleStyleCache[$btn.Name]
    $btn.ToolTip = 'Tenant Configuration'
}

# Download button content as inline XAML, so the icon Fill binds to the
# Button's Foreground (a RelativeSource binding built from PowerShell is
# unreliable). Size 16 in the 32px button: the even leftover centres the
# arrow; Margin top 2 moves it exactly 1px down (same as the XAML).
function script:New-DownloadButtonContent {
    $xaml = @"
<Viewbox xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
         Width="16" Height="16" Stretch="Uniform"
         HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,2,0,0">
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
        # filters on again); per Side below, which button becomes Cancel.
        $UI.cmbSourceTenant.IsEnabled = $false
        $UI.cmbTargetTenant.IsEnabled = $false
        if ($UI.txtSourceFilter) { $UI.txtSourceFilter.IsEnabled = $false }
        if ($UI.txtTargetFilter) { $UI.txtTargetFilter.IsEnabled = $false }
        # Tenant Configuration is off while a job runs: editing or removing a
        # tenant (and rebuilding the tenant dropdowns when it closes) must not
        # happen during a load / compare / export / download.
        if ($UI.btnOpenConfig) { $UI.btnOpenConfig.IsEnabled = $false }

        if ($Side -eq 'Source') {
            $UI.btnOpenDownload.IsEnabled = $false
            $UI.btnSourceExport.IsEnabled = $false
            $UI.btnTargetExport.IsEnabled = $false
            $UI.btnTargetLoad.IsEnabled  = $false
            $UI.btnSourceLoad.Content    = New-ButtonContent $script:iconStop 'Cancel'
            Set-LoadButtonMode $UI.btnSourceLoad 'cancel'
            $UI.btnSourceLoad.Tag       = 'cancel'
        } elseif ($Side -eq 'Target') {
            $UI.btnOpenDownload.IsEnabled = $false
            $UI.btnSourceExport.IsEnabled = $false
            $UI.btnTargetExport.IsEnabled = $false
            $UI.btnSourceLoad.IsEnabled  = $false
            $UI.btnTargetLoad.Content    = New-ButtonContent $script:iconStop 'Cancel'
            Set-LoadButtonMode $UI.btnTargetLoad 'cancel'
            $UI.btnTargetLoad.Tag       = 'cancel'
        } elseif ($Side -eq 'Download') {
            # Download stays clickable as a red Cancel; everything else off.
            $UI.btnSourceExport.IsEnabled = $false
            $UI.btnTargetExport.IsEnabled = $false
            $UI.btnSourceLoad.IsEnabled  = $false
            $UI.btnTargetLoad.IsEnabled  = $false
            Set-IconButtonMode -Btn $UI.btnOpenDownload -Mode 'cancel' `
                -IdleIcon $script:iconDownload -IconSize 15
        } elseif ($Side -eq 'SourceExport' -or $Side -eq 'TargetExport') {
            # Active Export side stays clickable as a red Cancel.
            $UI.btnOpenDownload.IsEnabled = $false
            $UI.btnSourceLoad.IsEnabled  = $false
            $UI.btnTargetLoad.IsEnabled  = $false
            if ($Side -eq 'SourceExport') {
                $UI.btnTargetExport.IsEnabled = $false
                Set-IconButtonMode -Btn $UI.btnSourceExport -Mode 'cancel' `
                    -IdleIcon $script:iconExport -IconSize 15
            } else {
                $UI.btnSourceExport.IsEnabled = $false
                Set-IconButtonMode -Btn $UI.btnTargetExport -Mode 'cancel' `
                    -IdleIcon $script:iconExport -IconSize 15
            }
        } else {
            # Compare or other — disable everything load-related, including Download.
            $UI.btnOpenDownload.IsEnabled = $false
            $UI.btnSourceExport.IsEnabled = $false
            $UI.btnTargetExport.IsEnabled = $false
            $UI.btnSourceLoad.IsEnabled  = $false
            $UI.btnTargetLoad.IsEnabled  = $false
        }
    } else {
        # Compare: stop the delayed-Cancel timer and turn a red Cancel back
        # into Compare Policies (Update-Counts decides whether it's enabled).
        if ($AppState.compareCancelTimer) { $AppState.compareCancelTimer.Stop() }
        Set-CompareButtonMode 'idle'

        # Restore both Load buttons to normal state
        $UI.btnSourceLoad.Content    = New-ButtonContent $script:iconSync 'Load'
        Set-LoadButtonMode $UI.btnSourceLoad 'load'
        $UI.btnSourceLoad.Tag       = $null
        $UI.btnSourceLoad.IsEnabled = $true
        $UI.btnTargetLoad.Content    = New-ButtonContent $script:iconSync 'Load'
        Set-LoadButtonMode $UI.btnTargetLoad 'load'
        $UI.btnTargetLoad.Tag       = $null
        $UI.btnTargetLoad.IsEnabled = $true
        $UI.cmbSourceTenant.IsEnabled = $true
        $UI.cmbTargetTenant.IsEnabled = $true
        if ($UI.btnOpenConfig) { $UI.btnOpenConfig.IsEnabled = $true }

        # Download / Export icon buttons back to idle, only those in cancel
        # mode (Tag), so an untouched button keeps its ToolTip.
        if ($UI.btnOpenDownload.Tag -eq 'cancel') {
            Set-IconButtonMode -Btn $UI.btnOpenDownload -Mode 'idle' `
                -IdleIcon $script:iconDownload -IconSize 15
            $UI.btnOpenDownload.ToolTip = 'Download Definitions'
        }
        if ($UI.btnSourceExport.Tag -eq 'cancel') {
            Set-IconButtonMode -Btn $UI.btnSourceExport -Mode 'idle' `
                -IdleIcon $script:iconExport -IconSize 15
            $UI.btnSourceExport.ToolTip = 'Export Policies'
        }
        if ($UI.btnTargetExport.Tag -eq 'cancel') {
            Set-IconButtonMode -Btn $UI.btnTargetExport -Mode 'idle' `
                -IdleIcon $script:iconExport -IconSize 15
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
            # API and JSON tenants alike (the export writes the loaded
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
    'Reset-ConfigButtonStyle',
    'Set-Busy',
    'Update-ExportButtons'
)
