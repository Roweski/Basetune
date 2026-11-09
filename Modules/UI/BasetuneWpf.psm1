# =============================================================================
# BasetuneWpf.psm1
# WPF basics for every Basetune window: XAML loading (Import-Xaml,
# Find-InTree), light / dark theme, dark title bars, dialog chrome, the folder
# picker and calm wheel / touchpad scrolling. $UI / $AppState come from
# BasetuneState.psm1.
# =============================================================================

$script:UI       = (Get-BasetuneContext).UI
$script:AppState = (Get-BasetuneContext).State

# ── Folder browser dialog ─────────────────────────────────────────────────────
# Any drive or network share, owned by the calling window (never behind it).
#   1. Microsoft.Win32.OpenFolderDialog (WPF, .NET 8 = PowerShell 7.4+).
#   2. Fallback for older PowerShell 7: WinForms FolderBrowserDialog
#      (System.Windows.Forms is loaded by BasetuneUI.ps1).
#
#   InitialPath — optional start folder (ignored if it does not exist)
#   Owner       — the dialog it is opened from (Baseline Configuration / Options):
#                 a picker owned by the main window would re-enable the main
#                 window behind the still-open dialog. Default: main window.
function Show-FolderBrowser {
    param([string]$InitialPath = '', $Owner = $null)

    $owner = if ($Owner) { $Owner } else { $UI.Window }
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

# ── Calm, proportional wheel / touchpad scrolling ───────────────────────────
# WPF scrolls a fixed 3 lines / items per wheel EVENT. A mouse notch is one
# event (Delta 120), but a touchpad sends many small ones (Delta 5-30) per
# swipe, so the policy lists fly past. This scrolls in proportion to Delta:
#   Pixels (log): $Lines lines of $LinePx pixels per notch, smooth.
#   -PerItem (policy lists, VirtualizingPanel.ScrollUnit="Item" in the XAML):
#     whole rows only; small touchpad events add up to a whole row.
#   -PerLine (the log): one whole line of $LinePx per notch, small touchpad
#     events add up to a line; the offset kept on a line, so no line is ever
#     shown cut in half (collapsed one line, expanded seven).
# Works on a TextBox (log) and a ListBox: the ScrollViewer is looked up inside
# the element, then above it, once (cached).
function Set-SlowScroll {
    param(
        [Parameter(Mandatory)][System.Windows.UIElement]$Element,
        [int]$Lines = 3,
        [double]$LinePx = 16,
        [switch]$PerItem,
        [switch]$PerLine
    )
    # Per-element state shared with the closure: cached ScrollViewer, pixels
    # per Delta unit, Delta per row, Delta not yet turned into rows.
    $state = @{ Sv = $null; Px = ([math]::Max(1, $Lines) * $LinePx / 120.0)
                PerItem = [bool]$PerItem; PerLine = [bool]$PerLine; DeltaPerItem = (120.0 / [math]::Max(1, $Lines)); Acc = 0.0 }

    $Element.Add_PreviewMouseWheel({
        param($sender, $e)

        # Find the ScrollViewer once: inside first (ListBox), then above (TextBox).
        # Found again when the cached one left the tree: a DPI or theme change
        # can rebuild the template, and a stale ScrollViewer would swallow the wheel.
        $sv = $state.Sv
        if ($sv -and -not ($sender.IsAncestorOf($sv) -or $sv.IsAncestorOf($sender))) { $sv = $null; $state.Sv = $null }
        if (-not $sv) {
        $queue = [System.Collections.Generic.Queue[System.Windows.DependencyObject]]::new()
        $queue.Enqueue($sender)
        while ($queue.Count -gt 0 -and -not $sv) {
            $el = $queue.Dequeue()
            $n  = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($el)
            for ($i = 0; $i -lt $n; $i++) {
                $c = [System.Windows.Media.VisualTreeHelper]::GetChild($el, $i)
                if ($c -is [System.Windows.Controls.ScrollViewer]) { $sv = $c; break }
                $queue.Enqueue($c)
            }
        }
        if (-not $sv) {
            $el = $sender
            while ($null -ne $el) {
                $el = [System.Windows.Media.VisualTreeHelper]::GetParent($el)
                if ($el -is [System.Windows.Controls.ScrollViewer]) { $sv = $el; break }
            }
        }
        if (-not $sv) { return }
        $state.Sv = $sv
        }

        if ($state.PerLine) {
            # One whole line per notch (the log); small touchpad events add up
            # to a line; the offset stays on a line.
            if (($state.Acc -gt 0 -and $e.Delta -lt 0) -or ($state.Acc -lt 0 -and $e.Delta -gt 0)) { $state.Acc = 0.0 }
            $state.Acc += $e.Delta
            $lines = [math]::Truncate($state.Acc / 120.0)
            if ($lines -ne 0) {
                $line = [math]::Round($sv.VerticalOffset / $LinePx)
                $sv.ScrollToVerticalOffset(($line - $lines) * $LinePx)
                $state.Acc -= $lines * 120.0
            }
        } elseif ($state.PerItem) {
            # Whole rows (offset in items). The remainder is kept for the next
            # event and reset when the direction changes.
            if (($state.Acc -gt 0 -and $e.Delta -lt 0) -or ($state.Acc -lt 0 -and $e.Delta -gt 0)) { $state.Acc = 0.0 }
            $state.Acc += $e.Delta
            $rows = [math]::Truncate($state.Acc / $state.DeltaPerItem)
            if ($rows -ne 0) {
                $sv.ScrollToVerticalOffset($sv.VerticalOffset - $rows)
                $state.Acc -= $rows * $state.DeltaPerItem
            }
        } else {
            # Pixel offset in proportion to Delta (ScrollToVerticalOffset clamps).
            $sv.ScrollToVerticalOffset($sv.VerticalOffset - $e.Delta * $state.Px)
        }
        $e.Handled = $true
    }.GetNewClosure())
}

# ─────────────────────────────────────────────────────────────────────────────
# Theme (light / dark / basetune)
#
# Shared styles (Xaml\BasetuneTheme.xaml) are loaded once into
# Application.Current.Resources and use colours by key (DynamicResource). The
# colours come from the palettes below, in a second merged dictionary;
# Set-BasetuneTheme swaps it and every open window repaints.
#
# PowerShell has no WPF Application; one is created here as a resource
# container only (OnExplicitShutdown: closing a dialog never ends it).
# ─────────────────────────────────────────────────────────────────────────────
$script:ThemePalettes = @{
    # Material Design 3 roles from one blue seed (#1A6EF5): greys tinted with
    # the seed hue (dark: a little more blue than the MD3 tones; surface
    # containers instead of white overlays), solid
    # colours except the hover tints. Both themes have the same accent, the
    # house blue (#0072CE, #0062B1 on hover; calmer than tone 40),
    # and the Material error red for Cancel.
    # Disabled (both themes): dimmed text and icons (DisabledFgBrush); light
    # uses a readable bluish grey instead of the MD3 grey-out.
    light = [ordered]@{
        BgBrush               = '#EEF4FB'
        CardBrush             = '#FFFFFF'
        CardBorderBrush       = '#E1E7EF'
        TextBrush             = '#191C20'
        SubTextBrush          = '#43474E'
        MutedBrush            = '#43474E'
        HintBrush             = '#73777F'
        # A light blue window (#EEF4FB) with white
        # cards; inputs a flat light grey fill.
        InputBgBrush          = '#F2F4F7'
        InputBorderBrush      = '#C3C7CF'
        AccentBrush           = '#0072CE'
        AccentSoftBrush       = '#0D0072CE'   # selected / focused row: 5%, lighter than the hover
        # Mouse-over on an active segment (AccentSoftBrush): about twice the tint.
        AccentSoftHoverBrush  = '#380072CE'
        HoverBrush            = '#140072CE'   # mouse-over: 8%
        CheckTickBrush        = '#FFFFFF'
        # Action segments (StripAccentBtn: Load, Compare, the layers buttons): a
        # soft blue tint with blue text and icon and a 1px blue line on the card
        # edge, as in dark (a filled blue was too dominant on the light page);
        # a stronger tint on hover. Cancel the same in red.
        ActionBgBrush            = '#1F0072CE'
        ActionFgBrush            = '#0072CE'
        ActionHoverBgBrush       = '#380072CE'
        ActionHoverFgBrush       = '#0062B1'
        CancelActionBgBrush      = '#1FBA1A1A'
        CancelActionFgBrush      = '#BA1A1A'
        CancelActionHoverBgBrush = '#38BA1A1A'
        CancelActionHoverFgBrush = '#A41717'
        ActionLineBrush          = '#0072CE'
        CancelActionLineBrush    = '#BA1A1A'
        # View Report / View Details: no tint and no line, blue text and icon; the
        # hover tint on mouse-over. Compare (tint + line) stays the main action.
        SecondaryActionBgBrush      = '#00FFFFFF'
        SecondaryActionFgBrush      = '#0072CE'
        SecondaryActionHoverBgBrush = '#140072CE'
        SecondaryActionHoverFgBrush = '#0062B1'
        SecondaryActionLineBrush    = '#00000000'
        # The layers button at the bottom left (StripLayersBtn): as the icon
        # buttons (no tint, grey icon; the hover tint and a blue icon on mouse-over).
        LayersBgBrush            = '#00FFFFFF'
        LayersFgBrush            = '#43474E'
        LayersHoverBgBrush       = '#140072CE'
        LayersHoverFgBrush       = '#0072CE'
        DisabledFgBrush       = '#667389'
        IconFgBrush           = '#43474E'
        SecBtnFgBrush         = '#191C20'
        SectionLabelBrush     = '#0072CE'
        ConsoleBgBrush        = '#F8F9FB'   # log: lighter than the grey labels (#F2F4F7), a step off the white card
        ConsoleFgBrush        = '#191C20'
        ScrollThumbBrush      = '#C3C7CF'
        PopupBgBrush          = '#FFFFFF'
        PopupBorderBrush      = '#D8DEE6'
        WarnBrush             = '#B85C00'
        ErrorBrush            = '#BA1A1A'
        CaptionHoverBrush     = '#14191C20'
        CaptionPressedBrush   = '#1F191C20'
    }
    dark = [ordered]@{
        BgBrush               = '#0F1219'
        CardBrush             = '#1B1F27'
        CardBorderBrush       = '#252A33'
        TextBrush             = '#E1E4E8'
        SubTextBrush          = '#B8C5D0'
        MutedBrush            = '#B8C5D0'
        HintBrush             = '#8D99A6'
        InputBgBrush          = '#252A33'
        InputBorderBrush      = '#404652'
        # The blue and red of the light theme (accent, action buttons,
        # Cancel, ticks); the tints at the dark alphas (8% / 16%). Main text
        # #E1E4E8 (a soft white: brighter was too harsh); the other text and
        # icons a muted blue-grey #B8C5D0 (about 9:1 on a card), hints #8D99A6,
        # so the names stand out (as Reddit's dark mode). The labels, the line
        # of an action segment and its mouse-over text the house blue #0072CE,
        # as in light (3.4:1 on a card).
        AccentBrush           = '#0072CE'
        AccentSoftBrush       = '#290072CE'
        AccentSoftHoverBrush  = '#520072CE'
        HoverBrush            = '#140072CE'
        CheckTickBrush        = '#FFFFFF'
        # Action segments: the hover tint with the neutral icon colour; on
        # hover accent text. Cancel the same with red text on hover.
        ActionBgBrush            = '#140072CE'
        ActionFgBrush            = '#B8C5D0'
        ActionHoverBgBrush       = '#140072CE'
        ActionHoverFgBrush       = '#0072CE'
        CancelActionBgBrush      = '#140072CE'
        CancelActionFgBrush      = '#B8C5D0'
        CancelActionHoverBgBrush = '#140072CE'
        CancelActionHoverFgBrush = '#BA1A1A'
        ActionLineBrush          = '#0072CE'     # the 1px blue line of an action segment
        CancelActionLineBrush    = '#BA1A1A'
        # View Report / View Details: as the other action segments.
        SecondaryActionBgBrush      = '#140072CE'
        SecondaryActionFgBrush      = '#B8C5D0'
        SecondaryActionHoverBgBrush = '#140072CE'
        SecondaryActionHoverFgBrush = '#0072CE'
        SecondaryActionLineBrush    = '#0072CE'     # as ActionLineBrush
        # The layers button at the bottom left (StripLayersBtn): the action tint, as Load and Compare.
        LayersBgBrush            = '#140072CE'
        LayersFgBrush            = '#B8C5D0'
        LayersHoverBgBrush       = '#140072CE'
        LayersHoverFgBrush       = '#0072CE'
        DisabledFgBrush       = '#676A6E'
        IconFgBrush           = '#B8C5D0'
        SecBtnFgBrush         = '#E1E4E8'
        SectionLabelBrush     = '#0072CE'
        ConsoleBgBrush        = '#0A0D13'
        ConsoleFgBrush        = '#B8C5D0'
        ScrollThumbBrush      = '#404652'
        PopupBgBrush          = '#30353F'
        PopupBorderBrush      = '#404652'
        WarnBrush             = '#F0A340'
        ErrorBrush            = '#E5534B'   # a calm red, 5.3:1 on the log (the pale #F2B8B5 read as pink)
        CaptionHoverBrush     = '#14E1E2E8'
        CaptionPressedBrush   = '#1FE1E2E8'
    }
}

$script:CurrentTheme   = 'dark'      # default until Options.json is read
$script:ThemeStyles    = $null     # ResourceDictionary from BasetuneTheme.xaml
$script:ThemeColors    = $null     # ResourceDictionary with the palette brushes
$script:ThemedWindows  = [System.Collections.Generic.List[System.Windows.Window]]::new()

function script:New-PaletteDictionary {
    param([string]$Theme)
    $dict = [System.Windows.ResourceDictionary]::new()
    $conv = [System.Windows.Media.BrushConverter]::new()
    foreach ($k in $script:ThemePalettes[$Theme].Keys) {
        $brush = $conv.ConvertFromString($script:ThemePalettes[$Theme][$k])
        $brush.Freeze()
        $dict[$k] = $brush
    }
    return $dict
}

function Initialize-BasetuneTheme {
    if ($script:ThemeStyles) { return }

    $app = [System.Windows.Application]::Current
    if (-not $app) {
        $app = [System.Windows.Application]::new()
        $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    }

    $themePath = Join-Path $AppState.XamlPath 'BasetuneTheme.xaml'
    if (-not (Test-Path -LiteralPath $themePath)) { throw "Theme file not found: $themePath" }
    [xml]$tx = Get-Content -LiteralPath $themePath -Raw -Encoding UTF8
    $script:ThemeStyles = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($tx))
    $script:ThemeColors = New-PaletteDictionary $script:CurrentTheme

    # Colours first, styles second: the styles' DynamicResource lookups find
    # the brushes in the same Application resources.
    $app.Resources.MergedDictionaries.Clear()
    $app.Resources.MergedDictionaries.Add($script:ThemeColors)
    $app.Resources.MergedDictionaries.Add($script:ThemeStyles)

    # Open dropdown lists scroll one item per mouse notch, as the policy lists
    # (Set-SlowScroll -PerItem -Lines 1): a class handler on every ComboBoxItem,
    # so it holds for all dropdowns of all windows. The popup's ScrollViewer
    # scrolls in items (CanContentScroll in the templates); small touchpad
    # events add up to a whole item.
    if (-not $script:ComboWheelHooked) {
        $script:ComboWheelHooked = $true
        $script:ComboWheelAcc = 0.0
        [System.Windows.EventManager]::RegisterClassHandler([System.Windows.Controls.ComboBoxItem],
            [System.Windows.UIElement]::PreviewMouseWheelEvent,
            [System.Windows.Input.MouseWheelEventHandler]{
                param($s, $e)
                $sv = $s
                while ($sv -and $sv -isnot [System.Windows.Controls.ScrollViewer]) { $sv = [System.Windows.Media.VisualTreeHelper]::GetParent($sv) }
                if (-not $sv) { return }
                if (($script:ComboWheelAcc -gt 0 -and $e.Delta -lt 0) -or ($script:ComboWheelAcc -lt 0 -and $e.Delta -gt 0)) { $script:ComboWheelAcc = 0.0 }
                $script:ComboWheelAcc += $e.Delta
                $rows = [math]::Truncate($script:ComboWheelAcc / 120.0)
                if ($rows -ne 0) {
                    $sv.ScrollToVerticalOffset($sv.VerticalOffset - $rows)
                    $script:ComboWheelAcc -= $rows * 120.0
                }
                $e.Handled = $true
            })
    }
}

