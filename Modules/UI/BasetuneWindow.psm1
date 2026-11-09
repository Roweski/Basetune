# =============================================================================
# BasetuneWindow.psm1
# Main window chrome: own title bar, start size / position, maximised margin,
# tooltips for cut-off text, rounded corners, and the collapsible log view.
# $UI / $AppState come from BasetuneState.psm1.
# =============================================================================

$script:UI       = (Get-BasetuneContext).UI
$script:AppState = (Get-BasetuneContext).State

# ── Native window helpers ────────────────────────────────────────────────────
# For Resize-BasetuneWindowToScreen and the maximised margin.
# DPI: pwsh.exe is "system DPI aware" (its manifest): sharp on the main
# monitor, scaled by Windows on a monitor with other scaling. Per-monitor DPI
# set from the script (thread or HighDpiAware layer) gives half-drawn windows
# or stuck scaling; WPF needs it from the manifest (an own launcher .exe).
try {
    if (-not ('Basetune.NativeWin' -as [type])) {
        Add-Type -Namespace Basetune -Name NativeWin -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetDpiForWindow(System.IntPtr hwnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetWindowPos(System.IntPtr hwnd, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool GetWindowRect(System.IntPtr hwnd, out RECT rect);
'@
    }
} catch {}

# ── Fit the start size to the monitor ────────────────────────────────────────
# 1400x1000 does not fit every screen (a laptop at 175% has ~850-900 DIP
# height), and a window can open across two monitors. Once shown, a window that
# does not fit on one monitor is moved onto the monitor holding most of it,
# shrunk to at most 92% of its work area and centred. Pixels via the window's
# own DPI + SetWindowPos (one coordinate space, also with other scaling).
# Best-effort: on any error nothing changes.
function Resize-BasetuneWindowToScreen {
    param($Win)
    try {
        $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($Win).Handle
        if ($hwnd -eq [System.IntPtr]::Zero) { return }
        $scale = [Basetune.NativeWin]::GetDpiForWindow($hwnd) / 96.0
        if ($scale -le 0) { return }
        $wa = [System.Windows.Forms.Screen]::FromHandle($hwnd).WorkingArea   # physical pixels
        $availW = $wa.Width  / $scale
        $availH = $wa.Height / $scale
        $maxW   = [math]::Floor($availW * 0.92)
        $maxH   = [math]::Floor($availH * 0.92)
        if ($Win.MinWidth  -gt $maxW) { $Win.MinWidth  = $maxW }
        if ($Win.MinHeight -gt $maxH) { $Win.MinHeight = $maxH }
        $w = [math]::Min($Win.ActualWidth,  $maxW)
        $h = [math]::Min($Win.ActualHeight, $maxH)

        $pxW = [int][math]::Round($w * $scale)
        $pxH = [int][math]::Round($h * $scale)
        $tooBig = ($w -lt $Win.ActualWidth) -or ($h -lt $Win.ActualHeight)
        $r = New-Object Basetune.NativeWin+RECT
        $inside = $true
        if ([Basetune.NativeWin]::GetWindowRect($hwnd, [ref]$r)) {
            # Small tolerance for the invisible resize border around the window.
            $tol = [int](8 * $scale)
            $inside = ($r.Left -ge $wa.Left - $tol) -and ($r.Top -ge $wa.Top - $tol) -and
                      ($r.Right -le $wa.Right + $tol) -and ($r.Bottom -le $wa.Bottom + $tol)
        }
        if (-not $tooBig -and $inside) { return }
        $x = $wa.Left + [int](($wa.Width  - $pxW) / 2)
        $y = $wa.Top  + [int](($wa.Height - $pxH) / 2)
        # SWP_NOZORDER (0x4) | SWP_NOACTIVATE (0x10)
        [void][Basetune.NativeWin]::SetWindowPos($hwnd, [System.IntPtr]::Zero, $x, $y, $pxW, $pxH, 0x14)
    } catch {}
}

# Maximised: Windows puts the resize frame off-screen on every side. Move the
# content in by that amount (window rect vs work area) and hide the outline.
# Restored: no margin, outline back. Also sets the maximise / restore glyph.
function Update-BasetuneMaximizedState {
    $w = $UI.Window
    $isMax = ($w.WindowState -eq 'Maximized')
    if ($UI.btnCaptionMax) {
        $UI.btnCaptionMax.Content = if ($isMax) { [string][char]0xE923 } else { [string][char]0xE922 }
        $UI.btnCaptionMax.ToolTip = if ($isMax) { 'Restore Down' } else { 'Maximize' }
    }
    if (-not $UI.rootBorder) { return }
    if (-not $isMax) {
        $UI.rootBorder.Margin          = [System.Windows.Thickness]::new(0)
        $UI.rootBorder.BorderThickness = [System.Windows.Thickness]::new(1)
        return
    }
    $UI.rootBorder.BorderThickness = [System.Windows.Thickness]::new(0)
    try {
        $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($w).Handle
        $r = New-Object Basetune.NativeWin+RECT
        if (-not [Basetune.NativeWin]::GetWindowRect($hwnd, [ref]$r)) { return }
        $wa    = [System.Windows.Forms.Screen]::FromHandle($hwnd).WorkingArea
        $scale = [System.Windows.Media.VisualTreeHelper]::GetDpi($w).DpiScaleX
        if ($scale -le 0) { $scale = 1 }
        $l = [math]::Max(0, $wa.Left   - $r.Left)   / $scale
        $t = [math]::Max(0, $wa.Top    - $r.Top)    / $scale
        $rr = [math]::Max(0, $r.Right  - $wa.Right)  / $scale
        $b = [math]::Max(0, $r.Bottom - $wa.Bottom) / $scale
        $UI.rootBorder.Margin = [System.Windows.Thickness]::new($l, $t, $rr, $b)
    } catch {
        # Fallback: the usual frame width.
        $UI.rootBorder.Margin = [System.Windows.Thickness]::new(7)
    }
}

# ── Tooltips with the full name only when the text is cut off ────────────────
# Policy names and the selected tenant are cut off with "..." in a narrow
# window. When the text fits, the tooltip is cancelled just before it opens
# (one text measurement at that moment, nothing in the background).
# The width the text needs is measured by a TextBlock of its own with the
# same text and font, in the same text formatting mode: the UI draws in
# Display mode, where a TextBlock needs about 10px more than a FormattedText
# measures (332 against 322 for a 50-character name), so FormattedText
# missed names that are only just cut off. Within 1px it counts as cut off:
# a tooltip too many is better than a missing one.
function Test-BasetuneTextTrimmed {
    param([System.Windows.Controls.TextBlock]$Tb)
    if (-not $Tb -or -not $Tb.Text -or $Tb.ActualWidth -le 0) { return $false }
    $probe = [System.Windows.Controls.TextBlock]::new()
    $probe.Text        = $Tb.Text
    $probe.FontFamily  = $Tb.FontFamily
    $probe.FontSize    = $Tb.FontSize
    $probe.FontStyle   = $Tb.FontStyle
    $probe.FontWeight  = $Tb.FontWeight
    $probe.FontStretch = $Tb.FontStretch
    [System.Windows.Media.TextOptions]::SetTextFormattingMode($probe, [System.Windows.Media.TextOptions]::GetTextFormattingMode($Tb))
    $probe.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
    return ($probe.DesiredSize.Width -gt ($Tb.ActualWidth - 1))
}

# Width of a labelled strip button that holds each of $Labels (label = its
# icon size): the spacing of the icon buttons (2 x 12.5 padding) + the icon +
# 6px + the label, the widest of them, measured in the button's font
# (SemiBold), so it holds for every scaling and font.
function script:Get-StripLabelWidth {
    param($Button, [System.Collections.IDictionary]$Labels)
    $face = [System.Windows.Media.Typeface]::new($Button.FontFamily, $Button.FontStyle, [System.Windows.FontWeights]::SemiBold, $Button.FontStretch)
    $dpi  = [System.Windows.Media.VisualTreeHelper]::GetDpi($Button).PixelsPerDip
    $max  = 0.0
    foreach ($label in $Labels.Keys) {
        $ft = [System.Windows.Media.FormattedText]::new($label, [System.Globalization.CultureInfo]::CurrentUICulture,
                  [System.Windows.FlowDirection]::LeftToRight, $face, $Button.FontSize, [System.Windows.Media.Brushes]::Black, $dpi)
        $max = [math]::Max($max, 25 + $Labels[$label] + 6 + [math]::Ceiling($ft.WidthIncludingTrailingWhitespace))
    }
    return $max
}

# Width of one labelled action button: the widest of the three; all three get
# it. Measured once (the labels do not change; "Cancel" on Compare is shorter).
function script:Get-StripActionWidth {
    if (-not $script:StripActionWidth) { $script:StripActionWidth = Get-StripLabelWidth $UI.btnCompare ([ordered]@{ 'Compare' = 20; 'View Report' = 20; 'View Details' = 20 }) }
    return $script:StripActionWidth
}

# Width of the Load buttons: "Load" or "Cancel" (while loading), whichever is
# wider, so the strip never moves when a load starts. Measured once.
function script:Get-StripLoadWidth {
    if (-not $script:StripLoadWidth) { $script:StripLoadWidth = Get-StripLabelWidth $UI.btnSourceLoad ([ordered]@{ 'Load' = 20; 'Cancel' = 18 }) }
    return $script:StripLoadWidth
}

# The action buttons of the strip: all three as wide as the widest content
# (Get-StripActionWidth), or icon only (40px, as the icon buttons; see
# Initialize-BasetuneWindow); the Load buttons follow (Get-StripLoadWidth / 40).
# The buttons card (the left half of the actions card: its width minus the
# 12px gap, halved, minus its 2px border) must hold the three labelled
# buttons, the three 40px icon buttons (Baseline Configuration, Download,
# Options) and the 6 lines between;
# icon only only when the labelled buttons would reach the icon buttons (the
# empty strip between them is gone).
# Only sets the resources when the mode changes.
function script:Set-StripMode {
    $w      = $UI.cardActions.ActualWidth
    $action = Get-StripActionWidth
    $narrow = $w -gt 0 -and (($w - 12) / 2 - 2) -lt (3 * $action + 3 * 40 + 6)
    # The empty strip (column 8) almost gone: drop the line before Download, so it
    # never shows as a second line right next to the one after View Details.
    if ($UI.sepStripGap) {
        $UI.sepStripGap.Visibility = if ($UI.stripActions.ColumnDefinitions[8].ActualWidth -lt 2) { 'Hidden' } else { 'Visible' }
    }
    if ($AppState.stripNarrow -eq $narrow) { return }
    $AppState.stripNarrow = $narrow
    # On the window: the action buttons, the Load buttons of the tenant strips
    # (their column, StripLoadWidth) and the Load / Compare Cancel content
    # (New-ButtonContent) all follow it.
    $UI.Window.Resources['StripActionWidth']     = if ($narrow) { [double]40 } else { [double]$action }
    # Side padding 12.5 next to a label; icon only none, so the 20px icon is
    # centred in the 40px segment and never squeezed (40 - 25 = 15 < 20).
    $UI.Window.Resources['StripActionPadding']   = [System.Windows.Thickness]::new($(if ($narrow) { 0 } else { 12.5 }), 0, $(if ($narrow) { 0 } else { 12.5 }), 0)
    $UI.Window.Resources['StripLoadWidth']       = [System.Windows.GridLength]::new($(if ($narrow) { 40 } else { Get-StripLoadWidth }))
    $UI.Window.Resources['StripLabelVisibility'] = if ($narrow) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }
    # The play triangle of Load sits off centre in its 20px box (more blank space
    # left, 8 of 24, than right, 5); a negative margin also narrows the centred
    # content, so it moves left: -6 next to its label, -3 when icon only
    # (measured); no top margin.
    $UI.Window.Resources['StripPlayIconMargin'] = [System.Windows.Thickness]::new($(if ($narrow) { -3 } else { -6 }), 0, 0, 0)
    # The reload arrows of a loaded side (18, centred in their box): next to the
    # label the same room as the play triangle (20 - 6 = 18 - 4), so "Load" stays
    # put and both icons have the same centre; icon only centred (0).
    $UI.Window.Resources['StripReloadIconMargin'] = [System.Windows.Thickness]::new($(if ($narrow) { 0 } else { -4 }), 1, 0, 0)
}

# ── Height of the expanded log ───────────────────────────────────────────────
# Whole lines of 18 + 2x10 padding. $AppState.logLines is the number the user
# chose (5 at start, dragging the top edge, thumbLogResize). The bottom card
# (log + buttons strip) is never taller than the source card above it (tenant
# strip + policy list): at most 50/50. Both share the height of the window
# minus the gap (top + bottom stays the same while the log grows), so the
# bottom card may have half of it. At least 2 lines, unless 50/50 leaves room
# for fewer (a small window: 50/50 wins, 1 line at least). A smaller window
# shows fewer lines without changing the choice; a bigger one shows them again.
$script:LogLineHeight = 18
$script:LogPadding    = 20
function script:Get-LogMaxLines {
    $top = $UI.stripSource.Parent.ActualHeight + $UI.cardSource.Parent.ActualHeight
    $bottom = $UI.cardActions.ActualHeight
    if ($top -le 0 -or $bottom -le 0) { return [int]$AppState.logLines }
    # Expanded: cardActions = the log (txtLog + its 1px top border) + the buttons
    # card; collapsed: only the buttons row. Either way top + bottom is the total.
    $maxLog = ($top + $bottom) / 2 - $UI.cardButtons.ActualHeight - 1
    return [math]::Max(1, [int][math]::Floor(($maxLog - $script:LogPadding) / $script:LogLineHeight))
}
function script:Set-LogLines {
    param([int]$Lines)
    $Lines = [math]::Min([math]::Max(2, $Lines), (Get-LogMaxLines))
    $h = $Lines * $script:LogLineHeight + $script:LogPadding
    if ($UI.txtLog.Height -ne $h) {
        $UI.txtLog.Height = $h
        $UI.txtLog.ScrollToEnd()
    }
}

# Collapse the log into the strip (its last line left of the buttons) or
# expand it above the strip ($AppState.logLines, Set-LogLines); see
# Initialize-BasetuneWindow.
function script:Set-LogCollapsed {
    param([bool]$Collapsed)
    $AppState.logCollapsed = $Collapsed
    if ($UI.thumbLogResize) { $UI.thumbLogResize.Visibility = if ($Collapsed) { 'Collapsed' } else { 'Visible' } }
    if ($Collapsed) {
        $UI.bdLog.Child          = $null
        $UI.bdLog.Visibility     = 'Collapsed'
        Set-ActionsJoined $false
        $UI.txtLog.Height        = 34      # the strip: 1 line of 18 + 8 above and below
        # Left 9: the RichTextBox puts the text 5px in (+1 of the glyph), so it
        # starts at 14 + 1, as the tenant name in the dropdown above (padding 14).
        $UI.txtLog.Padding       = [System.Windows.Thickness]::new(9, 8, 16, 8)
        # The one line in the UI font (Segoe UI 13, one below the strip text);
        # the expanded log stays a console (Consolas 13, the XAML values).
        Set-LogFont -Family 'Segoe UI' -Size 13
        $UI.bdLogLine.Child      = $UI.txtLog
        $UI.bdLogLine.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'ConsoleBgBrush')
        $UI.btnToggleLog.ToolTip = 'Expand log'
        Set-LogToggleRotation -Angle 180
    } else {
        $UI.bdLogLine.Child      = $null
        $UI.bdLogLine.Background = [System.Windows.Media.Brushes]::Transparent   # the strip colour, as the icon buttons
        Set-LogLines $AppState.logLines   # the chosen lines of 18 + padding 2x10
        # Left 9 (+ the 5px text inset of the RichTextBox + 1 border): the text
        # starts at 15 in from the card, on the policy checkboxes (ListBox 8 + 1 +
        # item padding 6).
        $UI.txtLog.Padding       = [System.Windows.Thickness]::new(9, 10, 16, 10)
        Set-LogFont -Family 'Consolas' -Size 13
        $UI.bdLog.Child          = $UI.txtLog
        $UI.bdLog.Visibility     = 'Visible'
        Set-ActionsJoined $true
        $UI.btnToggleLog.ToolTip = 'Collapse log'
        Set-LogToggleRotation -Angle 0
    }
    $UI.txtLog.ScrollToEnd()
}