function Get-BasetuneTheme { return $script:CurrentTheme }

# Switch every open window to 'light' or 'dark' (anything else: dark, the
# default). Safe before any window exists.
function Set-BasetuneTheme {
    param([string]$Theme)
    $Theme = "$Theme".Trim().ToLower()
    if ($Theme -notin @('light', 'dark')) { $Theme = 'dark' }
    Initialize-BasetuneTheme

    $app = [System.Windows.Application]::Current
    $new = New-PaletteDictionary $Theme
    $idx = $app.Resources.MergedDictionaries.IndexOf($script:ThemeColors)
    if ($idx -ge 0) { $app.Resources.MergedDictionaries[$idx] = $new }
    else            { $app.Resources.MergedDictionaries.Insert(0, $new) }
    $script:ThemeColors  = $new
    $script:CurrentTheme = $Theme

    foreach ($w in @($script:ThemedWindows)) { Set-WindowTitleBarTheme $w }
}

# ── Dark title bar ───────────────────────────────────────────────────────────
# Windows draws the title bar, so it stays white in dark mode without this.
# DWMWA_USE_IMMERSIVE_DARK_MODE = 20 on Windows 10 20H1+ / 11 (19 on older 10
# builds). Best-effort: on older Windows the title bar stays light.
if (-not ('Basetune.DwmTheme' -as [type])) {
    try {
        Add-Type -Namespace Basetune -Name DwmTheme -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int value, int size);
'@ -ErrorAction Stop
    } catch {}
}

function script:Set-WindowTitleBarTheme {
    param([System.Windows.Window]$Window)
    if (-not ('Basetune.DwmTheme' -as [type])) { return }
    try {
        $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($Window).Handle
        if ($hwnd -eq [IntPtr]::Zero) { return }   # not shown yet; SourceInitialized handles it
        $on = if ($script:CurrentTheme -ne 'light') { 1 } else { 0 }   # dark
        if ([Basetune.DwmTheme]::DwmSetWindowAttribute($hwnd, 20, [ref]$on, 4) -ne 0) {
            [void][Basetune.DwmTheme]::DwmSetWindowAttribute($hwnd, 19, [ref]$on, 4)
        }
    } catch {}
}

function script:Register-ThemedWindow {
    param([System.Windows.Window]$Window)
    $script:ThemedWindows.Add($Window)
    # No GetNewClosure here: the handlers must run in this module's scope to
    # reach $script:ThemedWindows and Set-WindowTitleBarTheme.
    $Window.Add_SourceInitialized({ param($s, $e) Set-WindowTitleBarTheme $s })
    $Window.Add_Closed({ param($s, $e) [void]$script:ThemedWindows.Remove($s) })
}

# ── Dialogs: own title bar + fixed size ──────────────────────────────────────
# Baseline Configuration, Options and Download Definitions use WindowChrome
# (see their XAML): no invisible Windows border, so a Dell Display Manager
# zone beside a monitor with other scaling does not enlarge them. DDM also
# sizes a window to its zone: when something outside sets the size (WPF then
# switches SizeToContent to Manual), width and SizeToContent are put back and
# the dialog is centred in the given area. A zone only sets the position.
function Initialize-DialogChrome {
    param([System.Windows.Window]$Dialog, $CloseButton)

    $CloseButton.Add_Click({ param($s, $e) [System.Windows.Window]::GetWindow($s).Close() })

    # Title bar icon: the icon of the host process (pwsh), like the main window.
    $img = Find-InTree -Root $Dialog -Name 'imgDlgIcon'
    if ($img) {
        try {
            if (-not $script:DialogIcon) {
                $ico = [System.Drawing.Icon]::ExtractAssociatedIcon((Get-Process -Id $PID).Path)
                if ($ico) {
                    $script:DialogIcon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                        $ico.Handle, [System.Windows.Int32Rect]::Empty,
                        [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
                }
            }
            if ($script:DialogIcon) { $img.Source = $script:DialogIcon }
        } catch {}
    }

    # Strips (stripButtons: Save / Download | Close; stripFields: the fields
    # as label | value rows; stripTenant: the tenant strip), the strip style of the main window: clipped to
    # their rounded card (radius 8 - 1px border = 7), so the square tint of a
    # segment never shows past the corners; 1px taller for the line of an
    # action segment on the bottom edge (StripBtn). stripButtons is the bottom
    # of the card (a line above it): only its bottom corners are rounded, the
    # top ones stay square (a rounded top cut the tint of Close). stripTenant
    # is the top of the card (a line under it): only its top corners rounded.
    foreach ($stripName in 'stripButtons', 'stripFields', 'stripTenant') {
        $strip = Find-InTree -Root $Dialog -Name $stripName
        if (-not $strip) { continue }
        $strip.Add_SizeChanged({
            param($s, $e)
            $w = $e.NewSize.Width; $h = $e.NewSize.Height + 1
            $rounded = [System.Windows.Media.RectangleGeometry]::new([System.Windows.Rect]::new(0, 0, $w, $h), 7, 7)
            if ($s.Name -eq 'stripButtons') {
                $top = [System.Windows.Media.RectangleGeometry]::new([System.Windows.Rect]::new(0, 0, $w, [math]::Max(0, $h - 7)))
                $s.Clip = [System.Windows.Media.CombinedGeometry]::new([System.Windows.Media.GeometryCombineMode]::Union, $rounded, $top)
            } elseif ($s.Name -eq 'stripTenant') {
                $bottom = [System.Windows.Media.RectangleGeometry]::new([System.Windows.Rect]::new(0, [math]::Min(7, $h), $w, [math]::Max(0, $h - 7)))
                $s.Clip = [System.Windows.Media.CombinedGeometry]::new([System.Windows.Media.GeometryCombineMode]::Union, $rounded, $bottom)
            } else {
                $s.Clip = $rounded
            }
        })
    }

    # Windows 11: rounded corners (DWMWA_WINDOW_CORNER_PREFERENCE = 33, round = 2).
    $Dialog.Add_SourceInitialized({
        param($s, $e)
        try {
            if ('Basetune.DwmTheme' -as [type]) {
                $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($s).Handle
                $round = 2
                [void][Basetune.DwmTheme]::DwmSetWindowAttribute($hwnd, 33, [ref]$round, 4)
            }
        } catch {}
    })

    # Fixed size: undo a size set from outside (DDM zone, snap).
    $fixedWidth = $Dialog.Width
    $sizeMode   = $Dialog.SizeToContent
    $handler = [System.EventHandler]{
        param($s, $e)
        if ($s.SizeToContent -ne 'Manual' -or $sizeMode -eq 'Manual') { return }
        # GetNewClosure() only captures local variables: copy them into $st.
        $st = @{ Win = $s; Width = $fixedWidth; Mode = $sizeMode }
        # Run after the new size is applied, so the given area is known.
        [void]$s.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{
            $st = $st   # local copy, so the nested closure below captures it
            $w = $st.Win
            $st.L = $w.Left; $st.T = $w.Top; $st.W = $w.ActualWidth; $st.H = $w.ActualHeight
            if ($st.Width -gt 0) { $w.Width = $st.Width }
            $w.SizeToContent = $st.Mode
            [void]$w.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{
                $w = $st.Win
                $w.Left = $st.L + [math]::Max(0, ($st.W - $w.ActualWidth)  / 2)
                $w.Top  = $st.T + [math]::Max(0, ($st.H - $w.ActualHeight) / 2)
            }.GetNewClosure())
        }.GetNewClosure())
    }.GetNewClosure()
    $desc = [System.ComponentModel.DependencyPropertyDescriptor]::FromProperty(
        [System.Windows.Window]::SizeToContentProperty, [System.Windows.Window])
    $desc.AddValueChanged($Dialog, $handler)
    # AddValueChanged keeps a reference to the dialog: remove it on close.
    $Dialog.Add_Closed({ $desc.RemoveValueChanged($Dialog, $handler) }.GetNewClosure())
}