# Font of the log text: on the RichTextBox and its FlowDocument (the document
# has its own FontFamily / FontSize in the XAML, which the paragraphs inherit).
function script:Set-LogFont {
    param([string]$Family, [double]$Size)
    $ff = [System.Windows.Media.FontFamily]::new($Family)
    $UI.txtLog.FontFamily = $ff; $UI.txtLog.FontSize = $Size
    if ($UI.txtLog.Document) { $UI.txtLog.Document.FontFamily = $ff; $UI.txtLog.Document.FontSize = $Size }
}

# Expanded log: the log and the buttons strip one card over the full width
# (the log on top with the rounded top corners, the strip under it with
# the bottom ones, the strip's top border the line between them); the empty
# log line card goes. Collapsed: the buttons card under the source card,
# the log line card under the target card, the 12px gap between them. The
# buttons start at the left in both states, so they never move.
function script:Set-ActionsJoined {
    param([bool]$Joined)
    if (-not $UI.cardButtons) { return }
    # The chevron: right in the log line card, or (expanded) at the right end of
    # the buttons strip, the same place at the window edge; an icon segment
    # (StripIconBtn) in both, with a line before it in the strip.
    if ($UI.hostToggleCollapsed -and $UI.hostToggleExpanded) {
        $UI.hostToggleCollapsed.Child = $null
        $UI.hostToggleExpanded.Child  = $null
        $vis = if ($Joined) { 'Visible' } else { 'Collapsed' }
        $UI.hostToggleExpanded.Visibility = $vis
        if ($UI.sepToggleExpanded) { $UI.sepToggleExpanded.Visibility = $vis }
        if ($Joined) { $UI.hostToggleExpanded.Child = $UI.btnToggleLog } else { $UI.hostToggleCollapsed.Child = $UI.btnToggleLog }
    }
    # The log button: left in the log line card, or (expanded) in the strip
    # between Options and the chevron, so it never disappears with that card.
    if ($UI.btnOpenLog -and $UI.hostLogCollapsed -and $UI.hostLogExpanded) {
        $UI.hostLogCollapsed.Child = $null
        $UI.hostLogExpanded.Child  = $null
        $vis = if ($Joined) { 'Visible' } else { 'Collapsed' }
        $UI.hostLogExpanded.Visibility = $vis
        if ($UI.sepLogExpanded) { $UI.sepLogExpanded.Visibility = $vis }
        if ($Joined) { $UI.hostLogExpanded.Child = $UI.btnOpenLog } else { $UI.hostLogCollapsed.Child = $UI.btnOpenLog }
    }
    $colProp  = [System.Windows.Controls.Grid]::ColumnProperty
    $spanProp = [System.Windows.Controls.Grid]::ColumnSpanProperty
    if ($Joined) {
        $UI.cardLogLine.Visibility = 'Collapsed'
        $UI.cardButtons.SetValue($colProp, 0)
        $UI.cardButtons.SetValue($spanProp, 3)
        if ($UI.progressBar) { $UI.progressBar.SetValue($colProp, 0); $UI.progressBar.SetValue($spanProp, 3) }   # the busy bar over the full width too
        $UI.cardButtons.CornerRadius = [System.Windows.CornerRadius]::new(0, 0, 8, 8)
        $UI.bdLog.CornerRadius       = [System.Windows.CornerRadius]::new(8, 8, 0, 0)
        $UI.bdLog.BorderThickness    = [System.Windows.Thickness]::new(1, 1, 1, 0)
        $UI.bdLog.Margin             = [System.Windows.Thickness]::new(0)
    } else {
        $UI.cardLogLine.Visibility = 'Visible'
        $UI.cardButtons.SetValue($colProp, 0)
        $UI.cardButtons.SetValue($spanProp, 1)
        if ($UI.progressBar) { $UI.progressBar.SetValue($colProp, 2); $UI.progressBar.SetValue($spanProp, 1) }   # the busy bar under the log line card
        $UI.cardButtons.ClearValue([System.Windows.Controls.Border]::CornerRadiusProperty)   # the Card style's 8
        $UI.bdLog.CornerRadius       = [System.Windows.CornerRadius]::new(8)
        $UI.bdLog.BorderThickness    = [System.Windows.Thickness]::new(1)
        $UI.bdLog.Margin             = [System.Windows.Thickness]::new(0, 0, 0, 12)
    }
    Update-StripClip $UI.stripActions   # the corners of the buttons card changed
}