# ── Load a XAML file and return the root element ─────────────────────────────
# Reads UTF-8, parses, throws clear errors. With -Width/-Height it forces a
# layout pass, so FindName / visual tree walks work right away.
function Import-Xaml {
    param(
        [Parameter(Mandatory)][string]$Path,
        [double]$Width  = 0,
        [double]$Height = 0
    )
    # Errors are thrown; at startup Show-StartupError (BasetuneUI.ps1) shows
    # them in a message box. No Write-Host / Read-Host: the console is hidden,
    # so the process would wait forever, invisible.

    if (-not (Test-Path $Path)) {
        $msg = "XAML FILE NOT FOUND: $Path"
        throw $msg
    }

    try {
        [xml]$xaml = Get-Content $Path -Raw -Encoding UTF8
    } catch {
        $msg = "XAML XML PARSE ERROR: $_"
        throw $msg
    }

    # Shared styles + colour palette must exist before the window is parsed:
    # the windows reference Card, StripBtn, ... with StaticResource, which
    # falls back to Application.Current.Resources.
    Initialize-BasetuneTheme

    $reader = [System.Xml.XmlNodeReader]::new($xaml)
    try {
        $root = [Windows.Markup.XamlReader]::Load($reader)
    } catch {
        $inner = $_.Exception.InnerException
        $msg = "XAML LOAD ERROR: $($_.Exception.Message)" + $(if ($inner) { "`nINNER: $($inner.Message)" } else { '' })
        throw $msg
    }
    if (-not $root) {
        $msg = "XAML loaded but root is null: $Path"
        throw $msg
    }

    # Dark/light title bar follows the theme (Windows 10 20H1+ / 11).
    if ($root -is [System.Windows.Window]) { Register-ThemedWindow $root }

    # Dialogs with the own title bar (btnDlgClose): close button, icon,
    # rounded corners and a fixed size.
    if ($root -is [System.Windows.Window]) {
        $dlgClose = Find-InTree -Root $root -Name 'btnDlgClose'
        if ($dlgClose) { Initialize-DialogChrome -Dialog $root -CloseButton $dlgClose }
    }

    # Force a layout pass: XamlReader::Load registers names in its own
    # nameScope, so FindName needs the visual tree built.
    if ($Width -gt 0 -and $Height -gt 0) {
        $root.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
        $root.Arrange([System.Windows.Rect]::new(0, 0, $Width, $Height))
        $root.UpdateLayout()
    }

    return $root
}

# ── Find a named element anywhere in a WPF tree ───────────────────────────────
# FindName first (name in the tree's nameScope), then a BFS over the visual
# tree for names XamlReader put in another scope.
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
    'Show-FolderBrowser',
    'Set-SlowScroll',
    'Initialize-BasetuneTheme',
    'Get-BasetuneTheme',
    'Set-BasetuneTheme',
    'Initialize-DialogChrome',
    'Import-Xaml',
    'Find-InTree'
)