# Rotate the chevron (down = log open, up = log closed) in 0.4 s, from the
# current angle, so a fast double click turns back smoothly.
function Set-LogToggleRotation {
    param([double]$Angle)
    if (-not $UI.pathToggleLog) { return }
    $rot = $UI.pathToggleLog.RenderTransform
    if (-not ($rot -is [System.Windows.Media.RotateTransform]) -or $rot.IsFrozen) {
        $rot = New-Object System.Windows.Media.RotateTransform 0
        $UI.pathToggleLog.RenderTransformOrigin = New-Object System.Windows.Point 0.5, 0.5
        $UI.pathToggleLog.RenderTransform = $rot
    }
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.To       = $Angle
    $anim.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(400))
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseInOut
    $anim.EasingFunction = $ease
    $rot.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $anim)
}

# ═════════════════════════════════════════════════════════════════════════════
# INITIALISATION
# Title bar, window and log view handlers. Called once from BasetuneUI.ps1,
# after the main window is loaded and its controls registered.
# ═════════════════════════════════════════════════════════════════════════════
# Clip a strip Grid to the inside of its card: per corner the card's
# CornerRadius minus its 1px border (a square corner stays square); a Grid
# whose parent has no rounded corners (cardActions) gets 7 all round. 1px
# taller than the inside, for the line of an action segment on the bottom
# edge (StripBtn). Called on every size change and when Set-ActionsJoined
# changes the corners of the buttons card.
function script:Update-StripClip {
    param($Strip)
    if (-not $Strip -or $Strip.ActualWidth -le 0) { return }
    $w = $Strip.ActualWidth; $h = $Strip.ActualHeight + 1
    $cr = if ($Strip.Parent -is [System.Windows.Controls.Border]) { $Strip.Parent.CornerRadius } else { $null }
    if (-not $cr -or ($cr.TopLeft + $cr.TopRight + $cr.BottomRight + $cr.BottomLeft) -eq 0) {
        $Strip.Clip = [System.Windows.Media.RectangleGeometry]::new([System.Windows.Rect]::new(0, 0, $w, $h), 7, 7)
        return
    }
    $tl = [math]::Max(0, $cr.TopLeft - 1);     $tr = [math]::Max(0, $cr.TopRight - 1)
    $br = [math]::Max(0, $cr.BottomRight - 1); $bl = [math]::Max(0, $cr.BottomLeft - 1)
    $pt = { param($x, $y) [System.Windows.Point]::new($x, $y) }
    $sz = { param($r) [System.Windows.Size]::new($r, $r) }
    $g = [System.Windows.Media.StreamGeometry]::new()
    $c = $g.Open()
    $c.BeginFigure((& $pt $tl 0), $true, $true)
    $c.LineTo((& $pt ($w - $tr) 0), $false, $false)
    if ($tr -gt 0) { $c.ArcTo((& $pt $w $tr), (& $sz $tr), 0, $false, 'Clockwise', $false, $false) }
    $c.LineTo((& $pt $w ($h - $br)), $false, $false)
    if ($br -gt 0) { $c.ArcTo((& $pt ($w - $br) $h), (& $sz $br), 0, $false, 'Clockwise', $false, $false) }
    $c.LineTo((& $pt $bl $h), $false, $false)
    if ($bl -gt 0) { $c.ArcTo((& $pt 0 ($h - $bl)), (& $sz $bl), 0, $false, 'Clockwise', $false, $false) }
    $c.LineTo((& $pt 0 $tl), $false, $false)
    if ($tl -gt 0) { $c.ArcTo((& $pt $tl 0), (& $sz $tl), 0, $false, 'Clockwise', $false, $false) }
    $c.Close()
    $g.Freeze()
    $Strip.Clip = $g
}
function Initialize-BasetuneWindow {
    $UI.Window.Add_ContentRendered({ Resize-BasetuneWindowToScreen $UI.Window })

    # ── Cards: clip the strip segments to the rounded card ──────────────────────
    # The segments of the strips (the source / target tenant strips, each a
    # card of its own, the button strip at the bottom of the actions card) are square;
    # the Grid inside each card is clipped to the card's inner shape (radius
    # 8 - 1px border = 7), so a coloured corner segment (red Cancel on Export
    # or Compare, a hover tint, the log background) never shows past the
    # rounded corners. Set again on every size change. A Clip keeps ClearType
    # (an OpacityMask would not). 1px taller than the inside: the line of an
    # action segment lies on the bottom edge of the card (StripBtn).
    # Each corner follows the card around it (Update-StripClip): a square card
    # corner (the bottom of a tenant strip, the top of the buttons strip under
    # the expanded log) stays square, so a label or a hover tint fills it.
    foreach ($name in 'stripSource', 'stripTarget', 'cardSource', 'cardTarget', 'cardActions', 'stripActions', 'stripLogLine') {
        $card = $UI[$name]
        if (-not $card) { continue }
        $card.Add_SizeChanged({ param($s, $e) Update-StripClip $s })
    }

    # ── Own title bar (WindowChrome, see BasetuneUI.xaml) ────────────────────────
    if ($UI.btnCaptionMin)   { $UI.btnCaptionMin.Add_Click({ $UI.Window.WindowState = 'Minimized' }) }
    if ($UI.btnCaptionClose) { $UI.btnCaptionClose.Add_Click({ $UI.Window.Close() }) }
    if ($UI.btnCaptionMax) {
        $UI.btnCaptionMax.Add_Click({
            $UI.Window.WindowState = if ($UI.Window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }
        })
    }

    # Title bar icon: the icon of the host process (pwsh), same as the taskbar.
    try {
        $exeIcon = [System.Drawing.Icon]::ExtractAssociatedIcon((Get-Process -Id $PID).Path)
        if ($exeIcon -and $UI.imgTitleIcon) {
            $UI.imgTitleIcon.Source = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                $exeIcon.Handle, [System.Windows.Int32Rect]::Empty,
                [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        }
    } catch {}

    $UI.Window.Add_StateChanged({
        # Run after Windows has applied the new window rect.
        [void]$UI.Window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background,
            [action]{ Update-BasetuneMaximizedState })
    })

    try {
        # Policy names: TextBlock with TextTrimming and its own tooltip. The
        # lists recycle their rows, so the tooltip text is set from the
        # current Text when it opens (a recycled row could show the name it
        # had before).
        [System.Windows.EventManager]::RegisterClassHandler([System.Windows.Controls.TextBlock],
            [System.Windows.FrameworkElement]::ToolTipOpeningEvent,
            [System.Windows.Controls.ToolTipEventHandler]{
                param($sender, $e)
                try {
                    if ($sender.TextTrimming -eq 'None') { return }
                    if (Test-BasetuneTextTrimmed $sender) { $sender.ToolTip = $sender.Text }
                    else { $e.Handled = $true }
                } catch {}
            })
        # Tenant dropdowns: check the text of the selected item in the template.
        [System.Windows.EventManager]::RegisterClassHandler([System.Windows.Controls.ComboBox],
            [System.Windows.FrameworkElement]::ToolTipOpeningEvent,
            [System.Windows.Controls.ToolTipEventHandler]{
                param($sender, $e)
                try {
                    $cp = $sender.Template.FindName('content', $sender)
                    $tb = if ($cp -and [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($cp) -gt 0) {
                        [System.Windows.Media.VisualTreeHelper]::GetChild($cp, 0) } else { $null }
                    if ($tb -is [System.Windows.Controls.TextBlock] -and -not (Test-BasetuneTextTrimmed $tb)) { $e.Handled = $true }
                } catch {}
            })
    } catch {}

    # Windows 11: rounded corners for the own frame (DWMWA_WINDOW_CORNER_PREFERENCE
    # = 33, DWMWCP_ROUND = 2). Ignored on Windows 10.
    $UI.Window.Add_SourceInitialized({
        try {
            if ('Basetune.DwmTheme' -as [type]) {
                $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($UI.Window).Handle
                $round = 2
                [void][Basetune.DwmTheme]::DwmSetWindowAttribute($hwnd, 33, [ref]$round, 4)
            }
        } catch {}
    })

    # No undo on the log view (RichTextBox): its undo stack of thousands of
    # appended lines costs 50-200 MB that the 10k-line trim cannot free.
    # Must be set BEFORE any text is appended.
    $UI.txtLog.IsUndoEnabled = $false

    # Calm scrolling for the log (line by line, collapsed and expanded) and
    # both policy lists (one row per notch); see Set-SlowScroll.
    Set-SlowScroll -Element $UI.txtLog -PerLine -LinePx 18

    # ── Open / close the log ─────────────────────────────────────────────────────
    # Expanded, the log (txtLog, 7 lines) is in bdLog at the top of the actions
    # card, above the button strip (a line, sepLog, between them); the policy
    # lists above get shorter. Collapsed, the same RichTextBox moves into
    # bdLogLine, left of the buttons in the strip, and shows its last line
    # there (colours, links and the busy dots stay, it is the same control);
    # bdLog and sepLog are hidden, so the card is one strip high. The chevron
    # button right of Options switches (Set-LogCollapsed). Collapsed at start,
    # the policy lists get the space; errors do not expand it (an ERROR line
    # is red, also as the only line shown).
    $AppState.logCollapsed  = $false
    Set-LogCollapsed $true

    if ($UI.btnToggleLog) {
        $UI.btnToggleLog.Add_Click({ Set-LogCollapsed (-not $AppState.logCollapsed) })
    }

    # Resize the expanded log by dragging its top edge (thumbLogResize): the
    # mouse position against the window, not the Thumb's own deltas (the Thumb
    # moves up with the top of the log while it grows). Whole lines only.
    if ($UI.thumbLogResize) {
        $UI.thumbLogResize.Add_DragStarted({
            $AppState.logDragStartY      = [System.Windows.Input.Mouse]::GetPosition($UI.Window).Y
            $AppState.logDragStartHeight = $UI.txtLog.ActualHeight
        })
        $UI.thumbLogResize.Add_DragDelta({
            if ($null -eq $AppState.logDragStartY) { return }
            $y = [System.Windows.Input.Mouse]::GetPosition($UI.Window).Y
            $h = $AppState.logDragStartHeight + ($AppState.logDragStartY - $y)
            $lines = [int][math]::Round(($h - $script:LogPadding) / $script:LogLineHeight)
            $lines = [math]::Min([math]::Max(2, $lines), (Get-LogMaxLines))
            $AppState.logLines = $lines
            Set-LogLines $lines
        })
        $UI.thumbLogResize.Add_DragCompleted({ $AppState.logDragStartY = $null })
    }
    # Window resized: keep the expanded log within 50/50 (or give back the
    # chosen lines when there is room again). On the window too: a squeezed
    # policy card may not change size any more.
    foreach ($el in $UI.cardSource, $UI.Window) {
        $el.Add_SizeChanged({
            if (-not $AppState.logCollapsed -and $null -eq $AppState.logDragStartY) { Set-LogLines $AppState.logLines }
        })
    }
    # The log icon left of the log line: opens Basetune.log (as the "See
    # Basetune.log" links in the log).
    if ($UI.btnOpenLog) {
        $UI.btnOpenLog.Add_Click({ if ($AppState.logFile) { Open-UILogPath -Path $AppState.logFile -Kind 'Log' } })
    }

    # ── Action buttons: fixed width, icon only when narrow ───────────────────────
    # Compare, View Report and View Details have one width
    # (StripActionWidth) and sit right in the strip, the log line takes the
    # rest. When the labelled buttons would reach past the left edge of the
    # target card (Set-StripMode), the labels go (StripLabelVisibility) and
    # the buttons get the width of an icon segment; their tooltip (always set,
    # XAML) names them.
    # DynamicResource in Window.Resources, so the Cancel content of
    # Compare (New-ButtonContent) follows too.
    if ($UI.cardActions) {
        foreach ($b in $UI.btnCompare, $UI.btnOpenReport, $UI.btnViewDetails) {
            [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($b, $true)
        }
        $AppState.stripNarrow = $null
        Set-StripMode
        # No GetNewClosure: the handler runs in this module's scope ($UI,
        # $AppState, Set-StripMode).
        $UI.cardActions.Add_SizeChanged({ Set-StripMode })
    }
    # Policy lists: whole rows (3 per mouse notch), never half a row at the top.
    Set-SlowScroll -Element $UI.lstSource -PerItem -Lines 1
    Set-SlowScroll -Element $UI.lstTarget -PerItem -Lines 1

    # Arrow keys + Space in the policy lists (see Enable-PolicyListKeys).
    Enable-PolicyListKeys -List $UI.lstSource
    Enable-PolicyListKeys -List $UI.lstTarget
    # Only whole lines visible in the policy lists (see Enable-WholeLineList).
    Enable-WholeLineList -List $UI.lstSource
    Enable-WholeLineList -List $UI.lstTarget
}

Export-ModuleMember -Function @(
    'Resize-BasetuneWindowToScreen',
    'Update-BasetuneMaximizedState',
    'Test-BasetuneTextTrimmed',
    'Set-LogToggleRotation',
    'Initialize-BasetuneWindow'
)
